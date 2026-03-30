{-# LANGUAGE LambdaCase #-}

-- | Workflow factory - dispatches to category-specific workflows
--
-- This module provides the main entry point for executing release workflows.
-- It dispatches to the appropriate workflow implementation based on ReleaseCategory.
module Products.Autopilot.Workflow.Factory
  ( executeReleaseWorkflow
  , getWorkflowForCategory
  , WorkflowExecutor
  ) where

import Control.Monad.Except (runExceptT, throwError)
import Control.Monad.Trans.Class (lift)
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import qualified Data.Text as T

import Products.Autopilot.Workflow.Types
  ( ReleaseWorkFlow
  , WorkFlowError(..)
  , ReleaseState(..)
  )
import Products.Autopilot.Workflow.Recorded (runRecorded)
import Products.Autopilot.Types.Workflow (ReleaseCategory(..))
import Products.Autopilot.Types.Release (ReleaseTracker(..))
import Core.Utils.FlowMonad (Flow)

-- Import category-specific workflows
import qualified Products.Autopilot.Workflow.BackendServiceWorkflow as Backend
import qualified Products.Autopilot.Workflow.MobileAppAndroidWorkflow as Android
import qualified Products.Autopilot.Workflow.BackendConfigWorkflow as Config

-- | Workflow executor function type
type WorkflowExecutor = ReleaseWorkFlow ()

-- ============================================================================
-- Main Workflow Execution
-- ============================================================================

-- | Execute a release workflow based on its category
--
-- This is the main entry point for workflow execution. It:
-- 1. Determines the category from ReleaseTracker
-- 2. Selects the appropriate workflow implementation
-- 3. Executes the workflow with checkpoint/resume support
-- 4. Handles errors gracefully
--
-- Usage:
-- @
-- result <- executeReleaseWorkflow releaseState
-- case result of
--   Right finalState -> -- success
--   Left error -> -- handle error
-- @
executeReleaseWorkflow
  :: ReleaseState
  -> Flow (Either WorkFlowError ReleaseState)
executeReleaseWorkflow initialState = do
  let rt = releaseTracker initialState
      category = getCategoryFromTracker rt

  -- Get workflow executor for this category
  let workflow = getWorkflowForCategory category

  -- Execute workflow with checkpoint/resume
  (result, finalState) <- runRecorded (runExceptT workflow) initialState
  pure $ case result of
    Left err -> Left err
    Right () -> Right finalState

-- ============================================================================
-- Workflow Selection
-- ============================================================================

-- | Get workflow executor for a release category
--
-- Dispatches to category-specific workflow implementations:
-- - BackendService → Backend.backendServiceWorkflow
-- - BackendScheduler → Backend.backendServiceWorkflow (same as service)
-- - MobileAppAndroid → Android.mobileAppAndroidWorkflow
-- - etc.
getWorkflowForCategory :: ReleaseCategory -> WorkflowExecutor
getWorkflowForCategory = \case
  -- Backend workflows (K8s-based)
  BackendService   -> Backend.backendServiceWorkflow
  BackendScheduler -> Backend.backendServiceWorkflow  -- Same workflow, different deployment
  BackendCronJob   -> Backend.backendServiceWorkflow
  BackendJob       -> Backend.backendServiceWorkflow

  -- Backend config workflow
  BackendConfig    -> Config.backendConfigWorkflow

  -- Mobile app workflows
  MobileAppAndroid -> Android.mobileAppAndroidWorkflow
  MobileAppIOS     -> notImplementedWorkflow "MobileAppIOS"

  -- Web application workflow
  WebApplication   -> notImplementedWorkflow "WebApplication"

  -- Infrastructure workflow
  Infrastructure   -> notImplementedWorkflow "Infrastructure"

-- | Placeholder for not-yet-implemented workflows
notImplementedWorkflow :: Text -> WorkflowExecutor
notImplementedWorkflow categoryName = do
  lift $ lift $ liftIO $ putStrLn $ T.unpack $
    "⚠️  Workflow not implemented for category: " <> categoryName
  throwError $ DomainError $ T.unpack $
    "Workflow not implemented for category: " <> categoryName

-- ============================================================================
-- Helper Functions
-- ============================================================================

-- | Get ReleaseCategory from ReleaseTracker
getCategoryFromTracker :: ReleaseTracker -> ReleaseCategory
getCategoryFromTracker = category
