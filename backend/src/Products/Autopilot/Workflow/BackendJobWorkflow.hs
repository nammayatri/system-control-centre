{-# LANGUAGE OverloadedStrings #-}

-- | Backend Job workflow (K8s one-time job execution)
--
-- This module implements the workflow for running one-time Jobs in Kubernetes.
-- Jobs are simpler than services:
-- 1. PREPARING: Create job from template or apply job YAML
-- 2. DEPLOYING: Monitor job status, check .status.succeeded and .status.failed
-- 3. MONITORING: Poll until job completes (succeeded >= 1) or fails (failed > backoffLimit)
-- 4. DONE: Mark COMPLETED or ABORTED based on job status
module Products.Autopilot.Workflow.BackendJobWorkflow
  ( backendJobWorkflow,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Strict (gets, modify)
import Control.Monad.Trans.Class (lift)
import Core.Config (Config (..))
import Core.Environment (DBEnv)
import Core.Utils.FlowMonad (getConfig, getDBEnv)
import Data.Aeson (Value (..))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Products.Autopilot.K8s.Execute (K8sError (..), K8sResult (..), runCmd, shellQuote)
import Products.Autopilot.Notifications
  ( notifyReleaseAborted,
    notifyReleaseCompleted,
  )
-- Selective import: exclude oldVersion/newVersion to avoid clash with K8sReleaseContext
import Products.Autopilot.Types.Release (ReleaseStatus (..), ReleaseTracker (appGroup, releaseId, status))
import Products.Autopilot.Types.Target
  ( BackendServiceWFStatus (..),
    K8sDeploymentState (..),
    TargetState (..),
    emptyK8sState,
  )
import Products.Autopilot.Types.Target.Kubernetes (K8sReleaseContext (..))
import Products.Autopilot.Types.Workflow (ReleaseWFStatus (..))
import Products.Autopilot.Workflow.Helpers
  ( getRT,
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

-- | Get DBEnv from the Flow (ReaderT) environment
getDB :: StateFlow DBEnv
getDB = lift getDBEnv

-- | Extract K8sReleaseContext from the current workflow state
getK8sCtx :: StateFlow K8sReleaseContext
getK8sCtx = do
  rs <- gets id
  case targetState rs of
    Just (K8sState k8s) -> pure (context k8s)
    _ -> liftIO $ fail "BackendJobWorkflow: missing K8sState in targetState"

-- | Run an IO action that returns Either K8sError, lifting into StateFlow
runK8sIO :: IO (Either K8sError a) -> StateFlow a
runK8sIO action = do
  result <- liftIO action
  case result of
    Right a -> pure a
    Left (K8sError err) -> liftIO $ fail ("K8s error: " <> T.unpack err)

-- ============================================================================
-- Workflow Step Implementations
-- ============================================================================

-- | Validate preconditions: cluster reachable, namespace exists
validatePreconditions :: StateFlow ()
validatePreconditions = do
  rt <- getRT
  cfg <- getCfg
  liftIO $ putStrLn $ "Validating preconditions for job " <> T.unpack (appGroup rt)

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
            [ kubectlBin cfg,
              "-n",
              T.unpack (namespace ctx),
              "get namespace",
              T.unpack (namespace ctx)
            ]
        )

  liftIO $ putStrLn "  Cluster reachable, namespace exists"
  liftIO $ putStrLn "Preconditions validated for job"

-- | Create the job: apply from deployFilePath YAML or create from image
createJob :: StateFlow ()
createJob = do
  rt <- getRT
  cfg <- getCfg
  ctx <- getK8sCtx
  liftIO $ putStrLn $ "Creating job for " <> T.unpack (appGroup rt)

  updateK8sStatus BSCreateDeployment

  let jobName = T.unpack (serviceName ctx) <> "-" <> T.unpack (newVersion ctx)
      ns = T.unpack (namespace ctx)

  case deployFilePath ctx of
    Just filePath -> do
      -- Apply job YAML from file path
      liftIO $ putStrLn $ "  Applying job YAML from: " <> T.unpack filePath
      let applyCmd =
            unwords
              [ kubectlBin cfg,
                "apply -f",
                T.unpack filePath,
                "-n",
                ns
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
                [ "apiVersion: batch/v1",
                  "kind: Job",
                  "metadata:",
                  "  name: " <> jobName,
                  "  namespace: " <> ns,
                  "spec:",
                  "  backoffLimit: 3",
                  "  template:",
                  "    spec:",
                  "      containers:",
                  "      - name: " <> container,
                  "        image: " <> newImg,
                  "      restartPolicy: Never"
                ]
      liftIO $ putStrLn $ "  Creating job: " <> jobName
      _ <-
        runK8sIO $
          runCmd
            ( unwords
                [ "echo",
                  shellQuote jobYaml,
                  "|",
                  kubectlBin cfg,
                  "-n",
                  ns,
                  "apply -f -"
                ]
            )
      pure ()

  updateK8sField (\k8s -> k8s{deploymentCreated = True})
  liftIO $ putStrLn "Job created"

-- | Monitor job status: poll until completed or failed
monitorJobStatus :: StateFlow ()
monitorJobStatus = do
  rt <- getRT
  cfg <- getCfg
  ctx <- getK8sCtx
  liftIO $ putStrLn $ "MONITORING job status for " <> T.unpack (appGroup rt)

  updateK8sStatus BSMonitoring

  let jobName = T.unpack (serviceName ctx) <> "-" <> T.unpack (newVersion ctx)
      ns = T.unpack (namespace ctx)
      maxPolls = 60 :: Int -- 60 * 10s = 10 minutes max wait
      getJobCmd =
        unwords
          [ kubectlBin cfg,
            "get job",
            jobName,
            "-n",
            ns,
            "-o json"
          ]

  pollJobStatus cfg getJobCmd maxPolls 1

-- | Poll job status until complete or failed
pollJobStatus :: Config -> String -> Int -> Int -> StateFlow ()
pollJobStatus cfg getJobCmd maxPolls currentPoll = do
  when (currentPoll > maxPolls) $
    liftIO $
      fail "Job timed out waiting for completion"

  liftIO $ putStrLn $ "  Poll " <> show currentPoll <> "/" <> show maxPolls <> ": checking job status"
  result <- liftIO $ runCmd getJobCmd
  case result of
    Left (K8sError err) -> liftIO $ fail $ "Failed to get job status: " <> T.unpack err
    Right (K8sResult out) -> do
      let (succeeded, failed, backoffLimit) = parseJobStatus out
      liftIO $
        putStrLn $
          "    succeeded="
            <> show succeeded
            <> " failed="
            <> show failed
            <> " backoffLimit="
            <> show backoffLimit

      if succeeded >= 1
        then do
          liftIO $ putStrLn "  Job completed successfully"
          updateK8sField (\k8s -> k8s{trafficPercentage = 100})
        else
          if failed > backoffLimit
            then do
              liftIO $ putStrLn "  Job FAILED: exceeded backoff limit"
              -- Mark as aborted
              updateRT $ \r -> r{status = ABORTED}
              db <- getDB
              rt <- getRT
              liftIO $ notifyReleaseAborted db rt
              liftIO $ fail $ "Job failed: exceeded backoff limit (failed=" <> show failed <> ", backoffLimit=" <> show backoffLimit <> ")"
            else do
              -- Still running, wait and poll again
              liftIO $ threadDelay 10000000 -- 10 seconds
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
  db <- getDB
  updateK8sStatus BSDone

  -- Check if job was already marked as aborted
  case status rt of
    ABORTED -> do
      liftIO $ putStrLn $ "Job " <> T.unpack (releaseId rt) <> " was aborted"
    _ -> do
      liftIO $ putStrLn $ "Release " <> T.unpack (releaseId rt) <> " completed successfully!"
      liftIO $ putStrLn $ "   Service: " <> T.unpack (appGroup rt)
      liftIO $ putStrLn $ "   Category: BackendJob"
      liftIO $ putStrLn $ "   Status: COMPLETED"

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
