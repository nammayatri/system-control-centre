{-# LANGUAGE OverloadedStrings #-}

{- | Where the release bot's config comes from. First hit wins:

  1. __The deployment config rows__ (@deployment_config.release_bot_config@): the rules sit on the
     app group / service they describe, edited in the Deployment Config UI. Used whenever ANY row
     has rules.
  2. The @release_bot_config_json@ row in @server_config@ — one JSON blob for the whole bot.
  3. The JSON file (@SC_PROD_RELEASE_CONFIG@, default @./dhall-configs/prod-release-config.json@).

A source that is present but INVALID is an error, never a silent fall through to the next one:
falling through would run the bot with different rules than the operator just saved.
-}
module Products.Autopilot.ReleaseBot.ConfigSource (loadBotConfig) where

import Core.Environment (Flow)
import Data.Text (Text)
import qualified Data.Text as T
import Products.Autopilot.ProdRelease.Config
import Products.Autopilot.Queries.ProductService (listBotConfigRows)
import Products.Autopilot.ReleaseBot.RowConfig (buildFromRows)
import Shared.Config.Runtime (getConfigTextForProduct)

loadBotConfig :: Flow (Either Text ProdReleaseConfig)
loadBotConfig = do
    rows <- listBotConfigRows
    if not (null rows)
        then pure (buildFromRows rows)
        else do
            raw <- getConfigTextForProduct "release_bot_config_json" (Just "autopilot") ""
            if T.null (T.strip raw) then loadProdReleaseConfig else pure (parseProdReleaseConfig raw)
