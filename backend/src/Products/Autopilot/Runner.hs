module Products.Autopilot.Runner where

import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (forM_, forever)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import Core.Config (Config (..))
import Core.Environment (AppState (..), DBEnv)
import Core.Logging (LoggerEnv, logInfoIO, logErrorIO, logWarningIO)
import Core.Utils.FlowMonad
import Data.Aeson (object, toJSON, (.=))
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Products.Autopilot.EventLog (logStatusUpdated, logTrafficUpdatedWithMessage)
import Products.Autopilot.K8s.Deployment (buildScaleNamedDeploymentCommand)
import Products.Autopilot.K8s.Execute (runCmd)
import Products.Autopilot.K8s.VirtualService (applyVirtualServiceRollout, getPrimarySubsetFromVirtualService)
import Products.Autopilot.Notifications (notifyPodsScaledDown, notifyReleaseAborted)
import Products.Autopilot.Queries.ProductService (findProductByNameAndCluster, getProductVsLockedBy, releaseExpiredVsLocks)
import Products.Autopilot.Queries.ReleaseTracker
import Products.Autopilot.RuntimeConfig (getPodsScaleDownDelayFromConfig, getReleaseWatchDelay, isMultiReleasePerProduct)
import Products.Autopilot.Types
import qualified Products.Autopilot.Types as NT
import Products.Autopilot.Types.Target (TargetState (..))
import Products.Autopilot.Types.Target.Kubernetes (K8sDeploymentState (..), K8sReleaseContext (..), PodsScaleDownStatus (..))
import qualified Products.Autopilot.Types.Target.Kubernetes as K8s
import Products.Autopilot.Workflow.Factory (executeReleaseWorkflow)
import Products.Autopilot.Workflow.Types (ReleaseState (..), WorkFlowError)
import Prelude

-- ============================================================================
-- Runner Entry Point
-- ============================================================================

-- | Full runner lifecycle: synchronous startup recovery then the polling
-- loop. Used by the standalone @RUNNER@ mode. The @SERVER@ mode in
-- "Main" calls 'runnerStartupRecovery' and 'runnerPollLoop' separately so
-- that startup recovery finishes before the HTTP port is bound — this
-- closes the CRITICAL race (task #35 FIX 1) where concurrent HTTP writes
-- could be silently clobbered by a stale rollback sweep (race-hunter #29).
runnerLoop :: AppState -> IO ()
runnerLoop st = do
  runnerStartupRecovery st
  runnerPollLoop st

-- | Synchronous startup recovery. Must run BEFORE the HTTP server binds
-- its port, otherwise user-initiated state changes (abort, revert) can
-- land in parallel with these sweeps and get overwritten by their stale
-- snapshots. See #35 FIX 1 for the full race description.
--
-- This function performs two recovery actions:
--
--   1. 'rollbackInProgressOnStartup' — drives any INPROGRESS/PAUSED/
--      REVERTING releases to a terminal state (ABORTED/REVERTED) because
--      their workflow threads were lost when the server died.
--   2. 'releaseExpiredVsLocksOnStartup' — clears any orphaned VS locks
--      whose timestamp is older than @lock_expiry_delay_minutes@. Covers
--      the case where a lock is held but no one tries to acquire it (so
--      the inline expiry check inside 'tryAcquireVsLock' never runs),
--      leaving an orphaned lock visible to 'isEligibleToRun' and blocking
--      release dispatch.
runnerStartupRecovery :: AppState -> IO ()
runnerStartupRecovery st = do
  runFlow st rollbackInProgressOnStartup
  runFlow st releaseExpiredVsLocksOnStartup

-- | Forever poll loop. Picks CREATED trackers, handles aborting releases,
-- schedules scale-downs. Safe to run concurrently with the HTTP server.
runnerPollLoop :: AppState -> IO ()
runnerPollLoop st = runFlow st loop

-- | Release any VS lock older than the configured expiry. Runs once at
-- startup; tryAcquireVsLock also treats stale locks as released so new
-- edit attempts unblock themselves without needing this sweep to run first.
releaseExpiredVsLocksOnStartup :: Flow ()
releaseExpiredVsLocksOnStartup = do
  db <- getDBEnv
  n <- liftIO $ releaseExpiredVsLocks db
  if n == 0
    then logInfo "[STARTUP] No expired VS locks to release"
    else logInfo $ "[STARTUP] Released " <> T.pack (show n) <> " expired VS lock(s)"

-- ============================================================================
-- Startup Rollback (Julia parity: rollbackReleaseInProgress)
-- ============================================================================

-- | Roll back all orphaned INPROGRESS/PAUSED/REVERTING releases on server startup.
-- Restores VS traffic to old version and marks as ABORTED.
-- Julia reference: api/rollback/rollback.jl lines 10-75
rollbackInProgressOnStartup :: Flow ()
rollbackInProgressOnStartup = do
  cfg <- getConfig
  db <- getDBEnv
  orphaned <- liftIO $ findInProgressReleaseTrackers db
  st <- getAppState
  let logEnv = loggerEnv st
  if null orphaned
    then logInfo "[STARTUP] No orphaned INPROGRESS releases found"
    else do
      logInfo $ "[STARTUP] Rolling back " <> T.pack (show (length orphaned)) <> " orphaned release(s)"
      forM_ orphaned $ \(rt, mts) -> liftIO $ do
        logInfoIO logEnv $ "[STARTUP] Rolling back: " <> releaseId rt <> " (status: " <> T.pack (show (NT.status rt)) <> ")"
        -- Restore VS traffic to old version (best-effort). For REVERTING releases
        -- this is also the correct recovery action: the revert was mid-flight, so
        -- pointing traffic back to old version completes the revert's intent.
        restoreVsTrafficOnFailure logEnv cfg db rt mts
        now <- getCurrentTime
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
            ok <- conditionalUpdateTracker db reverted mts oldStatusText
            if not ok
              then
                logWarningIO logEnv $
                  "[STARTUP] Skipping revert completion for "
                    <> releaseId rt
                    <> " — status changed under us during restoreVsTrafficOnFailure"
              else do
                logStatusUpdated db reverted "Revert completed on startup recovery"
                insertReleaseEvent
                  db
                  (releaseId rt)
                  "BUSINESS"
                  "STARTUP_REVERT_COMPLETED"
                  (toJSON ("Revert completed on startup recovery — VS traffic restored to old version" :: T.Text))
          _ -> do
            let aborted = rt{status = ABORTED, endTime = Just now}
            ok <- conditionalUpdateTracker db aborted mts oldStatusText
            if not ok
              then
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
                logTrafficUpdatedWithMessage db aborted previousRollout "Rolling back traffic due to server restart"
                insertReleaseEvent
                  db
                  (releaseId rt)
                  "BUSINESS"
                  "STARTUP_ROLLBACK"
                  (toJSON ("ABORTED due to server restart — VS traffic restored to old version" :: T.Text))
                notifyReleaseAborted db aborted
      logInfo "[STARTUP] Rollback complete"

-- ============================================================================
-- Main Poll Loop
-- ============================================================================

loop :: Flow ()
loop = forever $ do
  cfg <- getConfig
  db <- getDBEnv
  now <- liftIO getCurrentTime

  -- Step 1: Find runnable trackers (CREATED only — never INPROGRESS).
  -- conditionalUpdateTrackerRow provides atomic claim if two polls overlap.
  jobs <- liftIO $ findRunnableReleaseTrackers db now
  ongoing <- liftIO $ findOngoingReleaseTrackers db
  multiRelease <- liftIO $ isMultiReleasePerProduct db
  eligible <- liftIO $ filterM (isEligibleToRun db multiRelease ongoing) jobs

  -- Step 2: Pick jobs and fork each into a background thread for parallel execution
  let picked = pickJobs multiRelease eligible
  st <- getAppState
  forM_ picked $ \twt -> liftIO $ forkIO $ runFlow st (trigger db twt)

  -- Step 3: Handle aborting trackers
  abortingTrackers <- liftIO $ findAbortingReleaseTrackers db
  let logEnv' = loggerEnv st
  forM_ abortingTrackers $ \(rt, mts) -> liftIO $ handleAbortingRelease logEnv' cfg db rt mts

  -- Step 4: Handle scale-down of old deployments after delay
  scaleDownDelay <- liftIO $ getPodsScaleDownDelayFromConfig db
  completedTrackers <- liftIO $ findCompletedTrackersForScaleDown db now scaleDownDelay
  forM_ completedTrackers $ \twt -> liftIO $ scaleDownOldDeployment logEnv' db cfg twt

  pollDelay <- liftIO $ getReleaseWatchDelay db
  liftIO $ threadDelay (pollDelay * 1000000)
  where
    filterM _ [] = pure []
    filterM f (x : xs) = do
      ok <- f x
      rest <- filterM f xs
      pure (if ok then x : rest else rest)

-- | Get the full AppState from the Flow monad (for passing to forkIO threads)
getAppState :: Flow AppState
getAppState = ask

-- ============================================================================
-- Eligibility & Job Selection
-- ============================================================================

isEligibleToRun :: DBEnv -> Bool -> [TrackerWithTarget] -> TrackerWithTarget -> IO Bool
isEligibleToRun db multiRelease ongoing (rt, mts) = case category rt of
  BackendService -> k8sEligible multiRelease
  BackendScheduler -> k8sEligible True
  BackendCronJob -> k8sEligible True
  BackendJob -> k8sEligible True
  BackendConfig -> pure True
  MobileAppAndroid -> pure True
  MobileAppIOS -> pure True
  WebApplication -> pure True
  Infrastructure -> pure True
  VSEdit -> pure True
  where
    k8sEligible skipOngoingCheck = do
      let k8sCluster = case mts of
            Just (K8sState k8s) -> cluster (context k8s)
            _ -> ""
      p <- findProductByNameAndCluster db (appGroup rt) k8sCluster
      let vsLocked = maybe False (isJust . getProductVsLockedBy) p
          hasOngoingSameProduct = any (\(o, _) -> appGroup o == appGroup rt && env o == env rt) ongoing
      pure (not vsLocked && (skipOngoingCheck || not hasOngoingSameProduct))

pickJobs :: Bool -> [TrackerWithTarget] -> [TrackerWithTarget]
pickJobs multi jobs
  | multi = jobs
  | otherwise = go Map.empty (sortByPriority jobs)
  where
    go _ [] = []
    go counts ((rt, mts) : rest) =
      let key = appGroup rt <> ":" <> env rt
          picked = Map.findWithDefault 0 key counts
       in if picked >= 1
            then go counts rest
            else (rt, mts) : go (Map.insert key (picked + 1) counts) rest

sortByPriority :: [TrackerWithTarget] -> [TrackerWithTarget]
sortByPriority = foldr insert []
  where
    insert twt [] = [twt]
    insert twt@(rt, _) (x@(xrt, _) : xs)
      | priority rt > priority xrt = twt : x : xs
      | otherwise = x : insert twt xs

-- ============================================================================
-- Trigger — Only for CREATED trackers
-- ============================================================================

-- | Trigger a release — only called for CREATED trackers.
-- Atomically claims via conditionalUpdateTrackerRow (prevents double-pick).
trigger :: DBEnv -> TrackerWithTarget -> Flow ()
trigger db (rt, mts) = do
  cfg <- getConfig
  -- Version validation
  versionOk <- liftIO $ validateRunningVersion cfg db rt mts
  case versionOk of
    Just mismatchMsg -> do
      let discarded = rt{status = DISCARDED}
      liftIO $ insertReleaseTracker db discarded mts
      liftIO $
        insertReleaseEvent
          db
          (releaseId rt)
          "BUSINESS"
          "VERSION_MISMATCH"
          (object ["message" .= mismatchMsg, "trackerOldVersion" .= NT.oldVersion rt])
      liftIO $ notifyReleaseAborted db discarded
    Nothing -> do
      now <- liftIO getCurrentTime
      -- Atomically claim: CREATED → INPROGRESS
      let rtNew = rt{status = INPROGRESS, startTime = Just now}
          row = toRow now now rtNew mts
      claimed <- liftIO $ conditionalUpdateTrackerRow db row "CREATED"
      if not claimed
        then logInfo $ "[RUNNER] Release " <> releaseId rt <> " already claimed, skipping"
        else do
          liftIO $ insertReleaseEvent db (releaseId rt) "BUSINESS" "RUNNER_PICKED" (toJSON rt)
          result <- dispatchWorkflow rtNew mts
          case result of
            Left err -> do
              cfg' <- getConfig
              -- Re-read tracker — user may have set ABORTING while workflow ran
              freshM <- liftIO $ findReleaseTracker db (releaseId rt)
              let currentStatus' = case freshM of
                    Just (freshRT, _) -> status freshRT
                    Nothing -> status rtNew
                  isUserAbort = currentStatus' == ABORTING || currentStatus' == USER_ABORTED
              if isUserAbort
                then do
                  -- Defer to handleAbortingRelease (Step 3 of poll loop)
                  logInfo $ "[RUNNER] Workflow exited due to user abort — deferring: " <> releaseId rt
                  liftIO $ insertReleaseEvent db (releaseId rt) "BUSINESS" "WORKFLOW_ABORT_EXIT" (toJSON (show err))
                else do
                  endNow <- liftIO getCurrentTime
                  let abortedTracker = rtNew{status = ABORTED, releaseWFStatus = ROLLING_BACK, endTime = Just endNow}
                  liftIO $ insertReleaseTracker db abortedTracker mts
                  liftIO $ insertReleaseEvent db (releaseId rt) "BUSINESS" "FAILED" (toJSON (show err))
                  st' <- getAppState
                  liftIO $ restoreVsTrafficOnFailure (loggerEnv st') cfg' db rt mts
                  liftIO $ notifyReleaseAborted db abortedTracker
            Right finalState -> do
              liftIO $ insertReleaseTracker db (releaseTracker finalState) (targetState finalState)
              liftIO $ insertReleaseEvent db (releaseId rt) "BUSINESS" "COMPLETED" (toJSON ("success" :: String))

dispatchWorkflow :: ReleaseTracker -> Maybe TargetState -> Flow (Either WorkFlowError ReleaseState)
dispatchWorkflow rt mts = do
  let initialState = ReleaseState rt mts Nothing
  executeReleaseWorkflow initialState

-- ============================================================================
-- Version Validation
-- ============================================================================

validateRunningVersion :: Config -> DBEnv -> ReleaseTracker -> Maybe TargetState -> IO (Maybe T.Text)
validateRunningVersion cfg _db rt mts = do
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
            Left _err -> pure Nothing
            Right Nothing -> pure Nothing
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

restoreVsTrafficOnFailure :: LoggerEnv -> Config -> DBEnv -> ReleaseTracker -> Maybe TargetState -> IO ()
restoreVsTrafficOnFailure logEnv cfg db rt mts = do
  case mts of
    Just (K8sState k8s) -> do
      let ctx = context k8s
          oldVer = K8s.oldVersion ctx
          isNewSvc = newService k8s
      if isNewSvc || T.null oldVer || oldVer == "new" || oldVer == "unknown"
        then logInfoIO logEnv $ "[restoreVsTrafficOnFailure] Skipping VS restore for " <> releaseId rt <> " (new service or no old version)"
        else do
          logInfoIO logEnv $ "[restoreVsTrafficOnFailure] Restoring VS traffic to old version for " <> releaseId rt
          vsResult <- applyVirtualServiceRollout cfg ctx 100 0
          case vsResult of
            Left err -> logWarningIO logEnv $ "[restoreVsTrafficOnFailure] WARNING: Failed to restore VS: " <> T.pack (show err)
            Right _ -> logInfoIO logEnv "[restoreVsTrafficOnFailure] VS traffic restored to old version"
          let newDepName = deploymentName ctx
              ns = namespace ctx
          scaleResult <- runCmd (buildScaleNamedDeploymentCommand cfg ns newDepName 0)
          case scaleResult of
            Left err -> logWarningIO logEnv $ "[restoreVsTrafficOnFailure] WARNING: Failed to scale down new deployment: " <> T.pack (show err)
            Right _ -> logInfoIO logEnv "[restoreVsTrafficOnFailure] New deployment scaled down to 0"
          insertReleaseEvent
            db
            (releaseId rt)
            "BUSINESS"
            "VS_TRAFFIC_RESTORED"
            (object ["action" .= ("restore_on_failure" :: T.Text), "oldVersion" .= (oldVer :: T.Text), "newDeployment" .= (newDepName :: T.Text)])
    _ -> pure ()

-- ============================================================================
-- Abort Handling
-- ============================================================================

handleAbortingRelease :: LoggerEnv -> Config -> DBEnv -> ReleaseTracker -> Maybe TargetState -> IO ()
handleAbortingRelease logEnv cfg db rt mts = do
  logInfoIO logEnv $ "[handleAbortingRelease] Processing abort for " <> releaseId rt
  restoreVsTrafficOnFailure logEnv cfg db rt mts
  now <- getCurrentTime
  let aborted = rt{status = USER_ABORTED, endTime = Just now}
  insertReleaseTracker db aborted mts
  -- Production parity (events.jl:251-286 rollbackEvent!):
  -- BUSINESS / TRAFFIC_UPDATED with a message field on rollback.
  let previousRollout = case rolloutHistory rt of
        [] -> 0
        xs -> historyRolloutPercent (last xs)
      oldVer = case mts of
        Just (K8sState k8s) -> K8s.oldVersion (context k8s)
        _ -> ""
  logTrafficUpdatedWithMessage db aborted previousRollout ("Rolling back traffic to old version: " <> oldVer)
  insertReleaseEvent db (releaseId rt) "BUSINESS" "ABORT_HANDLED" (toJSON ("User abort processed" :: String))
  notifyReleaseAborted db aborted

-- ============================================================================
-- Scale-Down of Old Deployments After Delay
-- ============================================================================

-- | Scale down old deployment. Sends Slack notification only on success.
--
-- Race guard (#35 FIX 2): between the poll pick (which sees status=COMPLETED
-- and schedules this callback after the scale-down delay) and this function
-- firing, a user may have issued an immediate revert via the HTTP API. The
-- tracker's status in the DB will then be REVERTING, and the revert path
-- needs the old deployment pods still running — scaling them down here
-- would corrupt the revert.
--
-- Two defenses, matching race-hunter's HIGH-severity finding:
--
--   Part A — re-read the tracker's status from DB before running the
--   kubectl scale-down. If the status is no longer in the set
--   @{COMPLETED, ABORTED, USER_ABORTED}@ (e.g. user reverted, admin edit),
--   skip the entire scale-down. Prevents kubectl-level corruption.
--
--   Part B — CAS the final DB write of the scale-down flag against the
--   status we saw at poll-pick time. If anything changed between re-read
--   and CAS (narrow window but real), the blind insert is suppressed so
--   we don't overwrite the user's concurrent edit.
scaleDownOldDeployment :: LoggerEnv -> DBEnv -> Config -> TrackerWithTarget -> IO ()
scaleDownOldDeployment logEnv db cfg (rt, mts) = do
  case mts of
    Just (K8sState k8s) -> do
      -- Part A — re-verify the tracker is still scale-down-eligible.
      freshM <- findReleaseTracker db (releaseId rt)
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
                logInfoIO logEnv $ "[scaleDownOldDeployment] Scaling down old deployment: " <> oldDepName <> " for release " <> releaseId rt
                result <- runCmd (buildScaleNamedDeploymentCommand cfg ns oldDepName 0)
                case result of
                  Left err -> logWarningIO logEnv $ "[scaleDownOldDeployment] WARNING: Failed to scale down: " <> T.pack (show err)
                  Right _ -> do
                    logInfoIO logEnv "[scaleDownOldDeployment] Old deployment scaled down successfully"
                    notifyPodsScaledDown db rt oldVer
                let updatedCtx = ctx{podsScaleDownStatus = Just ScaleDownCompleted}
                    updatedK8s = k8s{context = updatedCtx}
                    updatedMts = Just (K8sState updatedK8s)
                -- Part B — CAS against the original poll-pick status.
                ok <- conditionalUpdateTracker db rt updatedMts (releaseStatusToText (NT.status rt))
                if not ok
                  then
                    logWarningIO logEnv $
                      "[scaleDownOldDeployment] Status changed under us; not persisting scale-down flag for "
                        <> releaseId rt
                  else
                    insertReleaseEvent
                      db
                      (releaseId rt)
                      "BUSINESS"
                      "OLD_PODS_SCALED_DOWN"
                      (object ["oldDeployment" .= (oldDepName :: T.Text), "namespace" .= (ns :: T.Text)])
        _ ->
          logWarningIO logEnv $
            "[scaleDownOldDeployment] Skipping "
              <> releaseId rt
              <> " — status no longer scale-down-eligible (was "
              <> T.pack (show (NT.status rt))
              <> ", now "
              <> T.pack (show (fmap (NT.status . fst) freshM))
              <> ")"
    _ -> pure ()
