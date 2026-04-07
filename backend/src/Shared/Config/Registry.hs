{-# LANGUAGE OverloadedStrings #-}

{- | Generic config registry utilities.

This module is deliberately product-agnostic. It exposes:

  * 'findConfigEntryIn' — pure lookup over a list of 'ConfigEntry' values.
  * 'validateConfigValue' — type-level shape check for an incoming value.

It does NOT import any product module. Assembly of the full product-aware
list lives one layer up in "Products.ConfigCatalog" so this module stays
inside the 'Shared/' layer policy ("Shared must not import from Products"
per the layer rules in CONTEXT.md).

There are intentionally no global (cross-product) configs at this layer —
every config belongs to a specific product. If a future config genuinely
needs to be cross-cutting, add a 'globalConfigs' list back here.
-}
module Shared.Config.Registry (
    findConfigEntryIn,
    validateConfigValue,
)
where

import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import Shared.Config.Types
import Text.Read (readMaybe)

{- | Look up a config entry by key in a caller-supplied list. The list is
passed in (rather than being a module constant) so this module remains
product-agnostic — callers that need the full product-aware list should
import 'Products.ConfigCatalog.allConfigEntries' and pass that here.
-}
findConfigEntryIn :: [ConfigEntry] -> Text -> Maybe ConfigEntry
findConfigEntryIn entries key = find (\c -> ceKey c == key) entries

-- | Validate that a value matches the expected type of a config entry.
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
