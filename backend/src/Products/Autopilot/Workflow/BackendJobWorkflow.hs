{-# LANGUAGE OverloadedStrings #-}

{- | Backend Job workflow (K8s one-time job execution)

This module implements the workflow for running one-time Jobs in Kubernetes.
Jobs are simpler than services:
1. PREPARING: Create job from template or apply job YAML
2. DEPLOYING: Monitor job status, check .status.succeeded and .status.failed
3. MONITORING: Poll until job completes (succeeded >= 1) or fails (failed > backoffLimit)
4. DONE: Mark COMPLETED or ABORTED based on job status
-}
module Products.Autopilot.Workflow.BackendJobWorkflow (
    backendJobWorkflow,
)
where

import Control.Exception (throwIO)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Strict (gets, modify)
import Control.Monad.Trans.Class (lift)
import Core.AppError (WorkflowError (..))
import Core.Config (Config (..))
import Core.Environment (getConfig, logError, logInfo)
import Core.Types.Time (threadDelaySec)
import Data.Aeson (Value (..))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Products.Autopilot.K8s.Execute (K8sError (..), K8sResult (..), runCmd, shellQuote)
import Products.Autopilot.Notifications (
    notifyReleaseAborted,
    notifyReleaseCompleted,
 )

-- Selective import: exclude oldVersion/newVersion to avoid clash with K8sReleaseContext
import Products.Autopilot.Types.Release (ReleaseStatus (..), ReleaseTracker (appGroup, releaseId, status))
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
    withK8sContext,
    (|>>),
 )
import Products.Autopilot.Workflow.Types (
    ReleaseState (..),
    ReleaseWorkFlow,
    StateFlow,
 )
import Prelude

-- ============================================================================
-- Workflow Definition
-- ============================================================================

-- | Backend Job workflow: one-time job execution
backendJobWorkflow :: ReleaseWorkFlow ()
backendJobWorkflow = do
    INIT |>> validatePreconditions
    PREPARING |>> createJob
    DEPLOYING |>> monitorJobStatus
    DONE |>> notifyComplete

-- ============================================================================
-- Helpers: Config / Context / K8s IO
-- ============================================================================

-- | Get bootstrap config from the Flow (ReaderT) environment
getCfg :: StateFlow Config
getCfg = lift getConfig

-- | StateFlow-level logging
logInfoS :: T.Text -> StateFlow ()
logInfoS = lift . logInfo

logErrorS :: T.Text -> StateFlow ()
logErrorS = lift . logError

-- | Extract K8sReleaseContext from the current workflow state
getK8sCtx :: StateFlow K8sReleaseContext
getK8sCtx = withK8sContext

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
    logInfoS $ "Validating preconditions for job " <> appGroup rt

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
                    [ kubectlBin cfg
                    , "-n"
                    , T.unpack (namespace ctx)
                    , "get namespace"
                    , T.unpack (namespace ctx)
                    ]
                )

    logInfoS "  Cluster reachable, namespace exists"
    logInfoS "Preconditions validated for job"

-- | Create the job: apply from deployFilePath YAML or create from image
createJob :: StateFlow ()
createJob = do
    rt <- getRT
    cfg <- getCfg
    ctx <- getK8sCtx
    logInfoS $ "Creating job for " <> appGroup rt

    updateK8sStatus BSCreateDeployment

    let jobName = T.unpack (serviceName ctx) <> "-" <> T.unpack (newVersion ctx)
        ns = T.unpack (namespace ctx)

    case deployFilePath ctx of
        Just filePath -> do
            -- Apply job YAML from file path
            logInfoS $ "  Applying job YAML from: " <> filePath
            let applyCmd =
                    unwords
                        [ kubectlBin cfg
                        , "apply -f"
                        , T.unpack filePath
                        , "-n"
                        , ns
                        ]
            _ <- runK8sIO $ runCmd applyCmd
            pure ()
        Nothing -> do
            -- Create job from image
            let container = T.unpack (containerName ctx)
                newImg = case dockerImage ctx of
                    Just img -> T.unpack img
                    Nothing -> container <> ":" <> T.unpack (newVersion ctx)
                jobYaml =
                    T.pack $
                        unlines
                            [ "apiVersion: batch/v1"
                            , "kind: Job"
                            , "metadata:"
                            , "  name: " <> jobName
                            , "  namespace: " <> ns
                            , "spec:"
                            , "  backoffLimit: 3"
                            , "  template:"
                            , "    spec:"
                            , "      containers:"
                            , "      - name: " <> container
                            , "        image: " <> newImg
                            , "      restartPolicy: Never"
                            ]
            logInfoS $ "  Creating job: " <> T.pack jobName
            _ <-
                runK8sIO $
                    runCmd
                        ( unwords
                            [ "echo"
                            , shellQuote jobYaml
                            , "|"
                            , kubectlBin cfg
                            , "-n"
                            , ns
                            , "apply -f -"
                            ]
                        )
            pure ()

    updateK8sField (\k8s -> k8s{deploymentCreated = True})
    logInfoS "Job created"

-- | Monitor job status: poll until completed or failed
monitorJobStatus :: StateFlow ()
monitorJobStatus = do
    rt <- getRT
    cfg <- getCfg
    ctx <- getK8sCtx
    logInfoS $ "MONITORING job status for " <> appGroup rt

    updateK8sStatus BSMonitoring

    let jobName = T.unpack (serviceName ctx) <> "-" <> T.unpack (newVersion ctx)
        ns = T.unpack (namespace ctx)
        maxPolls = 60 :: Int -- 60 * 10s = 10 minutes max wait
        getJobCmd =
            unwords
                [ kubectlBin cfg
                , "get job"
                , jobName
                , "-n"
                , ns
                , "-o json"
                ]

    pollJobStatus cfg getJobCmd maxPolls 1

-- | Poll job status until complete or failed
pollJobStatus :: Config -> String -> Int -> Int -> StateFlow ()
pollJobStatus cfg getJobCmd maxPolls currentPoll = do
    when (currentPoll > maxPolls) $
        liftIO $
            throwIO $
                WorkflowError "wait" "Job timed out waiting for completion"

    logInfoS $ "  Poll " <> T.pack (show currentPoll) <> "/" <> T.pack (show maxPolls) <> ": checking job status"
    result <- liftIO $ runCmd getJobCmd
    case result of
        Left (K8sError err) -> liftIO $ throwIO $ WorkflowError "k8s" ("Failed to get job status: " <> err)
        Right (K8sResult out) -> do
            let (succeeded, failed, backoffLimit) = parseJobStatus out
            logInfoS $
                "    succeeded="
                    <> T.pack (show succeeded)
                    <> " failed="
                    <> T.pack (show failed)
                    <> " backoffLimit="
                    <> T.pack (show backoffLimit)

            if succeeded >= 1
                then do
                    logInfoS "  Job completed successfully"
                    updateK8sField (\k8s -> k8s{trafficPercentage = 100})
                else
                    if failed > backoffLimit
                        then do
                            logErrorS "  Job FAILED: exceeded backoff limit"
                            -- Mark as aborted
                            updateRT $ \r -> r{status = ABORTED}
                            rt <- getRT
                            lift $ notifyReleaseAborted rt
                            liftIO $ throwIO $ WorkflowError "wait" ("Job failed: backoff limit exceeded (failed=" <> T.pack (show failed) <> ")")
                        else do
                            -- Still running, wait and poll again
                            liftIO $ threadDelaySec 10
                            pollJobStatus cfg getJobCmd maxPolls (currentPoll + 1)

-- | Parse job status JSON to extract succeeded, failed, backoffLimit
parseJobStatus :: T.Text -> (Int, Int, Int)
parseJobStatus jsonText =
    case A.decodeStrict' (encodeUtf8 jsonText) :: Maybe Value of
        Nothing -> (0, 0, 3)
        Just (Object root) ->
            let statusObj = case KM.lookup (K.fromText "status") root of
                    Just (Object s) -> s
                    _ -> KM.empty
                specObj = case KM.lookup (K.fromText "spec") root of
                    Just (Object s) -> s
                    _ -> KM.empty
                succeeded = getIntField "succeeded" statusObj
                failed = getIntField "failed" statusObj
                backoffLimit = fromMaybe 3 (getIntFieldMaybe "backoffLimit" specObj)
             in (succeeded, failed, backoffLimit)
        _ -> (0, 0, 3)
  where
    getIntField key obj = case KM.lookup (K.fromText key) obj of
        Just (Number n) -> round n
        _ -> 0
    getIntFieldMaybe key obj = case KM.lookup (K.fromText key) obj of
        Just (Number n) -> Just (round n)
        _ -> Nothing

-- | Notify complete
notifyComplete :: StateFlow ()
notifyComplete = do
    rt <- getRT
    updateK8sStatus BSDone

    -- Check if job was already marked as aborted
    case status rt of
        ABORTED -> do
            logErrorS $ "Job " <> releaseId rt <> " was aborted"
        _ -> do
            logInfoS $ "Release " <> releaseId rt <> " completed successfully!"
            logInfoS $ "   Service: " <> appGroup rt
            logInfoS $ "   Category: BackendJob"
            logInfoS $ "   Status: COMPLETED"

            updateRT $ \r -> r{status = COMPLETED}

            -- Notify Slack
            currentTS <- gets targetState
            lift $ notifyReleaseCompleted rt currentTS

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
