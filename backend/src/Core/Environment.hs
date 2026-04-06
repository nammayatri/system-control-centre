-- | Application environment: state, DB pool, and the Flow monad.
module Core.Environment
  ( AppState (..),
    DBEnv (..),
    Flow,
    runFlow,
    getConfig,
    getDBEnv,
    inDB,
    inConfig,
  )
where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ReaderT, asks, runReaderT)
import Core.Config (Config)
import Data.Pool (Pool)
import Database.PostgreSQL.Simple (Connection)

data DBEnv = DBEnv
  { dbPool :: Pool Connection
  }

data AppState = AppState
  { config :: Config,
    dbEnv :: DBEnv
  }

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
