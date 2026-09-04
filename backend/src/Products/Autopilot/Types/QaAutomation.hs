{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

{- | QA automation: trigger the private ny-qa-automation regression suites
(NY/MSIL/YS) against a running test dashboard, either automatically when a
release completes or manually from the release page — domain types + the
JSON shape sent to/read from the dashboard's webhook.

Mirrors "Products.Autopilot.Types.Webhook" in spirit (a config row per app
group, dispatch elsewhere in "Products.Autopilot.QaAutomation").
-}
module Products.Autopilot.Types.QaAutomation (
    -- * Flows
    QaFlow (..),

    -- * Config
    QaAutomationConfig (..),

    -- * Runs
    QaAutomationRun (..),

    -- * API payloads
    TriggerQaRunResponse (..),
)
where

import Data.Aeson (
    FromJSON (..),
    Options (..),
    ToJSON (..),
    Value,
    defaultOptions,
    genericParseJSON,
    genericToJSON,
 )
import Data.Char (toLower)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import GHC.Generics (Generic)
import GHC.Int (Int32)

-- | Drop an @n@-character field prefix and lower-case what is left — same
-- convention as "Products.Autopilot.Types.Webhook".strippedOpts.
strippedOpts :: Int -> Options
strippedOpts n =
    defaultOptions
        { fieldLabelModifier = lowerFirst . drop n
        , omitNothingFields = True
        }
  where
    lowerFirst [] = []
    lowerFirst (c : cs) = toLower c : cs

-- | One entry in a config's @flows@ list. No @qfFilename@ means "every
-- collection currently in that directory" — expanded on the dashboard side
-- (@_expand_collections@ in qa_runner.py), not here.
data QaFlow = QaFlow
    { qfDirectory :: Text
    , qfFilename :: Maybe Text
    }
    deriving (Eq, Show, Generic)

instance ToJSON QaFlow where
    toJSON = genericToJSON (strippedOpts 2)

instance FromJSON QaFlow where
    parseJSON = genericParseJSON (strippedOpts 2)

-- | Per-@(appGroup, cloudType)@ QA automation settings. @qcOnSuccess@ gates
-- only the *automatic* trigger on a COMPLETED release; the manual button
-- ignores it (an operator asking for a run should get one).
data QaAutomationConfig = QaAutomationConfig
    { qcId :: Int32
    , qcAppGroup :: Text
    , qcEnabled :: Bool
    , qcOnSuccess :: Bool
    , qcTestDashboardUrl :: Text
    , -- | In-cluster Service DNS to actually fire the webhook/refresh calls
      -- against, bypassing the external Pomerium-fronted route (meant for
      -- browser/SSO sessions, not server-to-server calls). 'Nothing' falls
      -- back to 'qcTestDashboardUrl'.
      qcInternalBaseUrl :: Maybe Text
    , qcWebhookToken :: Text
    , qcFlows :: [QaFlow]
    , qcEnvFile :: Text
    , qcConcurrency :: Int32
    }
    deriving (Eq, Show, Generic)

instance ToJSON QaAutomationConfig where
    toJSON = genericToJSON (strippedOpts 2)

-- | One triggered run, as shown on the release page's QA Automation tab.
-- @qrDetail@ is the dashboard's per-request/response failure detail, cached
-- here on refresh (not re-fetched on every poll).
data QaAutomationRun = QaAutomationRun
    { qrId :: Int32
    , qrRunId :: Text
    , qrReleaseId :: Text
    , qrAppGroup :: Text
    , qrReleaseVersion :: Maybe Text
    , qrStatus :: Text
    , qrTriggerSource :: Text
    , qrTestDashboardUrl :: Maybe Text
    , qrPassed :: Maybe Int32
    , qrFailed :: Maybe Int32
    , qrDetail :: Maybe Value
    , qrCreatedAt :: UTCTime
    , qrUpdatedAt :: UTCTime
    }
    deriving (Show, Generic)

instance ToJSON QaAutomationRun where
    toJSON = genericToJSON (strippedOpts 2)

-- | What the manual-trigger action hands back — a link the caller can open
-- (or hand to someone else) to watch the run live.
data TriggerQaRunResponse = TriggerQaRunResponse
    { tqrRunId :: Text
    , tqrTestDashboardUrl :: Text
    }
    deriving (Show, Generic)

instance ToJSON TriggerQaRunResponse where
    toJSON = genericToJSON (strippedOpts 3)
