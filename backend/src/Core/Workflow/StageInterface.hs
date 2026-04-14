{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}

{- | StageInterface pattern — composable workflow stages.

This module provides the infrastructure for building workflows as a sequence
of composable, testable stages instead of monolithic handlers.

Each stage has three phases:

1. @preCheck@   — Validates preconditions before execution (returns 'Either')
2. @exec@       — Performs the actual work (in the workflow monad)
3. @validate@   — Post-execution validation (returns 'Either')

Stages compose naturally via standard monadic bind ('>>=').

Example usage:

    data PrepareDeploymentStage m = PrepareDeploymentStage

    instance StageInterface PrepareDeploymentStage Flow where
        type StageInput  PrepareDeploymentStage = ReleaseId
        type StageOutput PrepareDeploymentStage = PreparedDeployment

    instance PreCheckStage PrepareDeploymentStage Flow where
        preCheck _ releaseId = do
            -- Check DB state, validate inputs...
            Right <$> validateReleaseExists releaseId

    instance ExecStage PrepareDeploymentStage Flow where
        exec _ releaseId validated = do
            -- Clone deployment, set up resources...
            prepareDeployment validated

    instance ValidateStage PrepareDeploymentStage Flow where
        validate _ result = do
            -- Verify pods are ready...
            Right <$> verifyDeploymentHealthy result

Pattern ported from infra-switch's Autopilot.Typeclass.Stage.Interface.
-}
module Core.Workflow.StageInterface (
    -- * Stage Interface Type Classes
    StageInterface (..),
    PreCheckStage (..),
    ExecStage (..),
    ValidateStage (..),

    -- * Stage Combinators
    runStage,
    runStageUnchecked,
    (>>>),

    -- * Stage Result Types
    StageResult,
    StageError (..),
    ValidationError (..),

    -- * Integration with WorkFlowError
    stageErrorToWorkFlowError,
) where

import Control.Monad.Except (ExceptT)
import Core.Workflow.Types (WorkFlowError (..))
import Data.Kind (Type)

-- | Errors that can occur during stage execution.
data StageError
    = PreconditionFailed String
    | ExecutionFailed String
    | PostValidationFailed String
    | AggregateErrors [StageError]
    deriving (Eq, Show)

-- | Validation errors collected during pre/post checks.
newtype ValidationError = ValidationError String
    deriving (Eq, Show)

-- | The result of running a stage (success or failure).
type StageResult m a = ExceptT StageError m a

{- | Type family defining the interface for a workflow stage.

Each stage declares its input and output types, allowing type-safe
composition and testing.
-}
class StageInterface s (m :: Type -> Type) | s -> m where
    type StageInput s
    type StageOutput s

{- | Pre-check phase: validates preconditions before execution.

Returns 'Either' to indicate validation success/failure without
monadic exceptions. This enables collecting multiple validation
errors before failing.
-}
class (StageInterface s m) => PreCheckStage s m where
    preCheck :: s -> StageInput s -> StageResult m (StageInput s)

{- | Execution phase: performs the actual work.

This is where side effects (DB writes, API calls, K8s operations)
occur. Runs only if preCheck succeeded.
-}
class (StageInterface s m) => ExecStage s m where
    exec :: s -> StageInput s -> StageResult m (StageOutput s)

{- | Post-validation phase: verifies the execution produced expected results.

Runs after exec to catch regressions or partial failures.
Returns 'Either' for consistent error handling.
-}
class (StageInterface s m) => ValidateStage s m where
    validate :: s -> StageOutput s -> StageResult m (StageOutput s)

-- | Run a complete stage (preCheck → exec → validate).
runStage ::
    ( Monad m
    , PreCheckStage s m
    , ExecStage s m
    , ValidateStage s m
    ) =>
    s ->
    StageInput s ->
    StageResult m (StageOutput s)
runStage stage input = do
    validatedInput <- preCheck stage input
    output <- exec stage validatedInput
    validate stage output

-- | Run a stage without validation (useful for testing or trusted operations).
runStageUnchecked ::
    ( Monad m
    , PreCheckStage s m
    , ExecStage s m
    ) =>
    s ->
    StageInput s ->
    StageResult m (StageOutput s)
runStageUnchecked stage input = do
    validatedInput <- preCheck stage input
    exec stage validatedInput

{- | Compose two stages: output of first becomes input of second.

Requires a conversion function since stages may have different types.
-}
infixr 1 >>>

(>>>) ::
    (Monad m) =>
    (a -> StageResult m b) ->
    (b -> StageResult m c) ->
    (a -> StageResult m c)
f >>> g = \x -> f x >>= g

{- | Convert 'StageError' to 'WorkFlowError' so stages plug into existing
workflow error handling. Product workflows call this at the boundary
where StageResult meets the main workflow monad.
-}
stageErrorToWorkFlowError :: StageError -> WorkFlowError
stageErrorToWorkFlowError (PreconditionFailed msg) = DomainError ("Precondition: " ++ msg)
stageErrorToWorkFlowError (ExecutionFailed msg) = RetriableError ("Execution: " ++ msg)
stageErrorToWorkFlowError (PostValidationFailed msg) = DomainError ("Validation: " ++ msg)
stageErrorToWorkFlowError (AggregateErrors errs) =
    MultipleErrors $ map (show . stageErrorToWorkFlowError) errs
