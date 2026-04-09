{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Product-agnostic stage and outcome types for the SCC workflow engine.

Defines 'Stage' — a value bundling the six-step lifecycle every stage runs:
skip-check, acquire-locks, pre-check, exec, validate, advance+persist.

Parameterized over the state type @s@ so products reuse the same engine
with their own state. Executor fields are polymorphic in the monad via
'StageM' for testability.
-}
module Core.Workflow.Stage (
    -- * Stages
    Stage (..),
    mkStage,

    -- * Stage execution context
    StageM,

    -- * Stage outcomes
    StageOutcome (..),

    -- * Resource locking
    LockHandle (..),
)
where

import qualified Control.Monad.Catch as MC
import Control.Monad.Except (MonadError)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Reader (MonadReader)
import Control.Monad.State.Strict (MonadState)
import Core.Environment (AppState, Flow)
import Core.Workflow.Types (WorkFlowError)
import Data.Text (Text)

{- | Polymorphic constraint for stage executors.

A constraint synonym (not a class) deliberately excluding 'MonadMask' —
stages should use 'stageAcquireLocks' + the engine's @withLockBracket@
instead of masking directly. The engine pins @m@ to
@ExceptT WorkFlowError (Recorded s Flow)@ in production.
-}
type StageM s m =
    ( MonadIO m
    , MC.MonadThrow m
    , MC.MonadCatch m
    , MonadReader AppState m
    , MonadState s m
    , MonadError WorkFlowError m
    )

{- | Outcome of 'stageExec':

* 'StageSuccess' — advance to next stage.
* 'StageWaiting' — not failed but not done (polling, cooloff); engine throws
  'RetriableError' so the runner retries on the next tick at the same stage.
* 'StageAbort' — terminal failure; engine throws 'DomainError' and runs rollback.
-}
data StageOutcome
    = StageSuccess
    | StageWaiting
    | StageAbort
    deriving (Eq, Show)

{- | A handle to an acquired lock, bundled with a closure that releases it.

Products implement their own lock primitive (e.g. Autopilot's
@deployment_config.vs_locked_by@) and return 'LockHandle' values from
'stageAcquireLocks'. The engine releases every handle on all exit paths.
-}
data LockHandle = LockHandle
    { lockResource :: Text
    -- ^ Human-readable resource identifier (for logs / metrics).
    , lockReleaseFn :: Flow ()
    -- ^ Release closure. MUST be idempotent — may be called more than once.
    }

{- | A single workflow stage as a value. Composed into @[Stage s]@ inside a
'Core.Workflow.Spec.WorkflowSpec' and walked by the engine.

Executor fields are polymorphic in @m@ via 'StageM' so stage bodies don't
depend on a concrete monad stack.
-}
data Stage s = Stage
    { stageName :: Text
    -- ^ Log tag / metric label / event record name.
    , stagePreCheck :: forall m. (StageM s m) => m ()
    -- ^ Runs after the skip check, before 'stageExec'. Throws via
    --   'throwError' on failure. Default: @pure ()@.
    , stageExec :: forall m. (StageM s m) => m StageOutcome
    -- ^ The main work. 'throwError' 'DomainError'→'StageAbort',
    --   'RetriableError'→'StageWaiting'.
    , stageOnError :: forall m. (StageM s m) => WorkFlowError -> m ()
    -- ^ Per-stage cleanup. Called on any failure AFTER locks are released
    --   and BEFORE 'wsRollback'. Default: no-op.
    , stageAcquireLocks :: forall m. (StageM s m) => m [LockHandle]
    -- ^ Acquire resource locks; engine releases them on every exit path.
    --   Default: @pure []@.
    , stageGuard :: s -> Bool
    -- ^ Resume check. MUST be a pure function of __persisted__ state —
    --   inspecting values mutated by earlier stages in the same tick
    --   produces wrong results on resume. Default: @const False@.
    , stageOnAdvance :: s -> s
    -- ^ State update after 'StageSuccess', before advancing. MUST be
    --   idempotent. Default: @id@.
    }

{- | Smart constructor: only name and exec required, everything else
defaulted to no-ops. Override other fields with record-update syntax.
-}
mkStage :: Text -> (forall m. (StageM s m) => m StageOutcome) -> Stage s
mkStage name exec =
    Stage
        { stageName = name
        , stagePreCheck = pure ()
        , stageExec = exec
        , stageOnError = \_ -> pure ()
        , stageAcquireLocks = pure []
        , stageGuard = const False
        , stageOnAdvance = id
        }
