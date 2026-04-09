{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}

{- | Recorded monad for resumable workflow execution.

The Recorded monad combines StateT with checkpointing:

- Each step can check if it's already completed via 'getter'
- If completed, the step is skipped
- If not completed, the step runs and persists state

This enables automatic resume on process crashes without manual
status checks throughout the codebase.

This module is fully generic — it does not depend on any product.
Every SCC product that needs resumable, checkpointed workflows reuses
this exact engine by choosing its own state type @s@ and base monad @m@.
-}
module Core.Workflow.Recorded (
    Recorded (..),
    runRecorded,
    recordedWithPersist,
)
where

import Control.Exception (SomeException)
import Control.Monad
import qualified Control.Monad.Catch as MC
import Control.Monad.IO.Class
import Control.Monad.Reader.Class (MonadReader (ask, local, reader))
import Control.Monad.State.Class (MonadState, state)
import Control.Monad.Trans.Class
import Control.Monad.Trans.State.Strict

-- | A Recorded computation that can be resumed from checkpoints
data Recorded s m a = Recorded
    { inner :: StateT s m a -- The actual computation
    , getter :: s -> Maybe a -- Check if already completed
    }

{- | Run a Recorded computation
If the getter returns a value, skip the computation
Otherwise, run the inner StateT computation
-}
runRecorded :: (Monad m) => Recorded s m a -> s -> m (a, s)
runRecorded (Recorded{inner, getter}) s =
    maybe
        (runStateT inner s) -- Not done, run computation
        (pure . (,s)) -- Already done, return cached result
        (getter s)

-- Functor instance
instance (Monad m) => Functor (Recorded s m) where
    fmap f (Recorded{inner, getter}) =
        Recorded
            { inner = f <$> inner
            , getter = fmap f . getter
            }

-- Applicative instance
instance (Monad m) => Applicative (Recorded s m) where
    pure a =
        Recorded
            { inner = pure a
            , getter = const Nothing -- No cached value, always run
            }
    (<*>) = ap

{- | Monad instance for chained checkpointed steps.

== How the @inner@ chain works ==

@inner@ runs the chain in the natural way: thread state @s@ through
@runRecorded recordedma@, then through @runRecorded (recordedmab a)@. Each
'runRecorded' consults its own getter and either replays from cache or
re-executes. State propagates correctly between halves: action B sees the
state mutations made by action A.

== How the @getter@ chain works (and the contract on getters) ==

The bind's getter is a pure short-circuit — it asks both halves whether
they're already done, using the __same input state @s@__:

@
getter = \\s -> do
    a <- getter recordedma s    -- A's getter, with state s
    getter (recordedmab a) s    -- B's getter, also with state s (NOT s')
@

This is __not__ the same shape as @inner@ — @inner@ threads state through,
@getter@ does not. The reason: getters live in the pure 'Maybe' monad and
have no way to compute the post-A state without actually running A's
effects (which they cannot do, by definition).

This is __safe__ as long as every 'getter' is a pure predicate over
__persisted state__. For example, SCC's only production getter is
@stateCheckFuncV2@:

@
stateCheckFuncV2 :: ReleaseWFStatus -> ReleaseState -> Maybe ()
stateCheckFuncV2 targetStatus rs =
    if releaseWFStatus (releaseTracker rs) >= targetStatus
        then Just ()
        else Nothing
@

It looks at @rs.releaseTracker.releaseWFStatus@, which is what the previous
run __persisted__ (via @persistWorkflowState@). It does not depend on
intermediate state mutations made by other actions in the current call,
because those mutations are not yet persisted at the moment the getter is
consulted.

== When the contract breaks (and why we don't fix it in the engine) ==

A theoretically broken getter would look like:

@
badGetter s = case intermediateValueComputedByA s of
    Just _  -> Just ()
    Nothing -> Nothing
@

If A computes @intermediateValueComputedByA@ in its 'inner' but does not
persist it before B's getter is consulted, the getter chain returns 'Nothing'
when it should return 'Just' on a hot path. The fix is __not__ to change the
engine — it's to make the getter only inspect persisted fields. The engine
cannot enforce this; the contract is on every author of a 'Recorded' value.

__In short: getters must be pure functions of persisted state. Engine
guarantees skip-if-past resumption only when this contract is honored.__
-}
instance (Monad m) => Monad (Recorded s m) where
    recordedma >>= recordedmab =
        Recorded
            { inner = StateT $ \s -> do
                (a, s') <- runRecorded recordedma s
                runRecorded (recordedmab a) s'
            , getter = \s -> do
                a <- getter recordedma s
                getter (recordedmab a) s
            }

-- MonadTrans instance for lifting
instance MonadTrans (Recorded s) where
    lift ma =
        Recorded
            { inner = lift ma
            , getter = const Nothing -- Lifted actions are never cached
            }

-- MonadIO instance for IO operations
instance (MonadIO m) => MonadIO (Recorded s m) where
    liftIO action =
        Recorded
            { inner = liftIO action
            , getter = const Nothing -- IO actions are never cached
            }

-- ============================================================================
-- Pass-through instances — delegate to the underlying StateT s m
-- ============================================================================
--
-- The 'Recorded' wrapper around 'StateT' needs the same set of mtl-style
-- instances any product workflow would expect, so the @StageM@ constraint
-- in 'Core.Workflow.Stage' can be satisfied by
-- @ExceptT WorkFlowError (Recorded s Flow)@.
--
-- All these instances are __pass-throughs__ — they delegate to the
-- existing instance on the underlying 'StateT s m' (via @inner@) and set
-- the getter to a sensible default (usually @const Nothing@ because
-- side-effecting operations like throwing or reading the environment
-- aren't checkpointed).

-- | Throw exceptions through the inner StateT. Setter: never cached.
instance (MC.MonadThrow m) => MC.MonadThrow (Recorded s m) where
    throwM e =
        Recorded
            { inner = MC.throwM e
            , getter = const Nothing
            }

{- | Catch exceptions in the inner StateT. The handler's getter is dropped
  because exception-recovery paths are not part of the normal workflow
  flow and shouldn't participate in cache lookups.
-}
instance (MC.MonadCatch m) => MC.MonadCatch (Recorded s m) where
    catch (Recorded innerAction g) handler =
        Recorded
            { inner = MC.catch innerAction (\e -> case handler e of Recorded i _ -> i)
            , getter = g
            }

{- | Read the underlying environment (e.g. 'AppState' from the 'Flow' base).
  Pass-through to the StateT instance which itself passes through to @m@.
-}
instance (MonadReader r m) => MonadReader r (Recorded s m) where
    ask = Recorded{inner = ask, getter = const Nothing}
    local f (Recorded i g) = Recorded{inner = local f i, getter = g}
    reader f = Recorded{inner = reader f, getter = const Nothing}

{- | __MonadState instance for state manipulation.__

__⚠ Idempotency contract:__ State operations performed inside a 'Recorded'
block (via 'modify', 'put', 'state', etc.) have @getter = const Nothing@,
which means they are __not cached__ and __will re-execute on every resume__
of the workflow. This is by design — caching arbitrary state mutations would
require running the rest of the chain to know whether they had already been
applied.

__Therefore, every state operation inside a 'Recorded' block must be
idempotent.__ Concretely:

* OK:  @modify (\\s -> s { stepDone = True })@      — set a flag (idempotent)
* OK:  @modify (\\s -> s { result = computeResult })@ — replace a field
* BAD: @modify (\\s -> s { counter = counter s + 1 })@ — increments on resume
* BAD: @modify (\\s -> s { log = newEvent : log s })@  — appends on resume

If you need to do something that is not naturally idempotent, structure it
as a checkpointed step via 'recordedWithPersist' or 'step' so the getter can
detect whether the operation has already been applied (by inspecting the
state) and skip it on resume.

This same constraint applies to 'lift' (MonadTrans) and 'liftIO' (MonadIO):
both bypass the cache and re-run on every resume. Lifted actions must be
idempotent for the same reason.
-}
instance (Monad m) => MonadState s (Recorded s m) where
    state exec =
        Recorded
            { inner = StateT (pure . exec)
            , getter = const Nothing
            }

{- | Create a 'Recorded' step with automatic persistence.

This is the main helper for creating checkpointed workflow steps. The step
runs in three phases:

1. Read current state and consult @getter@. If it returns @Just a@, the step
   was already completed in a previous run; return the cached result and
   skip the computation entirely.

2. Otherwise, run @computation@ to produce both the new state (via the
   surrounding 'StateT') and the result @a@.

3. Call @persist@ on the new state. If @persist@ raises a synchronous
   exception, it propagates up to the caller via the 'MC.MonadCatch'
   constraint — we catch it explicitly here so future versions of this
   module can attach context (e.g. the step name, a structured error type)
   without changing the signature, and immediately re-raise so the runner's
   top-level @try \@SomeException@ in 'Products.Autopilot.Runner' converts
   it to a typed 'WorkFlowError'.

== Idempotency contract ==

The @computation@ MUST be idempotent. If @persist@ throws, the
computation's result and state mutations are lost, and the computation will
be re-run on the next runner tick. This is a fundamental contract of every
step in a Recorded workflow. Operations that are not idempotent (e.g.
@modify (\\s -> s { counter = counter + 1 })@) will produce wrong results
on resume.

@persist@ itself is the durability barrier — it MUST be transactional and
idempotent. SCC's persistence layer satisfies this via Beam's
'withTransaction' wrapping and the natural idempotence of @UPDATE ... WHERE
release_id = ?@.
-}
recordedWithPersist ::
    (MC.MonadCatch m) =>
    -- | Persist function (save to DB). Must be transactional + idempotent.
    (s -> m ()) ->
    -- | The computation. Must be idempotent — see contract above.
    StateT s m a ->
    -- | Getter to check if already done
    (s -> Maybe a) ->
    Recorded s m a
recordedWithPersist persist computation getter =
    Recorded
        { inner = do
            -- Try to get cached result
            cachedResult <- gets getter
            case cachedResult of
                Just a -> return a -- Already done, return cached
                Nothing -> do
                    -- Not done, run computation
                    result <- computation
                    -- Persist the new state.
                    --
                    -- We catch any synchronous exception so the failure
                    -- point is explicit (and so future versions can attach
                    -- context here without breaking the API). On failure,
                    -- we re-throw via 'MC.throwM' so the runner's
                    -- top-level handler sees the exception and converts it
                    -- to a typed 'WorkFlowError'. The computation's result
                    -- is lost on this path; the next tick will re-run the
                    -- (idempotent) computation from scratch.
                    s <- get
                    persistResult <- lift $ MC.try @_ @SomeException (persist s)
                    case persistResult of
                        Right () -> return result
                        Left ex -> lift $ MC.throwM ex
        , getter = getter
        }

-- Note: the legacy 'step' and 'stepWithRollback' helpers were removed after
-- the workflow-engine refactor — no callers remained in the codebase. The
-- canonical stage API now lives in 'Core.Workflow.Stage' + 'Core.Workflow.Engine',
-- which provides the same checkpointing + bracketed rollback semantics at
-- the 'Stage s' level. If you want a standalone checkpointed step, use
-- 'recordedWithPersist' directly with your own getter function.
