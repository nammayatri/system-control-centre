{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Generic @{status, message}@ JSON response envelope used by every product's
-- HTTP surface.
--
-- Lives in 'Shared.API' because it is a wire-format utility — a library-shaped
-- type any product (autopilot, config-manager, future ones) uses unchanged.
-- It is not framework plumbing, so it does not belong in 'Core'; and it is not
-- autopilot-specific domain, so it does not belong in 'Products.Autopilot'.
module Shared.API.Response
  ( APIResponse (..),
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), defaultOptions, genericParseJSON, genericToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

data APIResponse = APIResponse
  { status :: Text,
    message :: Text
  }
  deriving (Show, Generic)

instance ToJSON APIResponse where
  toJSON = genericToJSON defaultOptions

instance FromJSON APIResponse where
  parseJSON = genericParseJSON defaultOptions
