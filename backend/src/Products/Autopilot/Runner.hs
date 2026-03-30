module Products.Autopilot.Runner where

import Control.Concurrent (threadDelay)
import Control.Monad (forever)
import Control.Monad.IO.Class (liftIO)
import Core.Config (Config (..))
import Products.Autopilot.RuntimeConfig (getReleaseWatchDelay, isMultiReleasePerProduct)
import Core.Environment (AppState, DBEnv)
import Core.Utils.FlowMonad
import Data.Aeson (Value (..), toJSON, object, (.=))
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Products.Autopilot.K8s.VirtualService (getPrimarySubsetFromVirtualService)
import Products.Autopilot.Notifications (notifyReleaseAborted)
import Products.Autopilot.Queries.ProductService (findProductByNameAndCluster, getProductVsLockedBy)
import Products.Autopilot.Queries.ReleaseTracker
import Products.Autopilot.Types
import qualified Products.Autopilot.Types as NT
import Products.Autopilot.Types.Target (TargetState (..))
import Products.Autopilot.Types.Target.Kubernetes (K8sDeploymentState (..), K8sReleaseContext (..), PodsScaleDownStatus (..))
import Products.Autopilot.Workflow.Factory (executeReleaseWorkflow)
import Products.Autopilot.Workflow.Types (ReleaseState (..), WorkFlowError)
import Prelude hiding (product)

runnerLoop :: AppState -> IO ()
runnerLoop st = runFlow st loop
  where
    loop = forever $ do
        _cfg <- getConfig
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

        -- TODO: Step 3: Handle aborting trackers (needs reimplementation)
        -- aborting <- liftIO $ findAbortingReleaseTrackers db
        -- mapM_ runRollbackOnly aborting

        -- TODO: Step 4: Handle cleanup jobs (needs reimplementation)
        -- cleanupJobs <- liftIO $ findCleanupScheduledTrackers db now
        -- mapM_ runScheduledCleanup cleanupJobs

        -- TODO: Step 5: Handle scale-down (needs reimplementation)
        -- scaleDownCandidates <- ...
        -- mapM_ runScheduledCleanup (filter isScaleDownReady scaleDownCandidates)

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
  where
    k8sEligible skipOngoingCheck = do
        let k8sCluster = case mts of
                Just (K8sState k8s) -> cluster (context k8s)
                _ -> ""
        p <- findProductByNameAndCluster db (product rt) k8sCluster
        let vsLocked = maybe False (isJust . getProductVsLockedBy) p
            hasOngoingSameProduct = any (\(o, _) -> product o == product rt && env o == env rt) ongoing
        pure (not vsLocked && (skipOngoingCheck || not hasOngoingSameProduct))

-- | Trigger a release - dispatch to appropriate workflow using new Factory
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
            -- Mark InProgress BEFORE dispatching to prevent re-pickup on next poll
            let rtInProgress = rt{status = InProgress}
            liftIO $ insertReleaseTracker db rtInProgress mts
            liftIO $ insertReleaseEvent db (releaseId rt) "BUSINESS" "RUNNER_PICKED" (toJSON rt)
            result <- dispatchWorkflow rtInProgress mts
            case result of
                Left err -> do
                    let errStatus = case status rt of
                            Aborting -> UserAborted
                            _ -> Aborted
                        abortedTracker = rtInProgress{status = errStatus, releaseWFStatus = RollingBack}
                    liftIO $ insertReleaseTracker db abortedTracker mts
                    liftIO $ insertReleaseEvent db (releaseId rt) "BUSINESS" "FAILED" (toJSON (show err))
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
        let key = product rt <> ":" <> env rt
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
