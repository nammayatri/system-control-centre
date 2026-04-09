{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeApplications #-}

{- | 'AppState', the 'Flow' monad, and the 'MonadFlow' constraint
reused across the codebase.

@MonadFlow@ is a constraint synonym (not a typeclass) aggregating
MonadIO / MonadThrow / MonadCatch / MonadMask / MonadReader AppState.
Queries, handlers, and workflow steps declare @MonadFlow m@; Servant
resolves @m = Flow@ at the API boundary, tests can resolve to a
different stack. Inheriting MonadMask means @bracket@/@finally@ from
"Control.Monad.Catch" work everywhere, including through 'forkFlow'.
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
import qualified Control.Exception as E
import Control.Monad.Catch (MonadCatch, MonadMask, MonadThrow)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (MonadReader, ReaderT, ask, asks, runReaderT)
import Core.Config (Config)
import Core.Logging (LogLevel (..), LoggerEnv, logErrorIO, logOutput)
import Data.Pool (Pool)
import Data.Text (Text)
import qualified Data.Text as T
import Database.PostgreSQL.Simple (Connection)

data DBEnv = DBEnv
    { dbPool :: Pool Connection
    }

data AppState = AppState
    { config :: Config
    , dbEnv :: DBEnv
    , loggerEnv :: LoggerEnv
    }

-- | The canonical concrete monad.
type Flow = ReaderT AppState IO

-- | Declared instead of concrete 'Flow' for testability.
type MonadFlow m =
    ( MonadIO m
    , MonadThrow m
    , MonadCatch m
    , MonadMask m
    , MonadReader AppState m
    )

runFlow :: AppState -> Flow a -> IO a
runFlow = flip runReaderT

getConfig :: (MonadFlow m) => m Config
getConfig = asks config

getDBEnv :: (MonadFlow m) => m DBEnv
getDBEnv = asks dbEnv

getLoggerEnv :: (MonadFlow m) => m LoggerEnv
getLoggerEnv = asks loggerEnv

-- | Run an IO action that needs the 'DBEnv'.
withDb :: (MonadFlow m) => (DBEnv -> IO a) -> m a
withDb action = do
    db <- getDBEnv
    liftIO (action db)

-- | Run an IO action that needs the bootstrap 'Config'.
withConfig :: (MonadFlow m) => (Config -> IO a) -> m a
withConfig action = do
    cfg <- getConfig
    liftIO (action cfg)

{- | Fork a 'Flow' action, propagating the current 'AppState' to the
child. Child crashes are caught and logged (see 'forkIO' wrapping) so
they don't take the parent thread down silently.
-}
forkFlow :: Flow () -> Flow ThreadId
forkFlow action = do
    st <- ask
    liftIO $ forkIO $ do
        result <- E.try @E.SomeException (runFlow st action)
        case result of
            Left e ->
                logErrorIO (loggerEnv st) $
                    "[forkFlow] Worker thread died with exception: "
                        <> T.pack (show e)
            Right _ -> pure ()

logInfo :: (MonadFlow m) => Text -> m ()
logInfo msg = getLoggerEnv >>= \env -> liftIO (logOutput env INFO msg)

logError :: (MonadFlow m) => Text -> m ()
logError msg = getLoggerEnv >>= \env -> liftIO (logOutput env ERROR msg)

logWarning :: (MonadFlow m) => Text -> m ()
logWarning msg = getLoggerEnv >>= \env -> liftIO (logOutput env WARNING msg)

logDebug :: (MonadFlow m) => Text -> m ()
logDebug msg = getLoggerEnv >>= \env -> liftIO (logOutput env DEBUG msg)
