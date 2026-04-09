{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | Product-agnostic SCC workflow engine.

'runWorkflowSpec' walks any 'WorkflowSpec s' through the canonical
six-step stage lifecycle (skip, lock, pre-check, exec, validate,
advance+persist). On failure, 'wsRollback' runs before the error
propagates to the runner. Resumability is inherited from
'Core.Workflow.Recorded' via the stage's 'stageGuard' as the cache getter.
-}
module Core.Workflow.Engine (
    -- * Running a workflow spec
    runWorkflowSpec,

    -- * Adapter for legacy 'StateFlow' code
    liftStateFlow,
)
where

import Control.Exception (SomeException)
import qualified Control.Monad.Catch as MC
import Control.Monad.Except (ExceptT, catchError, throwError)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (MonadReader, ask)
import Control.Monad.State.Strict (MonadState, get, gets, modify, put)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Reader (runReaderT)
import Control.Monad.Trans.State.Strict (StateT, runStateT)
import Core.Environment (AppState, Flow)
import Core.Logging (logErrorG, logInfoG, withLogTag)
import Core.Workflow.Recorded (Recorded)
import Core.Workflow.Spec (WorkflowSpec (..))
import Core.Workflow.Stage (LockHandle (..), Stage (..), StageOutcome (..))
import Core.Workflow.Types (WorkFlowError (..))
import qualified Data.Text as T

-- | Walk @wsStages@ in order. On failure, run @wsRollback@ and rethrow.
runWorkflowSpec ::
    forall s.
    WorkflowSpec s ->
    ExceptT WorkFlowError (Recorded s Flow) ()
runWorkflowSpec spec = do
    lift . lift $ withLogTag (wsName spec) $ logInfoG ("workflow start: " <> wsName spec)
    walk `catchError` \err -> do
        lift . lift $
            withLogTag (wsName spec) $
                logErrorG ("workflow failed: " <> wsName spec <> " — " <> renderError err)
        wsRollback spec err
        throwError err
    lift . lift $ withLogTag (wsName spec) $ logInfoG ("workflow done: " <> wsName spec)
  where
    walk :: ExceptT WorkFlowError (Recorded s Flow) ()
    walk = mapM_ (runStage spec) (wsStages spec)

    renderError :: WorkFlowError -> T.Text
    renderError = \case
        DomainError msg -> "DomainError: " <> T.pack msg
        RetriableError msg -> "RetriableError: " <> T.pack msg

-- | Run one 'Stage' through skip/lock/pre-check/exec/validate/advance+persist.
runStage ::
    forall s.
    WorkflowSpec s ->
    Stage s ->
    ExceptT WorkFlowError (Recorded s Flow) ()
runStage spec stage = withLogTagInExceptT (stageName stage) $ do
    alreadyDone <- lift $ gets (stageGuard stage)
    if alreadyDone
        then lift . lift $ logInfoG ("skipped (already done): " <> stageName stage)
        else do
            lift . lift $ logInfoG ("running: " <> stageName stage)
            withLockBracket stage $ do
                stagePreCheck stage
                outcome <- stageExec stage
                case outcome of
                    StageSuccess -> do
                        modify (stageOnAdvance stage)
                        s <- get
                        lift . lift $ wsPersist spec s
                        lift . lift $ logInfoG ("completed: " <> stageName stage)
                    StageWaiting ->
                        throwError
                            ( RetriableError
                                ( T.unpack (stageName stage)
                                    <> ": waiting (will retry on next tick)"
                                )
                            )
                    StageAbort ->
                        throwError
                            ( DomainError
                                ( T.unpack (stageName stage)
                                    <> ": aborted"
                                )
                            )

{- | Bracket locks over the body: release on every exit path. A broken
release swallows its own exception (logged) so it can't mask the original
failure. 'stageOnError' runs BEFORE locks are released so it can still
inspect the locked state.
-}
withLockBracket ::
    forall s a.
    Stage s ->
    ExceptT WorkFlowError (Recorded s Flow) a ->
    ExceptT WorkFlowError (Recorded s Flow) a
withLockBracket stage body = do
    locks <- stageAcquireLocks stage
    -- Single cleanup closure over 'locks', reused on every exit path.
    let cleanup :: ExceptT WorkFlowError (Recorded s Flow) ()
        cleanup = lift . lift $ mapM_ releaseOne locks

        releaseOne :: LockHandle -> Flow ()
        releaseOne (LockHandle name release) = do
            r <- MC.try @_ @SomeException release
            case r of
                Right () -> pure ()
                Left ex ->
                    logErrorG
                        ( "lock release failed for resource "
                            <> name
                            <> ": "
                            <> T.pack (show ex)
                        )

    -- Wrap body with typed WorkFlowError catch and raw IO exception catch
    -- (buggy stage code may throw outside MonadError).
    let bodyWithErrorCatch =
            body `catchError` \err -> do
                stageOnError stage err
                cleanup
                throwError err

        bodyWithExceptionCatch =
            bodyWithErrorCatch `MC.catch` \(ex :: SomeException) -> do
                cleanup
                throwError
                    ( DomainError
                        ( T.unpack (stageName stage)
                            <> ": uncaught exception: "
                            <> show ex
                        )
                    )

    -- Success path: run body then cleanup. Failure paths already ran
    -- cleanup in their handler above and rethrew.
    result <- bodyWithExceptionCatch
    cleanup
    pure result

{- | Emit a tagged log line on entry. We can't wrap ExceptT in 'withLogTag'
(which uses IO bracket_) so this is a best-effort marker, not a tag scope.
-}
withLogTagInExceptT ::
    forall s a.
    T.Text ->
    ExceptT WorkFlowError (Recorded s Flow) a ->
    ExceptT WorkFlowError (Recorded s Flow) a
withLogTagInExceptT tag body = do
    lift . lift $ logInfoG ("[" <> tag <> "] entering")
    body

{- | Adapter for incremental migration: runs a legacy @StateT s Flow a@ body
inside any stage monad. State is committed atomically at the final 'put'
(no streaming). Errors must be thrown via @liftIO . throwIO@; @StateT s
Flow@ has no 'MonadError'.
-}
liftStateFlow ::
    forall s m a.
    ( MonadIO m
    , MonadReader AppState m
    , MonadState s m
    ) =>
    StateT s Flow a ->
    m a
liftStateFlow action = do
    s <- get
    appSt <- ask
    (a, s') <- liftIO (runReaderT (runStateT action s) appSt)
    put s'
    pure a
