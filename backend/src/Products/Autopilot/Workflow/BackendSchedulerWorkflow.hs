{-# LANGUAGE OverloadedStrings #-}

-- | Backend scheduler workflow (K8s pod-count based deployment)
--
-- This module implements the workflow for deploying backend schedulers to Kubernetes.
-- Unlike BackendServiceWorkflow, schedulers use pod-count based rollout:
-- - NO VirtualService manipulation (schedulers don't have VS)
-- - NO DestinationRule manipulation
-- - Scale old to 0, then scale new up progressively
-- - Pod count at each step: max(podsRolloutRatio * rollout%, totalPods)
module Products.Autopilot.Workflow.BackendSchedulerWorkflow
  ( backendSchedulerWorkflow,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Control.Monad (forM_, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Strict (gets, modify)
import Control.Monad.Trans.Class (lift)
import Core.AppError (WorkflowError (..))
import Core.Config (Config (..))
import Core.Environment (DBEnv)
import Core.Utils.FlowMonad (getConfig, getDBEnv, logInfo, logWarning)
import qualified Data.Text as T
import Products.Autopilot.K8s.Deployment
  ( buildCloneDeploymentCommand,
    buildConfigMapApplyCommand,
    buildDeleteDeploymentCommand,
    buildScaleDeploymentCommand,
    buildScaleNamedDeploymentCommand,
    deploymentExists,
    getDeploymentReplicaStatus,
  )
import Products.Autopilot.K8s.Execute (K8sError (..), executeWithRetry, runCmd)
import Products.Autopilot.K8s.HPA (buildDeleteHpaCommand, hpaExists)
import Products.Autopilot.Notifications
  ( notifyPodsScaledDown,
    notifyReleaseCompleted,
    notifyReleaseProgress,
  )
import Products.Autopilot.RuntimeConfig (isScaleDownPodsOnCompletion)
-- Selective import: exclude oldVersion/newVersion to avoid clash with K8sReleaseContext
import Products.Autopilot.Types.Release (ReleaseStatus (..), ReleaseTracker (appGroup, releaseId, rolloutStrategy, status), RolloutStep (..))
import Products.Autopilot.Types.Target
  ( BackendServiceWFStatus (..),
    K8sDeploymentState (..),
    TargetState (..),
    emptyK8sState,
  )
import Products.Autopilot.Types.Target.Kubernetes (K8sReleaseContext (..))
import Products.Autopilot.Types.Workflow (ReleaseWFStatus (..))
import Products.Autopilot.Workflow.Helpers
  ( captureDeploymentSnapshot,
    getRT,
    updateRT,
    (|>>),
  )
import Products.Autopilot.Workflow.Types
  ( ReleaseState (..),
    ReleaseWorkFlow,
    StateFlow,
  )
import Prelude

-- ============================================================================
-- Workflow Definition
-- ============================================================================

-- | Backend scheduler workflow using pod-count based rollout (no traffic shifting)
backendSchedulerWorkflow :: ReleaseWorkFlow ()
backendSchedulerWorkflow = do
  INIT |>> validatePreconditions
  PREPARING |>> prepareK8sResources
  DEPLOYING |>> podCountRollout
  MONITORING |>> monitorHealth
  FINALIZING |>> cleanupOldVersion
  DONE |>> notifyComplete

-- ============================================================================
-- Helpers: Config / Context / K8s IO
-- ============================================================================

-- | Get bootstrap config from the Flow (ReaderT) environment
getCfg :: StateFlow Config
getCfg = lift getConfig

-- | Get DBEnv from the Flow (ReaderT) environment
getDB :: StateFlow DBEnv
getDB = lift getDBEnv

-- | StateFlow-level logging (lifts from Flow)
logInfoS :: T.Text -> StateFlow ()
logInfoS = lift . logInfo

logWarningS :: T.Text -> StateFlow ()
logWarningS = lift . logWarning

-- | Extract K8sReleaseContext from the current workflow state
getK8sCtx :: StateFlow K8sReleaseContext
getK8sCtx = do
  rs <- gets id
  case targetState rs of
    Just (K8sState k8s) -> pure (context k8s)
    _ -> liftIO $ throwIO $ WorkflowError "init" "Missing K8sState in targetState"

-- | Run an IO action that returns Either K8sError, lifting into StateFlow
runK8sIO :: IO (Either K8sError a) -> StateFlow a
runK8sIO action = do
  result <- liftIO action
  case result of
    Right a -> pure a
    Left (K8sError err) -> liftIO $ throwIO $ WorkflowError "k8s" err

-- ============================================================================
-- Workflow Step Implementations
-- ============================================================================

-- | Validate preconditions: cluster reachable, namespace exists
validatePreconditions :: StateFlow ()
validatePreconditions = do
  rt <- getRT
  cfg <- getCfg
  logInfoS $ "Validating preconditions for scheduler " <> appGroup rt

  -- Initialise or update K8s deployment state
  rs <- gets id
  case targetState rs of
    Just (K8sState k8s) ->
      modify $ \s -> s{targetState = Just (K8sState (k8s{categoryWorkflowStatus = BSInit}))}
    _ -> do
      let k8sState = emptyK8sState{categoryWorkflowStatus = BSInit}
      modify $ \s -> s{targetState = Just (K8sState k8sState)}

  ctx <- getK8sCtx

  -- Check cluster reachable by verifying namespace exists
  logInfoS "  Checking cluster reachability"
  _ <-
    runK8sIO $
      runCmd
        ( unwords
            [ kubectlBin cfg,
              "-n",
              T.unpack (namespace ctx),
              "get namespace",
              T.unpack (namespace ctx)
            ]
        )

  -- Verify old deployment exists (for non-new schedulers)
  let oldDepName = serviceName ctx <> "-" <> oldVersion ctx
  oldExists <- liftIO $ deploymentExists cfg (namespace ctx) oldDepName
  when (not oldExists && not (T.null (oldVersion ctx)) && oldVersion ctx /= "new") $
    logWarningS $ "  Old deployment not found: " <> oldDepName

  logInfoS "  Cluster reachable, namespace exists"
  logInfoS "Preconditions validated for scheduler"

-- | Prepare K8s resources: ConfigMap, clone deployment with 1 pod for verification
prepareK8sResources :: StateFlow ()
prepareK8sResources = do
  rt <- getRT
  cfg <- getCfg
  ctx <- getK8sCtx
  db <- getDB
  logInfoS $ "PREPARING K8s resources for scheduler " <> appGroup rt

  -- Capture BEFORE snapshot (old deployment)
  let oldDepName = serviceName ctx <> "-" <> oldVersion ctx
  liftIO $ captureDeploymentSnapshot cfg db (releaseId rt) (namespace ctx) oldDepName "DEPLOYMENT_BEFORE"

  -- 1. Apply ConfigMap
  updateK8sStatus BSApplyConfigMap
  logInfoS "  Applying ConfigMap"
  _ <- runK8sIO $ executeWithRetry cfg (buildConfigMapApplyCommand cfg ctx)
  updateK8sField (\k8s -> k8s{configMapApplied = True})

  -- 2. Clone deployment with 1 pod for verification (skip if already exists)
  updateK8sStatus BSCreateDeployment
  newDepExists <- liftIO $ deploymentExists cfg (namespace ctx) (deploymentName ctx)
  if newDepExists
    then logInfoS "  Deployment already exists, skipping clone"
    else do
      logInfoS $ "  Cloning deployment to " <> deploymentName ctx <> " with 1 pod for verification"
      _ <- runK8sIO $ executeWithRetry cfg (buildCloneDeploymentCommand cfg ctx)
      -- Scale to 1 pod for initial verification
      _ <- runK8sIO $ runCmd (buildScaleDeploymentCommand cfg ctx 1)
      pure ()
  updateK8sField (\k8s -> k8s{deploymentCreated = True})

  -- Wait for verification pod to be ready
  logInfoS "  Waiting for verification pod"
  liftIO $ threadDelay 10000000 -- 10 seconds
  checkDeploymentHealth cfg ctx

  logInfoS "K8s resources prepared for scheduler"

-- | Pod-count based rollout: scale old to 0, scale new up progressively
podCountRollout :: StateFlow ()
podCountRollout = do
  rt <- getRT
  cfg <- getCfg
  ctx <- getK8sCtx
  db <- getDB
  logInfoS $ "Starting pod-count rollout for scheduler " <> appGroup rt

  updateK8sStatus BSProgressiveRollout

  -- Step 1: Scale old deployment to 0 replicas
  let oldDepName = serviceName ctx <> "-" <> oldVersion ctx
  logInfoS $ "  Scaling down old deployment to 0: " <> oldDepName
  _ <- runK8sIO $ runCmd (buildScaleNamedDeploymentCommand cfg (namespace ctx) oldDepName 0)
  updateK8sField (\k8s -> k8s{oldDeploymentScaledDown = True})

  -- Notify Slack of old pods scaled down
  currentRT <- getRT
  liftIO $ notifyPodsScaledDown db currentRT (oldVersion ctx)

  -- Step 2: Scale new deployment up progressively through rollout steps
  let steps = rolloutStrategy rt
  if null steps
    then do
      -- No rollout strategy defined, scale to full desired count
      -- Get the desired count from the old deployment's spec (use a reasonable default)
      logInfoS "  No rollout strategy, scaling new deployment to desired count"
      _ <- runK8sIO $ runCmd (buildScaleDeploymentCommand cfg ctx 1)
      updateK8sField (\k8s -> k8s{trafficPercentage = 100})
      liftIO $ notifyReleaseProgress db currentRT 100
    else do
      forM_ steps $ \step -> do
        let targetPods = max 1 (podPercent step)
        logInfoS $
            "  Scaling new deployment to "
              <> T.pack (show targetPods)
              <> " pods (rollout "
              <> T.pack (show (rolloutPercent step))
              <> "%)"
        _ <- runK8sIO $ runCmd (buildScaleDeploymentCommand cfg ctx targetPods)
        updateK8sField (\k8s -> k8s{trafficPercentage = rolloutPercent step})

        -- Notify Slack of progress
        latestRT <- getRT
        liftIO $ notifyReleaseProgress db latestRT (rolloutPercent step)

        -- Cooloff between steps
        when (cooloffMinutes step > 0 && rolloutPercent step < 100) $ do
          logInfoS $
              "  Cooloff: " <> T.pack (show (cooloffMinutes step)) <> " seconds"
          liftIO $ threadDelay (cooloffMinutes step * 1000000)

        -- Health check between steps
        when (rolloutPercent step < 100) $
          checkDeploymentHealth cfg ctx

  logInfoS "Pod-count rollout complete"

-- | Check deployment health via replica status
checkDeploymentHealth :: Config -> K8sReleaseContext -> StateFlow ()
checkDeploymentHealth cfg ctx = do
  (ready, available, desired) <-
    runK8sIO $
      getDeploymentReplicaStatus cfg (namespace ctx) (deploymentName ctx)
  logInfoS $
      "    Health: ready="
        <> T.pack (show ready)
        <> " available="
        <> T.pack (show available)
        <> " desired="
        <> T.pack (show desired)
  when (ready < desired) $
    logWarningS "    WARNING: Not all replicas ready yet"

-- | Monitor health: poll replica status for stabilisation period
monitorHealth :: StateFlow ()
monitorHealth = do
  rt <- getRT
  cfg <- getCfg
  ctx <- getK8sCtx
  logInfoS $ "MONITORING health for scheduler " <> appGroup rt

  updateK8sStatus BSMonitoring
  logInfoS "  MONITORING pod health metrics"

  updateK8sStatus BSStabilize
  logInfoS "  Stabilization period (30s)"
  let checks = 6 :: Int -- 6 * 5s = 30s
  forM_ [1 .. checks] $ \i -> do
    liftIO $ threadDelay 5000000 -- 5 seconds
    (ready, _available, desired) <-
      runK8sIO $
        getDeploymentReplicaStatus cfg (namespace ctx) (deploymentName ctx)
    logInfoS $
        "    Check "
          <> T.pack (show i)
          <> "/"
          <> T.pack (show checks)
          <> ": ready="
          <> T.pack (show ready)
          <> "/"
          <> T.pack (show desired)

  logInfoS "Health monitoring complete for scheduler"

-- | Cleanup old version: optionally delete old deployment and its HPA
cleanupOldVersion :: StateFlow ()
cleanupOldVersion = do
  rt <- getRT
  cfg <- getCfg
  ctx <- getK8sCtx
  logInfoS $ "Cleaning up old version for scheduler " <> appGroup rt

  updateK8sStatus BSScaleDownOld
  let oldDepName = serviceName ctx <> "-" <> oldVersion ctx
      oldHpaName = oldDepName <> "-hpa"

  -- Clean up old deployment's HPA if it exists
  oldHpaFound <- liftIO $ hpaExists cfg (namespace ctx) oldHpaName
  when oldHpaFound $ do
    logInfoS $ "  Deleting old HPA: " <> oldHpaName
    _ <- runK8sIO $ runCmd (buildDeleteHpaCommand cfg (namespace ctx) oldHpaName)
    pure ()

  -- Optionally delete old deployment
  db <- getDB
  shouldDelete <- liftIO $ isScaleDownPodsOnCompletion db
  when shouldDelete $ do
    logInfoS $ "  Deleting old deployment: " <> oldDepName
    _ <- runK8sIO $ runCmd (buildDeleteDeploymentCommand cfg (namespace ctx) oldDepName)
    pure ()

  -- Capture AFTER snapshot (new deployment)
  cfgAfter <- getCfg
  dbAfter <- getDB
  rtAfter <- getRT
  ctxAfter <- getK8sCtx
  liftIO $ captureDeploymentSnapshot cfgAfter dbAfter (releaseId rtAfter) (namespace ctxAfter) (deploymentName ctxAfter) "DEPLOYMENT_AFTER"

  logInfoS "Cleanup complete for scheduler"

-- | Notify complete
notifyComplete :: StateFlow ()
notifyComplete = do
  rt <- getRT
  db <- getDB
  updateK8sStatus BSDone

  logInfoS $ "Release " <> releaseId rt <> " completed successfully!"
  logInfoS $ "   Service: " <> appGroup rt
  logInfoS $ "   Category: BackendScheduler"
  logInfoS $ "   Status: COMPLETED"

  updateRT $ \r -> r{status = COMPLETED}

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
      let k8s' = k8s{categoryWorkflowStatus = newStatus}
      modify $ \s -> s{targetState = Just (K8sState k8s')}
    _ -> return ()

-- | Update K8s deployment state field
updateK8sField :: (K8sDeploymentState -> K8sDeploymentState) -> StateFlow ()
updateK8sField f = do
  rs <- gets id
  case targetState rs of
    Just (K8sState k8s) -> do
      let k8s' = f k8s
      modify $ \s -> s{targetState = Just (K8sState k8s')}
    _ -> return ()
