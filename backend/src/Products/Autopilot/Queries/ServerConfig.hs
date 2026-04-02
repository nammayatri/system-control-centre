{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.Queries.ServerConfig (
    getEnabledServerConfigValue,
    listAllServerConfigs,
    upsertServerConfig,
    deleteServerConfig,
)
where

import Core.DB.Connection (runDB, withConn)
import Core.Environment (DBEnv)
import Data.Text (Text)
import Data.Time.Clock (getCurrentTime)
import Database.Beam
import Database.PostgreSQL.Simple (execute)
import GHC.Int (Int32)
import Shared.Types.Storage.Schema

{- | Fetch a server_config value by name where enabled is truthy (1).
Backward compatible: does not filter by product.
-}
getEnabledServerConfigValue :: DBEnv -> Text -> IO (Maybe Text)
getEnabledServerConfigValue db name = do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    sc <- all_ (serverConfigs nammaAPDb)
                    guard_ (scName sc ==. val_ name)
                    guard_ (scEnabled sc ==. val_ 1)
                    pure (scValue sc)
    pure $ case rows of
        (v : _) -> Just v
        _ -> Nothing

-- | List all server_config rows (now includes product column).
listAllServerConfigs :: DBEnv -> IO [(Int, Text, Text, Text, Int, Maybe Text)]
listAllServerConfigs db = do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (\sc -> (asc_ (scType sc), asc_ (scName sc))) $
                        all_ (serverConfigs nammaAPDb)
    pure $ map toTuple rows
  where
    toTuple :: ServerConfig -> (Int, Text, Text, Text, Int, Maybe Text)
    toTuple sc =
        ( fromIntegral (scId sc)
        , scType sc
        , scName sc
        , scValue sc
        , fromIntegral (scEnabled sc)
        , scProduct sc
        )

-- | Upsert a server_config row by name (now includes product column).
-- Uses INSERT ON CONFLICT to avoid TOCTOU race between SELECT and UPDATE/INSERT.
upsertServerConfig :: DBEnv -> Text -> Text -> Text -> Bool -> Maybe Text -> IO ()
upsertServerConfig db name typ value enabled product_ = do
    let enabledInt = if enabled then (1 :: Int32) else 0
    now <- getCurrentTime
    withConn db $ \conn -> do
        _ <- execute conn
            "INSERT INTO server_config (type, name, value, last_updated, enabled, product) \
            \VALUES (?, ?, ?, ?, ?, ?) \
            \ON CONFLICT (name) DO UPDATE SET \
            \type = EXCLUDED.type, value = EXCLUDED.value, \
            \last_updated = EXCLUDED.last_updated, enabled = EXCLUDED.enabled, \
            \product = EXCLUDED.product"
            (typ, name, value, now, enabledInt, product_)
        pure ()

-- | Delete a server_config row by ID.
deleteServerConfig :: DBEnv -> Int32 -> IO ()
deleteServerConfig db configId =
    runDB db $
        runDelete $
            delete
                (serverConfigs nammaAPDb)
                (\sc -> scId sc ==. val_ configId)
