{-# LANGUAGE OverloadedStrings #-}

module NammaAP.Products.Autopilot.Queries.ServerConfig
  ( getEnabledServerConfigValue,
    listAllServerConfigs,
    upsertServerConfig,
  )
where

import Data.Text (Text)
import Database.PostgreSQL.Simple (Only (..), query, query_, execute)
import NammaAP.Core.DB.Connection (withConn)
import NammaAP.Core.Environment (DBEnv)

-- | Fetch a server_config value by name where enabled is truthy.
-- Works with both boolean (true/false) and int (1/0) enabled columns.
getEnabledServerConfigValue :: DBEnv -> Text -> IO (Maybe Text)
getEnabledServerConfigValue db name = do
  rows <-
    withConn db $ \conn ->
      query
        conn
        "select value from server_config where name = ? and enabled::text in ('1', 't', 'true') limit 1"
        (Only name)
  pure $ case rows of
    (Only v : _) -> Just v
    _ -> Nothing

-- | List all server_config rows.
listAllServerConfigs :: DBEnv -> IO [(Int, Text, Text, Text, Int)]
listAllServerConfigs db =
  withConn db $ \conn ->
    query_ conn "select id, type, name, value, enabled from server_config order by type, name"

-- | Upsert a server_config row by name.
upsertServerConfig :: DBEnv -> Text -> Text -> Text -> Bool -> IO ()
upsertServerConfig db name typ value enabled = do
  let enabledInt = if enabled then (1 :: Int) else 0
  withConn db $ \conn -> do
    existing <- query conn "select id from server_config where name = ? limit 1" (Only name) :: IO [Only Int]
    case existing of
      (Only existingId : _) -> do
        _ <- execute conn "update server_config set type = ?, value = ?, enabled = ?, last_updated = CURRENT_TIMESTAMP where id = ?" (typ, value, enabledInt, existingId)
        pure ()
      [] -> do
        _ <- execute conn "insert into server_config (type, name, value, enabled) values (?, ?, ?, ?)" (typ, name, value, enabledInt)
        pure ()
