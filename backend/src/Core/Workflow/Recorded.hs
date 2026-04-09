{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}

{- | Recorded monad for resumable, checkpointed workflow execution.

Wraps 'StateT s m' with a pure 'getter :: s -> Maybe a' that short-circuits
execution if the step was already completed (by inspecting persisted state).
Product-agnostic: pick your own @s@ and base monad @m@.
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

{- | A resumable computation: a StateT action paired with a pure predicate
  that short-circuits execution when the state shows it's already done.
-}
data Recorded s m a = Recorded
    { inner :: StateT s m a
    , getter :: s -> Maybe a
    }

-- | If @getter s@ hits, return the cached value without running @inner@.
runRecorded :: (Monad m) => Recorded s m a -> s -> m (a, s)
runRecorded (Recorded{inner, getter}) s =
    maybe (runStateT inner s) (pure . (,s)) (getter s)

instance (Monad m) => Functor (Recorded s m) where
    fmap f (Recorded{inner, getter}) =
        Recorded
            { inner = f <$> inner
            , getter = fmap f . getter
            }

instance (Monad m) => Applicative (Recorded s m) where
    pure a =
        Recorded
            { inner = pure a
            , getter = const Nothing
            }
    (<*>) = ap

{- | Bind chains the @inner@ actions by threading state through, but chains
the @getter@s using the __same input state @s@__ for both halves (getters
are pure 'Maybe' and can't compute post-A state without running A).

Contract: every 'getter' must be a pure predicate over __persisted__ state
only. Inspecting intermediate values mutated by earlier actions in the same
call will produce false negatives on resume. The engine cannot enforce this.
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

-- Lifted and IO actions are never cached — they re-execute on every resume,
-- so they must be idempotent. See the MonadState note below.
instance MonadTrans (Recorded s) where
    lift ma =
        Recorded
            { inner = lift ma
            , getter = const Nothing
            }

instance (MonadIO m) => MonadIO (Recorded s m) where
    liftIO action =
        Recorded
            { inner = liftIO action
            , getter = const Nothing
            }

-- Pass-through mtl instances so @StageM@ can be satisfied by
-- @ExceptT WorkFlowError (Recorded s Flow)@. Getter is 'const Nothing'
-- because these effects are not checkpointed.

instance (MC.MonadThrow m) => MC.MonadThrow (Recorded s m) where
    throwM e =
        Recorded
            { inner = MC.throwM e
            , getter = const Nothing
            }

-- The handler's getter is dropped — exception-recovery paths don't
-- participate in cache lookups.
instance (MC.MonadCatch m) => MC.MonadCatch (Recorded s m) where
    catch (Recorded innerAction g) handler =
        Recorded
            { inner = MC.catch innerAction (\e -> case handler e of Recorded i _ -> i)
            , getter = g
            }

instance (MonadReader r m) => MonadReader r (Recorded s m) where
    ask = Recorded{inner = ask, getter = const Nothing}
    local f (Recorded i g) = Recorded{inner = local f i, getter = g}
    reader f = Recorded{inner = reader f, getter = const Nothing}

{- | __Idempotency contract:__ state operations inside 'Recorded' are NOT
cached and re-execute on every resume. Use field replacements or flag sets
(@s { stepDone = True }@), NOT accumulators like @counter + 1@ or list
prepends — those will be applied repeatedly. If an operation isn't naturally
idempotent, wrap it in 'recordedWithPersist' with a getter that detects
completion. Same rule applies to 'lift' and 'liftIO'.
-}
instance (Monad m) => MonadState s (Recorded s m) where
    state exec =
        Recorded
            { inner = StateT (pure . exec)
            , getter = const Nothing
            }

{- | Build a checkpointed step: skip via @getter@ if already done, otherwise
run @computation@ then @persist@ the new state.

Both @computation@ and @persist@ MUST be idempotent — on persist failure the
computation's result is lost and the next tick re-runs it from scratch. The
explicit try/rethrow exists so future versions can attach context (step
name, structured error) without changing the signature.
-}
recordedWithPersist ::
    (MC.MonadCatch m) =>
    -- | Persist (transactional + idempotent).
    (s -> m ()) ->
    -- | Computation (idempotent).
    StateT s m a ->
    -- | Skip predicate over persisted state.
    (s -> Maybe a) ->
    Recorded s m a
recordedWithPersist persist computation getter =
    Recorded
        { inner = do
            cachedResult <- gets getter
            case cachedResult of
                Just a -> return a
                Nothing -> do
                    result <- computation
                    s <- get
                    persistResult <- lift $ MC.try @_ @SomeException (persist s)
                    case persistResult of
                        Right () -> return result
                        Left ex -> lift $ MC.throwM ex
        , getter = getter
        }
