{-# LANGUAGE OverloadedStrings #-}

{- | Global runtime config helpers shared across all products.
Product-specific configs live in each product's own RuntimeConfig module.
-}
module Shared.Config.Runtime (
    getConfigBool,
    getConfigBoolForProduct,
    getConfigInt,
    getConfigIntForProduct,
    getConfigDouble,
    getConfigDoubleForProduct,
    getConfigText,
    getConfigTextForProduct,
)
where

import Core.Environment (MonadFlow, withDb)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Shared.Queries.ServerConfig (getEnabledServerConfigValueForProduct_io)
import Text.Read (readMaybe)

-- ── Helpers ────────────────────────────────────────────────────────

-- | Read a boolean config (global only).
getConfigBool :: (MonadFlow m) => Text -> Bool -> m Bool
getConfigBool name fallback = getConfigBoolForProduct name Nothing fallback

getConfigBoolForProduct :: (MonadFlow m) => Text -> Maybe Text -> Bool -> m Bool
getConfigBoolForProduct name mProduct fallback = withDb $ \db -> do
    v <- getEnabledServerConfigValueForProduct_io db name mProduct
    pure $ case v of
        Just t -> T.toLower (T.strip t) `elem` ["true", "1", "yes"]
        Nothing -> fallback

-- | Read an int config (global only).
getConfigInt :: (MonadFlow m) => Text -> Int -> m Int
getConfigInt name fallback = getConfigIntForProduct name Nothing fallback

getConfigIntForProduct :: (MonadFlow m) => Text -> Maybe Text -> Int -> m Int
getConfigIntForProduct name mProduct fallback = withDb $ \db -> do
    v <- getEnabledServerConfigValueForProduct_io db name mProduct
    pure $ case v of
        Just t -> fromMaybe fallback (readMaybe (T.unpack (T.strip t)))
        Nothing -> fallback

-- | Read a double config (global only).
getConfigDouble :: (MonadFlow m) => Text -> Double -> m Double
getConfigDouble name fallback = getConfigDoubleForProduct name Nothing fallback

getConfigDoubleForProduct :: (MonadFlow m) => Text -> Maybe Text -> Double -> m Double
getConfigDoubleForProduct name mProduct fallback = withDb $ \db -> do
    v <- getEnabledServerConfigValueForProduct_io db name mProduct
    pure $ case v of
        Just t -> fromMaybe fallback (readMaybe (T.unpack (T.strip t)))
        Nothing -> fallback

getConfigText :: (MonadFlow m) => Text -> Text -> m Text
getConfigText name fallback = getConfigTextForProduct name Nothing fallback

getConfigTextForProduct :: (MonadFlow m) => Text -> Maybe Text -> Text -> m Text
getConfigTextForProduct name mProduct fallback = withDb $ \db -> do
    v <- getEnabledServerConfigValueForProduct_io db name mProduct
    pure $ fromMaybe fallback v
