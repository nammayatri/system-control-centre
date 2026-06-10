{-# LANGUAGE OverloadedStrings #-}

{- | Load AI config from @server_config@ (product @autopilot@) plus the
@SC_AI_API_KEY@ env secret. Returns 'Left' (with a reason) when AI is disabled,
the key is missing, or the base URL fails validation — callers degrade gracefully.
-}
module Shared.AI.Config (loadAiConfig, resolveAiConfig) where

import Core.Environment (MonadFlow)
import Core.Secrets (lookupEnvSecret)
import Data.Text (Text)
import qualified Data.Text as T
import Shared.AI.Types
import Shared.Config.Runtime (
    getConfigBoolForProduct,
    getConfigDoubleForProduct,
    getConfigTextForProduct,
 )

prod :: Maybe Text
prod = Just "autopilot"

loadAiConfig :: (MonadFlow m) => m (Either AiError AiConfig)
loadAiConfig = do
    enabled <- getConfigBoolForProduct "ai_enabled" prod False
    if not enabled
        then pure (Left AiDisabled)
        else resolveAiConfig

{- | Resolve base URL + key + model WITHOUT the @ai_enabled@ gate. The config
UI's model picker needs this: an operator must be able to choose a valid model
*before* switching AI on (otherwise it's chicken-and-egg — you can't enable AI
usefully until the model is set, and you can't list models until it's enabled).
Still enforces the key + base-URL (SSRF) checks.
-}
resolveAiConfig :: (MonadFlow m) => m (Either AiError AiConfig)
resolveAiConfig = do
    rawUrl <- getConfigTextForProduct "ai_base_url" prod ""
    -- GLM 4.7 Flash ('glm-flash-experimental') — Grid's Summarize/Doc model and the
    -- fastest. The big "Plan, Build" models (Kimi/GLM-5 = open-large/glm-latest) are
    -- slower and overkill here. Thinking is disabled in the provider so even the full
    -- every-commit prompt streams straight to content.
    model <- getConfigTextForProduct "ai_model" prod "glm-flash-experimental"
    allowSfx <- getConfigTextForProduct "ai_allowed_host_suffix" prod ""
    temp <- getConfigDoubleForProduct "ai_temperature" prod 0.2
    ttl <- getConfigDoubleForProduct "ai_cache_ttl_hours" prod 168
    mKey <- lookupEnvSecret "SC_AI_API_KEY"
    let cleanUrl = T.dropWhileEnd (== '/') (T.strip rawUrl)
        suffixes = filter (not . T.null) (map T.strip (T.splitOn "," allowSfx))
    case (mKey, validateBaseUrl cleanUrl suffixes) of
        (Nothing, _) -> pure (Left (AiNotConfigured "SC_AI_API_KEY not set"))
        (_, Left e) -> pure (Left (AiBadBaseUrl e))
        (Just key, Right u) ->
            pure $
                Right
                    AiConfig
                        { aiBaseUrl = u
                        , aiApiKey = key
                        , aiModel = model
                        , aiTemperature = temp
                        , aiCacheTtlHrs = ttl
                        }

{- | SSRF defense-in-depth (no external URL-parser dep): require https and a
host that is not loopback / link-local / private / metadata, and — if an
allowlist is configured — a host whose name ends with one of the allowed
suffixes. The authoritative boundary is a k8s egress NetworkPolicy; this is a
second gate. A prefix check on IP literals is intentionally coarse.
-}
validateBaseUrl :: Text -> [Text] -> Either Text Text
validateBaseUrl url suffixes
    | not ("https://" `T.isPrefixOf` url) = Left "must be https"
    | T.null host = Left "missing host"
    | any (`T.isPrefixOf` host) blocked = Left "loopback/link-local/private/metadata host"
    | not (null suffixes) && not (any (`T.isSuffixOf` host) suffixes) =
        Left "host not in ai_allowed_host_suffix allowlist"
    | otherwise = Right url
  where
    afterScheme = T.drop (T.length ("https://" :: Text)) url
    host = T.toLower (T.takeWhile (\ch -> ch /= '/' && ch /= ':') afterScheme)
    blocked =
        [ "localhost"
        , "127."
        , "0."
        , "10."
        , "192.168."
        , "169.254."
        , "metadata."
        , "172.16."
        , "172.17."
        , "172.18."
        , "172.19."
        , "172.2"
        , "172.30."
        , "172.31."
        ]
