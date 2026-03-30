{-# LANGUAGE OverloadedStrings #-}

-- | Backend service workflow (K8s deployment)
--
-- This module implements the workflow for deploying backend services to Kubernetes.
-- It uses the new type system with:
-- - ReleaseCategory (BackendService)
-- - ReleaseWFStatus (generic stages)
-- - BackendServiceWFStatus (K8s-specific sub-stages)
-- - Recorded monad for checkpoint/resume
module Products.Autopilot.Workflow.BackendServiceWorkflow
  ( backendServiceWorkflow
  ) where

import Prelude hiding (product)
import Control.Monad (when, forM_)
import Control.Monad.State.Strict (gets, modify)
import Control.Monad.Trans.Class (lift)
import Control.Monad.IO.Class (liftIO)
import Control.Concurrent (threadDelay)
import qualified Data.Text as T

import Core.Config (Config(..))
import Core.Environment (DBEnv)
import Core.Utils.FlowMonad (getConfig, getDBEnv)
import Products.Autopilot.K8s.Execute (K8sError(..), runCmd, executeWithRetry)
import Products.Autopilot.K8s.Deployment
  ( deploymentExists, getDeploymentReplicaStatus
  , buildCloneDeploymentCommand, buildScaleNamedDeploymentCommand
  , buildDeleteDeploymentCommand, buildConfigMapApplyCommand, serviceExists )
import Products.Autopilot.K8s.VirtualService (applyVirtualServiceRollout)
import Products.Autopilot.K8s.DestinationRule (ensureDestinationRule)
import Products.Autopilot.Notifications
  ( notifyReleaseProgress
  , notifyReleaseCompleted
  , notifyPodsScaledDown
  )
import Products.Autopilot.Workflow.Helpers
  ( (|>>)
  , updateRT
  , getRT
  )
import Products.Autopilot.Workflow.Types
  ( ReleaseWorkFlow
  , StateFlow
  , ReleaseState(..)
  )
-- Selective import: exclude oldVersion/newVersion to avoid clash with K8sReleaseContext
import Products.Autopilot.Types.Release (ReleaseStatus(..), ReleaseTracker(product, releaseId, status))
import Products.Autopilot.Types.Workflow (ReleaseWFStatus(..))
import Products.Autopilot.Types.Target
  ( TargetState(..)
  , K8sDeploymentState(..)
  , BackendServiceWFStatus(..)
  , emptyK8sState
  )
import Products.Autopilot.Types.Target.Kubernetes (K8sReleaseContext(..))

-- ============================================================================
-- Workflow Definition
-- ============================================================================

-- | Backend service workflow using generic stages
backendServiceWorkflow :: ReleaseWorkFlow ()
backendServiceWorkflow = do
  Init |>> validatePreconditions
  Preparing |>> prepareK8sResources
  Deploying |>> progressiveRollout
  Monitoring |>> monitorHealth
  Finalizing |>> cleanupOldVersion
  Done |>> notifyComplete

-- ============================================================================
-- Helpers: Config / Context / K8s IO
-- ============================================================================

-- | Get bootstrap config from the Flow (ReaderT) environment
getCfg :: StateFlow Config
getCfg = lift getConfig

-- | Get DBEnv from the Flow (ReaderT) environment
getDB :: StateFlow DBEnv
getDB = lift getDBEnv

-- | Extract K8sReleaseContext from the current workflow state
getK8sCtx :: StateFlow K8sReleaseContext
getK8sCtx = do
  rs <- gets id
  case targetState rs of
    Just (K8sState k8s) -> pure (context k8s)
    _ -> error "BackendServiceWorkflow: missing K8sState in targetState"

-- | Run an IO action that returns Either K8sError, lifting into StateFlow
runK8sIO :: IO (Either K8sError a) -> StateFlow a
runK8sIO action = do
  result <- liftIO action
  case result of
    Right a  -> pure a
    Left (K8sError err) -> error ("K8s error: " <> T.unpack err)

-- ============================================================================
-- Workflow Step Implementations
-- ============================================================================

-- | Validate preconditions: cluster reachable, namespace exists
validatePreconditions :: StateFlow ()
validatePreconditions = do
  rt <- getRT
  cfg <- getCfg
  liftIO $ putStrLn $ "Validating preconditions for " <> T.unpack (product rt)

  -- Initialise or update K8s deployment state
  rs <- gets id
  case targetState rs of
    Just (K8sState k8s) ->
      modify $ \s -> s { targetState = Just (K8sState (k8s { categoryWorkflowStatus = BSInit })) }
    _ -> do
      let k8sState = emptyK8sState { categoryWorkflowStatus = BSInit }
      modify $ \s -> s { targetState = Just (K8sState k8sState) }

  ctx <- getK8sCtx

  -- Check cluster reachable by verifying namespace exists
  liftIO $ putStrLn "  Checking cluster reachability"
  _ <- runK8sIO $ runCmd (unwords [kubectlBin cfg, "-n", T.unpack (namespace ctx),
                                   "get namespace", T.unpack (namespace ctx)])

  liftIO $ putStrLn "  Cluster reachable, namespace exists"
  liftIO $ putStrLn "Preconditions validated"

-- | Prepare K8s resources: ConfigMap, clone deployment, service check, DestinationRule
prepareK8sResources :: StateFlow ()
prepareK8sResources = do
  rt <- getRT
  cfg <- getCfg
  ctx <- getK8sCtx
  liftIO $ putStrLn $ "Preparing K8s resources for " <> T.unpack (product rt)

  -- 1. Apply ConfigMap
  updateK8sStatus BSApplyConfigMap
  liftIO $ putStrLn "  Applying ConfigMap"
  _ <- runK8sIO $ executeWithRetry cfg (buildConfigMapApplyCommand cfg ctx)
  updateK8sField (\k8s -> k8s { configMapApplied = True })

  -- 2. Clone deployment (skip if target already exists, e.g. checkpoint resume)
  updateK8sStatus BSCreateDeployment
  newDepExists <- liftIO $ deploymentExists cfg (namespace ctx) (deploymentName ctx)
  if newDepExists
    then liftIO $ putStrLn "  Deployment already exists, skipping clone"
    else do
      liftIO $ putStrLn $ "  Cloning deployment to " <> T.unpack (deploymentName ctx)
      _ <- runK8sIO $ executeWithRetry cfg (buildCloneDeploymentCommand cfg ctx)
      pure ()
  updateK8sField (\k8s -> k8s { deploymentCreated = True })

  -- 3. Check Service exists
  updateK8sStatus BSUpdateService
  liftIO $ putStrLn "  Checking Service exists"
  svcOk <- liftIO $ serviceExists cfg (namespace ctx) (serviceName ctx)
  when (not svcOk) $
    liftIO $ putStrLn "  WARNING: Service not found (pods may still route via selector)"
  updateK8sField (\k8s -> k8s { serviceCreated = svcOk })

  -- 4. Ensure DestinationRule (creates if missing, adds subset if existing)
  updateK8sStatus BSApplyDestinationRule
  liftIO $ putStrLn "  Ensuring DestinationRule"
  _ <- runK8sIO $ ensureDestinationRule cfg ctx
  updateK8sField (\k8s -> k8s { destinationRuleApplied = True })

  liftIO $ putStrLn "K8s resources prepared"

-- | Progressive rollout: shift traffic old -> new in steps
progressiveRollout :: StateFlow ()
progressiveRollout = do
  rt <- getRT
  cfg <- getCfg
  ctx <- getK8sCtx
  liftIO $ putStrLn $ "Starting progressive rollout for " <> T.unpack (product rt)

  updateK8sStatus BSFlipVirtualService
  updateK8sField (\k8s -> k8s { virtualServiceApplied = True })

  updateK8sStatus BSProgressiveRollout
  -- Traffic weight steps: (oldWeight, newWeight)
  let steps = [(75, 25), (50, 50), (0, 100)] :: [(Int, Int)]
  db <- getDB
  forM_ steps $ \(oldW, newW) -> do
    liftIO $ putStrLn $ "  Shifting traffic: old=" <> show oldW <> "% new=" <> show newW <> "%"
    _ <- runK8sIO $ applyVirtualServiceRollout cfg ctx oldW newW
    updateK8sField (\k8s -> k8s { trafficPercentage = newW })

    -- Notify Slack of traffic shift
    currentRT <- getRT
    liftIO $ notifyReleaseProgress db currentRT newW

    -- Health check between steps (skip after final 100% step)
    when (newW < 100) $ do
      liftIO $ threadDelay 5000000  -- 5 seconds between steps
      checkDeploymentHealth cfg ctx

  liftIO $ putStrLn "Progressive rollout complete"

-- | Check deployment health via replica status
checkDeploymentHealth :: Config -> K8sReleaseContext -> StateFlow ()
checkDeploymentHealth cfg ctx = do
  (ready, available, desired) <- runK8sIO $
    getDeploymentReplicaStatus cfg (namespace ctx) (deploymentName ctx)
  liftIO $ putStrLn $ "    Health: ready=" <> show ready
    <> " available=" <> show available <> " desired=" <> show desired
  when (ready < desired) $
    liftIO $ putStrLn "    WARNING: Not all replicas ready yet"

-- | Monitor health: poll replica status for stabilisation period
monitorHealth :: StateFlow ()
monitorHealth = do
  rt <- getRT
  cfg <- getCfg
  ctx <- getK8sCtx
  liftIO $ putStrLn $ "Monitoring health for " <> T.unpack (product rt)

  updateK8sStatus BSMonitoring
  liftIO $ putStrLn "  Monitoring pod health metrics"

  updateK8sStatus BSStabilize
  liftIO $ putStrLn "  Stabilization period (30s)"
  let checks = 6 :: Int  -- 6 * 5s = 30s
  forM_ [1..checks] $ \i -> do
    liftIO $ threadDelay 5000000  -- 5 seconds
    (ready, _available, desired) <- runK8sIO $
      getDeploymentReplicaStatus cfg (namespace ctx) (deploymentName ctx)
    liftIO $ putStrLn $ "    Check " <> show i <> "/" <> show checks
      <> ": ready=" <> show ready <> "/" <> show desired

  liftIO $ putStrLn "Health monitoring complete"

-- | Cleanup old version: scale down (and optionally delete) old deployment
cleanupOldVersion :: StateFlow ()
cleanupOldVersion = do
  rt <- getRT
  cfg <- getCfg
  ctx <- getK8sCtx
  liftIO $ putStrLn $ "Cleaning up old version for " <> T.unpack (product rt)

  updateK8sStatus BSScaleDownOld
  let oldDepName = serviceName ctx <> "-" <> oldVersion ctx
  liftIO $ putStrLn $ "  Scaling down old deployment: " <> T.unpack oldDepName

  -- Scale old deployment to 0 replicas
  _ <- runK8sIO $ runCmd (buildScaleNamedDeploymentCommand cfg (namespace ctx) oldDepName 0)
  updateK8sField (\k8s -> k8s { oldDeploymentScaledDown = True })

  -- Notify Slack of pods scaled down
  db <- getDB
  liftIO $ notifyPodsScaledDown db rt (oldVersion ctx)

  -- Optionally delete old deployment
  when (deleteOldDeploymentOnComplete cfg) $ do
    liftIO $ putStrLn $ "  Deleting old deployment: " <> T.unpack oldDepName
    _ <- runK8sIO $ runCmd (buildDeleteDeploymentCommand cfg (namespace ctx) oldDepName)
    pure ()

  liftIO $ putStrLn "Cleanup complete"

-- | Notify complete
notifyComplete :: StateFlow ()
notifyComplete = do
  rt <- getRT
  db <- getDB
  updateK8sStatus BSDone

  liftIO $ putStrLn $ "Release " <> T.unpack (releaseId rt) <> " completed successfully!"
  liftIO $ putStrLn $ "   Service: " <> T.unpack (product rt)
  liftIO $ putStrLn $ "   Category: BackendService"
  liftIO $ putStrLn $ "   Status: Completed"

  updateRT $ \r -> r { status = Completed }

  -- Notify Slack
  liftIO $ notifyReleaseCompleted db rt

-- ============================================================================
-- K8s State Helpers
-- ============================================================================

-- | Update K8s workflow status
updateK8sStatus :: BackendServiceWFStatus -> StateFlow ()
updateK8sStatus newStatus = do
  rs <- gets id
  case targetState rs of
    Just (K8sState k8s) -> do
      let k8s' = k8s { categoryWorkflowStatus = newStatus }
      modify $ \s -> s { targetState = Just (K8sState k8s') }
    _ -> return ()

-- | Update K8s deployment state field
updateK8sField :: (K8sDeploymentState -> K8sDeploymentState) -> StateFlow ()
updateK8sField f = do
  rs <- gets id
  case targetState rs of
    Just (K8sState k8s) -> do
      let k8s' = f k8s
      modify $ \s -> s { targetState = Just (K8sState k8s') }
    _ -> return ()
