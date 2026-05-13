{-# LANGUAGE LambdaCase #-}

{- | Dispatches release execution to the appropriate 'WorkflowSpec' by
  'ReleaseCategory'.
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

import Products.Autopilot.Mobile.Workflow (mobileBuildSpec)
import Products.Autopilot.Workflow.BackendConfigWorkflow (backendConfigSpec)
import Products.Autopilot.Workflow.BackendSchedulerWorkflow (backendSchedulerSpec)
import Products.Autopilot.Workflow.BackendServiceWorkflow (backendServiceSpec)
import Products.Autopilot.Workflow.Recorded (runRecorded)
import Products.Autopilot.Workflow.Types (
    ReleaseState (..),
    ReleaseWorkFlow,
    WorkFlowError (..),
 )

type WorkflowExecutor = ReleaseWorkFlow ()

-- | Main entry: dispatch by category and run the spec with checkpoint/resume.
executeReleaseWorkflow ::
    ReleaseState ->
    Flow (Either WorkFlowError ReleaseState)
executeReleaseWorkflow initialState = do
    let rt = releaseTracker initialState
        category = getCategoryFromTracker rt
    let workflow = getWorkflowForCategory category
    (result, finalState) <- runRecorded (runExceptT workflow) initialState
    pure $ case result of
        Left err -> Left err
        Right () -> Right finalState

{- | 'VSEdit' is handled out-of-band via 'Products.Autopilot.Actions.VSEdit'
  and the runner filters it before dispatch; reaching it here is a bug.
-}
getWorkflowForCategory :: ReleaseCategory -> WorkflowExecutor
getWorkflowForCategory = \case
    BackendService -> runWorkflowSpec backendServiceSpec
    BackendScheduler -> runWorkflowSpec backendSchedulerSpec
    BackendConfig -> runWorkflowSpec backendConfigSpec
    VSEdit -> notImplementedWorkflow "VSEdit"
    MobileBuild -> runWorkflowSpec mobileBuildSpec

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

getCategoryFromTracker :: ReleaseTracker -> ReleaseCategory
getCategoryFromTracker = category
