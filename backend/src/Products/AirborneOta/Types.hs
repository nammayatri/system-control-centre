{-# LANGUAGE OverloadedStrings #-}

{- | Request/response shapes for the Airborne OTA proxy. Mutation bodies are
typed; upstream responses stay 'Data.Aeson.Value' (drift-tolerant reads).
-}
module Products.AirborneOta.Types (
    AppRef (..),
    RampReq (..),
    ConcludeReq (..),
    CreateAppReq (..),
)
where

import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.Text (Text)

{- | An app identity parsed from the URL @:app@ segment, which is the composite
ref @\<org\>~\<app\>@ (the airborne @x-organisation@/@x-application@ pair).
There is no local mapping table: the app list is driven live off airborne.
-}
data AppRef = AppRef
    { arOrg :: Text
    , arApp :: Text
    }
    deriving (Show, Eq)

data RampReq = RampReq
    { rampTrafficPercentage :: Int
    , rampChangeReason :: Maybe Text
    , rampExpectedCurrent :: Maybe Int
    -- ^ Clobber guard: the traffic % the operator was actually shown. When
    -- present the handler re-reads upstream and refuses if it has moved.
    -- Optional so an older frontend bundle keeps working (no guard, same
    -- last-write-wins as before).
    }
    deriving (Show)

instance FromJSON RampReq where
    parseJSON = withObject "RampReq" $ \o ->
        RampReq
            <$> o .: "trafficPercentage"
            <*> o .:? "changeReason"
            <*> o .:? "expectedTrafficPercentage"

data ConcludeReq = ConcludeReq
    { concChosenVariant :: Text
    , concChangeReason :: Maybe Text
    }
    deriving (Show)

instance FromJSON ConcludeReq where
    parseJSON = withObject "ConcludeReq" $ \o ->
        ConcludeReq <$> o .: "chosenVariant" <*> o .:? "changeReason"

{- | Body for the org-scoped application-create proxy. The org is explicit
because there is no @\<org\>~\<app\>@ ref yet — the app is what we are creating.
-}
data CreateAppReq = CreateAppReq
    { caOrg :: Text
    , caApp :: Text
    }
    deriving (Show)

instance FromJSON CreateAppReq where
    parseJSON = withObject "CreateAppReq" $ \o ->
        CreateAppReq <$> o .: "org" <*> o .: "app"
