{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- | HTTP client for Chime (appmonitor) — OTA push campaigns + adoption
analytics. Housed beside "Products.AirborneOta.Client" for the shared
plumbing ('UpstreamResult', 'renderQuery'), but its consumers live in the
MOBILE product ("Products.Autopilot.Mobile.Handlers.Chime" — campaigns are
catalog-addressed, not airborne-addressed); only 'chimeConfigured' is still
read here for @\/airborne\/health@. Chime is simpler than airborne (one
static @X-API-Key@, no token exchange), so this is a thin authenticated
passthrough. The device-side event key (@X-Event-Key@) is NEVER handled by
SCC — those endpoints are called by the mobile SDK, not by operators.

Chime's envelope is @{status, data}@ with errors as @{status: "error",
reason}@. Non-error outcomes like @skipped@ (one campaign per target) and
@ignored@ ride the 2xx path untouched — the FE interprets them; only HTTP
errors map to typed 'APIError's here. A Chime 401 maps to 'InternalError'
(key misconfigured), never an SCC 401 — that would log the operator out.
-}
module Products.AirborneOta.Chime (
    chimeConfigured,
    chimeRequest,
    expectChimeOk,
) where

import Control.Monad.Catch (throwM)
import Control.Monad.IO.Class (liftIO)
import Core.AppError (APIError (..))
import Core.Config (Config (..))
import Core.Environment (MonadFlow, getConfig)
import Core.Http.Client (
    HttpReq (..),
    HttpResponse (..),
    Method (..),
    defaultReq,
    httpRaw,
 )
import Core.Secrets (lookupEnvSecret)
import Data.Aeson (Value (..), eitherDecode, encode)
import Data.Aeson qualified as A
import Data.Aeson.Types qualified as AT
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Products.AirborneOta.Client (UpstreamResult (..), renderQuery)

-- | Non-throwing presence check: base URL + API key both set. Health/access
-- probes use this to tell "not configured" apart from "upstream down".
chimeConfigured :: (MonadFlow m) => m Bool
chimeConfigured = do
    base <- chimeBase
    mKey <- lookupEnvSecret "SC_CHIME_API_KEY"
    pure (not (null base) && isJust mKey)

{- | One authenticated call to Chime. GETs retry once; mutations never — a
launch that timed out may have started the campaign, and the relaunch answer
is Chime's own @skipped@, not a blind retry.
-}
chimeRequest ::
    (MonadFlow m) =>
    Method ->
    Text ->
    [(Text, Maybe Text)] ->
    Maybe Value ->
    m UpstreamResult
chimeRequest method path query mBody = do
    base <- chimeBase
    key <- requireKey
    if null base
        then throwM (InternalError "Chime not configured (SC_CHIME_URL)")
        else do
            let req =
                    (defaultReq (T.pack base <> path <> renderQuery query))
                        { reqMethod = method
                        , reqHeaders = [("X-API-Key", key), ("Content-Type", "application/json")]
                        , reqBody = encode <$> mBody
                        , reqRetries = if method == GET then 1 else 0
                        , reqLogTag = "chime"
                        }
            resp <- liftIO (httpRaw req)
            case resp of
                Left e ->
                    throwM . InternalError $
                        "chime unreachable (" <> path <> "): " <> T.pack (show e)
                Right HttpResponse{respStatus = s, respBody = b, respHeaders = hs} ->
                    pure
                        UpstreamResult
                            { urStatus = s
                            , urBody = either (const Null) id (eitherDecode b)
                            , urRequestId = lookup "x-request-id" [(T.toLower k, v) | (k, v) <- hs]
                            }
  where
    requireKey =
        lookupEnvSecret "SC_CHIME_API_KEY"
            >>= maybe (throwM (InternalError "Chime API key not configured (SC_CHIME_API_KEY)")) pure

{- | Map a non-2xx Chime result onto a typed 'APIError' using the
@{status: "error", reason}@ envelope; return the body on success (202
accepted, 200 skipped/recorded/ignored all pass through for the FE).
-}
expectChimeOk :: (MonadFlow m) => UpstreamResult -> m Value
expectChimeOk UpstreamResult{..}
    | urStatus < 400 = pure urBody
    | otherwise = throwM $ case urStatus of
        404 -> NotFound msg
        400 -> BadRequest msg
        401 -> InternalError "chime rejected the API key (check SC_CHIME_API_KEY)"
        503 -> InternalError ("chime unavailable: " <> msg)
        _ -> InternalError ("chime upstream " <> T.pack (show urStatus) <> ": " <> msg)
  where
    msg = case urBody of
        Object o ->
            case AT.parseMaybe (A.withObject "err" (A..: "reason")) (Object o) of
                Just m -> m
                Nothing -> fallback
        _ -> fallback
    fallback = "upstream error (HTTP " <> T.pack (show urStatus) <> ")"

chimeBase :: (MonadFlow m) => m String
chimeBase = do
    cfg <- getConfig
    pure (stripSlash (chimeUrl cfg))
  where
    stripSlash u = if not (null u) && last u == '/' then init u else u
