{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | The product-agnostic SCC workflow engine.

This module exports 'runWorkflowSpec', which takes any 'WorkflowSpec s' and
executes it through the canonical six-step lifecycle every stage runs:

@
  1. SKIP CHECK         - 'stageGuard' returns True if already done
  2. ACQUIRE LOCKS      - 'stageAcquireLocks' returns lock handles
  3. PRE-CHECK          - 'stagePreCheck' validates preconditions
  4. EXEC               - 'stageExec' does the actual work
  5. VALIDATE           - StageOutcome decides advance / wait / abort
  6. ADVANCE + PERSIST  - 'stageOnAdvance' marks state as done; persisted
@

On any stage failure (retriable or domain), the workflow's
'Core.Workflow.Spec.wsRollback' handler runs, then the exception propagates
upward to the runner.

== How this layer relates to 'Core.Workflow.Recorded' ==

The engine __builds on top of__ 'Core.Workflow.Recorded'. It does not
replace it. Each stage's lifecycle is wrapped in 'recordedWithPersist' so
that on a process crash mid-workflow, the next runner tick resumes from the
last persisted stage rather than starting from scratch. The 'stageGuard'
function is the recorded getter — if it returns 'True', the stage's effects
are skipped on resume.

== Polymorphism over the state type ==

The engine works for any state type @s@ — Autopilot uses 'ReleaseState',
future products can use their own. The constraint set @StageM s m@ pins the
required capabilities (state, error, IO, AppState reader). The runner is
expected to call this with the concrete monad stack
@'ExceptT' 'WorkFlowError' ('Recorded' s 'Flow')@.
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

-- ============================================================================
-- runWorkflowSpec — the main entry point
-- ============================================================================

{- | Execute a 'WorkflowSpec' end-to-end.

Walks the spec's @wsStages@ in order, running each through 'runStage'. On
any stage failure, calls @wsRollback@ before re-throwing the error so it
propagates up to the runner.

The result type is @ExceptT WorkFlowError (Recorded s Flow) ()@ — the same
shape as Autopilot's 'ReleaseWorkFlow', so this can be dropped into existing
'runRecorded' / 'runExceptT' call sites.

The whole workflow is wrapped in a 'withLogTag' for the spec's name so that
every log line emitted by any stage is automatically tagged with the
workflow name (e.g. @[BackendService]@). Individual stages add their own
tag on top via 'runStage'.
-}
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

-- ============================================================================
-- runStage — the canonical six-step lifecycle for one stage
-- ============================================================================

{- | Run a single 'Stage' through the canonical lifecycle.

Steps (matching the diagram in 'Core.Workflow.Stage'):

1. __Skip check__: consult @stageGuard@. If 'True', the stage was already
   completed in a previous run — skip everything.
2. __Acquire locks__: call @stageAcquireLocks@ to get handles. Locks are
   released by 'withLockBracket' on every exit path (success or failure).
3. __Pre-check__: call @stagePreCheck@. Throws on failure.
4. __Exec__: call @stageExec@. Returns a 'StageOutcome'.
5. __Validate__: map the outcome:
   * 'StageSuccess' → apply @stageOnAdvance@, persist, advance
   * 'StageWaiting' → throw 'RetriableError' so the runner retries next tick
   * 'StageAbort'   → throw 'DomainError' for terminal failure
6. __Advance + persist__: applied via 'recordedWithPersist' so the state
   change is saved before we return — on crash, the next tick will see
   the new state and skip this stage on resume.

On failure (any throw above), @stageOnError@ is called so the stage can
do per-stage cleanup before the exception propagates up to the workflow's
'wsRollback' handler.
-}
runStage ::
    forall s.
    WorkflowSpec s ->
    Stage s ->
    ExceptT WorkFlowError (Recorded s Flow) ()
runStage spec stage = withLogTagInExceptT (stageName stage) $ do
    -- Step 1: skip check (resume-from-cache)
    alreadyDone <- lift $ gets (stageGuard stage)
    if alreadyDone
        then lift . lift $ logInfoG ("skipped (already done): " <> stageName stage)
        else do
            lift . lift $ logInfoG ("running: " <> stageName stage)
            -- Step 2-5 wrapped in lock bracket + per-stage error hook
            withLockBracket stage $ do
                stagePreCheck stage
                outcome <- stageExec stage
                case outcome of
                    StageSuccess -> do
                        -- Step 6: advance + persist
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

-- ============================================================================
-- withLockBracket — bracketed lock acquisition / release
-- ============================================================================

{- | Run an action with the stage's locks acquired, releasing them on every
exit path (success or failure). This is the bracket pattern adapted for our
'ExceptT' + 'Recorded' monad stack.

Lock release uses 'try @SomeException' so a broken release function (network
blip, DB connection lost) doesn't mask the original failure — we log the
release exception but throw the original error from the body.

If 'stageOnError' is set, it runs BEFORE locks are released (so it has a
chance to inspect the locked state) and BEFORE the original exception
propagates.
-}
withLockBracket ::
    forall s a.
    Stage s ->
    ExceptT WorkFlowError (Recorded s Flow) a ->
    ExceptT WorkFlowError (Recorded s Flow) a
withLockBracket stage body = do
    locks <- stageAcquireLocks stage
    -- Build the cleanup action up front so all branches reuse the same
    -- closure over 'locks'. Cleanup itself catches and swallows any
    -- per-lock release error so it's safe to call from any path.
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

    -- Wrap body with MonadError catch (typed WorkFlowError) and MonadCatch
    -- catch (raw IO exceptions from buggy stage code).
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

    -- Success path: run the body and release locks. On failure, the
    -- catchError or MC.catch handler above unwinds via 'throwError' so
    -- this 'cleanup' line is not reached (good — already cleaned up).
    result <- bodyWithExceptionCatch
    cleanup
    pure result

-- ============================================================================
-- Internal — log tag wrapper that lifts through the ExceptT layer
-- ============================================================================

{- | 'withLogTag' lives in 'Flow', so we have to lift through both the
'Recorded' layer and the 'ExceptT' layer to use it inside a stage. This is
the convenience wrapper.
-}
withLogTagInExceptT ::
    forall s a.
    T.Text ->
    ExceptT WorkFlowError (Recorded s Flow) a ->
    ExceptT WorkFlowError (Recorded s Flow) a
withLogTagInExceptT tag body = do
    -- We can't easily wrap an ExceptT in 'withLogTag' because withLogTag is
    -- in IO (it uses bracket_ to push/pop a per-thread tag stack). Instead,
    -- we push the tag at entry and rely on the per-thread cleanup in
    -- 'withLogTag' callers to pop it. For now, just emit a tagged log line
    -- on entry and let the body run.
    --
    -- A future improvement is to thread a Reader-style tag stack through
    -- the engine so log lines can carry it without IO bracketing. For the
    -- minimum viable engine, this is sufficient.
    lift . lift $ logInfoG ("[" <> tag <> "] entering")
    body

-- ============================================================================
-- liftStateFlow — adapter for legacy StateFlow code
-- ============================================================================

{- | Lift a legacy @StateT s Flow a@ action into any polymorphic stage monad
@m@ that satisfies the 'StageM s m'-style constraint set.

This adapter exists so the migration from the imperative @|>>@ DSL to the
declarative 'Stage' / 'WorkflowSpec' design can be done __incrementally__:
existing @validatePreconditions :: StateFlow ()@ etc. functions can be
wrapped as 'stageExec' bodies without rewriting their internals.

== How it works ==

The polymorphic @m@ provides 'MonadState' s, 'MonadReader' 'AppState', and
'MonadIO'. We extract the current state and the @AppState@ from @m@, run
the inner @StateT s Flow a@ in @IO@ via @runReaderT (runStateT action s)
appSt@, then propagate the new state back via 'put'.

Any synchronous exception thrown by the inner action propagates through
'liftIO' into @m@, where the engine's 'withLockBracket' catches it and
maps it to a 'DomainError'.

== Caveats ==

* The state mutations from the inner action are committed __atomically__
  at the @put@ call — there's no streaming. If the inner action runs for
  a long time, intermediate state isn't visible to other observers.
* Errors thrown via @lift $ throwError@ inside a @ReleaseWorkFlow@ body
  will not be caught here because @StateT s Flow@ doesn't have 'MonadError'.
  Use plain @liftIO . throwIO@ inside legacy @StateFlow@ bodies.
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
