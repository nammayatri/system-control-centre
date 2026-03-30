{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Workflow helper functions for Recorded monad

Ported from Mobius.Utils.WorkFlow
Provides high-level combinators for checkpoint-based workflow composition
-}
module Products.Autopilot.Workflow.Helpers (
    -- * Workflow Combinators
    (|>>),
    stateCheckFuncV2,

    -- * State Persistence Functions
    persistWorkflowState,
    persistFinalState,

    -- * Snapshot Capture Functions
    captureDeploymentSnapshot,
    captureVSSnapshot,
    captureConfigMapSnapshot,

    -- * Utility Functions
    continueIf,
    scheduleAfter,
    getRT,
    getReleaseTracker,
    updateRT,
)
where

import Control.Monad (unless)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Strict (get, gets, modify)
import Control.Monad.Trans.Class (lift)
import Core.Config (Config (..))
import Core.Environment (DBEnv)
import Core.Utils.FlowMonad (Flow, getDBEnv)
import Data.Aeson (toJSON)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (NominalDiffTime, addUTCTime, getCurrentTime)
import Products.Autopilot.K8s.Execute (K8sError (..), K8sResult (..), runCmd)
import Products.Autopilot.K8s.VirtualService (getVirtualServiceJson)
import qualified Products.Autopilot.Queries.ReleaseTracker as DB
import Products.Autopilot.Types.Release (ReleaseStatus (..), ReleaseTracker (..))
import Products.Autopilot.Types.Workflow (ReleaseWFStatus (..))
import Products.Autopilot.Workflow.Recorded (recordedWithPersist)
import Products.Autopilot.Workflow.Types (
    ReleaseState (..),
    ReleaseWorkFlow,
    StateFlow,
    WorkFlowError (..),
 )

-- ============================================================================
-- State Persistence
-- ============================================================================

{- | Persist workflow state to database

Saves both the ReleaseTracker and the target state.
-}
persistWorkflowState :: ReleaseState -> Flow ()
persistWorkflowState rs = do
    db <- getDBEnv
    let rt = releaseTracker rs
        mts = targetState rs
    liftIO $ DB.insertReleaseTracker db rt mts

{- | Persist final state to database

Used for the final workflow step. Updates all fields including
those that might be set externally (like release_action).
-}
persistFinalState :: ReleaseState -> Flow ()
persistFinalState = persistWorkflowState

-- ============================================================================
-- Workflow Utilities
-- ============================================================================

{- | Continue workflow execution only if predicate is true

Useful for conditional workflow branching
-}
continueIf :: (ReleaseState -> Bool) -> ReleaseWorkFlow ()
continueIf predicate = do
    rs <- lift get
    unless (predicate rs) $
        throwError (DomainError "Condition not met for workflow continuation")

{- | Schedule workflow to resume after a delay

Updates scheduleTime in ReleaseTracker
-}
scheduleAfter :: NominalDiffTime -> ReleaseWorkFlow ()
scheduleAfter delay = do
    now <- lift $ lift $ liftIO getCurrentTime -- ExceptT -> Recorded -> Flow -> IO
    let scheduledTime = addUTCTime delay now
    modify $ \rs ->
        let rt = releaseTracker rs
            rt' = rt{scheduleTime = Just scheduledTime}
         in rs{releaseTracker = rt'}

-- | Get ReleaseTracker from current state
getRT :: StateFlow ReleaseTracker
getRT = gets releaseTracker

-- | Alias for getRT
getReleaseTracker :: StateFlow ReleaseTracker
getReleaseTracker = getRT

-- | Update ReleaseTracker in current state
updateRT :: (ReleaseTracker -> ReleaseTracker) -> StateFlow ()
updateRT f = modify $ \rs -> rs{releaseTracker = f (releaseTracker rs)}

-- ============================================================================
-- Snapshot Capture Functions
-- ============================================================================

-- | Capture deployment YAML snapshot and store as release event
captureDeploymentSnapshot :: Config -> DBEnv -> Text -> Text -> Text -> Text -> IO ()
captureDeploymentSnapshot cfg db releaseId ns depName label = do
    result <- runCmd (unwords [kubectlBin cfg, "-n", T.unpack ns, "get deployment", T.unpack depName, "-o", "yaml"])
    case result of
        Right (K8sResult yaml) -> DB.insertReleaseEvent db releaseId "SNAPSHOT" label (toJSON yaml)
        Left _ -> pure () -- silently skip if can't capture

-- | Capture VirtualService JSON snapshot and store as release event
captureVSSnapshot :: Config -> DBEnv -> Text -> Text -> Text -> Text -> IO ()
captureVSSnapshot cfg db releaseId ns vsName label = do
    result <- getVirtualServiceJson cfg ns vsName
    case result of
        Right vsJson -> DB.insertReleaseEvent db releaseId "SNAPSHOT" label (toJSON vsJson)
        Left _ -> pure () -- silently skip if can't capture

-- | Capture ConfigMap snapshot and store as release event
captureConfigMapSnapshot :: Config -> DBEnv -> Text -> Text -> Text -> Text -> IO ()
captureConfigMapSnapshot cfg db releaseId ns cmName label = do
    result <- runCmd (unwords [kubectlBin cfg, "-n", T.unpack ns, "get configmap", T.unpack cmName, "-o", "yaml"])
    case result of
        Right (K8sResult yaml) -> DB.insertReleaseEvent db releaseId "SNAPSHOT" label (toJSON yaml)
        Left _ -> pure () -- silently skip if can't capture

-- ============================================================================
-- ReleaseWFStatus-based Helpers
-- ============================================================================

{- | Check if workflow has reached a particular checkpoint

Returns Just () if releaseWFStatus >= target checkpoint
Returns Nothing if not yet reached (should execute the step)
-}
stateCheckFuncV2 :: ReleaseWFStatus -> ReleaseState -> Maybe ()
stateCheckFuncV2 targetStatus rs =
    let rt = releaseTracker rs
        currentStatus = releaseWFStatus rt
     in if currentStatus >= targetStatus
            then Just () -- Already completed this checkpoint
            else Nothing -- Not yet completed, need to execute

{- | Checkpoint-resume operator

Automatically checks if step is complete via releaseWFStatus, skips if done.
After execution, persists state to DB.

Usage:
@
workflow = do
 Init |>> validatePreconditions
 Deploying |>> deployApplication
 Monitoring |>> monitorHealth
 Finalizing |>> cleanup
@
-}
cprV2 :: ReleaseWFStatus -> StateFlow () -> ReleaseWorkFlow ()
cprV2 targetStatus func =
    lift $ recordedWithPersist persistWorkflowState funcExec (stateCheckFuncV2 targetStatus)
  where
    funcExec = do
        func
        -- Update releaseWFStatus after execution
        modify $ \rs ->
            let rt = releaseTracker rs
                rt' = rt{releaseWFStatus = targetStatus}
             in rs{releaseTracker = rt'}

-- | Infix synonym for 'cprV2'
(|>>) :: ReleaseWFStatus -> StateFlow () -> ReleaseWorkFlow ()
(|>>) = cprV2

infixl 1 |>>
