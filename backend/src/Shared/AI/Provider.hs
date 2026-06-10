{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- | The single provider path. Grid is LiteLLM (OpenAI-compatible) and fronts
every model behind @/v1/chat/completions@, so there is one 'complete' function —
no provider record, no selection, no provider config. 'listModels' (GET
@/v1/models@) backs the config UI's model picker. This is the only place the
wire format lives.
-}
module Shared.AI.Provider (complete, listModels) where

import Control.Concurrent.QSem (QSem, newQSem, signalQSem, waitQSem)
import Control.Exception (bracket_)
import Control.Monad.IO.Class (liftIO)
import Core.Environment (MonadFlow)
import Core.Http.Client (HttpError (..), HttpReq (..), Method (GET, POST), defaultReq, httpJson)
import Core.Types.Time (Seconds (..))
import Data.Aeson
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int32)
import Data.List (nub, sort)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Shared.AI.Types
import System.IO.Unsafe (unsafePerformIO)

{- | Global cap on concurrent Grid calls. Grid throttles concurrent requests from
a single API key — with several in flight (multiple async summary generations,
each running a fallback chain), EACH call slows past the timeout and they all fail
with ResponseTimeout. Serialising to a small number keeps every call fast. All
generation funnels through 'complete', so this one semaphore bounds total in-flight
Grid load process-wide.
-}
{-# NOINLINE aiCallSem #-}
aiCallSem :: QSem
aiCallSem = unsafePerformIO (newQSem 2)

complete :: (MonadFlow m) => AiConfig -> AiCompletion -> m (Either AiError AiCompletionResult)
complete cfg c = do
    let url = aiBaseUrl cfg <> "/v1/chat/completions"
        body =
            object
                [ "model" .= acModel c
                , "temperature" .= acTemperature c
                , "messages"
                    .= [ object ["role" .= ("system" :: Text), "content" .= acSystem c]
                       , object ["role" .= ("user" :: Text), "content" .= acUser c]
                       ]
                , -- Disable the model's chain-of-thought. This MUST be nested under
                  -- `extra_body` for the Grid/LiteLLM proxy to forward it to the model:
                  -- sent as a top-level field it is silently dropped, and the model then
                  -- reasons until it exhausts its budget and returns an EMPTY `content`
                  -- (the thinking lands in `reasoning_content`, which we don't read).
                  -- With it off, even the full every-commit prompt finishes cleanly
                  -- (finish_reason=stop) in seconds. No `max_tokens`: generation is
                  -- detached, so a large diff runs to completion rather than truncating.
                  "extra_body" .= object ["chat_template_kwargs" .= object ["enable_thinking" .= False]]
                ]
        req =
            (defaultReq url)
                { reqMethod = POST
                , reqHeaders =
                    [ ("Authorization", "Bearer " <> aiApiKey cfg)
                    , ("Content-Type", "application/json")
                    ]
                , reqBody = Just (encode body)
                , reqLogTag = "ai"
                , -- Generous bound. With thinking disabled, output streams immediately;
                  -- a big every-commit diff (200-300 commits) still takes ~2 min just to
                  -- emit, so allow for that. Generation is detached (forkFlow), so this
                  -- wait is never on a user request. 'generateWithFallback' retries once
                  -- on failure; 2 × this stays under the 10-min stale-reclaim window.
                  reqTimeout = Seconds 240
                , reqRetries = 0
                }
    resp <- liftIO (bracket_ (waitQSem aiCallSem) (signalQSem aiCallSem) (httpJson @OpenAiResp req))
    pure $ case resp of
        Right r -> maybe (Left AiEmpty) Right (toResult r)
        Left e -> Left (toAiErr e)
  where
    toResult r = case oarChoices r of
        (ch : _) ->
            let txt = T.strip (omcContent (oacMessage ch))
             in -- Reject (→ AiEmpty → fallback chain retries) when either:
                --   • content is empty (reasoning went to a hidden field), or
                --   • finish_reason == "length" — the model hit max_tokens, which for
                --     these reasoning models means it spent the budget thinking and the
                --     reply is missing or truncated mid-output. A clean changelog
                --     finishes with "stop"; "length" is the over-reasoning signal.
                if T.null txt || oacFinish ch == Just "length"
                    then Nothing
                    else
                        Just
                            ( AiCompletionResult
                                txt
                                (ouPrompt (oarUsage r))
                                (ouCompletion (oarUsage r))
                            )
        [] -> Nothing

{- | List the model ids Grid exposes for the configured key (OpenAI-compatible
@GET /v1/models@). Sorted + de-duped. Used by the config UI so an operator picks
a valid model instead of typing one Grid will 400 on.
-}
listModels :: (MonadFlow m) => AiConfig -> m (Either AiError [Text])
listModels cfg = do
    let url = aiBaseUrl cfg <> "/v1/models"
        req =
            (defaultReq url)
                { reqMethod = GET
                , reqHeaders = [("Authorization", "Bearer " <> aiApiKey cfg)]
                , reqLogTag = "ai"
                }
    resp <- liftIO (httpJson @ModelsResp req)
    pure $ case resp of
        Right r -> Right (sort (nub (filter (not . T.null) (map meId (mrData r)))))
        Left e -> Left (toAiErr e)

toAiErr :: HttpError -> AiError
toAiErr (HttpExceptionError m) = AiHttp m
toAiErr (HttpStatusError s b) =
    AiHttp ("HTTP " <> T.pack (show s) <> ": " <> TE.decodeUtf8 (LBS.toStrict b))
toAiErr (HttpDecodeError m) = AiDecode (T.pack m)

-- ─── Response decoders (OpenAI / LiteLLM chat-completions shape) ────────────

data OpenAiResp = OpenAiResp {oarChoices :: [OAChoice], oarUsage :: OAUsage}
data OAChoice = OAChoice {oacMessage :: OAMsg, oacFinish :: Maybe Text}
newtype OAMsg = OAMsg {omcContent :: Text}
data OAUsage = OAUsage {ouPrompt :: Int32, ouCompletion :: Int32}

instance FromJSON OpenAiResp where
    parseJSON = withObject "OpenAiResp" $ \o ->
        OpenAiResp <$> o .: "choices" <*> o .:? "usage" .!= OAUsage 0 0
instance FromJSON OAChoice where
    parseJSON = withObject "OAChoice" $ \o -> OAChoice <$> o .: "message" <*> o .:? "finish_reason"
instance FromJSON OAMsg where
    parseJSON = withObject "OAMsg" $ \o -> OAMsg <$> o .:? "content" .!= ""
instance FromJSON OAUsage where
    parseJSON = withObject "OAUsage" $ \o ->
        OAUsage <$> o .:? "prompt_tokens" .!= 0 <*> o .:? "completion_tokens" .!= 0

-- ─── /v1/models decoders (OpenAI list shape: {"data":[{"id":...}]}) ──────────

newtype ModelsResp = ModelsResp {mrData :: [ModelEntry]}
newtype ModelEntry = ModelEntry {meId :: Text}

instance FromJSON ModelsResp where
    parseJSON = withObject "ModelsResp" $ \o -> ModelsResp <$> o .:? "data" .!= []
instance FromJSON ModelEntry where
    parseJSON = withObject "ModelEntry" $ \o -> ModelEntry <$> o .: "id"
