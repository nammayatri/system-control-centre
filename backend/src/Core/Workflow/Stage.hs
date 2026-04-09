{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Product-agnostic stage and outcome types for the SCC workflow engine.

This module defines the @Stage s@ record — a __value__ that bundles the
six-step lifecycle every stage in every workflow follows:

@
  1. SKIP CHECK         - 'stageGuard' returns True if already done
  2. ACQUIRE LOCKS      - 'stageAcquireLocks' returns lock handles
  3. PRE-CHECK          - 'stagePreCheck' validates preconditions
  4. EXEC               - 'stageExec' does the actual work
  5. VALIDATE           - 'stageExec' returns 'StageOutcome'
  6. ADVANCE + PERSIST  - 'stageOnAdvance' marks state as done; engine persists
@

A 'Stage' is parameterized over the state type @s@ — different SCC products
can use different state types (e.g. @ReleaseState@ for Autopilot,
@FrontendReleaseState@ for a future frontend release product) while sharing
the same engine in 'Core.Workflow.Engine'.

The fields are __polymorphic in the monad @m@__ via the 'StageM' constraint
synonym, so stages don't need to know whether they're running inside the
production @ExceptT WorkFlowError (Recorded s Flow)@ stack or a test harness.
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

-- ============================================================================
-- StageM — the polymorphic monad constraint for stage executors
-- ============================================================================

{- | Polymorphic constraint for stage execution.

Every stage's @stagePreCheck@, @stageExec@, @stageOnError@, and
@stageAcquireLocks@ runs inside any monad @m@ that satisfies @StageM s m@.

This is a constraint __synonym__ (not a class), matching SCC's existing
'Core.Environment.MonadFlow' pattern. We deliberately enumerate the
constraints rather than reuse 'MonadFlow' because 'MonadFlow' includes
'MonadMask', and providing a 'MonadMask' instance for 'Recorded' adds
significant complexity for very little stage-author benefit
(stages should use 'stageAcquireLocks' + the engine's @withLockBracket@
for the bracket pattern, not 'mask' directly).

The capabilities provided to stage authors:

* 'MonadIO'                       — IO at the boundary
* 'MC.MonadThrow' / 'MC.MonadCatch' — typed exception throwing and catching
* 'MonadReader' 'AppState'        — read config, DB pool, logger
* 'MonadState s'                  — mutate the workflow state
* 'MonadError' 'WorkFlowError'    — throw the two-bucket typed errors
                                    ('DomainError' for terminal failures,
                                    'RetriableError' for transient failures
                                    the runner retries on the next tick)

The engine in 'Core.Workflow.Engine' instantiates @m@ at the concrete
@ExceptT WorkFlowError (Recorded s Flow)@ stack used in production.
-}
type StageM s m =
    ( MonadIO m
    , MC.MonadThrow m
    , MC.MonadCatch m
    , MonadReader AppState m
    , MonadState s m
    , MonadError WorkFlowError m
    )

-- ============================================================================
-- StageOutcome — three-state outcome from stage execution
-- ============================================================================

{- | What @stageExec@ returns. Three terminal states for a single stage run:

* 'StageSuccess' — the stage completed successfully. Engine advances to the
  next stage in the workflow's @[Stage s]@ list.

* 'StageWaiting' — the stage hasn't failed, but it isn't done either
  (e.g. waiting for a cooloff period, polling external state, waiting for
  pods to be Ready). Engine throws 'RetriableError' so the runner picks the
  workflow back up on the next tick at the same stage. The stage's @stageGuard@
  is responsible for the resumption check on the next call.

* 'StageAbort' — terminal failure. Engine throws 'DomainError' so the runner
  marks the workflow Aborted and runs the workflow's rollback handler.
-}
data StageOutcome
    = StageSuccess
    | StageWaiting
    | StageAbort
    deriving (Eq, Show)

-- ============================================================================
-- LockHandle — bracketed resource locks
-- ============================================================================

{- | A handle to an acquired lock, bundled with a closure that releases it.

Each product implements its own lock primitive on its own config table
(e.g. Autopilot's @deployment_config.vs_locked_by@ for VirtualService locks)
without the engine knowing about the storage layer. The product returns a
list of 'LockHandle' values from @stageAcquireLocks@, and the engine wraps
the stage execution in a bracket pattern that calls @lockReleaseFn@ on every
exit path (success or failure).

The 'lockResource' field is for logging / debugging only — it identifies
which resource the lock protects (e.g. @"vs:test-vs"@, @"cdn:E12345"@,
@"npm:@juspay/sdk"@) without exposing the locking mechanism.
-}
data LockHandle = LockHandle
    { lockResource :: Text
    -- ^ Human-readable resource identifier (for logs / metrics)
    , lockReleaseFn :: Flow ()
    -- ^ Closure that releases the lock. Idempotent — safe to call twice.
    }

-- ============================================================================
-- Stage — the core abstraction
-- ============================================================================

{- | A single workflow stage, as a __value__ rather than a function.

Composable into @[Stage s]@ inside a 'Core.Workflow.Spec.WorkflowSpec'.
The engine ('Core.Workflow.Engine.runWorkflowSpec') walks the list and runs
each stage through the canonical six-step lifecycle (see module header).

== Why polymorphic in @m@? ==

@stagePreCheck@, @stageExec@, @stageOnError@, and @stageAcquireLocks@ are
all written against the 'StageM' constraint set, so a stage author can write
the body without committing to the concrete monad stack. The engine pins it
at @ExceptT WorkFlowError (Recorded s Flow)@ when it actually runs. This also
makes individual stages testable in any monad that satisfies @StageM s m@,
including a pure test harness.

== Why a record, not a typeclass? ==

A record lets workflows be __values__ — composable via list literals,
inspectable for documentation / metrics / dispatch, and trivially extended
by setting different fields. The infra-switch parallel codebase tried a
typeclass approach (@StageInterface a@) and abandoned it (commented out in
their prod code). Records won.
-}
data Stage s = Stage
    { stageName :: Text
    -- ^ Human-readable name. Used as a log tag, metric label, and event
    --   record name (engine emits @STAGE_<name>_STARTED@ etc.).
    , stagePreCheck :: forall m. (StageM s m) => m ()
    -- ^ Idempotency guard. Runs after the resumption skip check but before
    --   the main exec — its job is to detect partial completion or sanity-
    --   check inputs. Throws via 'throwError' on failure.
    --
    --   Default ('mkStage'): @pure ()@ — no pre-check.
    , stageExec :: forall m. (StageM s m) => m StageOutcome
    -- ^ The actual work. Returns 'StageSuccess' to advance, 'StageWaiting'
    --   to keep current state and have the runner retry, or 'StageAbort'
    --   for terminal failure.
    --
    --   Errors thrown via 'throwError' are mapped by the engine:
    --   'DomainError' becomes 'StageAbort', 'RetriableError' becomes
    --   'StageWaiting'.
    , stageOnError :: forall m. (StageM s m) => WorkFlowError -> m ()
    -- ^ Cleanup hook. Called by the engine on any failure (retriable or
    --   domain), AFTER locks have been released, BEFORE the workflow-level
    --   'Core.Workflow.Spec.wsRollback' runs. The stage can use this to
    --   release partial state, emit a custom event, or notify Slack.
    --
    --   Default ('mkStage'): @\\_ -> pure ()@ — no cleanup.
    , stageAcquireLocks :: forall m. (StageM s m) => m [LockHandle]
    -- ^ Acquire all the resource locks this stage needs. Locks are released
    --   by the engine via the bracket pattern on every exit path (success
    --   or failure), so stage authors don't need to manually release them.
    --
    --   Default ('mkStage'): @pure []@ — no locks.
    , stageGuard :: s -> Bool
    -- ^ Resumption check: returns 'True' if this stage has already been
    --   completed in a previous run. The engine consults this BEFORE calling
    --   @stagePreCheck@ — if it returns 'True', the entire stage is skipped.
    --
    --   __MUST be a pure function of __persisted__ state.__ Inspecting
    --   intermediate values computed by previous stages in the same call
    --   will produce wrong results on resume. See 'Core.Workflow.Recorded'
    --   for the contract.
    --
    --   Default ('mkStage'): @const False@ — never skip.
    , stageOnAdvance :: s -> s
    -- ^ State update applied after a successful 'StageSuccess' return,
    --   before the engine advances to the next stage. Typically marks the
    --   stage as done (e.g. setting a status field, flipping a flag) so
    --   that @stageGuard@ returns 'True' on the next call.
    --
    --   __MUST be idempotent.__ Applying it twice should produce the same
    --   state as applying it once.
    --
    --   Default ('mkStage'): @id@ — no state change.
    }

{- | Smart constructor for 'Stage' with sensible defaults.

Builds a 'Stage' from just a name and an exec body. All other fields are
defaulted to no-ops:

* @stagePreCheck     = pure ()@
* @stageOnError      = \\_ -> pure ()@
* @stageAcquireLocks = pure []@
* @stageGuard        = const False@
* @stageOnAdvance    = id@

Override individual fields using record-update syntax:

@
myStage :: Stage MyState
myStage = (mkStage "create-resource" doCreate)
    { stageGuard     = isResourceCreated
    , stageOnAdvance = \\s -> s { resourceCreated = True }
    , stageOnError   = \\err -> logError ("create-resource failed: " <> show err)
    }
@
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
