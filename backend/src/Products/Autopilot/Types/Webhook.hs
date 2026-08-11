{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Outbound release webhooks: domain types, the placeholder registry, and the
template renderer shared by the dispatcher and the config API.

A webhook is a whole HTTP request the operator authors, not just a URL — and
every part of it (URL, query params, headers, body) is a @{{NEW_VERSION}}@-style
template substituted at fire time.

Adding a placeholder is two lines: an entry in 'availablePlaceholders' and a
pair in 'Products.Autopilot.Webhooks.releasePlaceholderEnv'.
-}
module Products.Autopilot.Types.Webhook (
    -- * Method
    WebhookMethod (..),
    webhookMethodToText,
    textToWebhookMethod,

    -- * Trigger
    WebhookTrigger (..),
    webhookTriggerToText,

    -- * Domain
    WebhookKV (..),
    ReleaseWebhook (..),
    triggersOn,

    -- * API payloads
    UpsertWebhookReq (..),
    WebhookTestResult (..),

    -- * Placeholders
    PlaceholderDef (..),
    PlaceholderEnv,
    availablePlaceholders,
    samplePlaceholderEnv,
    renderTemplate,
)
where

import Data.Aeson (
    FromJSON (..),
    Options (..),
    ToJSON (..),
    defaultOptions,
    genericParseJSON,
    genericToJSON,
    object,
    withObject,
    withText,
    (.!=),
    (.:),
    (.:?),
    (.=),
 )
import Data.Char (toLower)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import GHC.Int (Int32)

-- | Drop an @n@-character field prefix and lower-case what is left, e.g.
-- @whQueryParams@ -> @queryParams@. The prefixes keep selectors unambiguous
-- across the records here without leaking into the wire format.
strippedOpts :: Int -> Options
strippedOpts n =
    defaultOptions
        { fieldLabelModifier = lowerFirst . drop n
        , omitNothingFields = True
        }
  where
    lowerFirst [] = []
    lowerFirst (c : cs) = toLower c : cs

-- | HTTP verbs an operator may configure. Mirrors 'Core.Http.Client.Method'.
data WebhookMethod = WH_GET | WH_POST | WH_PUT | WH_PATCH | WH_DELETE
    deriving (Eq, Show, Read, Generic, Enum, Bounded)

webhookMethodToText :: WebhookMethod -> Text
webhookMethodToText WH_GET = "GET"
webhookMethodToText WH_POST = "POST"
webhookMethodToText WH_PUT = "PUT"
webhookMethodToText WH_PATCH = "PATCH"
webhookMethodToText WH_DELETE = "DELETE"

textToWebhookMethod :: Text -> Maybe WebhookMethod
textToWebhookMethod t = case T.toUpper (T.strip t) of
    "GET" -> Just WH_GET
    "POST" -> Just WH_POST
    "PUT" -> Just WH_PUT
    "PATCH" -> Just WH_PATCH
    "DELETE" -> Just WH_DELETE
    _ -> Nothing

instance ToJSON WebhookMethod where
    toJSON = toJSON . webhookMethodToText

instance FromJSON WebhookMethod where
    parseJSON = withText "WebhookMethod" $ \t ->
        case textToWebhookMethod t of
            Just m -> pure m
            Nothing -> fail ("Unsupported webhook method: " <> T.unpack t)

{- | Which terminal outcome fired the dispatch. 'OnSuccess' is COMPLETED;
'OnFailure' covers the whole ABORTED family (system abort, user abort,
decision-engine abort).
-}
data WebhookTrigger = OnSuccess | OnFailure
    deriving (Eq, Show, Generic, Enum, Bounded)

webhookTriggerToText :: WebhookTrigger -> Text
webhookTriggerToText OnSuccess = "SUCCESS"
webhookTriggerToText OnFailure = "FAILURE"

instance ToJSON WebhookTrigger where
    toJSON = toJSON . webhookTriggerToText

-- | One header or query-param entry. Both sides are templated.
data WebhookKV = WebhookKV
    { kvKey :: Text
    , kvValue :: Text
    }
    deriving (Eq, Show, Generic)

instance ToJSON WebhookKV where
    toJSON (WebhookKV k v) = object ["key" .= k, "value" .= v]

instance FromJSON WebhookKV where
    parseJSON = withObject "WebhookKV" $ \o ->
        WebhookKV <$> o .: "key" <*> o .:? "value" .!= ""

{- | A configured webhook. An empty @whServices@ means the hook applies to
every service in @whAppGroup@; otherwise only to the ones listed.
-}
data ReleaseWebhook = ReleaseWebhook
    { whId :: Int32
    , whAppGroup :: Text
    , whServices :: [Text]
    , whName :: Text
    , whEnabled :: Bool
    , whOnSuccess :: Bool
    , whOnFailure :: Bool
    , whMethod :: WebhookMethod
    , whUrl :: Text
    , whHeaders :: [WebhookKV]
    , whQueryParams :: [WebhookKV]
    , whBody :: Maybe Text
    , whTimeoutSeconds :: Maybe Int32
    , whRetries :: Maybe Int32
    }
    deriving (Eq, Show, Generic)

instance ToJSON ReleaseWebhook where
    toJSON = genericToJSON (strippedOpts 2)

-- | Disabled hooks never fire, whatever they opted into.
triggersOn :: WebhookTrigger -> ReleaseWebhook -> Bool
triggersOn trigger wh
    | not (whEnabled wh) = False
    | otherwise = case trigger of
        OnSuccess -> whOnSuccess wh
        OnFailure -> whOnFailure wh

-- | @uwId@ is ignored on create. @uwServices@ absent or empty means "every
-- service in the group".
data UpsertWebhookReq = UpsertWebhookReq
    { uwId :: Maybe Int32
    , uwAppGroup :: Text
    , uwServices :: Maybe [Text]
    , uwName :: Text
    , uwEnabled :: Maybe Bool
    , uwOnSuccess :: Maybe Bool
    , uwOnFailure :: Maybe Bool
    , uwMethod :: Text
    , uwUrl :: Text
    , uwHeaders :: Maybe [WebhookKV]
    , uwQueryParams :: Maybe [WebhookKV]
    , uwBody :: Maybe Text
    , uwTimeoutSeconds :: Maybe Int32
    , uwRetries :: Maybe Int32
    }
    deriving (Show, Generic)

instance FromJSON UpsertWebhookReq where
    parseJSON = genericParseJSON (strippedOpts 2)

instance ToJSON UpsertWebhookReq where
    toJSON = genericToJSON (strippedOpts 2)

-- | The request as actually resolved — so an operator can see what the
-- placeholders became — plus the outcome.
data WebhookTestResult = WebhookTestResult
    { wtrOk :: Bool
    , wtrRequestMethod :: Text
    , wtrRequestUrl :: Text
    , wtrResponseStatus :: Maybe Int
    , wtrResponseBody :: Maybe Text
    , wtrError :: Maybe Text
    }
    deriving (Show, Generic)

instance ToJSON WebhookTestResult where
    toJSON = genericToJSON (strippedOpts 3)

-- Placeholders

data PlaceholderDef = PlaceholderDef
    { pdName :: Text
    , pdToken :: Text
    , pdDescription :: Text
    , pdSample :: Text
    }
    deriving (Show, Generic)

instance ToJSON PlaceholderDef where
    toJSON = genericToJSON (strippedOpts 2)

-- | Resolved @(NAME, value)@ pairs. Names are upper-case.
type PlaceholderEnv = [(Text, Text)]

{- | The placeholders an operator may use anywhere in a webhook. Keep this in
sync with 'Products.Autopilot.Webhooks.releasePlaceholderEnv' — this list is
what the UI documents, that function is what actually resolves.
-}
availablePlaceholders :: [PlaceholderDef]
availablePlaceholders =
    [ PlaceholderDef
        { pdName = "NEW_VERSION"
        , pdToken = "{{NEW_VERSION}}"
        , pdDescription = "Version this release rolled out."
        , pdSample = "v1.4.0"
        }
    , PlaceholderDef
        { pdName = "OLD_VERSION"
        , pdToken = "{{OLD_VERSION}}"
        , pdDescription = "Version that was live before this release."
        , pdSample = "v1.3.9"
        }
    ]

samplePlaceholderEnv :: PlaceholderEnv
samplePlaceholderEnv = [(pdName p, "TEST_" <> pdName p) | p <- availablePlaceholders]

{- | Substitute every @{{NAME}}@ occurrence in @template@. Inner whitespace is
tolerated and the name is case-insensitive. An unknown token is left verbatim
rather than blanked, so a typo shows up in the delivered request instead of
silently vanishing.
-}
renderTemplate :: PlaceholderEnv -> Text -> Text
renderTemplate env template
    | T.null template = template
    | otherwise = renderCurly [(T.toUpper k, v) | (k, v) <- env] template

renderCurly :: PlaceholderEnv -> Text -> Text
renderCurly env = go
  where
    go t =
        let (before, rest) = T.breakOn "{{" t
         in if T.null rest
                then before
                else
                    let afterOpen = T.drop 2 rest
                        (inner, closeRest) = T.breakOn "}}" afterOpen
                     in if T.null closeRest
                            then before <> rest -- unterminated "{{": leave verbatim
                            else
                                let replacement =
                                        maybe ("{{" <> inner <> "}}") Prelude.id $
                                            lookup (T.toUpper (T.strip inner)) env
                                 in before <> replacement <> go (T.drop 2 closeRest)
