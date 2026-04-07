{-# LANGUAGE OverloadedStrings #-}

{- | Global runtime config helpers shared across all products.
Product-specific configs live in each product's own RuntimeConfig module.
-}
module Shared.Config.Runtime (
    -- Flow versions (preferred for handlers)
    getConfigBool,
    getConfigBoolForProduct,
    getConfigInt,
    getConfigIntForProduct,
    getConfigDouble,
    getConfigDoubleForProduct,
    getConfigText,
    -- IO versions (kept for background callers)
    getConfigBool_io,
    getConfigInt_io,
    getConfigIntForProduct_io,
    getConfigDouble_io,
    getConfigDoubleForProduct_io,
    getConfigText_io,
)
where

import Core.Environment (DBEnv, MonadFlow, withDb)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Shared.Queries.ServerConfig (
    getEnabledServerConfigValueForProduct_io,
    getEnabledServerConfigValue_io,
 )
import Text.Read (readMaybe)

-- ── Helpers ────────────────────────────────────────────────────────

-- | Read a boolean config. Tries product-specific first, then global.
getConfigBool_io :: DBEnv -> Text -> Bool -> IO Bool
getConfigBool_io db name fallback = do
    v <- getEnabledServerConfigValueForProduct_io db name Nothing
    pure $ case v of
        Just t -> T.toLower (T.strip t) `elem` ["true", "1", "yes"]
        Nothing -> fallback

getConfigBool :: (MonadFlow m) => Text -> Bool -> m Bool
getConfigBool name fallback = withDb $ \db -> getConfigBool_io db name fallback

getConfigBoolForProduct :: (MonadFlow m) => Text -> Maybe Text -> Bool -> m Bool
getConfigBoolForProduct name mProduct fallback = withDb $ \db -> do
    v <- getEnabledServerConfigValueForProduct_io db name mProduct
    pure $ case v of
        Just t -> T.toLower (T.strip t) `elem` ["true", "1", "yes"]
        Nothing -> fallback

-- | Read an int config. Tries product-specific first, then global.
getConfigInt_io :: DBEnv -> Text -> Int -> IO Int
getConfigInt_io db name fallback = getConfigIntForProduct_io db name Nothing fallback

getConfigInt :: (MonadFlow m) => Text -> Int -> m Int
getConfigInt name fallback = withDb $ \db -> getConfigInt_io db name fallback

getConfigIntForProduct_io :: DBEnv -> Text -> Maybe Text -> Int -> IO Int
getConfigIntForProduct_io db name mProduct fallback = do
    v <- getEnabledServerConfigValueForProduct_io db name mProduct
    pure $ case v of
        Just t -> fromMaybe fallback (readMaybe (T.unpack (T.strip t)))
        Nothing -> fallback

getConfigIntForProduct :: (MonadFlow m) => Text -> Maybe Text -> Int -> m Int
getConfigIntForProduct name mProduct fallback = withDb $ \db -> getConfigIntForProduct_io db name mProduct fallback

-- | Read a double config. Tries product-specific first, then global.
getConfigDouble_io :: DBEnv -> Text -> Double -> IO Double
getConfigDouble_io db name fallback = getConfigDoubleForProduct_io db name Nothing fallback

getConfigDouble :: (MonadFlow m) => Text -> Double -> m Double
getConfigDouble name fallback = withDb $ \db -> getConfigDouble_io db name fallback

getConfigDoubleForProduct_io :: DBEnv -> Text -> Maybe Text -> Double -> IO Double
getConfigDoubleForProduct_io db name mProduct fallback = do
    v <- getEnabledServerConfigValueForProduct_io db name mProduct
    pure $ case v of
        Just t -> fromMaybe fallback (readMaybe (T.unpack (T.strip t)))
        Nothing -> fallback

getConfigDoubleForProduct :: (MonadFlow m) => Text -> Maybe Text -> Double -> m Double
getConfigDoubleForProduct name mProduct fallback = withDb $ \db -> getConfigDoubleForProduct_io db name mProduct fallback

getConfigText_io :: DBEnv -> Text -> Text -> IO Text
getConfigText_io db name fallback = do
    v <- getEnabledServerConfigValue_io db name
    pure $ fromMaybe fallback v

getConfigText :: (MonadFlow m) => Text -> Text -> m Text
getConfigText name fallback = withDb $ \db -> getConfigText_io db name fallback
