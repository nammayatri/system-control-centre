{-# LANGUAGE OverloadedStrings #-}

{- | Detail-page AI handlers: summarise / risk-assess / freeform-Q&A over an
existing release's context. All three call the one 'runAiTask' engine; the
subject is the release id (so the cache is per-release). Gated by the
@AP_AI_*@ permissions via 'Protected' (product-scoped RBAC, like every other
release endpoint).
-}
module Products.Autopilot.Handlers.Ai (
    AiActionReq (..),
    AiAskReq (..),
    AiResp (..),
    AiModelsResp (..),
    summarizeReleaseH,
    assessReleaseH,
    askReleaseH,
    listAiModelsH,
) where

import Core.Auth.Protected (AuthedPerson (..))
import Core.Environment (Flow)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=))
import Data.Int (Int32)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Products.Autopilot.Queries.ReleaseTracker (findReleaseTracker)
import Products.Autopilot.Types.Release (ReleaseTracker (..))
import Shared.AI.Config (resolveAiConfig)
import Shared.AI.Prompts (fence)
import Shared.AI.Provider (listModels)
import Shared.AI.Service (runAiTask)
import Shared.AI.Types (AiConfig (..), AiError, AiResult (..), AiSubject (..), AiTask (..), aiErrorReason)

-- ─── Wire types ────────────────────────────────────────────────────

newtype AiActionReq = AiActionReq {aiForce :: Maybe Bool}

instance FromJSON AiActionReq where
    parseJSON = withObject "AiActionReq" $ \o -> AiActionReq <$> o .:? "force"

newtype AiAskReq = AiAskReq {aiQuestion :: Text}

instance FromJSON AiAskReq where
    parseJSON = withObject "AiAskReq" $ \o -> AiAskReq <$> o .: "question"

data AiResp = AiResp
    { arAvailable :: Bool
    , arReason :: Maybe Text
    , arSummary :: Maybe Text
    , arModelName :: Maybe Text
    , arCachedFlag :: Maybe Bool
    , arInTok :: Maybe Int32
    , arOutTok :: Maybe Int32
    }

instance ToJSON AiResp where
    toJSON r =
        object
            [ "available" .= arAvailable r
            , "reason" .= arReason r
            , "summary" .= arSummary r
            , "model" .= arModelName r
            , "cached" .= arCachedFlag r
            , "inputTokens" .= arInTok r
            , "outputTokens" .= arOutTok r
            ]

-- | Models available to the configured Grid key, for the config UI's picker.
data AiModelsResp = AiModelsResp
    { amrAvailable :: Bool
    , amrModels :: [Text]
    , amrCurrent :: Maybe Text
    -- ^ the model currently set in config (so the UI can keep it selectable)
    , amrReason :: Maybe Text
    }

instance ToJSON AiModelsResp where
    toJSON r =
        object
            [ "available" .= amrAvailable r
            , "models" .= amrModels r
            , "current" .= amrCurrent r
            , "reason" .= amrReason r
            ]

-- ─── Handlers ──────────────────────────────────────────────────────

summarizeReleaseH :: AuthedPerson -> Text -> AiActionReq -> Flow AiResp
summarizeReleaseH ap rid req =
    aiReleaseTask ap rid TaskChangelogSummary (fromMaybe False (aiForce req)) Nothing

assessReleaseH :: AuthedPerson -> Text -> AiActionReq -> Flow AiResp
assessReleaseH ap rid req =
    aiReleaseTask ap rid TaskReleaseRisk (fromMaybe False (aiForce req)) Nothing

askReleaseH :: AuthedPerson -> Text -> AiAskReq -> Flow AiResp
askReleaseH ap rid req =
    aiReleaseTask ap rid TaskFreeformQA False (Just (aiQuestion req))

{- | List the models Grid exposes for the configured key (config UI model
picker). Deliberately uses 'resolveAiConfig' (not 'loadAiConfig') so it works
while @ai_enabled@ is still off — you pick the model first, then switch AI on.
-}
listAiModelsH :: AuthedPerson -> Flow AiModelsResp
listAiModelsH _ = do
    ecfg <- resolveAiConfig
    case ecfg of
        Left e -> pure (AiModelsResp False [] Nothing (Just (aiErrorReason e)))
        Right cfg -> do
            eres <- listModels cfg
            pure $ case eres of
                Left e -> AiModelsResp False [] (Just (aiModel cfg)) (Just (aiErrorReason e))
                Right ms -> AiModelsResp True ms (Just (aiModel cfg)) Nothing

aiReleaseTask :: AuthedPerson -> Text -> AiTask -> Bool -> Maybe Text -> Flow AiResp
aiReleaseTask ap rid task force mQuestion = do
    mt <- findReleaseTracker rid
    case mt of
        Nothing -> pure (unavailable "release not found")
        Just (tr, _) -> do
            let ctx0 = fence "context" (releaseContextText tr)
                ctx = case mQuestion of
                    Just q -> ctx0 <> "\n" <> fence "question" q
                    Nothing -> ctx0
            res <- runAiTask (apEmail ap) task (AiSubject "release" rid) ctx force
            pure (toResp res)

-- | Whitelisted, plain-text release context fed to the model.
releaseContextText :: ReleaseTracker -> Text
releaseContextText tr =
    T.intercalate
        "\n"
        [ "app: " <> appGroup tr <> " / " <> service tr <> " (env " <> env tr <> ")"
        , "version: " <> orNone (oldVersion tr) <> " -> " <> orNone (newVersion tr)
        , maybe "" ("description: " <>) (description tr)
        , "changelog:"
        , fromMaybe "(none)" (changeLog tr)
        ]
  where
    orNone t = if T.null t then "(none)" else t

toResp :: Either AiError AiResult -> AiResp
toResp (Left e) = unavailable (aiErrorReason e)
toResp (Right r) =
    AiResp
        { arAvailable = True
        , arReason = Nothing
        , arSummary = Just (arText r)
        , arModelName = Just (arModel r)
        , arCachedFlag = Just (arCached r)
        , arInTok = Just (arInputTokens r)
        , arOutTok = Just (arOutputTokens r)
        }

unavailable :: Text -> AiResp
unavailable r =
    AiResp
        { arAvailable = False
        , arReason = Just r
        , arSummary = Nothing
        , arModelName = Nothing
        , arCachedFlag = Nothing
        , arInTok = Nothing
        , arOutTok = Nothing
        }
