{-# LANGUAGE OverloadedStrings #-}

module Shared.JSON
    ( snakeCaseOptions
    , enumOptions
    , omitNothingOptions
    ) where

import Data.Aeson (Options(..), defaultOptions, SumEncoding(..))
import Data.Char (toLower, isUpper)

-- For types where field names should be snake_case in JSON
snakeCaseOptions :: Options
snakeCaseOptions = defaultOptions
    { fieldLabelModifier = camelToSnake
    , omitNothingFields = True
    }

-- For enum types (constructors become SCREAMING_SNAKE_CASE)
enumOptions :: Options
enumOptions = defaultOptions
    { constructorTagModifier = camelToScreamingSnake
    , sumEncoding = UntaggedValue
    }

-- Omit Nothing fields
omitNothingOptions :: Options
omitNothingOptions = defaultOptions
    { omitNothingFields = True
    }

-- camelCase to snake_case
camelToSnake :: String -> String
camelToSnake [] = []
camelToSnake (x:xs) = toLower x : go xs
  where
    go [] = []
    go (c:cs)
        | isUpper c = '_' : toLower c : go cs
        | otherwise = c : go cs

-- camelCase to SCREAMING_SNAKE_CASE
camelToScreamingSnake :: String -> String
camelToScreamingSnake = map (\c -> if c == '_' then '_' else toUpper' c) . camelToSnake
  where
    toUpper' c | c >= 'a' && c <= 'z' = toEnum (fromEnum c - 32)
               | otherwise = c
