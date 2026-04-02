{-# LANGUAGE OverloadedStrings #-}

module Shared.JSON
  ( snakeCaseOptions,
    enumOptions,
    omitNothingOptions,
    flexibleOptions,
    responseOptions,
    stripPrefixOptions,
    camelToSnake,
    camelToScreamingSnake,
  )
where

import Data.Aeson (Options (..), SumEncoding (..), defaultOptions)
import Data.Char (isUpper, toLower)

-- | For types where field names should be snake_case in JSON
snakeCaseOptions :: Options
snakeCaseOptions =
  defaultOptions
    { fieldLabelModifier = camelToSnake,
      omitNothingFields = True
    }

-- | For enum types (constructors become SCREAMING_SNAKE_CASE)
enumOptions :: Options
enumOptions =
  defaultOptions
    { constructorTagModifier = camelToScreamingSnake,
      sumEncoding = UntaggedValue
    }

-- | Omit Nothing fields (keep camelCase field names)
omitNothingOptions :: Options
omitNothingOptions =
  defaultOptions
    { omitNothingFields = True
    }

-- | Flexible options for request types: accept both camelCase and snake_case.
-- Uses default field names (camelCase) with omitNothingFields.
flexibleOptions :: Options
flexibleOptions =
  defaultOptions
    { omitNothingFields = True
    }

-- | Response options: camelCase output with omitNothingFields.
-- For response types we control entirely.
responseOptions :: Options
responseOptions =
  defaultOptions
    { omitNothingFields = True
    }

-- | Options that strip a prefix from field labels and lowercase the first char.
-- Usage: stripPrefixOptions 2 strips "pc" from "pcProduct" -> "product"
--        stripPrefixOptions 3 strips "vet" from "vetProduct" -> "product"
stripPrefixOptions :: Int -> Options
stripPrefixOptions n =
  defaultOptions
    { fieldLabelModifier = \s ->
        let stripped = drop n s
         in case stripped of
              (c : cs) -> toLower c : cs
              [] -> s,
      omitNothingFields = True
    }

-- | camelCase to snake_case
camelToSnake :: String -> String
camelToSnake [] = []
camelToSnake (x : xs) = toLower x : go xs
  where
    go [] = []
    go (c : cs)
      | isUpper c = '_' : toLower c : go cs
      | otherwise = c : go cs

-- | camelCase to SCREAMING_SNAKE_CASE
camelToScreamingSnake :: String -> String
camelToScreamingSnake = map (\c -> if c == '_' then '_' else toUpper' c) . camelToSnake
  where
    toUpper' c
      | c >= 'a' && c <= 'z' = toEnum (fromEnum c - 32)
      | otherwise = c
