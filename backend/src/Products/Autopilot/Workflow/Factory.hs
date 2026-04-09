{-# LANGUAGE LambdaCase #-}

{- | Workflow factory - dispatches to category-specific workflows

This module provides the main entry point for executing release workflows.
It dispatches to the appropriate workflow implementation based on ReleaseCategory.
-}
module Products.Autopilot.Workflow.Factory (
    executeReleaseWorkflow,
    getWorkflowForCategory,
    WorkflowExecutor,
)
where

import Control.Monad.Except (runExceptT, throwError)
import Control.Monad.Trans.Class (lift)
import Core.Environment (Flow, logWarning)
import Core.Workflow.Engine (runWorkflowSpec)
import Data.Text (Text)
import qualified Data.Text as T
import Products.Autopilot.Types.Release (ReleaseTracker (..))
import Products.Autopilot.Types.Workflow (ReleaseCategory (..))

-- Import category-specific workflows
--
-- BackendJob, BackendCronJob, MobileAppAndroid have been removed (their
-- workflow files no longer exist). All three live categories — BackendService,
-- BackendScheduler, BackendConfig — now dispatch to the product-agnostic
-- engine via 'runWorkflowSpec'. VSEdit has its own handler in
-- Actions/VSEdit.hs and is intentionally not wired here.

import Products.Autopilot.Workflow.BackendConfigWorkflow (backendConfigSpec)
import Products.Autopilot.Workflow.BackendSchedulerWorkflow (backendSchedulerSpec)
import Products.Autopilot.Workflow.BackendServiceWorkflow (backendServiceSpec)
import Products.Autopilot.Workflow.Recorded (runRecorded)
import Products.Autopilot.Workflow.Types (
    ReleaseState (..),
    ReleaseWorkFlow,
    WorkFlowError (..),
 )

-- | Workflow executor function type
type WorkflowExecutor = ReleaseWorkFlow ()

-- ============================================================================
-- Main Workflow Execution
-- ============================================================================

{- | Execute a release workflow based on its category

This is the main entry point for workflow execution. It:
1. Determines the category from ReleaseTracker
2. Selects the appropriate workflow implementation
3. Executes the workflow with checkpoint/resume support
4. Handles errors gracefully

Usage:
@
result <- executeReleaseWorkflow releaseState
case result of
Right finalState -> -- success
Left error -> -- handle error
@
-}
executeReleaseWorkflow ::
    ReleaseState ->
    Flow (Either WorkFlowError ReleaseState)
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

{- | Get workflow executor for a release category.

Three categories are dispatched as runner workflows:

* 'BackendService'   — full K8s rollout with VS traffic shifting
* 'BackendScheduler' — pod-count based scheduler (no VS/DR)
* 'BackendConfig'    — ConfigMap / Secret applies (managed via 'Actions.ConfigMap')

'VSEdit' is intentionally not wired here — it is handled out-of-band via
'Products.Autopilot.Actions.VSEdit'. Attempting to dispatch it falls through
to 'notImplementedWorkflow' which short-circuits with a 'DomainError'. The
runner is expected to never select 'VSEdit' for dispatch (its eligibility
gate filters it out upstream).
-}
getWorkflowForCategory :: ReleaseCategory -> WorkflowExecutor
getWorkflowForCategory = \case
    BackendService -> runWorkflowSpec backendServiceSpec
    BackendScheduler -> runWorkflowSpec backendSchedulerSpec
    BackendConfig -> runWorkflowSpec backendConfigSpec
    VSEdit -> notImplementedWorkflow "VSEdit"

-- | Placeholder for not-yet-implemented workflows
notImplementedWorkflow :: Text -> WorkflowExecutor
notImplementedWorkflow categoryName = do
    lift $
        lift $
            logWarning $
                "Workflow not implemented for category: " <> categoryName
    throwError $
        DomainError $
            T.unpack $
                "Workflow not implemented for category: " <> categoryName

-- ============================================================================
-- Helper Functions
-- ============================================================================

-- | Get ReleaseCategory from ReleaseTracker
getCategoryFromTracker :: ReleaseTracker -> ReleaseCategory
getCategoryFromTracker = category
