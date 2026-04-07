{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}

{- | Application environment, the canonical 'Flow' monad, and the
'MonadFlow' constraint that every product reuses.

== The pattern (NammaYatri-style, simplified for one resource)

The whole codebase shares one constraint:

@
type MonadFlow m = (MonadIO m, MonadThrow m, MonadCatch m, MonadMask m, MonadReader AppState m)
@

Every query, every handler, every workflow step lives at type
@MonadFlow m => ... -> m a@ — never at concrete @Flow@. This means:

* Code is monomorphic at the call site (Servant resolves @m = Flow@)
  but polymorphic in source (tests can run the same code with a
  test runtime / mock 'AppState' / etc.)
* You write @throwM (NotFound \"...\")@ anywhere — the global handler
  in 'Core.Server' catches it and renders a typed JSON 4xx/5xx response.
* You write @bracket@, @finally@, @onException@ from
  "Control.Monad.Catch" anywhere — exception safety just works.
* You don't write @liftIO@ or @getDBEnv@ in handlers — call the
  query directly: @rows <- findReleaseTrackerById rid@.

== Why a constraint synonym instead of a typeclass?

A typeclass would force a method dictionary at every call site
(slower compile, no inlining), and we don't actually need
multi-instance dispatch — the only instance is 'Flow'. A constraint
synonym (@type MonadFlow m = (MonadIO m, ...)@) is the same shape
NammaYatri uses internally and gives us all the testability benefits
of polymorphism without any runtime cost.

== Crash safety

'Flow' inherits 'MonadThrow' / 'MonadCatch' / 'MonadMask' from
'ReaderT' so the full @Control.Monad.Catch@ vocabulary works:

@
withVsLock product owner action = do
    acquired <- tryAcquireVsLock product owner
    if not acquired
        then throwM (Conflict "VS is locked")
        else action \`finally\` releaseVsLockIfOwner product owner
@

The @finally@ runs even if @action@ throws an exception, an async
exception kills the thread, or the user aborts the request — same
guarantees you get from "Control.Exception.bracket".
-}
module Core.Environment (
    -- * The monad
    AppState (..),
    DBEnv (..),
    Flow,
    MonadFlow,
    runFlow,

    -- * Reader accessors (work in any MonadFlow)
    getConfig,
    getDBEnv,
    getLoggerEnv,

    -- * Convenience: lift an IO action that needs DBEnv / Config
    withDb,
    withConfig,
    inDB,
    inConfig,

    -- * Concurrency
    forkFlow,

    -- * Logging (work in any MonadFlow)
    logInfo,
    logError,
    logWarning,
    logDebug,
)
where

import Control.Concurrent (ThreadId, forkIO)
import Control.Monad.Catch (MonadCatch, MonadMask, MonadThrow)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (MonadReader, ReaderT, ask, asks, runReaderT)
import Core.Config (Config)
import Core.Logging (LogLevel (..), LoggerEnv, logOutput)
import Data.Pool (Pool)
import Data.Text (Text)
import Database.PostgreSQL.Simple (Connection)

-- ── Environment carriers ──────────────────────────────────────────

data DBEnv = DBEnv
    { dbPool :: Pool Connection
    }

data AppState = AppState
    { config :: Config
    , dbEnv :: DBEnv
    , loggerEnv :: LoggerEnv
    }

-- ── The monad ─────────────────────────────────────────────────────

{- | The canonical concrete monad. Inherits 'MonadIO', 'MonadThrow',
'MonadCatch', 'MonadMask', and 'MonadReader' 'AppState' from
'ReaderT', so you can throw\/catch typed errors and use 'bracket'\/'finally'
without any extra plumbing.
-}
type Flow = ReaderT AppState IO

{- | The capability constraint every query, handler, and workflow step
should declare instead of pinning to concrete 'Flow'.

@
findReleaseTrackerById :: MonadFlow m => Id ReleaseTracker -> m (Maybe ReleaseTracker)
findReleaseTrackerById rid = withDb $ \\db -> ...
@

Servant resolves @m = Flow@ at the API boundary. Tests can resolve
@m@ to a different stack with mock 'AppState'.
-}
type MonadFlow m =
    ( MonadIO m
    , MonadThrow m
    , MonadCatch m
    , MonadMask m
    , MonadReader AppState m
    )

runFlow :: AppState -> Flow a -> IO a
runFlow = flip runReaderT

-- ── Reader accessors ──────────────────────────────────────────────

getConfig :: (MonadFlow m) => m Config
getConfig = asks config

getDBEnv :: (MonadFlow m) => m DBEnv
getDBEnv = asks dbEnv

getLoggerEnv :: (MonadFlow m) => m LoggerEnv
getLoggerEnv = asks loggerEnv

-- ── Convenience: lift IO actions that need env ────────────────────

{- | Run an IO action that needs the 'DBEnv', without the
@db <- getDBEnv; liftIO $ action db@ boilerplate.

@
findReleaseTrackerById rid = withDb $ \\db -> runDB db $ ...
@
-}
withDb :: (MonadFlow m) => (DBEnv -> IO a) -> m a
withDb action = do
    db <- getDBEnv
    liftIO (action db)

-- | Run an IO action that needs the bootstrap 'Config'.
withConfig :: (MonadFlow m) => (Config -> IO a) -> m a
withConfig action = do
    cfg <- getConfig
    liftIO (action cfg)

-- ── Concurrency ───────────────────────────────────────────────────

{- | Fork a 'Flow' action in a fresh OS thread, propagating the current
'AppState' (DB pool, config, logger) into the new thread.

Use this instead of @forkIO@ inside any 'Flow' computation — it lets
the forked action call queries, log, throw typed errors, etc. without
needing to thread @AppState@ around manually.
-}
forkFlow :: Flow () -> Flow ThreadId
forkFlow action = do
    st <- ask
    liftIO $ forkIO (runFlow st action)

-- | Backwards-compatible alias for 'withDb'. Prefer 'withDb' in new code.
inDB :: (MonadFlow m) => (DBEnv -> IO a) -> m a
inDB = withDb

-- | Backwards-compatible alias for 'withConfig'. Prefer 'withConfig' in new code.
inConfig :: (MonadFlow m) => (Config -> IO a) -> m a
inConfig = withConfig

-- ── Logging (polymorphic in MonadFlow) ────────────────────────────

logInfo :: (MonadFlow m) => Text -> m ()
logInfo msg = getLoggerEnv >>= \env -> liftIO (logOutput env INFO msg)

logError :: (MonadFlow m) => Text -> m ()
logError msg = getLoggerEnv >>= \env -> liftIO (logOutput env ERROR msg)

logWarning :: (MonadFlow m) => Text -> m ()
logWarning msg = getLoggerEnv >>= \env -> liftIO (logOutput env WARNING msg)

logDebug :: (MonadFlow m) => Text -> m ()
logDebug msg = getLoggerEnv >>= \env -> liftIO (logOutput env DEBUG msg)
