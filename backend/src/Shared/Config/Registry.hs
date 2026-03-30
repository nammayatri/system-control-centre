{-# LANGUAGE OverloadedStrings #-}

module Shared.Config.Registry (
    allConfigEntries,
    globalConfigs,
    findConfigEntry,
    validateConfigValue,
)
where

import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import Products.Autopilot.Config (autopilotConfigs)
import Shared.Config.Types
import Text.Read (readMaybe)

-- | Global configs (product = Nothing)
globalConfigs :: [ConfigEntry]
globalConfigs =
    [ ConfigEntry
        "mailing_enabled"
        (BoolConfig False)
        NotificationGroup
        "Enable email notifications"
        Nothing
    , ConfigEntry
        "slack_enabled"
        (BoolConfig False)
        NotificationGroup
        "Enable Slack notifications for release events"
        Nothing
    ]

-- | Collect from all products
allConfigEntries :: [ConfigEntry]
allConfigEntries = globalConfigs ++ autopilotConfigs

-- ++ frontendConfigs  <- add new product configs here

-- | Look up a config entry by key
findConfigEntry :: Text -> Maybe ConfigEntry
findConfigEntry key = find (\c -> ceKey c == key) allConfigEntries

-- | Validate that a value matches the expected type of a config entry
validateConfigValue :: ConfigEntry -> Text -> Either Text Text
validateConfigValue entry val = case ceType entry of
    BoolConfig _ ->
        if T.toLower val `elem` ["true", "false", "1", "0", "yes", "no"]
            then Right val
            else Left "Must be true/false"
    IntConfig _ -> case readMaybe (T.unpack val) :: Maybe Int of
        Just _ -> Right val
        Nothing -> Left "Must be an integer"
    DoubleConfig _ -> case readMaybe (T.unpack val) :: Maybe Double of
        Just _ -> Right val
        Nothing -> Left "Must be a number"
    TextConfig _ -> Right val
    JsonConfig _ -> Right val -- could add JSON parse validation
