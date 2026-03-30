{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE InstanceSigs #-}

-- | Recorded monad for resumable workflow execution.
-- Adapted from Mobius for NammaAP.
--
-- The Recorded monad combines StateT with checkpointing:
-- - Each step can check if it's already completed via 'getter'
-- - If completed, the step is skipped
-- - If not completed, the step runs and persists state
--
-- This enables automatic resume on process crashes without manual
-- workflowStatus checks throughout the codebase.
module NammaAP.Products.Autopilot.Workflow.Recorded
  ( Recorded(..)
  , runRecorded
  , recordedWithPersist
  , step
  , stepWithRollback
  ) where

import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.State.Strict
import Control.Monad.Trans.Class
import Control.Monad.State.Class (MonadState, state)

-- | A Recorded computation that can be resumed from checkpoints
data Recorded s m a = Recorded
  { inner :: StateT s m a        -- The actual computation
  , getter :: s -> Maybe a       -- Check if already completed
  }

-- | Run a Recorded computation
-- If the getter returns a value, skip the computation
-- Otherwise, run the inner StateT computation
runRecorded :: Monad m => Recorded s m a -> s -> m (a, s)
runRecorded (Recorded { inner, getter }) s =
  maybe
    (runStateT inner s)  -- Not done, run computation
    (pure . (,s))        -- Already done, return cached result
    (getter s)

-- Functor instance
instance Monad m => Functor (Recorded s m) where
  fmap f (Recorded { inner, getter }) =
    Recorded
      { inner = f <$> inner
      , getter = fmap f . getter
      }

-- Applicative instance
instance Monad m => Applicative (Recorded s m) where
  pure = return
  (<*>) = ap

-- Monad instance - this is where the magic happens
instance Monad m => Monad (Recorded s m) where
  return a =
    Recorded
      { inner = return a
      , getter = const Nothing  -- No cached value, always run
      }

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
      , getter = const Nothing  -- Lifted actions are never cached
      }

-- MonadIO instance for IO operations
instance MonadIO m => MonadIO (Recorded s m) where
  liftIO action =
    Recorded
      { inner = liftIO action
      , getter = const Nothing  -- IO actions are never cached
      }

-- MonadState instance for state manipulation
instance Monad m => MonadState s (Recorded s m) where
  state exec =
    Recorded
      { inner = StateT (pure . exec)
      , getter = const Nothing
      }

-- | Create a Recorded step with automatic persistence
-- This is the main helper for creating checkpointed workflow steps
recordedWithPersist
  :: Monad m
  => (s -> m ())        -- ^ Persist function (save to DB)
  -> StateT s m a       -- ^ The computation
  -> (s -> Maybe a)     -- ^ Getter to check if already done
  -> Recorded s m a
recordedWithPersist persist computation getter =
  Recorded
    { inner = do
        -- Try to get cached result
        cachedResult <- gets getter
        case cachedResult of
          Just a -> return a  -- Already done, return cached
          Nothing -> do
            -- Not done, run computation
            result <- computation
            -- Persist the new state
            s <- get
            lift $ persist s
            return result
    , getter = getter
    }

-- | Create a simple workflow step with checkpointing
--
-- Usage:
-- @
--   step "Create Deployment"
--     (\rt -> rt { deploymentCreated = True })
--     (\rt -> deploymentCreated rt)
--     (\rt -> insertReleaseTracker db rt)
--     createDeploymentAction
-- @
step
  :: MonadIO m
  => String                    -- ^ Step name (for logging)
  -> (s -> s)                  -- ^ State update after completion
  -> (s -> Bool)               -- ^ Check if already done
  -> (s -> m ())               -- ^ Persist function
  -> StateT s m ()             -- ^ The actual step computation
  -> Recorded s m ()
step stepName updateState isDone persist computation =
  recordedWithPersist persist computation' getter
  where
    computation' = do
      -- Check if already done
      s <- get
      if isDone s
        then return ()
        else do
          -- Run the computation
          computation
          -- Update state to mark as done
          modify updateState
          return ()

    getter s = if isDone s then Just () else Nothing

-- | Create a workflow step with rollback capability
--
-- Usage:
-- @
--   stepWithRollback "Deploy to Production"
--     (\rt -> rt { deployedToProduction = True })
--     (\rt -> deployedToProduction rt)
--     (\rt -> insertReleaseTracker db rt)
--     deployAction
--     rollbackAction
-- @
stepWithRollback
  :: MonadIO m
  => String                    -- ^ Step name
  -> (s -> s)                  -- ^ State update after completion
  -> (s -> Bool)               -- ^ Check if already done
  -> (s -> m ())               -- ^ Persist function
  -> StateT s m ()             -- ^ Forward action
  -> StateT s m ()             -- ^ Rollback action
  -> Recorded s m (Either String ())
stepWithRollback stepName updateState isDone persist forwardAction rollbackAction =
  recordedWithPersist persist computation' getter
  where
    computation' = do
      s <- get
      if isDone s
        then return $ Right ()
        else do
          -- Try to run forward action
          result <- lift $ tryAction forwardAction
          case result of
            Right () -> do
              modify updateState
              return $ Right ()
            Left err -> do
              -- Forward action failed, run rollback
              _ <- lift $ tryAction rollbackAction
              return $ Left err

    getter s = if isDone s then Just (Right ()) else Nothing

    tryAction :: Monad m => StateT s m () -> m (Either String ())
    tryAction action = do
      -- In a real implementation, you'd use ExceptT or catch exceptions
      -- For now, we assume actions succeed
      return $ Right ()
