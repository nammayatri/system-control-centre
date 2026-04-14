{-# LANGUAGE TypeApplications #-}

module Products.Autopilot.Runner where

import qualified Control.Concurrent as CC
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
import Products.Autopilot.K8s.Deployment (buildScaleNamedDeploymentCommand, getDeploymentReplicaStatus)
import Products.Autopilot.K8s.Execute (runCmd)
import Products.Autopilot.K8s.HPA (buildDeleteHpaCommand, buildPatchHpaReplicasCommand, getHpaMinMax)
import Products.Autopilot.K8s.VirtualService (applyVirtualServiceRollout, getPrimarySubsetFromVirtualService)
import Products.Autopilot.Notifications (notifyPodsScaledDown, notifyReleaseAborted)
import Products.Autopilot.Queries.ProductService (getProductCluster, getProductVsLockedBy, getProductsByNamesAndClusters, releaseExpiredVsLocks, releaseService)
import Products.Autopilot.Queries.ReleaseTracker
import Products.Autopilot.RuntimeConfig (getAutoCompleteVsTrackerMinutes, getDiscardingSweepMinutes, getHpaDefaultMinPods, getMaxCleanupRetries, getPodsScaleDownDelayFromConfig, getReleaseWatchDelay, isMultiReleasePerProduct)
import Products.Autopilot.Types
import qualified Products.Autopilot.Types as NT
import Products.Autopilot.Types.Storage.Schema (DeploymentConfig, dcAppGroup)
import Products.Autopilot.Types.Target (TargetState (..))
import Products.Autopilot.Types.Target.Kubernetes (K8sDeploymentState (..), K8sReleaseContext (..), PodsScaleDownStatus (..))
import qualified Products.Autopilot.Types.Target.Kubernetes as K8s
import Products.Autopilot.Workflow.Factory (executeReleaseWorkflow)
import Products.Autopilot.Workflow.Types (ReleaseState (..), WorkFlowError (..))
import Prelude

{- | Runner lifecycle: synchronous startup recovery, then poll loop.
SERVER mode calls the two phases separately so recovery finishes before
the HTTP port binds — otherwise concurrent HTTP writes can be clobbered
by the stale rollback sweep.
-}
runnerLoop :: AppState -> IO ()
runnerLoop st = do
    runnerStartupRecovery st
    runnerPollLoop st

{- | Startup recovery. Must run BEFORE the HTTP port binds, or concurrent
HTTP writes race with the sweeps. Performs:

  1. 'rollbackInProgressOnStartup' — drives orphaned INPROGRESS/REVERTING
     releases to a terminal state (their workflow threads died with the server).
  2. 'releaseExpiredVsLocksOnStartup' — clears orphaned VS locks older than
     @lock_expiry_delay_minutes@; covers locks nobody else tries to acquire.
-}
runnerStartupRecovery :: AppState -> IO ()
runnerStartupRecovery st = do
    runFlow st rollbackInProgressOnStartup
    -- Reset leaked-deployment scale-downs stuck SCALE_DOWN_INPROGRESS (worker
    -- crashed mid-scale-down) so the next poll retries.
    runFlow st $ do
        n <- resetStuckScaleDownInProgress
        when (n > 0) $
            logInfo $
                "[STARTUP] Reset "
                    <> T.pack (show n)
                    <> " tracker(s) stuck in SCALE_DOWN_INPROGRESS → SCALE_DOWN_SCHEDULED"
    runFlow st releaseExpiredVsLocksOnStartup

-- | Forever poll loop. Safe to run concurrently with the HTTP server.
runnerPollLoop :: AppState -> IO ()
runnerPollLoop st = runFlow st loop

{- | Release VS locks older than the configured expiry. tryAcquireVsLock also
treats stale locks as released, so this sweep is belt-and-braces at startup.
-}
releaseExpiredVsLocksOnStartup :: Flow ()
releaseExpiredVsLocksOnStartup = do
    n <- releaseExpiredVsLocks
    if n == 0
        then logInfo "[STARTUP] No expired VS locks to release"
        else logInfo $ "[STARTUP] Released " <> T.pack (show n) <> " expired VS lock(s)"

{- | Roll back orphaned INPROGRESS/REVERTING releases on startup: restore VS
traffic and mark ABORTED. PAUSED is NOT included — pause is a user state
with no in-flight kubectl work to recover.
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
                                releaseService (NT.appGroup reverted) (NT.service reverted)
                    _ -> do
                        let aborted = rt{status = ABORTED, endTime = Just now}
                        -- Julia parity: persist cleanup marker before flipping
                        -- status so the poll worker has something to sweep even
                        -- if restoreVsTrafficOnFailure's scale-down failed above.
                        scheduleNewDeploymentCleanup aborted mts
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
                                releaseService (NT.appGroup aborted) (NT.service aborted)
            logInfo "[STARTUP] Rollback complete"

-- ============================================================================
-- Main Poll Loop
-- ============================================================================

loop :: Flow ()
loop = forever $ do
    result <- MC.try @_ @E.SomeException $ do
        iteration
        -- Poll delay inside the try so async exceptions during sleep don't
        -- escape `forever`. Without this, AsyncCancelled raised in threadDelay
        -- (e.g. from concurrently_ cancellation signals) would kill the loop.
        pollDelay <- getReleaseWatchDelay
        threadDelaySec pollDelay
    case result of
        Left e ->
            logError $
                "[RUNNER] Poll iteration failed (continuing): " <> T.pack (show e)
        Right () -> pure ()
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

        -- Step 5 (Julia parity): Handle scale-down of LEAKED NEW deployments.
        -- If the workflow created a new deployment but crashed / was killed
        -- before reaching restoreVsTrafficOnFailure, the new deployment is
        -- left at full replicas. Mirrors Julia's scaleDownPodsInProgress +
        -- watcher poll pattern: the abort paths mark the tracker with
        -- cleanupTargetDeployment/cleanupStatus=SCALE_DOWN_SCHEDULED and
        -- this worker sweeps them idempotently.
        leakedTrackers <- findLeakedNewDeploymentTrackers now
        forM_ leakedTrackers $ \twt -> scaleDownLeakedNewDeployment cfg twt

        -- Step 6 (Julia parity, release/watcher.jl filterUsingScheduleTime!):
        -- Sweep stale-DISCARDING trackers. A discard request transitions a
        -- tracker to DISCARDING and triggers cleanup; if the cleanup itself
        -- crashes or stalls, the tracker stays DISCARDING forever and shows
        -- up in operator dashboards as "still working". The sweep flips any
        -- DISCARDING tracker older than @discarding_sweep_minutes@ to
        -- DISCARDED so the audit trail closes cleanly.
        sweepAge <- getDiscardingSweepMinutes
        sweptCount <- sweepStaleDiscardingTrackers sweepAge
        when (sweptCount > 0) $
            logInfo $
                "[RUNNER] Sweep flipped " <> T.pack (show sweptCount) <> " stale DISCARDING tracker(s) → DISCARDED"

        -- Step 7 (Julia parity, release/watcher.jl:158-160): Sweep VS-edit
        -- trackers stuck in APPLIED → auto-flip to COMPLETED after the
        -- @auto_complete_vs_tracker_minutes@ delay. Without this an APPLIED
        -- VS tracker stays in operator's "in-flight" list forever because
        -- nothing else transitions APPLIED → COMPLETED.
        vsAutoCompleteAge <- getAutoCompleteVsTrackerMinutes
        vsAutoCount <- sweepAutoCompleteVsTrackers vsAutoCompleteAge
        when (vsAutoCount > 0) $
            logInfo $
                "[RUNNER] Auto-completed " <> T.pack (show vsAutoCount) <> " stale VS tracker(s) → COMPLETED"

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
    BackendConfig -> pure True
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
trigger _db (rtStale, mtsStale) = do
    cfg <- getConfig
    -- Bug fix (Slack thread race): the (rt, mts) we got from
    -- findRunnableReleaseTrackers is a snapshot taken BEFORE the
    -- createReleaseH handler's notifyReleaseCreated saved slack_thread_ts
    -- via a separate UPDATE statement. If we proceed with the stale
    -- snapshot, the DELETE+INSERT inside conditionalUpdateTrackerRow
    -- (insertReleaseTrackerRow at line 820 of Queries.ReleaseTracker.hs)
    -- will overwrite the just-saved slack_thread_ts back to NULL,
    -- causing every subsequent notification (Approved, INPROGRESS,
    -- TRAFFIC_UPDATED, COMPLETED) to post as a fresh top-level Slack
    -- message instead of replying in-thread.
    -- Re-read the tracker once here so we pick up any column writes
    -- (slack_thread_ts, env_override_data, etc.) that landed between
    -- the runner poll and now.
    fresh <- findReleaseTracker (releaseId rtStale)
    let (rt, mts) = case fresh of
            Just (freshRt, freshMts) -> (freshRt, freshMts)
            Nothing -> (rtStale, mtsStale)
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
                    -- Catch IO exceptions thrown via `liftIO $ throwIO $
                    -- WorkflowError ...` from inside the workflow. The
                    -- ExceptT inside `executeReleaseWorkflow` only catches
                    -- typed `WorkFlowError` *returned* via Left — IO
                    -- exceptions escape it entirely. Without this catch the
                    -- exception bubbles up to forkFlow's `try @SomeException`
                    -- safety net which silently swallows it, leaving the
                    -- tracker dangling at INPROGRESS forever. Translating to
                    -- Left funnels into the existing abort+cleanup branch.
                    rawResult <- MC.try @_ @E.SomeException (dispatchWorkflow rtNew mts)
                    let result = case rawResult of
                            Right r -> r
                            Left ex -> Left (DomainError (show ex))
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
                                    -- Round 8 audit C1: CAS against INPROGRESS so a user
                                    -- pause/abort/discard that landed mid-workflow isn't
                                    -- silently overwritten by the workflow's failure path.
                                    casOk <- conditionalUpdateTracker abortedTracker mts (releaseStatusToText INPROGRESS)
                                    if not casOk
                                        then logWarning $ "[RUNNER] Workflow failed but tracker " <> releaseId rt <> " was concurrently modified — leaving as-is, the user state wins"
                                        else do
                                            insertReleaseEvent (releaseId rt) "BUSINESS" "FAILED" (toJSON (show err))
                                            -- Julia parity (release/watcher.jl:342-521 per-type
                                            -- failure handlers): VS traffic restore is meaningful
                                            -- only for categories that actually flip a VS during
                                            -- rollout. Schedulers, CronJobs, Jobs, and BackendConfig
                                            -- have no VirtualService to restore — calling kubectl
                                            -- on a non-existent VS would just emit a confusing
                                            -- "VS not found" error and waste a kubectl roundtrip.
                                            -- Dispatch by category to match Julia's per-type
                                            -- failure handlers. The leaked-deployment cleanup
                                            -- (scheduleNewDeploymentCleanup) and Slack abort
                                            -- notification still run for every category.
                                            case category rt of
                                                BackendService -> restoreVsTrafficOnFailure cfg' rt mts
                                                _ ->
                                                    logInfo $
                                                        "[RUNNER] Skipping VS restore for non-BackendService category "
                                                            <> T.pack (show (category rt))
                                                            <> " (no VS to restore)"
                                            -- Julia parity: mark for later poll-driven
                                            -- cleanup in case restoreVsTrafficOnFailure's
                                            -- kubectl scale-down itself failed.
                                            scheduleNewDeploymentCleanup abortedTracker mts
                                            notifyReleaseAborted abortedTracker
                                            releaseService (NT.appGroup abortedTracker) (NT.service abortedTracker)
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
                                        -- Round 8 audit H1: CAS against the snapshot we just
                                        -- read. If a parallel immediateRevert / abort flipped
                                        -- the row between findReleaseTracker and now, leave
                                        -- their status alone instead of clobbering it with
                                        -- COMPLETED.
                                        _ <- conditionalUpdateTracker completed freshTS (releaseStatusToText (NT.status freshRT))
                                        pure ()
                                _ -> pure ()
                            insertReleaseEvent (releaseId rt) "BUSINESS" "COMPLETED" (toJSON ("success" :: String))
                            releaseService (NT.appGroup rt) (NT.service rt)

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
            -- Skip VS-based version validation for products without a
            -- VirtualService (BackendScheduler, future non-VS products).
            -- The gate is `vsName' is empty` rather than a category check
            -- so any product type with no VS configured falls through
            -- cleanly without re-touching this code.
            if isNewSvc
                || T.null vsName'
                || T.null trackerOldVer
                || T.toLower trackerOldVer == "unknown"
                || trackerOldVer == "new"
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

                    -- Step 3: now flip the VS — but only if there IS one.
                    -- Schedulers (and any future non-VS product) have an empty
                    -- vsName; calling kubectl with that produces a noisy
                    -- "resource name may not be empty" error. The deployment-
                    -- side recovery (steps 1-2 + step 4 below) is still the
                    -- correct rollback action for a scheduler — the scaling
                    -- restores worker capacity, which is all schedulers care
                    -- about.
                    let vsName' = virtualServiceName ctx
                    if T.null vsName'
                        then logInfo $ "[restoreVsTrafficOnFailure] No VS configured for " <> releaseId rt <> " (scheduler / non-VS product); skipping VS flip"
                        else do
                            logInfo $ "[restoreVsTrafficOnFailure] Restoring VS traffic to old version for " <> releaseId rt
                            vsResult <- liftIO $ applyVirtualServiceRollout cfg ctx 100 0
                            case vsResult of
                                Left err -> logWarning $ "[restoreVsTrafficOnFailure] WARNING: Failed to restore VS: " <> T.pack (show err)
                                Right _ -> logInfo "[restoreVsTrafficOnFailure] VS traffic restored to old version"

                    -- Step 4: scale the new deployment to 0 (the failed one)
                    -- Round 8 audit H3: SKIP if newDep == oldDep (immediate-revert
                    -- path replaces the new deployment's image with the old image
                    -- in-place, so the names are the same row in k8s — scaling it
                    -- to 0 would zero the only deployment with the correct image).
                    if newDepName == oldDepName
                        then logInfo $ "[restoreVsTrafficOnFailure] Skipping scale-down: newDep == oldDep (" <> newDepName <> ") — immediate-revert path, only one deployment exists"
                        else do
                            -- Julia parity (kubernetes.jl:1718-1720 scaleDownPodsWithoutPolling):
                            -- delete the HPA BEFORE scaling to 0, otherwise the HPA reconciler
                            -- will scale the deployment back up within 15-90s.
                            let newHpaName = serviceName ctx <> "-" <> K8s.newVersion ctx <> "-hpa"
                            _ <- liftIO $ runCmd (buildDeleteHpaCommand cfg ns newHpaName)
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
    -- Julia parity: persist cleanup marker so a crash/kubectl-fail between
    -- now and the next poll doesn't leak the new deployment. Idempotent.
    scheduleNewDeploymentCleanup rt mts
    now <- liftIO getCurrentTime
    let aborted = rt{status = USER_ABORTED, endTime = Just now}
    -- Round 8 audit C2: CAS against ABORTING. If a parallel runner instance
    -- or a user-initiated handler raced and already moved the row, log and
    -- skip — abort/restore was already done.
    casOk <- conditionalUpdateTracker aborted mts (releaseStatusToText ABORTING)
    if not casOk
        then logWarning $ "[handleAbortingRelease] CAS miss for " <> releaseId rt <> "; another writer already transitioned. Skipping notify+event."
        else do
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
            releaseService (NT.appGroup aborted) (NT.service aborted)

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
                        -- CRITICAL: before draining the old version, check whether
                        -- it's currently the *new version* of an in-flight release on
                        -- the same service (e.g. a revert that's rolling traffic back
                        -- to it). If yes, skip the scale-down and clear the SCHEDULED
                        -- flag so we don't keep retrying. Without this guard, a queued
                        -- post-completion scale-down can fire mid-revert and wipe out
                        -- the version we're rolling back to.
                        inflightTrackers <- findActiveTrackersForService (NT.appGroup freshRT) (NT.service freshRT)
                        let inflightTargetsOld = any (\(t, _) -> NT.releaseId t /= releaseId rt && NT.newVersion t == oldVer) inflightTrackers
                        if T.null oldVer || oldVer == "new" || oldVer == "unknown"
                            then pure ()
                            else
                                if inflightTargetsOld
                                    then do
                                        logWarning $
                                            "[scaleDownOldDeployment] Skipping scale-down of "
                                                <> oldDepName
                                                <> " — an in-flight release on this service is targeting it as its newVersion. Clearing SCHEDULED flag for "
                                                <> releaseId rt
                                        let clearedCtx = (context k8s){podsScaleDownStatus = Just ScaleDownDiscarded}
                                            clearedMts = Just (K8sState k8s{context = clearedCtx})
                                        _ <- conditionalUpdateTracker freshRT clearedMts (releaseStatusToText (NT.status freshRT))
                                        insertReleaseEvent
                                            (releaseId rt)
                                            "BUSINESS"
                                            "SCALE_DOWN_SKIPPED_INFLIGHT"
                                            (object ["oldDeployment" .= oldDepName, "reason" .= ("inflight release targets this version as newVersion" :: T.Text)])
                                    else do
                                        logInfo $ "[scaleDownOldDeployment] Scaling down old deployment: " <> oldDepName <> " for release " <> releaseId rt
                                        -- Julia parity (kubernetes.jl:1718-1720 scaleDownPodsWithoutPolling):
                                        -- delete the OLD HPA BEFORE scaling to 0, otherwise the HPA
                                        -- reconciler will scale the old deployment back up.
                                        let oldHpaName = oldDepName <> "-hpa"
                                        -- Julia parity (hpa.jl:39-44 updateOldHPAConfig):
                                        -- before deleting, patch the OLD HPA's min DOWN to
                                        -- min(currentMin, hpa_default_min_pods_config). Closes the
                                        -- race window where the HPA reconciler runs between our
                                        -- delete-HPA call and the kubectl scale call and re-scales
                                        -- the old deployment back up. Best-effort: failures are
                                        -- non-fatal because the delete that follows is the real
                                        -- safety guarantee.
                                        defaultMinPodsForOld <- getHpaDefaultMinPods
                                        oldMinMaxRes <- liftIO $ getHpaMinMax cfg ns oldHpaName
                                        let (curOldMin, curOldMax) = oldMinMaxRes
                                            patchedMin = min curOldMin defaultMinPodsForOld
                                        when (curOldMin > 0) $ do
                                            _ <- liftIO $ runCmd (buildPatchHpaReplicasCommand cfg ns oldHpaName patchedMin curOldMax)
                                            pure ()
                                        deleteRes <- liftIO $ runCmd (buildDeleteHpaCommand cfg ns oldHpaName)
                                        case deleteRes of
                                            Right _ ->
                                                insertReleaseEvent
                                                    (releaseId rt)
                                                    "BUSINESS"
                                                    "HPA_DELETED"
                                                    (object ["hpa" .= oldHpaName, "phase" .= ("scale-down" :: T.Text)])
                                            Left _ -> pure ()
                                        result <- liftIO $ runCmd (buildScaleNamedDeploymentCommand cfg ns oldDepName 0)
                                        case result of
                                            Left err -> do
                                                -- Bug fix (round 6 / Julia parity): on kubectl failure
                                                -- KEEP the tracker in ScaleDownScheduled state so the
                                                -- next runner poll retries.
                                                -- Round 8 audit H5: use FRESH tracker (freshRT/freshTS),
                                                -- not the stale snapshot from poll-pick. Anything else
                                                -- that updated releaseContext between pick and now
                                                -- (e.g. immediate revert flipping revert=1) would be
                                                -- clobbered if we wrote against `rt`+`mts`.
                                                logWarning $ "[scaleDownOldDeployment] FAILED: " <> T.pack (show err) <> " — keeping ScaleDownScheduled for retry on next poll"
                                                freshM' <- findReleaseTracker (releaseId rt)
                                                case freshM' of
                                                    Just (freshRT', Just (K8sState freshK8s)) -> do
                                                        let retryCtx = (context freshK8s){podsScaleDownStatus = Just ScaleDownScheduled}
                                                            retryK8s = freshK8s{context = retryCtx}
                                                            retryMts = Just (K8sState retryK8s)
                                                        _ <- conditionalUpdateTracker freshRT' retryMts (releaseStatusToText (NT.status freshRT'))
                                                        pure ()
                                                    _ -> pure ()
                                                insertReleaseEvent
                                                    (releaseId rt)
                                                    "BUSINESS"
                                                    "SCALE_DOWN_FAILED"
                                                    (object ["oldDeployment" .= (oldDepName :: T.Text), "error" .= T.pack (show err)])
                                            Right _ -> do
                                                logInfo "[scaleDownOldDeployment] Old deployment scaled down successfully"
                                                notifyPodsScaledDown rt oldVer
                                                -- Same fix: use the fresh tracker we already
                                                -- read at the top so the success-path CAS
                                                -- doesn't overwrite a concurrent edit either.
                                                let updatedCtx = (context k8s){podsScaleDownStatus = Just ScaleDownCompleted}
                                                    updatedK8s = k8s{context = updatedCtx}
                                                    updatedMts = Just (K8sState updatedK8s)
                                                ok <- conditionalUpdateTracker freshRT updatedMts (releaseStatusToText (NT.status freshRT))
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

-- ============================================================================
-- Leaked-new-deployment cleanup (Julia parity: scaleDownPodsInProgress)
-- ============================================================================

{- | Mark a tracker for later scale-down of its NEW deployment. Mirrors
Julia's @scheduleScaleDownOfPods@ but targeted at the new (failed)
deployment rather than the old one.

Writes @cleanupTargetDeployment@ + @cleanupStatus = SCALE_DOWN_SCHEDULED@
+ @cleanupAt = now@ into the tracker's K8sState. The runner poll picks
these up via 'findLeakedNewDeploymentTrackers'.

Best-effort: silently no-ops if the tracker has no K8sState (non-K8s
release types) or no @newDepName@ to target. Uses CAS against the
current status so a concurrent state change isn't clobbered.
-}
scheduleNewDeploymentCleanup :: ReleaseTracker -> Maybe TargetState -> Flow ()
scheduleNewDeploymentCleanup rt mts = case mts of
    Just (K8sState k8s) -> do
        let ctx = context k8s
            newDepName = K8s.deploymentName ctx
        if T.null newDepName
            then pure ()
            else do
                now <- liftIO getCurrentTime
                let updatedCtx =
                        ctx
                            { cleanupTargetDeployment = Just newDepName
                            , cleanupStatus = Just "SCALE_DOWN_SCHEDULED"
                            , cleanupAt = Just now
                            , cleanupAttempts = 0
                            }
                    updatedMts = Just (K8sState k8s{context = updatedCtx})
                ok <- conditionalUpdateTracker rt updatedMts (releaseStatusToText (NT.status rt))
                if ok
                    then
                        logInfo $
                            "[scheduleNewDeploymentCleanup] Marked "
                                <> releaseId rt
                                <> " for new-deployment cleanup ("
                                <> newDepName
                                <> ")"
                    else
                        logWarning $
                            "[scheduleNewDeploymentCleanup] CAS miss for "
                                <> releaseId rt
                                <> " — concurrent modification, will be retried by next abort path"
    _ -> pure ()

{- | Worker (Julia parity: @scaleDownPods@ in watcher.jl): scale a leaked
NEW deployment to 0 replicas. Idempotent on the kubectl side. On
success flips @cleanupStatus@ to @SCALE_DOWN_COMPLETED@ via CAS; on
failure leaves @SCALE_DOWN_SCHEDULED@ for the next poll to retry.
-}
scaleDownLeakedNewDeployment :: Config -> TrackerWithTarget -> Flow ()
scaleDownLeakedNewDeployment cfg (rt, mts) = case mts of
    Just (K8sState k8s) -> do
        let ctx = context k8s
            K8s.K8sReleaseContext{K8s.namespace = ns} = ctx
        case cleanupTargetDeployment ctx of
            Nothing -> pure ()
            Just depName | T.null depName -> pure ()
            Just depName -> do
                -- Mark in-progress so the in-flight recovery sweep can
                -- distinguish "stuck mid-scale-down" from "scheduled".
                let inProgressCtx = ctx{cleanupStatus = Just "SCALE_DOWN_INPROGRESS"}
                    inProgressMts = Just (K8sState k8s{context = inProgressCtx})
                _ <- conditionalUpdateTracker rt inProgressMts (releaseStatusToText (NT.status rt))

                logInfo $
                    "[scaleDownLeakedNewDeployment] Scaling leaked deployment "
                        <> depName
                        <> " to 0 (release "
                        <> releaseId rt
                        <> ")"
                -- Julia parity (kubernetes.jl:1718-1720 scaleDownPodsWithoutPolling):
                -- delete the HPA BEFORE scaling to 0. The leaked deployment likely
                -- still has its HPA from the failed rollout — without this delete
                -- the HPA reconciler scales it back up within 15-90 seconds.
                let leakedHpaName = depName <> "-hpa"
                _ <- liftIO $ runCmd (buildDeleteHpaCommand cfg ns leakedHpaName)
                result <- liftIO $ runCmd (buildScaleNamedDeploymentCommand cfg ns depName 0)
                case result of
                    Left err -> do
                        maxRetries <- getMaxCleanupRetries
                        logWarning $
                            "[scaleDownLeakedNewDeployment] FAILED for "
                                <> depName
                                <> ": "
                                <> T.pack (show err)
                                <> " — attempt "
                                <> T.pack (show (cleanupAttempts ctx + 1))
                                <> "/"
                                <> T.pack (show maxRetries)
                        freshM <- findReleaseTracker (releaseId rt)
                        case freshM of
                            Just (freshRT, Just (K8sState freshK8s)) -> do
                                let currentAttempts = cleanupAttempts (context freshK8s) + 1
                                if currentAttempts >= maxRetries
                                    then do
                                        -- Max retries exceeded, mark as FAILED and stop retrying
                                        logWarning $
                                            "[scaleDownLeakedNewDeployment] Max retries ("
                                                <> T.pack (show maxRetries)
                                                <> ") exceeded for "
                                                <> depName
                                                <> " in release "
                                                <> releaseId rt
                                                <> " — marking SCALE_DOWN_FAILED"
                                        let failedCtx = (context freshK8s){cleanupStatus = Just "SCALE_DOWN_FAILED", cleanupAttempts = currentAttempts}
                                            failedMts = Just (K8sState freshK8s{context = failedCtx})
                                        _ <- conditionalUpdateTracker freshRT failedMts (releaseStatusToText (NT.status freshRT))
                                        insertReleaseEvent
                                            (releaseId rt)
                                            "BUSINESS"
                                            "LEAKED_DEPLOYMENT_SCALE_DOWN_ABANDONED"
                                            (object ["deployment" .= depName, "error" .= T.pack (show err), "attempts" .= currentAttempts])
                                    else do
                                        -- Retry: reset to SCHEDULED and increment counter
                                        let retryCtx = (context freshK8s){cleanupStatus = Just "SCALE_DOWN_SCHEDULED", cleanupAttempts = currentAttempts}
                                            retryMts = Just (K8sState freshK8s{context = retryCtx})
                                        _ <- conditionalUpdateTracker freshRT retryMts (releaseStatusToText (NT.status freshRT))
                                        insertReleaseEvent
                                            (releaseId rt)
                                            "BUSINESS"
                                            "LEAKED_DEPLOYMENT_SCALE_DOWN_FAILED"
                                            (object ["deployment" .= depName, "error" .= T.pack (show err), "attempts" .= currentAttempts])
                            _ -> pure ()
                    Right _ -> do
                        logInfo $ "[scaleDownLeakedNewDeployment] Scaled " <> depName <> " to 0 successfully"
                        freshM <- findReleaseTracker (releaseId rt)
                        case freshM of
                            Just (freshRT, Just (K8sState freshK8s)) -> do
                                let doneCtx = (context freshK8s){cleanupStatus = Just "SCALE_DOWN_COMPLETED"}
                                    doneMts = Just (K8sState freshK8s{context = doneCtx})
                                ok <- conditionalUpdateTracker freshRT doneMts (releaseStatusToText (NT.status freshRT))
                                if ok
                                    then
                                        insertReleaseEvent
                                            (releaseId rt)
                                            "BUSINESS"
                                            "LEAKED_DEPLOYMENT_SCALED_DOWN"
                                            (object ["deployment" .= depName, "namespace" .= (ns :: T.Text)])
                                    else
                                        logWarning $
                                            "[scaleDownLeakedNewDeployment] CAS miss persisting COMPLETED for "
                                                <> releaseId rt
                            _ -> pure ()
    _ -> pure ()

-- force rebuild 1775474191
