module NammaAP.Runner where

import Prelude hiding (product)
import Control.Concurrent (threadDelay)
import Control.Monad (forever)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (toJSON)
import Data.Maybe (isJust)
import qualified Data.Map.Strict as Map
import Data.Time.Clock (getCurrentTime)
import NammaAP.App.Storage.Queries.ReleaseTracker
import NammaAP.App.Storage.Queries.ProductService (findProductByNameAndCluster, getProductVsLockedBy)
import NammaAP.Config (Config (..), isMultiReleasePerProduct, runnerPollSeconds)
import NammaAP.Environment (AppState, DBEnv)
import NammaAP.Utils.FlowMonad
import NammaAP.Types
import NammaAP.Types.Target (TargetState(..))
import NammaAP.Types.Target.Kubernetes (K8sDeploymentState(..), K8sReleaseContext(..), PodsScaleDownStatus(..))
import NammaAP.Workflow.Types (WorkFlowError, ReleaseState(..))
import NammaAP.Workflow.Factory (executeReleaseWorkflow)

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
      let picked = pickJobs (isMultiReleasePerProduct cfg) eligible
      mapM_ (trigger db) picked

      -- TODO: Step 3: Handle aborting trackers (needs reimplementation)
      -- aborting <- liftIO $ findAbortingReleaseTrackers db
      -- mapM_ runRollbackOnly aborting

      -- TODO: Step 4: Handle cleanup jobs (needs reimplementation)
      -- cleanupJobs <- liftIO $ findCleanupScheduledTrackers db now
      -- mapM_ runScheduledCleanup cleanupJobs

      -- TODO: Step 5: Handle scale-down (needs reimplementation)
      -- let scaleDownTime = addUTCTime (fromIntegral (-(oldDeploymentCleanupDelaySeconds cfg))) now
      -- scaleDownCandidates <- liftIO $ findTrackersWithStatusAndTime db
      --   ["Completed", "Aborted", "UserAborted", "GcltAborted"] scaleDownTime
      -- mapM_ runScheduledCleanup (filter isScaleDownReady scaleDownCandidates)

      liftIO $ threadDelay (runnerPollSeconds cfg * 1000000)

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
  -- Mark InProgress BEFORE dispatching to prevent re-pickup on next poll
  let rtInProgress = rt { status = InProgress }
  liftIO $ insertReleaseTracker db rtInProgress mts
  liftIO $ insertReleaseEvent db (releaseId rt) "BUSINESS" "RUNNER_PICKED" (toJSON rt)
  result <- dispatchWorkflow rtInProgress mts
  case result of
    Left err -> do
      let errStatus = case status rt of
            Aborting -> UserAborted
            _ -> Aborted
      liftIO $ insertReleaseTracker db (rtInProgress {status = errStatus, releaseWFStatus = RollingBack}) mts
      liftIO $ insertReleaseEvent db (releaseId rt) "BUSINESS" "FAILED" (toJSON (show err))
    Right finalState -> do
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

