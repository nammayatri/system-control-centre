module Products.Autopilot.Runner where

import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (forM_, forever)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import Core.Config (Config (..))
import Core.Environment (AppState, DBEnv)
import Core.Utils.FlowMonad
import Data.Aeson (object, toJSON, (.=))
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Products.Autopilot.K8s.Deployment (buildScaleNamedDeploymentCommand)
import Products.Autopilot.K8s.Execute (runCmd)
import Products.Autopilot.K8s.VirtualService (applyVirtualServiceRollout, getPrimarySubsetFromVirtualService)
import Products.Autopilot.Notifications (notifyPodsScaledDown, notifyReleaseAborted)
import Products.Autopilot.Queries.ProductService (findProductByNameAndCluster, getProductVsLockedBy)
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

runnerLoop :: AppState -> IO ()
runnerLoop st = do
  -- Julia production parity (rollbackReleaseInProgress):
  -- On startup, roll back ALL INPROGRESS/PAUSED/REVERTING releases.
  -- Their workflow threads are gone (server restarted), so restore VS and abort.
  runFlow st rollbackInProgressOnStartup
  -- Then start the poll loop — only picks CREATED trackers.
  runFlow st loop

-- ============================================================================
-- Startup Rollback (Julia parity: rollbackReleaseInProgress)
-- ============================================================================

-- | Roll back all orphaned INPROGRESS/PAUSED/REVERTING releases on server startup.
-- Restores VS traffic to old version and marks as Aborted.
-- Julia reference: api/rollback/rollback.jl lines 10-75
rollbackInProgressOnStartup :: Flow ()
rollbackInProgressOnStartup = do
  cfg <- getConfig
  db <- getDBEnv
  orphaned <- liftIO $ findInProgressReleaseTrackers db
  if null orphaned
    then liftIO $ putStrLn "[STARTUP] No orphaned INPROGRESS releases found"
    else do
      liftIO $ putStrLn $ "[STARTUP] Rolling back " <> show (length orphaned) <> " orphaned release(s)"
      forM_ orphaned $ \(rt, mts) -> liftIO $ do
        putStrLn $ "[STARTUP] Rolling back: " <> T.unpack (releaseId rt) <> " (status: " <> show (NT.status rt) <> ")"
        -- Restore VS traffic to old version (best-effort)
        restoreVsTrafficOnFailure cfg db rt mts
        -- Mark as Aborted
        now <- getCurrentTime
        let aborted = rt{status = Aborted, endTime = Just now}
        insertReleaseTracker db aborted mts
        insertReleaseEvent
          db
          (releaseId rt)
          "BUSINESS"
          "STARTUP_ROLLBACK"
          (toJSON ("Aborted due to server restart — VS traffic restored to old version" :: T.Text))
        notifyReleaseAborted db aborted
      liftIO $ putStrLn "[STARTUP] Rollback complete"

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
  forM_ abortingTrackers $ \(rt, mts) -> liftIO $ handleAbortingRelease cfg db rt mts

  -- Step 4: Handle scale-down of old deployments after delay
  scaleDownDelay <- liftIO $ getPodsScaleDownDelayFromConfig db
  completedTrackers <- liftIO $ findCompletedTrackersForScaleDown db now scaleDownDelay
  forM_ completedTrackers $ \twt -> liftIO $ scaleDownOldDeployment db cfg twt

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
      let discarded = rt{status = Discarded}
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
      let rtNew = rt{status = InProgress, startTime = Just now}
          row = toRow now now rtNew mts
      claimed <- liftIO $ conditionalUpdateTrackerRow db row "CREATED"
      if not claimed
        then liftIO $ putStrLn $ "[RUNNER] Release " <> T.unpack (releaseId rt) <> " already claimed, skipping"
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
                  isUserAbort = currentStatus' == Aborting || currentStatus' == UserAborted
              if isUserAbort
                then do
                  -- Defer to handleAbortingRelease (Step 3 of poll loop)
                  liftIO $ putStrLn $ "[RUNNER] Workflow exited due to user abort — deferring: " <> T.unpack (releaseId rt)
                  liftIO $ insertReleaseEvent db (releaseId rt) "BUSINESS" "WORKFLOW_ABORT_EXIT" (toJSON (show err))
                else do
                  endNow <- liftIO getCurrentTime
                  let abortedTracker = rtNew{status = Aborted, releaseWFStatus = RollingBack, endTime = Just endNow}
                  liftIO $ insertReleaseTracker db abortedTracker mts
                  liftIO $ insertReleaseEvent db (releaseId rt) "BUSINESS" "FAILED" (toJSON (show err))
                  liftIO $ restoreVsTrafficOnFailure cfg' db rt mts
                  liftIO $ notifyReleaseAborted db abortedTracker
            Right _finalState ->
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

restoreVsTrafficOnFailure :: Config -> DBEnv -> ReleaseTracker -> Maybe TargetState -> IO ()
restoreVsTrafficOnFailure cfg db rt mts = do
  case mts of
    Just (K8sState k8s) -> do
      let ctx = context k8s
          oldVer = K8s.oldVersion ctx
          isNewSvc = newService k8s
      if isNewSvc || T.null oldVer || oldVer == "new" || oldVer == "unknown"
        then putStrLn $ "[restoreVsTrafficOnFailure] Skipping VS restore for " <> T.unpack (releaseId rt) <> " (new service or no old version)"
        else do
          putStrLn $ "[restoreVsTrafficOnFailure] Restoring VS traffic to old version for " <> T.unpack (releaseId rt)
          vsResult <- applyVirtualServiceRollout cfg ctx 100 0
          case vsResult of
            Left err -> putStrLn $ "[restoreVsTrafficOnFailure] WARNING: Failed to restore VS: " <> show err
            Right _ -> putStrLn $ "[restoreVsTrafficOnFailure] VS traffic restored to old version"
          let newDepName = deploymentName ctx
              ns = namespace ctx
          scaleResult <- runCmd (buildScaleNamedDeploymentCommand cfg ns newDepName 0)
          case scaleResult of
            Left err -> putStrLn $ "[restoreVsTrafficOnFailure] WARNING: Failed to scale down new deployment: " <> show err
            Right _ -> putStrLn $ "[restoreVsTrafficOnFailure] New deployment scaled down to 0"
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

handleAbortingRelease :: Config -> DBEnv -> ReleaseTracker -> Maybe TargetState -> IO ()
handleAbortingRelease cfg db rt mts = do
  putStrLn $ "[handleAbortingRelease] Processing abort for " <> T.unpack (releaseId rt)
  restoreVsTrafficOnFailure cfg db rt mts
  now <- getCurrentTime
  let aborted = rt{status = UserAborted, endTime = Just now}
  insertReleaseTracker db aborted mts
  insertReleaseEvent db (releaseId rt) "BUSINESS" "ABORT_HANDLED" (toJSON ("User abort processed" :: String))
  notifyReleaseAborted db aborted

-- ============================================================================
-- Scale-Down of Old Deployments After Delay
-- ============================================================================

-- | Scale down old deployment. Sends Slack notification only on success.
scaleDownOldDeployment :: DBEnv -> Config -> TrackerWithTarget -> IO ()
scaleDownOldDeployment db cfg (rt, mts) = do
  case mts of
    Just (K8sState k8s) -> do
      let ctx = context k8s
          oldVer = K8s.oldVersion ctx
          svcName = serviceName ctx
          ns = namespace ctx
          oldDepName = svcName <> "-" <> oldVer
      if T.null oldVer || oldVer == "new" || oldVer == "unknown"
        then pure ()
        else do
          putStrLn $ "[scaleDownOldDeployment] Scaling down old deployment: " <> T.unpack oldDepName <> " for release " <> T.unpack (releaseId rt)
          result <- runCmd (buildScaleNamedDeploymentCommand cfg ns oldDepName 0)
          case result of
            Left err -> putStrLn $ "[scaleDownOldDeployment] WARNING: Failed to scale down: " <> show err
            Right _ -> do
              putStrLn $ "[scaleDownOldDeployment] Old deployment scaled down successfully"
              notifyPodsScaledDown db rt oldVer
          let updatedCtx = ctx{podsScaleDownStatus = Just ScaleDownCompleted}
              updatedK8s = k8s{context = updatedCtx}
              updatedMts = Just (K8sState updatedK8s)
          insertReleaseTracker db rt updatedMts
          insertReleaseEvent
            db
            (releaseId rt)
            "BUSINESS"
            "OLD_PODS_SCALED_DOWN"
            (object ["oldDeployment" .= (oldDepName :: T.Text), "namespace" .= (ns :: T.Text)])
    _ -> pure ()
