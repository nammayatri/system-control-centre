{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.Queries.ServerConfig
  ( getEnabledServerConfigValue,
    getEnabledServerConfigValueForProduct,
    listAllServerConfigs,
    listServerConfigsByProduct,
    upsertServerConfig,
    deleteServerConfig,
  )
where

import Control.Applicative ((<|>))
import Core.DB.Connection (runDB, withConn)
import Core.Environment (DBEnv)
import Data.Text (Text)
import Data.Time.Clock (getCurrentTime)
import Database.Beam
import Database.PostgreSQL.Simple (execute)
import GHC.Int (Int32)
import Shared.Types.Storage.Schema

-- | Fetch a server_config value by name, with product-scoped lookup.
-- Priority: product-specific value > global (product IS NULL) value.
-- If no product param given, falls back to first enabled match (backward compat).
getEnabledServerConfigValue :: DBEnv -> Text -> IO (Maybe Text)
getEnabledServerConfigValue db name = getEnabledServerConfigValueForProduct db name Nothing

-- | Product-aware config lookup.
-- Queries all enabled rows matching the name, then picks:
-- 1. Product-specific match (if product param given and match exists)
-- 2. Global match (product IS NULL)
-- 3. Any match (first found)
getEnabledServerConfigValueForProduct :: DBEnv -> Text -> Maybe Text -> IO (Maybe Text)
getEnabledServerConfigValueForProduct db name mProduct = do
  rows <-
    runDB db $
      runSelectReturningList $
        select $ do
          sc <- all_ (serverConfigs nammaAPDb)
          guard_ (scName sc ==. val_ name)
          guard_ (scEnabled sc ==. val_ 1)
          pure (scProduct sc, scValue sc)
  -- Priority: product-specific > global (NULL) > any
  let productMatch = case mProduct of
        Just p -> lookup (Just p) rows
        Nothing -> Nothing
      globalMatch = lookup Nothing rows
      anyMatch = case rows of
        ((_, v) : _) -> Just v
        _ -> Nothing
  pure $ productMatch <|> globalMatch <|> anyMatch

-- | List server_config rows, optionally filtered by product.
-- If product given: returns product-specific + global (NULL) configs.
-- If no product: returns all configs.
listAllServerConfigs :: DBEnv -> IO [(Int, Text, Text, Text, Int, Maybe Text)]
listAllServerConfigs db = listServerConfigsByProduct db Nothing

listServerConfigsByProduct :: DBEnv -> Maybe Text -> IO [(Int, Text, Text, Text, Int, Maybe Text)]
listServerConfigsByProduct db mProduct = do
  rows <-
    runDB db $
      runSelectReturningList $
        select $
          orderBy_ (\sc -> (asc_ (scType sc), asc_ (scName sc))) $ do
            sc <- all_ (serverConfigs nammaAPDb)
            case mProduct of
              Just p -> guard_ (scProduct sc ==. val_ (Just p) ||. scProduct sc ==. val_ Nothing)
              Nothing -> pure ()
            pure sc
  pure $ map toTuple rows
  where
    toTuple :: ServerConfig -> (Int, Text, Text, Text, Int, Maybe Text)
    toTuple sc =
      ( fromIntegral (scId sc),
        scType sc,
        scName sc,
        scValue sc,
        fromIntegral (scEnabled sc),
        scProduct sc
      )

-- | Upsert a server_config row by name (now includes product column).
-- Uses INSERT ON CONFLICT to avoid TOCTOU race between SELECT and UPDATE/INSERT.
-- | Upsert a server_config row by (name, product).
-- Same name can exist for different products.
upsertServerConfig :: DBEnv -> Text -> Text -> Text -> Bool -> Maybe Text -> IO ()
upsertServerConfig db name typ value enabled product_ = do
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

-- | Delete a server_config row by ID.
deleteServerConfig :: DBEnv -> Int32 -> IO ()
deleteServerConfig db configId =
  runDB db $
    runDelete $
      delete
        (serverConfigs nammaAPDb)
        (\sc -> scId sc ==. val_ configId)
