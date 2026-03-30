{-# LANGUAGE OverloadedStrings #-}

-- | Global runtime config helpers shared across all products.
-- Product-specific configs live in each product's own RuntimeConfig module.
module Shared.Config.Runtime
    ( -- Helpers (reusable by product RuntimeConfig modules)
      getConfigBool
    , getConfigInt
    , getConfigDouble
    , getConfigText
      -- Global feature flags
    , isSlackEnabled
    , isMailingEnabled
    )
where

import Core.Environment (DBEnv)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Shared.Queries.ServerConfig (getEnabledServerConfigValue)
import Text.Read (readMaybe)

-- ── Helpers ────────────────────────────────────────────────────────

getConfigBool :: DBEnv -> Text -> Bool -> IO Bool
getConfigBool db name fallback = do
    v <- getEnabledServerConfigValue db name
    pure $ case v of
        Just t -> T.toLower (T.strip t) `elem` ["true", "1", "yes"]
        Nothing -> fallback

getConfigInt :: DBEnv -> Text -> Int -> IO Int
getConfigInt db name fallback = do
    v <- getEnabledServerConfigValue db name
    pure $ case v of
        Just t -> fromMaybe fallback (readMaybe (T.unpack (T.strip t)))
        Nothing -> fallback

getConfigDouble :: DBEnv -> Text -> Double -> IO Double
getConfigDouble db name fallback = do
    v <- getEnabledServerConfigValue db name
    pure $ case v of
        Just t -> fromMaybe fallback (readMaybe (T.unpack (T.strip t)))
        Nothing -> fallback

getConfigText :: DBEnv -> Text -> Text -> IO Text
getConfigText db name fallback = do
    v <- getEnabledServerConfigValue db name
    pure $ fromMaybe fallback v

-- ── Global feature flags ──────────────────────────────────────────

isSlackEnabled :: DBEnv -> IO Bool
isSlackEnabled db = getConfigBool db "slack_enabled" False

isMailingEnabled :: DBEnv -> IO Bool
isMailingEnabled db = getConfigBool db "mailing_enabled" False
