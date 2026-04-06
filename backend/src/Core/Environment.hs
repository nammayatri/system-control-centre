-- | Application environment: state, DB pool, and the Flow monad.
--
-- Backward-compatible layer. Existing handlers use 'Flow' (= ReaderT AppState IO).
-- New handlers should use 'AppM' from 'Core.AppM' with typeclasses.
-- Both coexist — 'toAppEnv' converts between them.
module Core.Environment
  ( AppState (..),
    DBEnv (..),
    Flow,
    runFlow,
    getConfig,
    getDBEnv,
    getLoggerEnv,
    inDB,
    inConfig,
    -- Flow-level log helpers (backward compat)
    logInfo,
    logError,
    logWarning,
    logDebug,
    -- Bridge to new monad
    toAppEnv,
  )
where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ReaderT, asks, runReaderT)
import Core.AppM (AppEnv (..), mkBackgroundEnv)
import Core.Config (Config)
import Core.Logging (LogLevel (..), LoggerEnv, logOutput)
import Data.Pool (Pool)
import Data.Text (Text)
import Database.PostgreSQL.Simple (Connection)

data DBEnv = DBEnv
  { dbPool :: Pool Connection
  }

data AppState = AppState
  { config :: Config,
    dbEnv :: DBEnv,
    loggerEnv :: LoggerEnv
  }

-- | Convert old AppState to new AppEnv (for background/non-request contexts).
toAppEnv :: AppState -> AppEnv
toAppEnv st =
  mkBackgroundEnv
    (config st)
    (dbPool (dbEnv st))
    (loggerEnv st)

type Flow = ReaderT AppState IO

runFlow :: AppState -> Flow a -> IO a
runFlow = flip runReaderT

getConfig :: Flow Config
getConfig = asks config

getDBEnv :: Flow DBEnv
getDBEnv = asks dbEnv

-- | Run an IO action that needs the DB environment, bundling the common
-- @db <- getDBEnv; liftIO $ action db@ pattern into a single call.
--
-- Preferred in new handler code and in simple one-liner DB lookups. Leave
-- the expanded @getDBEnv + liftIO@ form when a handler needs the 'DBEnv'
-- more than once or mixes DB calls with other 'Flow' effects — readability
-- beats compactness in those cases.
inDB :: (DBEnv -> IO a) -> Flow a
inDB action = do
  db <- getDBEnv
  liftIO (action db)

-- | Run an IO action that needs the bootstrap 'Config'. Same rationale as
-- 'inDB': bundles @cfg <- getConfig; liftIO $ action cfg@ into one call.
inConfig :: (Config -> IO a) -> Flow a
inConfig action = do
  cfg <- getConfig
  liftIO (action cfg)

getLoggerEnv :: Flow LoggerEnv
getLoggerEnv = asks loggerEnv

-- ── Flow-level log helpers ────────────────────────────────────────

logInfo :: Text -> Flow ()
logInfo msg = do
  env <- getLoggerEnv
  liftIO $ logOutput env INFO msg

logError :: Text -> Flow ()
logError msg = do
  env <- getLoggerEnv
  liftIO $ logOutput env ERROR msg

logWarning :: Text -> Flow ()
logWarning msg = do
  env <- getLoggerEnv
  liftIO $ logOutput env WARNING msg

logDebug :: Text -> Flow ()
logDebug msg = do
  env <- getLoggerEnv
  liftIO $ logOutput env DEBUG msg
