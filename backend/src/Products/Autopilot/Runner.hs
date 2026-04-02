module Products.Autopilot.Runner where

import Control.Concurrent (threadDelay)
import Control.Monad (forever, forM_)
import Control.Monad.IO.Class (liftIO)
import Core.Config (Config (..))
import Products.Autopilot.RuntimeConfig (getReleaseWatchDelay, isMultiReleasePerProduct, getPodsScaleDownDelayFromConfig)
import Core.Environment (AppState, DBEnv)
import Core.Utils.FlowMonad
import Data.Aeson (toJSON, object, (.=))
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Products.Autopilot.K8s.Deployment (buildScaleNamedDeploymentCommand)
import Products.Autopilot.K8s.Execute (runCmd)
import Products.Autopilot.K8s.VirtualService (getPrimarySubsetFromVirtualService, applyVirtualServiceRollout)
import Products.Autopilot.Notifications (notifyReleaseAborted)
import Products.Autopilot.Queries.ProductService (findProductByNameAndCluster, getProductVsLockedBy)
import Products.Autopilot.Queries.ReleaseTracker
import Products.Autopilot.Types
import qualified Products.Autopilot.Types as NT
import Products.Autopilot.Types.Target (TargetState (..))
import Products.Autopilot.Types.Target.Kubernetes (K8sDeploymentState (..), K8sReleaseContext (..), PodsScaleDownStatus (..))
import qualified Products.Autopilot.Types.Target.Kubernetes as K8s
import Products.Autopilot.Workflow.Factory (executeReleaseWorkflow)
import Products.Autopilot.Workflow.Types (ReleaseState (..), WorkFlowError)
import Prelude

runnerLoop :: AppState -> IO ()
runnerLoop st = runFlow st loop
  where
    loop = forever $ do
        cfg <- getConfig
        db <- getDBEnv
        now <- liftIO getCurrentTime

        -- Step 1: Find runnable trackers (CREATED + RECORDING, approved, schedule due)
        jobs <- liftIO $ findRunnableReleaseTrackers db now
        ongoing <- liftIO $ findOngoingReleaseTrackers db
        eligible <- liftIO $ filterM (isEligibleToRun db ongoing) jobs

        -- Step 2: Pick jobs respecting single-release constraint and priority
        multiRelease <- liftIO $ isMultiReleasePerProduct db
        let picked = pickJobs multiRelease eligible
        mapM_ (trigger db) picked

        -- Step 3: Handle aborting trackers
        abortingTrackers <- liftIO $ findAbortingReleaseTrackers db
        forM_ abortingTrackers $ \(rt, mts) -> liftIO $ handleAbortingRelease cfg db rt mts

        -- TODO: Step 4: Handle cleanup jobs (needs reimplementation)
        -- cleanupJobs <- liftIO $ findCleanupScheduledTrackers db now
        -- mapM_ runScheduledCleanup cleanupJobs

        -- Step 5: Handle scale-down of old deployments after delay
        scaleDownDelay <- liftIO $ getPodsScaleDownDelayFromConfig db
        completedTrackers <- liftIO $ findCompletedTrackersForScaleDown db now scaleDownDelay
        forM_ completedTrackers $ \twt -> liftIO $ scaleDownOldDeployment db cfg twt

        pollDelay <- liftIO $ getReleaseWatchDelay db
        liftIO $ threadDelay (pollDelay * 1000000)

    filterM _ [] = pure []
    filterM f (x : xs) = do
        ok <- f x
        rest <- filterM f xs
        pure (if ok then x : rest else rest)

isEligibleToRun :: DBEnv -> [TrackerWithTarget] -> TrackerWithTarget -> IO Bool
isEligibleToRun db ongoing (rt, mts) = case category rt of
    BackendService -> k8sEligible False
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

-- | Trigger a release - dispatch to appropriate workflow using new Factory.
-- Uses conditionalUpdateTrackerRow to atomically claim the release only if still CREATED,
-- preventing double-pick by concurrent runner instances.
trigger :: DBEnv -> TrackerWithTarget -> Flow ()
trigger db (rt, mts) = do
    cfg <- getConfig
    -- Version validation: compare tracker's oldVersion with what K8s actually has
    versionOk <- liftIO $ validateRunningVersion cfg db rt mts
    case versionOk of
        Just mismatchMsg -> do
            -- Version mismatch: discard the release
            let discarded = rt{status = Discarded}
            liftIO $ insertReleaseTracker db discarded mts
            liftIO $ insertReleaseEvent db (releaseId rt) "BUSINESS" "VERSION_MISMATCH"
                (object
                    [ "message" .= mismatchMsg
                    , "trackerOldVersion" .= NT.oldVersion rt
                    ])
            liftIO $ notifyReleaseAborted db discarded
            pure ()
        Nothing -> do
            -- Atomically claim: DELETE WHERE status='CREATED' + INSERT with INPROGRESS
            -- If another runner already changed the status, this returns False.
            now <- liftIO getCurrentTime
            let rtInProgress = rt{status = InProgress, startTime = Just now}
                row = toRow now now rtInProgress mts
            claimed <- liftIO $ conditionalUpdateTrackerRow db row "CREATED"
            if not claimed
                then liftIO $ putStrLn $ "[RUNNER] Release " <> T.unpack (releaseId rt) <> " already claimed by another runner, skipping"
                else do
                    liftIO $ insertReleaseEvent db (releaseId rt) "BUSINESS" "RUNNER_PICKED" (toJSON rt)
                    result <- dispatchWorkflow rtInProgress mts
                    case result of
                        Left err -> do
                            cfg' <- getConfig
                            -- Re-read tracker from DB to get the current status (user may have set ABORTING)
                            freshM <- liftIO $ findReleaseTracker db (releaseId rt)
                            let currentStatus = case freshM of
                                    Just (freshRT, _) -> status freshRT
                                    Nothing           -> status rtInProgress
                                isUserAbort = currentStatus == Aborting || currentStatus == UserAborted
                            if isUserAbort
                                then do
                                    -- User abort: leave status as ABORTING so that handleAbortingRelease
                                    -- (Step 3 of runLoop) picks it up and is the SOLE handler for
                                    -- VS restoration + status transition. This prevents duplicate kubectl calls.
                                    liftIO $ putStrLn $ "[RUNNER] Workflow exited due to user abort — deferring to handleAbortingRelease: " <> T.unpack (releaseId rt)
                                    liftIO $ insertReleaseEvent db (releaseId rt) "BUSINESS" "WORKFLOW_ABORT_EXIT" (toJSON (show err))
                                else do
                                    -- Non-abort failure: handle VS restoration here
                                    endNow <- liftIO getCurrentTime
                                    let abortedTracker = rtInProgress{status = Aborted, releaseWFStatus = RollingBack, endTime = Just endNow}
                                    liftIO $ insertReleaseTracker db abortedTracker mts
                                    liftIO $ insertReleaseEvent db (releaseId rt) "BUSINESS" "FAILED" (toJSON (show err))
                                    liftIO $ restoreVsTrafficOnFailure cfg' db rt mts
                                    liftIO $ notifyReleaseAborted db abortedTracker
                        Right _finalState -> do
                            liftIO $ insertReleaseEvent db (releaseId rt) "BUSINESS" "COMPLETED" (toJSON ("success" :: String))

-- | Dispatch to the new workflow factory
dispatchWorkflow :: ReleaseTracker -> Maybe TargetState -> Flow (Either WorkFlowError ReleaseState)
dispatchWorkflow rt mts = do
    let initialState = ReleaseState rt mts Nothing
    executeReleaseWorkflow initialState

-- | Check if a tracker is ready for scale-down
isScaleDownReady :: TrackerWithTarget -> Bool
isScaleDownReady (_, mts) =
    case mts of
        Just (K8sState k8s) ->
            let ctx = context k8s
             in case podsScaleDownStatus ctx of
                    Just ScaleDownScheduled -> True
                    _ -> case cleanupStatus ctx of
                        Just "SCALE_DOWN_SCHEDULED" -> True
                        _ -> False
        _ -> False

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

-- | Sort jobs by priority (higher priority first), then by schedule time
sortByPriority :: [TrackerWithTarget] -> [TrackerWithTarget]
sortByPriority = foldr insert []
  where
    insert twt [] = [twt]
    insert twt@(rt, _) (x@(xrt, _) : xs)
        | priority rt > priority xrt = twt : x : xs
        | otherwise = x : insert twt xs

-- ============================================================================
-- Version Validation
-- ============================================================================

{- | Validate the running version matches the tracker's oldVersion.
Returns Nothing if validation passes (or cannot be performed),
Just errorMessage if there is a mismatch.
-}
validateRunningVersion :: Config -> DBEnv -> ReleaseTracker -> Maybe TargetState -> IO (Maybe T.Text)
validateRunningVersion cfg db rt mts = do
    -- Only validate K8s-backed releases
    case mts of
        Just (K8sState k8s) -> do
            let ctx = context k8s
                ns = namespace ctx
                vsName' = virtualServiceName ctx
                svcHost = serviceName ctx
                trackerOldVer = NT.oldVersion rt
                isNewSvc = newService k8s
            -- Skip validation for new services, or if oldVersion is empty/unknown/new
            if isNewSvc || T.null trackerOldVer || T.toLower trackerOldVer == "unknown" || trackerOldVer == "new"
                then pure Nothing
                else do
                    result <- getPrimarySubsetFromVirtualService cfg ns vsName' svcHost
                    case result of
                        Left _err ->
                            -- Cannot validate (VS not found, etc.) - let it through
                            pure Nothing
                        Right Nothing ->
                            -- No primary subset found - let it through
                            pure Nothing
                        Right (Just runningVersion) ->
                            if runningVersion == trackerOldVer
                                then pure Nothing
                                else pure $ Just $
                                    "Running version (" <> runningVersion <> ") does not match tracker oldVersion (" <> trackerOldVer <> ")"
        _ -> pure Nothing -- Non-K8s releases: skip validation

-- ============================================================================
-- Failure Recovery: Restore VS Traffic
-- ============================================================================

{- | Restore VirtualService traffic to old version on release failure.
Routes 100% traffic back to old version and scales down new deployment to 0.
Best-effort: errors are logged but do not propagate.
-}
restoreVsTrafficOnFailure :: Config -> DBEnv -> ReleaseTracker -> Maybe TargetState -> IO ()
restoreVsTrafficOnFailure cfg db rt mts = do
    case mts of
        Just (K8sState k8s) -> do
            let ctx = context k8s
                oldVer = K8s.oldVersion ctx
                isNewSvc = newService k8s
            -- Only restore VS if there is an old version to restore to
            if isNewSvc || T.null oldVer || oldVer == "new" || oldVer == "unknown"
                then putStrLn $ "[restoreVsTrafficOnFailure] Skipping VS restore for " <> T.unpack (releaseId rt) <> " (new service or no old version)"
                else do
                    putStrLn $ "[restoreVsTrafficOnFailure] Restoring VS traffic to old version for " <> T.unpack (releaseId rt)
                    -- Route 100% back to old version, 0% to new
                    vsResult <- applyVirtualServiceRollout cfg ctx 100 0
                    case vsResult of
                        Left err -> putStrLn $ "[restoreVsTrafficOnFailure] WARNING: Failed to restore VS: " <> show err
                        Right _ -> putStrLn $ "[restoreVsTrafficOnFailure] VS traffic restored to old version"
                    -- Scale down new deployment to 0 replicas
                    let newDepName = deploymentName ctx
                        ns = namespace ctx
                    scaleResult <- runCmd (buildScaleNamedDeploymentCommand cfg ns newDepName 0)
                    case scaleResult of
                        Left err -> putStrLn $ "[restoreVsTrafficOnFailure] WARNING: Failed to scale down new deployment: " <> show err
                        Right _ -> putStrLn $ "[restoreVsTrafficOnFailure] New deployment scaled down to 0"
                    -- Log the restore event
                    insertReleaseEvent db (releaseId rt) "BUSINESS" "VS_TRAFFIC_RESTORED"
                        (object
                            [ "action" .= ("restore_on_failure" :: T.Text)
                            , "oldVersion" .= (oldVer :: T.Text)
                            , "newDeployment" .= (newDepName :: T.Text)
                            ])
        _ -> pure () -- Non-K8s releases: nothing to restore

-- ============================================================================
-- Abort Handling
-- ============================================================================

{- | Handle an aborting release: restore VS traffic, mark as UserAborted, notify.
Best-effort: errors in VS restore are logged but do not prevent status transition.
-}
handleAbortingRelease :: Config -> DBEnv -> ReleaseTracker -> Maybe TargetState -> IO ()
handleAbortingRelease cfg db rt mts = do
    putStrLn $ "[handleAbortingRelease] Processing abort for " <> T.unpack (releaseId rt)
    -- Restore VS traffic to old version
    restoreVsTrafficOnFailure cfg db rt mts
    -- Mark as UserAborted with endTime
    now <- getCurrentTime
    let aborted = rt{status = UserAborted, endTime = Just now}
    insertReleaseTracker db aborted mts
    insertReleaseEvent db (releaseId rt) "BUSINESS" "ABORT_HANDLED" (toJSON ("User abort processed" :: String))
    notifyReleaseAborted db aborted

-- ============================================================================
-- Scale-Down of Old Deployments After Delay
-- ============================================================================

{- | Scale down the old version's deployment for a completed/aborted release.
Updates the tracker's podsScaleDownStatus to ScaleDownCompleted.
-}
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
                        Right _ -> putStrLn $ "[scaleDownOldDeployment] Old deployment scaled down successfully"
                    -- Update tracker with scale-down completed status
                    let updatedCtx = ctx{podsScaleDownStatus = Just ScaleDownCompleted}
                        updatedK8s = k8s{context = updatedCtx}
                        updatedMts = Just (K8sState updatedK8s)
                    insertReleaseTracker db rt updatedMts
                    insertReleaseEvent db (releaseId rt) "BUSINESS" "OLD_PODS_SCALED_DOWN"
                        (object
                            [ "oldDeployment" .= (oldDepName :: T.Text)
                            , "namespace" .= (ns :: T.Text)
                            ])
        _ -> pure ()
