{-# LANGUAGE OverloadedStrings #-}

{- | Cross-product queries for the @server_config@ table.

This module is product-agnostic: every query that cares about scoping takes
a @Maybe Text@ product argument. Callers inside a specific product should
pass @Just "autopilot"@ (etc.); callers that legitimately want global-only
behaviour pass 'Nothing'.

History: these queries used to live at @Products.Autopilot.Queries.ServerConfig@
even though the table itself is cross-product, which broke the product
boundary for "Shared" consumers like 'Shared.Config.Runtime'. Task #30
moved them here.
-}
module Shared.Queries.ServerConfig (
    -- Flow versions (preferred for handlers)
    getEnabledServerConfigValue,
    getEnabledServerConfigValueForProduct,
    listAllServerConfigs,
    listServerConfigsByProduct,
    upsertServerConfig,
    deleteServerConfig,
    -- IO versions (kept for background callers / cross-module IO use)
    getEnabledServerConfigValue_io,
    getEnabledServerConfigValueForProduct_io,
    listAllServerConfigs_io,
    listServerConfigsByProduct_io,
    upsertServerConfig_io,
    deleteServerConfig_io,
)
where

import Control.Applicative ((<|>))
import Core.DB.Connection (runDB, withConn)
import Core.Environment (DBEnv, MonadFlow, withDb)
import Data.Text (Text)
import Data.Time.Clock (getCurrentTime)
import Database.Beam
import Database.PostgreSQL.Simple (execute)
import GHC.Int (Int32)
import Shared.Types.Storage.ServerConfig

{- | Fetch a server_config value by name, global lookup only (no product scoping).
Equivalent to 'getEnabledServerConfigValueForProduct' with @mProduct = Nothing@,
kept as a thin wrapper for call-sites that truly want global-only semantics.
-}
getEnabledServerConfigValue_io :: DBEnv -> Text -> IO (Maybe Text)
getEnabledServerConfigValue_io db name = getEnabledServerConfigValueForProduct_io db name Nothing

getEnabledServerConfigValue :: (MonadFlow m) => Text -> m (Maybe Text)
getEnabledServerConfigValue name = withDb $ \db -> getEnabledServerConfigValue_io db name

{- | Product-aware config lookup.
Queries all enabled rows matching the name, then picks:
  1. Product-specific match (if product param given and match exists)
  2. Global match (product IS NULL)
  3. Any match (first found) — backward-compat fallback
-}
getEnabledServerConfigValueForProduct_io :: DBEnv -> Text -> Maybe Text -> IO (Maybe Text)
getEnabledServerConfigValueForProduct_io db name mProduct = do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    sc <- all_ (serverConfigs serverConfigDb)
                    guard_ (scName sc ==. val_ name)
                    guard_ (scEnabled sc ==. val_ 1)
                    pure (scProduct sc, scValue sc)
    let productMatch = case mProduct of
            Just p -> lookup (Just p) rows
            Nothing -> Nothing
        globalMatch = lookup Nothing rows
        anyMatch = case rows of
            ((_, v) : _) -> Just v
            _ -> Nothing
    pure $ productMatch <|> globalMatch <|> anyMatch

getEnabledServerConfigValueForProduct :: (MonadFlow m) => Text -> Maybe Text -> m (Maybe Text)
getEnabledServerConfigValueForProduct name mProduct = withDb $ \db -> getEnabledServerConfigValueForProduct_io db name mProduct

{- | List server_config rows, optionally filtered by product.
If product given: returns product-specific + global (NULL) configs.
If no product: returns all configs.
-}
listAllServerConfigs_io :: DBEnv -> IO [(Int, Text, Text, Text, Int, Maybe Text)]
listAllServerConfigs_io db = listServerConfigsByProduct_io db Nothing

listAllServerConfigs :: (MonadFlow m) => m [(Int, Text, Text, Text, Int, Maybe Text)]
listAllServerConfigs = withDb $ \db -> listAllServerConfigs_io db

listServerConfigsByProduct_io :: DBEnv -> Maybe Text -> IO [(Int, Text, Text, Text, Int, Maybe Text)]
listServerConfigsByProduct_io db mProduct = do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (\sc -> (asc_ (scType sc), asc_ (scName sc))) $ do
                        sc <- all_ (serverConfigs serverConfigDb)
                        case mProduct of
                            Just p -> guard_ (scProduct sc ==. val_ (Just p) ||. scProduct sc ==. val_ Nothing)
                            Nothing -> pure ()
                        pure sc
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

listServerConfigsByProduct :: (MonadFlow m) => Maybe Text -> m [(Int, Text, Text, Text, Int, Maybe Text)]
listServerConfigsByProduct mProduct = withDb $ \db -> listServerConfigsByProduct_io db mProduct

{- | Upsert a server_config row by (name, product).
Same name can exist for different products. Uses INSERT ON CONFLICT to
avoid TOCTOU race between SELECT and UPDATE/INSERT.
-}
upsertServerConfig_io :: DBEnv -> Text -> Text -> Text -> Bool -> Maybe Text -> IO ()
upsertServerConfig_io db name typ value enabled product_ = do
    let enabledInt = if enabled then (1 :: Int32) else 0
    now <- getCurrentTime
    withConn db $ \conn -> do
        _ <-
            execute
                conn
                "INSERT INTO server_config (type, name, value, last_updated, enabled, product) \
                \VALUES (?, ?, ?, ?, ?, ?) \
                \ON CONFLICT (name, COALESCE(product, '')) DO UPDATE SET \
                \type = EXCLUDED.type, value = EXCLUDED.value, \
                \last_updated = EXCLUDED.last_updated, enabled = EXCLUDED.enabled"
                (typ, name, value, now, enabledInt, product_)
        pure ()

upsertServerConfig :: (MonadFlow m) => Text -> Text -> Text -> Bool -> Maybe Text -> m ()
upsertServerConfig name typ value enabled product_ = withDb $ \db -> upsertServerConfig_io db name typ value enabled product_

-- | Delete a server_config row by ID.
deleteServerConfig_io :: DBEnv -> Int32 -> IO ()
deleteServerConfig_io db configId =
    runDB db $
        runDelete $
            delete
                (serverConfigs serverConfigDb)
                (\sc -> scId sc ==. val_ configId)

deleteServerConfig :: (MonadFlow m) => Int32 -> m ()
deleteServerConfig configId = withDb $ \db -> deleteServerConfig_io db configId
