{-# LANGUAGE TypeApplications #-}

module Products.Autopilot.Runner where

import qualified Control.Exception as E
import Control.Monad (filterM, forM_, forever, when)
import qualified Control.Monad.Catch as MC
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import Core.Config (Config (..))
import Core.Environment (AppState (..), DBEnv, Flow, MonadFlow, forkFlow, getConfig, getDBEnv, logError, logInfo, logWarning, runFlow)
import Core.Logging (logInfoIO, logWarningIO)
import Core.Types.Time (threadDelaySec)
import Data.Aeson (object, toJSON, (.=))
import Data.List (sortBy)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Ord (Down (..), comparing)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Products.Autopilot.EventLog (logStatusUpdated, logTrafficUpdatedWithMessage)
import qualified Control.Concurrent as CC
import Products.Autopilot.K8s.Deployment (buildScaleNamedDeploymentCommand, getDeploymentReplicaStatus)
import Products.Autopilot.K8s.Execute (runCmd)
import Products.Autopilot.K8s.VirtualService (applyVirtualServiceRollout, getPrimarySubsetFromVirtualService)
import Products.Autopilot.Notifications (notifyPodsScaledDown, notifyReleaseAborted)
import Products.Autopilot.Queries.ProductService (getProductCluster, getProductVsLockedBy, getProductsByNamesAndClusters, releaseExpiredVsLocks)
import Products.Autopilot.Queries.ReleaseTracker
import Products.Autopilot.RuntimeConfig (getPodsScaleDownDelayFromConfig, getReleaseWatchDelay, isMultiReleasePerProduct)
import Products.Autopilot.Types
import qualified Products.Autopilot.Types as NT
import Products.Autopilot.Types.Storage.Schema (DeploymentConfig, dcAppGroup)
import Products.Autopilot.Types.Target (TargetState (..))
import Products.Autopilot.Types.Target.Kubernetes (K8sDeploymentState (..), K8sReleaseContext (..), PodsScaleDownStatus (..))
import qualified Products.Autopilot.Types.Target.Kubernetes as K8s
import Products.Autopilot.Workflow.Factory (executeReleaseWorkflow)
import Products.Autopilot.Workflow.Types (ReleaseState (..), WorkFlowError)
import Prelude

-- ============================================================================
-- Runner Entry Point
-- ============================================================================

{- | Full runner lifecycle: synchronous startup recovery then the polling
loop. Used by the standalone @RUNNER@ mode. The @SERVER@ mode in
"Main" calls 'runnerStartupRecovery' and 'runnerPollLoop' separately so
that startup recovery finishes before the HTTP port is bound — this
closes the CRITICAL race (task #35 FIX 1) where concurrent HTTP writes
could be silently clobbered by a stale rollback sweep (race-hunter #29).
-}
runnerLoop :: AppState -> IO ()
runnerLoop st = do
    runnerStartupRecovery st
    runnerPollLoop st

{- | Synchronous startup recovery. Must run BEFORE the HTTP server binds
its port, otherwise user-initiated state changes (abort, revert) can
land in parallel with these sweeps and get overwritten by their stale
snapshots. See #35 FIX 1 for the full race description.

This function performs two recovery actions:

  1. 'rollbackInProgressOnStartup' — drives any INPROGRESS/PAUSED/
     REVERTING releases to a terminal state (ABORTED/REVERTED) because
     their workflow threads were lost when the server died.
  2. 'releaseExpiredVsLocksOnStartup' — clears any orphaned VS locks
     whose timestamp is older than @lock_expiry_delay_minutes@. Covers
     the case where a lock is held but no one tries to acquire it (so
     the inline expiry check inside 'tryAcquireVsLock' never runs),
     leaving an orphaned lock visible to 'isEligibleToRun' and blocking
     release dispatch.
-}
runnerStartupRecovery :: AppState -> IO ()
runnerStartupRecovery st = do
    runFlow st rollbackInProgressOnStartup
    runFlow st releaseExpiredVsLocksOnStartup

{- | Forever poll loop. Picks CREATED trackers, handles aborting releases,
schedules scale-downs. Safe to run concurrently with the HTTP server.
-}
runnerPollLoop :: AppState -> IO ()
runnerPollLoop st = runFlow st loop

{- | Release any VS lock older than the configured expiry. Runs once at
startup; tryAcquireVsLock also treats stale locks as released so new
edit attempts unblock themselves without needing this sweep to run first.
-}
releaseExpiredVsLocksOnStartup :: Flow ()
releaseExpiredVsLocksOnStartup = do
    n <- releaseExpiredVsLocks
    if n == 0
        then logInfo "[STARTUP] No expired VS locks to release"
        else logInfo $ "[STARTUP] Released " <> T.pack (show n) <> " expired VS lock(s)"

-- ============================================================================
-- Startup Rollback (Julia parity: rollbackReleaseInProgress)
-- ============================================================================

{- | Roll back all orphaned INPROGRESS/REVERTING releases on server startup.
Restores VS traffic to old version and marks as ABORTED.
PAUSED releases are intentionally NOT included — pause is a user state with
no in-flight kubectl work to recover, so a backend restart must not silently
abort them.
Julia reference: api/rollback/rollback.jl lines 10-75
-}
rollbackInProgressOnStartup :: Flow ()
rollbackInProgressOnStartup = do
    cfg <- getConfig
    orphaned <- findInProgressReleaseTrackers
    st <- getAppState
    let logEnv = loggerEnv st
    if null orphaned
        then logInfo "[STARTUP] No orphaned INPROGRESS releases found"
        else do
            logInfo $ "[STARTUP] Rolling back " <> T.pack (show (length orphaned)) <> " orphaned release(s)"
            forM_ orphaned $ \(rt, mts) -> do
                liftIO $ logInfoIO logEnv $ "[STARTUP] Rolling back: " <> releaseId rt <> " (status: " <> T.pack (show (NT.status rt)) <> ")"
                -- Restore VS traffic to old version (best-effort). For REVERTING releases
                -- this is also the correct recovery action: the revert was mid-flight, so
                -- pointing traffic back to old version completes the revert's intent.
                restoreVsTrafficOnFailure cfg rt mts
                now <- liftIO getCurrentTime
                -- Julia parity (api/rollback/rollback.jl:32-38): a REVERTING release
                -- whose thread was lost on restart should be treated as a *completed*
                -- revert (RECORDED in Julia), not a fresh abort. Our equivalent of the
                -- "revert finished" terminal state is `REVERTED` (see
                -- validateStatusTransition: REVERTING → REVERTED).
                -- Defense-in-depth CAS: Layer 1 (synchronous startup in Main.hs)
                -- guarantees no HTTP writes have landed yet, so in practice the
                -- status we snapshotted at findInProgressReleaseTrackers still
                -- matches. The CAS below guards against the RUNNER-mode path
                -- where this sweep runs alongside the server, and against any
                -- future regression that re-parallelises startup with HTTP.
                let oldStatus = NT.status rt
                    oldStatusText = releaseStatusToText oldStatus
                case oldStatus of
                    REVERTING -> do
                        let reverted = rt{status = REVERTED, endTime = Just now}
                        ok <- conditionalUpdateTracker reverted mts oldStatusText
                        if not ok
                            then
                                liftIO $
                                    logWarningIO logEnv $
                                        "[STARTUP] Skipping revert completion for "
                                            <> releaseId rt
                                            <> " — status changed under us during restoreVsTrafficOnFailure"
                            else do
                                logStatusUpdated reverted "Revert completed on startup recovery"
                                insertReleaseEvent
                                    (releaseId rt)
                                    "BUSINESS"
                                    "STARTUP_REVERT_COMPLETED"
                                    (toJSON ("Revert completed on startup recovery — VS traffic restored to old version" :: T.Text))
                    _ -> do
                        let aborted = rt{status = ABORTED, endTime = Just now}
                        ok <- conditionalUpdateTracker aborted mts oldStatusText
                        if not ok
                            then
                                liftIO $
                                    logWarningIO logEnv $
                                        "[STARTUP] Skipping rollback for "
                                            <> releaseId rt
                                            <> " — status changed under us during restoreVsTrafficOnFailure"
                            else do
                                -- Production parity (events.jl:251-286 rollbackEvent!):
                                -- BUSINESS / TRAFFIC_UPDATED with a message field on rollback.
                                let previousRollout = case rolloutHistory rt of
                                        [] -> 0
                                        xs -> historyRolloutPercent (last xs)
                                logTrafficUpdatedWithMessage aborted previousRollout "Rolling back traffic due to server restart"
                                insertReleaseEvent
                                    (releaseId rt)
                                    "BUSINESS"
                                    "STARTUP_ROLLBACK"
                                    (toJSON ("ABORTED due to server restart — VS traffic restored to old version" :: T.Text))
                                notifyReleaseAborted aborted
            logInfo "[STARTUP] Rollback complete"

-- ============================================================================
-- Main Poll Loop
-- ============================================================================

loop :: Flow ()
loop = forever $ do
    result <- MC.try @_ @E.SomeException iteration
    case result of
        Left e ->
            logError $
                "[RUNNER] Poll iteration failed (continuing): " <> T.pack (show e)
        Right () -> pure ()
    -- Always honour the poll delay, even after a failed iteration, so we
    -- don't spin-loop on a persistent error.
    pollDelay <- getReleaseWatchDelay
    threadDelaySec pollDelay
  where
    iteration = do
        cfg <- getConfig
        now <- liftIO getCurrentTime

        -- Step 1: Find runnable trackers (CREATED only — never INPROGRESS).
        -- conditionalUpdateTrackerRow provides atomic claim if two polls overlap.
        jobs <- findRunnableReleaseTrackers now
        ongoing <- findOngoingReleaseTrackers
        multiRelease <- isMultiReleasePerProduct
        -- Batch product lookup to collapse N+1 (one SELECT instead of one per job).
        let jobPairs =
                [ ( appGroup rt
                  , case mts of
                        Just (K8sState k8s) -> cluster (context k8s)
                        _ -> ""
                  )
                | (rt, mts) <- jobs
                ]
        products <- getProductsByNamesAndClusters jobPairs
        eligible <- filterM (isEligibleToRun products multiRelease ongoing) jobs

        -- Step 2: Pick jobs and fork each into a background thread for parallel execution
        let picked = pickJobs multiRelease eligible
        db <- getDBEnv
        forM_ picked $ \twt -> forkFlow (trigger db twt)

        -- Step 3: Handle aborting trackers
        abortingTrackers <- findAbortingReleaseTrackers
        forM_ abortingTrackers $ \(rt, mts) -> handleAbortingRelease cfg rt mts

        -- Step 4: Handle scale-down of old deployments after delay
        scaleDownDelay <- getPodsScaleDownDelayFromConfig
        completedTrackers <- findCompletedTrackersForScaleDown now scaleDownDelay
        forM_ completedTrackers $ \twt -> scaleDownOldDeployment cfg twt

-- | Get the full AppState from the Flow monad (for passing to forkIO threads)
getAppState :: Flow AppState
getAppState = ask

-- ============================================================================
-- Eligibility & Job Selection
-- ============================================================================

isEligibleToRun :: (MonadFlow m) => [DeploymentConfig] -> Bool -> [TrackerWithTarget] -> TrackerWithTarget -> m Bool
isEligibleToRun products multiRelease ongoing (rt, mts) = case category rt of
    BackendService -> k8sEligible
    BackendScheduler -> k8sEligible
    BackendCronJob -> k8sEligible
    BackendJob -> k8sEligible
    BackendConfig -> pure True
    MobileAppAndroid -> pure True
    MobileAppIOS -> pure True
    WebApplication -> pure True
    Infrastructure -> pure True
    VSEdit -> pure True
  where
    k8sEligible = do
        let k8sCluster = case mts of
                Just (K8sState k8s) -> cluster (context k8s)
                _ -> ""
            sameName = filter (\dc -> dcAppGroup dc == appGroup rt) products
            -- Mirror findProductByNameAndCluster semantics: prefer exact cluster
            -- match, fall back to first row with matching name when cluster is
            -- empty or no exact match exists.
            p = case k8sCluster of
                "" -> firstOf sameName
                _ -> case filter (\q -> getProductCluster q == k8sCluster) sameName of
                    (q : _) -> Just q
                    [] -> firstOf sameName
            firstOf [] = Nothing
            firstOf (x : _) = Just x
        let vsLocked = maybe False (isJust . getProductVsLockedBy) p
            -- Block same-service concurrent releases (always, even with multi_release_per_product)
            hasOngoingSameService = any (\(o, _) -> appGroup o == appGroup rt && service o == service rt && env o == env rt) ongoing
            -- Block same-appGroup when multi_release_per_product is off
            hasOngoingSameProduct = any (\(o, _) -> appGroup o == appGroup rt && env o == env rt) ongoing
        pure (not vsLocked && not hasOngoingSameService && (multiRelease || not hasOngoingSameProduct))

pickJobs :: Bool -> [TrackerWithTarget] -> [TrackerWithTarget]
pickJobs multi jobs
    | multi = jobs
    | otherwise = go Map.empty (sortByPriority jobs)
  where
    go _ [] = []
    go counts ((rt, mts) : rest) =
        let key = appGroup rt <> ":" <> env rt
            picked = Map.findWithDefault (0 :: Int) key counts
         in if picked >= 1
                then go counts rest
                else (rt, mts) : go (Map.insert key (picked + 1) counts) rest

sortByPriority :: [TrackerWithTarget] -> [TrackerWithTarget]
sortByPriority = sortBy (comparing (Down . priority . fst))

-- ============================================================================
-- Trigger — Only for CREATED trackers
-- ============================================================================

{- | Trigger a release — only called for CREATED trackers.
Atomically claims via conditionalUpdateTrackerRow (prevents double-pick).
-}
trigger :: DBEnv -> TrackerWithTarget -> Flow ()
trigger _db (rt, mts) = do
    cfg <- getConfig
    -- Version validation
    versionOk <- liftIO $ validateRunningVersion cfg rt mts
    case versionOk of
        Just mismatchMsg -> do
            let discarded = rt{status = DISCARDED}
            insertReleaseTracker discarded mts
            insertReleaseEvent
                (releaseId rt)
                "BUSINESS"
                "VERSION_MISMATCH"
                (object ["message" .= mismatchMsg, "trackerOldVersion" .= NT.oldVersion rt])
            notifyReleaseAborted discarded
        Nothing -> do
            now <- liftIO getCurrentTime
            -- Atomically claim: CREATED → INPROGRESS
            let rtNew = rt{status = INPROGRESS, startTime = Just now}
                row = toRow now now rtNew mts
            claimed <- conditionalUpdateTrackerRow row "CREATED"
            if not claimed
                then logInfo $ "[RUNNER] Release " <> releaseId rt <> " already claimed, skipping"
                else do
                    insertReleaseEvent (releaseId rt) "BUSINESS" "RUNNER_PICKED" (toJSON rt)
                    result <- dispatchWorkflow rtNew mts
                    case result of
                        Left err -> do
                            cfg' <- getConfig
                            -- Re-read tracker — user may have set ABORTING while workflow ran
                            freshM <- findReleaseTracker (releaseId rt)
                            let currentStatus' = case freshM of
                                    Just (freshRT, _) -> status freshRT
                                    Nothing -> status rtNew
                                isUserAbort = currentStatus' == ABORTING || currentStatus' == USER_ABORTED
                            if isUserAbort
                                then do
                                    -- Defer to handleAbortingRelease (Step 3 of poll loop)
                                    logInfo $ "[RUNNER] Workflow exited due to user abort — deferring: " <> releaseId rt
                                    insertReleaseEvent (releaseId rt) "BUSINESS" "WORKFLOW_ABORT_EXIT" (toJSON (show err))
                                else do
                                    endNow <- liftIO getCurrentTime
                                    let abortedTracker = rtNew{status = ABORTED, releaseWFStatus = ROLLING_BACK, endTime = Just endNow}
                                    insertReleaseTracker abortedTracker mts
                                    insertReleaseEvent (releaseId rt) "BUSINESS" "FAILED" (toJSON (show err))
                                    restoreVsTrafficOnFailure cfg' rt mts
                                    notifyReleaseAborted abortedTracker
                        Right _ -> do
                            -- The workflow persists state via persistWorkflowState in each cprV2
                            -- stage, but the Recorded monad's bind may short-circuit the final
                            -- stage's persist. Re-read from DB to verify, and force COMPLETED if
                            -- the workflow reported success but the status wasn't persisted.
                            freshM <- findReleaseTracker (releaseId rt)
                            case freshM of
                                Just (freshRT, freshTS)
                                    | NT.status freshRT /= COMPLETED -> do
                                        now' <- liftIO getCurrentTime
                                        let completed = freshRT{NT.status = COMPLETED, NT.endTime = Just now'}
                                        insertReleaseTracker completed freshTS
                                _ -> pure ()
                            insertReleaseEvent (releaseId rt) "BUSINESS" "COMPLETED" (toJSON ("success" :: String))

dispatchWorkflow :: ReleaseTracker -> Maybe TargetState -> Flow (Either WorkFlowError ReleaseState)
dispatchWorkflow rt mts = do
    let initialState = ReleaseState rt mts Nothing
    executeReleaseWorkflow initialState

-- ============================================================================
-- Version Validation
-- ============================================================================

validateRunningVersion :: Config -> ReleaseTracker -> Maybe TargetState -> IO (Maybe T.Text)
validateRunningVersion cfg rt mts = do
    case mts of
        Just (K8sState k8s) -> do
            let ctx = context k8s
                ns = namespace ctx
                vsName' = virtualServiceName ctx
                svcHost = serviceName ctx
                trackerOldVer = NT.oldVersion rt
                isNewSvc = newService k8s
            if isNewSvc || T.null trackerOldVer || T.toLower trackerOldVer == "unknown" || trackerOldVer == "new"
                then pure Nothing
                else do
                    result <- getPrimarySubsetFromVirtualService cfg ns vsName' svcHost
                    case result of
                        -- Bug fix (round 7 / G7): Julia DISCARDs on VS lookup
                        -- failure (service.jl:324) — silently treating an
                        -- unknown VS state as "OK to proceed" can pick up a
                        -- release that targets a deployment whose live state
                        -- is unknown, leading to traffic shifts in the wrong
                        -- direction. Surface the error so the runner discards.
                        Left err ->
                            pure $
                                Just $
                                    "Could not read VirtualService " <> vsName' <> " in " <> ns <> ": " <> T.pack (show err)
                        Right Nothing ->
                            pure $
                                Just $
                                    "VirtualService " <> vsName' <> " has no primary subset for host " <> svcHost
                        Right (Just runningVersion) ->
                            if runningVersion == trackerOldVer
                                then pure Nothing
                                else
                                    pure $
                                        Just $
                                            "Running version (" <> runningVersion <> ") does not match tracker oldVersion (" <> trackerOldVer <> ")"
        _ -> pure Nothing

-- ============================================================================
-- Failure Recovery: Restore VS Traffic
-- ============================================================================

{- | Restore traffic to the old version after a failed/orphaned release.

Order matters (round-7 audit + outage prevention):
  1. Check old deployment's current replica count.
  2. If 0 (someone manually scaled it down OR a previous COMPLETED release
     scaled it down legitimately), SCALE IT BACK UP first to a sensible
     count derived from the new deployment's current replicas (or default 1)
     and wait briefly for at least one pod to be ready.
  3. THEN flip the VS to point at oldVersion.
  4. Then scale the new deployment to 0.

Without step 2, restoring traffic to a 0-pod deployment would cause an
immediate 5xx outage on the very route the rollback is supposed to protect.
-}
restoreVsTrafficOnFailure :: Config -> ReleaseTracker -> Maybe TargetState -> Flow ()
restoreVsTrafficOnFailure cfg rt mts = do
    case mts of
        Just (K8sState k8s) -> do
            let ctx = context k8s
                oldVer = K8s.oldVersion ctx
                isNewSvc = newService k8s
            if isNewSvc || T.null oldVer || oldVer == "new" || oldVer == "unknown"
                then logInfo $ "[restoreVsTrafficOnFailure] Skipping VS restore for " <> releaseId rt <> " (new service or no old version)"
                else do
                    let newDepName = deploymentName ctx
                        ns = namespace ctx
                        oldDepName = serviceName ctx <> "-" <> oldVer

                    -- Step 1: probe old deployment's replica count
                    oldStatus <- liftIO $ getDeploymentReplicaStatus cfg ns oldDepName
                    let oldDesired = case oldStatus of
                            Right (_, _, d) -> d
                            Left _ -> 0
                    -- Probe new deployment so we can target a sensible replica count.
                    newStatus <- liftIO $ getDeploymentReplicaStatus cfg ns newDepName
                    let newDesired = case newStatus of
                            Right (_, _, d) -> d
                            Left _ -> 0
                        targetOldReplicas = max 1 (max oldDesired newDesired)

                    -- Step 2: scale OLD UP first if it's at 0 — never restore
                    -- traffic to a deployment with no pods.
                    when (oldDesired <= 0) $ do
                        logInfo $
                            "[restoreVsTrafficOnFailure] Old deployment "
                                <> oldDepName
                                <> " has 0 replicas — scaling UP to "
                                <> T.pack (show targetOldReplicas)
                                <> " before VS restore"
                        scaleUpRes <- liftIO $ runCmd (buildScaleNamedDeploymentCommand cfg ns oldDepName targetOldReplicas)
                        case scaleUpRes of
                            Left err -> logWarning $ "[restoreVsTrafficOnFailure] WARNING: scale-up of old failed: " <> T.pack (show err)
                            Right _ -> do
                                logInfo "[restoreVsTrafficOnFailure] Old deployment scale-up issued; waiting for first pod ready"
                                _ <- liftIO $ waitForFirstPodReady cfg ns oldDepName
                                pure ()
                        insertReleaseEvent
                            (releaseId rt)
                            "BUSINESS"
                            "OLD_DEPLOYMENT_SCALED_UP_FOR_ROLLBACK"
                            ( object
                                [ "oldDeployment" .= (oldDepName :: T.Text)
                                , "targetReplicas" .= targetOldReplicas
                                , "reason" .= ("Restoring traffic to a deployment that had 0 pods — scaling up first to avoid 5xx outage" :: T.Text)
                                ]
                            )

                    -- Step 3: now flip the VS
                    logInfo $ "[restoreVsTrafficOnFailure] Restoring VS traffic to old version for " <> releaseId rt
                    vsResult <- liftIO $ applyVirtualServiceRollout cfg ctx 100 0
                    case vsResult of
                        Left err -> logWarning $ "[restoreVsTrafficOnFailure] WARNING: Failed to restore VS: " <> T.pack (show err)
                        Right _ -> logInfo "[restoreVsTrafficOnFailure] VS traffic restored to old version"

                    -- Step 4: scale the new deployment to 0 (the failed one)
                    scaleResult <- liftIO $ runCmd (buildScaleNamedDeploymentCommand cfg ns newDepName 0)
                    case scaleResult of
                        Left err -> logWarning $ "[restoreVsTrafficOnFailure] WARNING: Failed to scale down new deployment: " <> T.pack (show err)
                        Right _ -> logInfo "[restoreVsTrafficOnFailure] New deployment scaled down to 0"

                    insertReleaseEvent
                        (releaseId rt)
                        "BUSINESS"
                        "VS_TRAFFIC_RESTORED"
                        ( object
                            [ "action" .= ("restore_on_failure" :: T.Text)
                            , "oldVersion" .= (oldVer :: T.Text)
                            , "newDeployment" .= (newDepName :: T.Text)
                            , "oldDesiredAtRestore" .= oldDesired
                            , "scaledOldUp" .= (oldDesired <= 0)
                            ]
                        )
        _ -> pure ()

{- | Best-effort wait for at least one ready pod on a deployment, capped at
~30s. Used by restoreVsTrafficOnFailure to bridge the gap after scaling
the old deployment back up before flipping the VS. Returns even on
timeout — the caller proceeds either way.
-}
waitForFirstPodReady :: Config -> T.Text -> T.Text -> IO ()
waitForFirstPodReady cfg ns depName = go (15 :: Int)
  where
    go 0 = pure ()
    go n = do
        r <- getDeploymentReplicaStatus cfg ns depName
        case r of
            Right (ready, _, _) | ready >= 1 -> pure ()
            _ -> do
                CC.threadDelay 2000000 -- 2s
                go (n - 1)

-- ============================================================================
-- Abort Handling
-- ============================================================================

handleAbortingRelease :: Config -> ReleaseTracker -> Maybe TargetState -> Flow ()
handleAbortingRelease cfg rt mts = do
    logInfo $ "[handleAbortingRelease] Processing abort for " <> releaseId rt
    restoreVsTrafficOnFailure cfg rt mts
    now <- liftIO getCurrentTime
    let aborted = rt{status = USER_ABORTED, endTime = Just now}
    insertReleaseTracker aborted mts
    -- Production parity (events.jl:251-286 rollbackEvent!):
    -- BUSINESS / TRAFFIC_UPDATED with a message field on rollback.
    let previousRollout = case rolloutHistory rt of
            [] -> 0
            xs -> historyRolloutPercent (last xs)
        oldVer = case mts of
            Just (K8sState k8s) -> K8s.oldVersion (context k8s)
            _ -> ""
    logTrafficUpdatedWithMessage aborted previousRollout ("Rolling back traffic to old version: " <> oldVer)
    insertReleaseEvent (releaseId rt) "BUSINESS" "ABORT_HANDLED" (toJSON ("User abort processed" :: String))
    notifyReleaseAborted aborted

-- ============================================================================
-- Scale-Down of Old Deployments After Delay
-- ============================================================================

{- | Scale down old deployment. Sends Slack notification only on success.

Race guard (#35 FIX 2): between the poll pick (which sees status=COMPLETED
and schedules this callback after the scale-down delay) and this function
firing, a user may have issued an immediate revert via the HTTP API. The
tracker's status in the DB will then be REVERTING, and the revert path
needs the old deployment pods still running — scaling them down here
would corrupt the revert.

Two defenses, matching race-hunter's HIGH-severity finding:

  Part A — re-read the tracker's status from DB before running the
  kubectl scale-down. If the status is no longer in the set
  @{COMPLETED, ABORTED, USER_ABORTED}@ (e.g. user reverted, admin edit),
  skip the entire scale-down. Prevents kubectl-level corruption.

  Part B — CAS the final DB write of the scale-down flag against the
  status we saw at poll-pick time. If anything changed between re-read
  and CAS (narrow window but real), the blind insert is suppressed so
  we don't overwrite the user's concurrent edit.
-}
scaleDownOldDeployment :: Config -> TrackerWithTarget -> Flow ()
scaleDownOldDeployment cfg (rt, mts) = do
    case mts of
        Just (K8sState k8s) -> do
            -- Part A — re-verify the tracker is still scale-down-eligible.
            freshM <- findReleaseTracker (releaseId rt)
            case freshM of
                Just (freshRT, _)
                    | NT.status freshRT `elem` [COMPLETED, ABORTED, USER_ABORTED] -> do
                        let ctx = context k8s
                            oldVer = K8s.oldVersion ctx
                            svcName = serviceName ctx
                            ns = namespace ctx
                            oldDepName = svcName <> "-" <> oldVer
                        if T.null oldVer || oldVer == "new" || oldVer == "unknown"
                            then pure ()
                            else do
                                logInfo $ "[scaleDownOldDeployment] Scaling down old deployment: " <> oldDepName <> " for release " <> releaseId rt
                                result <- liftIO $ runCmd (buildScaleNamedDeploymentCommand cfg ns oldDepName 0)
                                case result of
                                    Left err -> do
                                        -- Bug fix (round 6 / Julia parity): on kubectl failure
                                        -- KEEP the tracker in ScaleDownScheduled state so the
                                        -- next runner poll retries. Previously we marked it
                                        -- Completed regardless and the failure was silently
                                        -- dropped — leaving stale old pods running forever.
                                        -- Julia: watcher.jl:433-450 podsFailureHandler.
                                        logWarning $ "[scaleDownOldDeployment] FAILED: " <> T.pack (show err) <> " — keeping ScaleDownScheduled for retry on next poll"
                                        let retryCtx = ctx{podsScaleDownStatus = Just ScaleDownScheduled}
                                            retryK8s = k8s{context = retryCtx}
                                            retryMts = Just (K8sState retryK8s)
                                        _ <- conditionalUpdateTracker rt retryMts (releaseStatusToText (NT.status rt))
                                        insertReleaseEvent
                                            (releaseId rt)
                                            "BUSINESS"
                                            "SCALE_DOWN_FAILED"
                                            (object ["oldDeployment" .= (oldDepName :: T.Text), "error" .= T.pack (show err)])
                                    Right _ -> do
                                        logInfo "[scaleDownOldDeployment] Old deployment scaled down successfully"
                                        notifyPodsScaledDown rt oldVer
                                        let updatedCtx = ctx{podsScaleDownStatus = Just ScaleDownCompleted}
                                            updatedK8s = k8s{context = updatedCtx}
                                            updatedMts = Just (K8sState updatedK8s)
                                        ok <- conditionalUpdateTracker rt updatedMts (releaseStatusToText (NT.status rt))
                                        if not ok
                                            then
                                                logWarning $
                                                    "[scaleDownOldDeployment] Status changed under us; not persisting scale-down flag for "
                                                        <> releaseId rt
                                            else
                                                insertReleaseEvent
                                                    (releaseId rt)
                                                    "BUSINESS"
                                                    "OLD_PODS_SCALED_DOWN"
                                                    (object ["oldDeployment" .= (oldDepName :: T.Text), "namespace" .= (ns :: T.Text)])
                _ ->
                    logWarning $
                        "[scaleDownOldDeployment] Skipping "
                            <> releaseId rt
                            <> " — status no longer scale-down-eligible (was "
                            <> T.pack (show (NT.status rt))
                            <> ", now "
                            <> T.pack (show (fmap (NT.status . fst) freshM))
                            <> ")"
        _ -> pure ()

-- force rebuild 1775474191
