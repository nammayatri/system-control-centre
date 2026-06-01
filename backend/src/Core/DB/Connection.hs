module Core.DB.Connection (
    mkDBEnv,
    runDB,
    runBeamLogged,
    withConn,
)
where

import Core.Config (Config (..))
import Core.Environment (DBEnv (..))
import Core.Logging (logDebugG)
import qualified Data.ByteString.Char8 as BS
import Data.Pool (defaultPoolConfig, newPool, withResource)
import Data.Text (pack)
import Database.Beam.Postgres (Pg, runBeamPostgresDebug)
import Database.PostgreSQL.Simple (Connection, close, connectPostgreSQL)

mkDBEnv :: Config -> IO DBEnv
mkDBEnv cfg = do
    pool <- newPool $ defaultPoolConfig (connectPostgreSQL (mkConnString cfg)) close 30 20
    pure (DBEnv pool)

runDB :: DBEnv -> Pg a -> IO a
runDB db action = withConn db (\conn -> runBeamLogged conn action)

{- | Run a Beam Pg action on a raw Connection, routing the formatted SQL
through 'logDebugG'. Emitted only at DEBUG log level (the callback is
always invoked but 'logDebugG' drops it otherwise).
-}
runBeamLogged :: Connection -> Pg a -> IO a
runBeamLogged conn = runBeamPostgresDebug logSql conn
  where
    logSql :: String -> IO ()
    logSql s = logDebugG ("[SQL] " <> pack s)

withConn :: DBEnv -> (Connection -> IO a) -> IO a
withConn DBEnv{..} = withResource dbPool

mkConnString :: Config -> BS.ByteString
mkConnString Config{..} =
    case databaseUrl of
        Just url -> BS.pack url
        Nothing ->
            BS.pack $
                "host="
                    <> postgresHost
                    <> " port="
                    <> show postgresPort
                    <> " user="
                    <> postgresUser
                    <> " password="
                    <> postgresPassword
                    <> " dbname="
                    <> postgresDatabase
