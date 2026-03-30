{-# LANGUAGE OverloadedStrings #-}

{- | Backend CronJob workflow (K8s CronJob image update)

This module implements the workflow for updating CronJobs in Kubernetes.
CronJobs are simpler than services:
1. Preparing: Get current cronjob spec
2. Deploying: Update cronjob image
3. Monitoring: Optionally suspend old cronjob if cronjob_suspend flag is set
4. Done: Mark Completed
-}
module Products.Autopilot.Workflow.BackendCronJobWorkflow (
    backendCronJobWorkflow,
)
where

import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Strict (gets, modify)
import Control.Monad.Trans.Class (lift)
import Core.Config (Config (..))
import Core.Environment (DBEnv)
import Core.Utils.FlowMonad (getConfig, getDBEnv)
import qualified Data.Text as T
import Products.Autopilot.K8s.Execute (K8sError (..), runCmd)
import Products.Autopilot.Notifications (
    notifyReleaseCompleted,
 )

-- Selective import: exclude oldVersion/newVersion to avoid clash with K8sReleaseContext
import Products.Autopilot.Types.Release (ReleaseStatus (..), ReleaseTracker (product, releaseId, status))
import Products.Autopilot.Types.Target (
    BackendServiceWFStatus (..),
    K8sDeploymentState (..),
    TargetState (..),
    emptyK8sState,
 )
import Products.Autopilot.Types.Target.Kubernetes (K8sReleaseContext (..))
import Products.Autopilot.Types.Workflow (ReleaseWFStatus (..))
import Products.Autopilot.Workflow.Helpers (
    getRT,
    updateRT,
    (|>>),
 )
import Products.Autopilot.Workflow.Types (
    ReleaseState (..),
    ReleaseWorkFlow,
    StateFlow,
 )
import Prelude hiding (product)

-- ============================================================================
-- Workflow Definition
-- ============================================================================

-- | Backend CronJob workflow: simple image update
backendCronJobWorkflow :: ReleaseWorkFlow ()
backendCronJobWorkflow = do
    Init |>> validatePreconditions
    Preparing |>> getCronJobSpec
    Deploying |>> updateCronJobImage
    Monitoring |>> handleCronJobSuspend
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
        _ -> error "BackendCronJobWorkflow: missing K8sState in targetState"

-- | Check if cronjob_suspend flag is set
getCronJobSuspend :: StateFlow Bool
getCronJobSuspend = do
    rs <- gets id
    case targetState rs of
        Just (K8sState k8s) -> pure (cronjobSuspend k8s)
        _ -> pure False

-- | Run an IO action that returns Either K8sError, lifting into StateFlow
runK8sIO :: IO (Either K8sError a) -> StateFlow a
runK8sIO action = do
    result <- liftIO action
    case result of
        Right a -> pure a
        Left (K8sError err) -> error ("K8s error: " <> T.unpack err)

-- ============================================================================
-- Workflow Step Implementations
-- ============================================================================

-- | Validate preconditions: cluster reachable, namespace exists
validatePreconditions :: StateFlow ()
validatePreconditions = do
    rt <- getRT
    cfg <- getCfg
    liftIO $ putStrLn $ "Validating preconditions for cronjob " <> T.unpack (product rt)

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
    liftIO $ putStrLn "  Checking cluster reachability"
    _ <-
        runK8sIO $
            runCmd
                ( unwords
                    [ kubectlBin cfg
                    , "-n"
                    , T.unpack (namespace ctx)
                    , "get namespace"
                    , T.unpack (namespace ctx)
                    ]
                )

    liftIO $ putStrLn "  Cluster reachable, namespace exists"
    liftIO $ putStrLn "Preconditions validated for cronjob"

-- | Get current CronJob spec
getCronJobSpec :: StateFlow ()
getCronJobSpec = do
    rt <- getRT
    cfg <- getCfg
    ctx <- getK8sCtx
    liftIO $ putStrLn $ "Getting CronJob spec for " <> T.unpack (product rt)

    updateK8sStatus BSCreateDeployment

    -- Get current cronjob spec via kubectl
    let cronJobName = T.unpack (serviceName ctx)
        ns = T.unpack (namespace ctx)
        getCmd =
            unwords
                [ kubectlBin cfg
                , "get cronjob"
                , cronJobName
                , "-n"
                , ns
                , "-o json"
                ]
    liftIO $ putStrLn $ "  Fetching CronJob: " <> cronJobName
    _ <- runK8sIO $ runCmd getCmd

    liftIO $ putStrLn "CronJob spec retrieved"

-- | Update CronJob image
updateCronJobImage :: StateFlow ()
updateCronJobImage = do
    rt <- getRT
    cfg <- getCfg
    ctx <- getK8sCtx
    liftIO $ putStrLn $ "Updating CronJob image for " <> T.unpack (product rt)

    updateK8sStatus BSFlipVirtualService -- Reuse status for "deploying" phase

    let cronJobName = T.unpack (serviceName ctx)
        ns = T.unpack (namespace ctx)
        container = T.unpack (containerName ctx)
        newImg = case dockerImage ctx of
            Just img -> T.unpack img
            Nothing -> T.unpack (containerName ctx) <> ":" <> T.unpack (newVersion ctx)
        setImageCmd =
            unwords
                [ kubectlBin cfg
                , "set image"
                , "cronjob/" <> cronJobName
                , container <> "=" <> newImg
                , "-n"
                , ns
                ]

    liftIO $ putStrLn $ "  Setting image: " <> newImg
    _ <- runK8sIO $ runCmd setImageCmd
    updateK8sField (\k8s -> k8s{deploymentCreated = True, trafficPercentage = 100})

    liftIO $ putStrLn "CronJob image updated"

-- | Handle CronJob suspend: optionally suspend old cronjob
handleCronJobSuspend :: StateFlow ()
handleCronJobSuspend = do
    rt <- getRT
    cfg <- getCfg
    ctx <- getK8sCtx
    liftIO $ putStrLn $ "Handling CronJob post-deploy for " <> T.unpack (product rt)

    updateK8sStatus BSMonitoring

    -- Optionally suspend old cronjob if cronjob_suspend flag is set
    shouldSuspend <- getCronJobSuspend
    when shouldSuspend $ do
        let cronJobName = T.unpack (serviceName ctx)
            ns = T.unpack (namespace ctx)
            suspendCmd =
                unwords
                    [ kubectlBin cfg
                    , "patch cronjob"
                    , cronJobName
                    , "-n"
                    , ns
                    , "-p"
                    , "'{\"spec\":{\"suspend\":true}}'"
                    ]
        liftIO $ putStrLn $ "  Suspending CronJob: " <> cronJobName
        _ <- runK8sIO $ runCmd suspendCmd
        liftIO $ putStrLn "  CronJob suspended"

    liftIO $ putStrLn "CronJob post-deploy handling complete"

-- | Notify complete
notifyComplete :: StateFlow ()
notifyComplete = do
    rt <- getRT
    db <- getDB
    updateK8sStatus BSDone

    liftIO $ putStrLn $ "Release " <> T.unpack (releaseId rt) <> " completed successfully!"
    liftIO $ putStrLn $ "   Service: " <> T.unpack (product rt)
    liftIO $ putStrLn $ "   Category: BackendCronJob"
    liftIO $ putStrLn $ "   Status: Completed"

    updateRT $ \r -> r{status = Completed}

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
