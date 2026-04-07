module Core.DB.Connection (
    mkDBEnv,
    runDB,
    withConn,
)
where

import Core.Config (Config (..))
import Core.Environment (DBEnv (..))
import qualified Data.ByteString.Char8 as BS
import Data.Pool (defaultPoolConfig, newPool, withResource)
import Database.Beam.Postgres (Pg, runBeamPostgres)
import Database.PostgreSQL.Simple (Connection, close, connectPostgreSQL)

mkDBEnv :: Config -> IO DBEnv
mkDBEnv cfg = do
    pool <- newPool $ defaultPoolConfig (connectPostgreSQL (mkConnString cfg)) close 30 20
    pure (DBEnv pool)

runDB :: DBEnv -> Pg a -> IO a
runDB db action = withConn db (\conn -> runBeamPostgres conn action)

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
