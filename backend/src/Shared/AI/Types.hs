{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Pure data for the AI engine. No DB, no IO. Grid (LiteLLM) is the only
provider and it is OpenAI-compatible, so there is no provider-kind selector.
-}
module Shared.AI.Types (
    AiConfig (..),
    AiCompletion (..),
    AiCompletionResult (..),
    AiTask (..),
    taskText,
    AiSubject (..),
    AiError (..),
    aiErrorReason,
    AiResult (..),
) where

import Data.Int (Int32)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import GHC.Generics (Generic)

-- | Resolved AI config (from server_config + the SC_AI_API_KEY env secret).
-- Deliberately small: thinking-disable, timeout, and retry are fixed behaviours in
-- 'Shared.AI.Provider'/'Shared.AI.ReleaseSummary', not operator knobs.
data AiConfig = AiConfig
    { aiBaseUrl :: Text
    , aiApiKey :: Text
    -- ^ from env; never logged or serialised
    , aiModel :: Text
    , aiTemperature :: Double
    , aiCacheTtlHrs :: Double
    }

-- | A provider-neutral completion request.
data AiCompletion = AiCompletion
    { acSystem :: Text
    , acUser :: Text
    , acModel :: Text
    , acTemperature :: Double
    }

-- | A provider-neutral completion result.
data AiCompletionResult = AiCompletionResult
    { acrText :: Text
    , acrInputTokens :: Int32
    , acrOutputTokens :: Int32
    }

data AiTask = TaskChangelogSummary | TaskReleaseRisk | TaskFreeformQA
    deriving (Eq, Show)

taskText :: AiTask -> Text
taskText TaskChangelogSummary = "changelog_summary"
taskText TaskReleaseRisk = "release_risk"
taskText TaskFreeformQA = "freeform_qa"

-- | What is being summarised: a release id, or a changelog commit range, etc.
data AiSubject = AiSubject
    { asType :: Text
    , asId :: Text
    }

data AiError
    = AiDisabled
    | AiNotConfigured Text
    | AiBadBaseUrl Text
    | AiHttp Text
    | AiDecode Text
    | AiEmpty
    deriving (Show)

aiErrorReason :: AiError -> Text
aiErrorReason AiDisabled = "AI is not enabled"
aiErrorReason (AiNotConfigured t) = "AI is not configured: " <> t
aiErrorReason (AiBadBaseUrl t) = "AI endpoint rejected: " <> t
aiErrorReason (AiHttp t) = "AI service error: " <> t
aiErrorReason (AiDecode t) = "AI response could not be parsed: " <> t
aiErrorReason AiEmpty = "AI returned an empty response"

data AiResult = AiResult
    { arText :: Text
    , arModel :: Text
    , arCached :: Bool
    , arInputTokens :: Int32
    , arOutputTokens :: Int32
    , arGeneratedAt :: UTCTime
    }
    deriving (Generic)
