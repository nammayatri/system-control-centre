{-# LANGUAGE OverloadedStrings #-}

module NammaAP.Products.Autopilot.Queries.ServerConfig
  ( getEnabledServerConfigValue,
    listAllServerConfigs,
    upsertServerConfig,
  )
where

import Data.Text (Text)
import Data.Time.Clock (getCurrentTime)
import Database.Beam
import GHC.Int (Int32)
import NammaAP.Core.DB.Connection (runDB)
import NammaAP.Core.Environment (DBEnv)
import NammaAP.Shared.Types.Storage.Schema

-- | Fetch a server_config value by name where enabled is truthy (1).
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

-- | List all server_config rows.
listAllServerConfigs :: DBEnv -> IO [(Int, Text, Text, Text, Int)]
listAllServerConfigs db = do
  rows <-
    runDB db $
      runSelectReturningList $
        select $
          orderBy_ (\sc -> (asc_ (scType sc), asc_ (scName sc))) $
            all_ (serverConfigs nammaAPDb)
  pure $ map toTuple rows
  where
    toTuple :: ServerConfig -> (Int, Text, Text, Text, Int)
    toTuple sc =
      ( fromIntegral (scId sc)
      , scType sc
      , scName sc
      , scValue sc
      , fromIntegral (scEnabled sc)
      )

-- | Upsert a server_config row by name.
upsertServerConfig :: DBEnv -> Text -> Text -> Text -> Bool -> IO ()
upsertServerConfig db name typ value enabled = do
  let enabledInt = if enabled then (1 :: Int32) else 0
  now <- getCurrentTime
  existing <-
    runDB db $
      runSelectReturningList $
        select $ do
          sc <- all_ (serverConfigs nammaAPDb)
          guard_ (scName sc ==. val_ name)
          pure (scId sc)
  case existing of
    (existingId : _) ->
      runDB db $
        runUpdate $
          update
            (serverConfigs nammaAPDb)
            ( \sc ->
                mconcat
                  [ scType sc <-. val_ typ,
                    scValue sc <-. val_ value,
                    scEnabled sc <-. val_ enabledInt,
                    scLastUpdated sc <-. val_ now
                  ]
            )
            (\sc -> scId sc ==. val_ existingId)
    [] ->
      runDB db $
        runInsert $
          insert (serverConfigs nammaAPDb) $
            insertExpressions
              [ ServerConfigT
                  { scId = default_,
                    scType = val_ typ,
                    scName = val_ name,
                    scValue = val_ value,
                    scLastUpdated = val_ now,
                    scEnabled = val_ enabledInt
                  }
              ]
