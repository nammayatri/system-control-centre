{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Standard JSON response envelopes used by every product's HTTP surface.

Lives in 'Shared.API' because it is a wire-format utility — a library-shaped
type any product (autopilot, config-manager, future ones) uses unchanged.
It is not framework plumbing, so it does not belong in 'Core'; and it is
not autopilot-specific domain, so it does not belong in 'Products.Autopilot'.

== Two response shapes

* 'APISuccess' — preferred for action endpoints (POST/PUT/DELETE) that
  have no payload. Always serializes as @{\"result\": \"Success\"}@ so
  the frontend has a single shape to check.
* 'APIResponse' — legacy shape @{\"status\": \"...\", \"message\": \"...\"}@
  kept for backward compatibility with existing handlers. Prefer
  'APISuccess' in new code.
-}
module Shared.API.Response (
    APISuccess (..),
    APIResponse (..),
)
where

import Data.Aeson (FromJSON (..), ToJSON (..), defaultOptions, genericParseJSON, genericToJSON, object, withObject, (.:), (.=))
import Data.Text (Text)
import GHC.Generics (Generic)

-- | Canonical success envelope. Always serializes to @{\"result\": \"Success\"}@.
data APISuccess = Success
    deriving (Show, Eq, Generic)

instance ToJSON APISuccess where
    toJSON Success = object ["result" .= ("Success" :: Text)]

instance FromJSON APISuccess where
    parseJSON = withObject "APISuccess" $ \o -> do
        r <- o .: "result"
        case (r :: Text) of
            "Success" -> pure Success
            other -> fail ("Expected result=Success, got: " <> show other)

-- | Legacy response envelope. Use 'APISuccess' in new code.
data APIResponse = APIResponse
    { status :: Text
    , message :: Text
    }
    deriving (Show, Generic)

instance ToJSON APIResponse where
    toJSON = genericToJSON defaultOptions

instance FromJSON APIResponse where
    parseJSON = genericParseJSON defaultOptions
