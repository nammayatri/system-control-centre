-- | Application environment: state, DB pool, and the Flow monad.
module Core.Environment (
    AppState (..),
    DBEnv (..),
    Flow,
    runFlow,
    getConfig,
    getDBEnv,
)
where

import Control.Monad.Reader (ReaderT, asks, runReaderT)
import Core.Config (Config)
import Data.Pool (Pool)
import Database.PostgreSQL.Simple (Connection)

data DBEnv = DBEnv
    { dbPool :: Pool Connection
    }

data AppState = AppState
    { config :: Config
    , dbEnv :: DBEnv
    }

type Flow = ReaderT AppState IO

runFlow :: AppState -> Flow a -> IO a
runFlow = flip runReaderT

getConfig :: Flow Config
getConfig = asks config

getDBEnv :: Flow DBEnv
getDBEnv = asks dbEnv
