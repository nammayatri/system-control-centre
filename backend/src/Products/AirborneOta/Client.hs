{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- | HTTP client for airborne_server. Authenticates with the service-account
PAT: the public @POST /api/token/issue@ exchanges the stored
@{client_id, client_secret}@ for a ~5-minute bearer token, cached in a
process-wide MVar with single-flight refresh (~30s early). The browser never
sees any of this; SCC RBAC gates every proxied route in Routes.hs.

Upstream errors are uniformly @{"code": "AB_00x", "message": ...}@ and are
mapped onto typed 'APIError's so airborne token expiry can never surface as
an SCC 401 (which would log the user out of SCC).
-}
module Products.AirborneOta.Client (
    UpstreamResult (..),
    airborneRequest,
    analyticsRequest,
    expectOk,
    forceTokenRefresh,
    AirborneCreds (..),
    loadAirborneCreds,
    airborneConfigured,
    fetchUpstreamApps,
    renderQuery,
    KeepaliveOutcome (..),
    recordKeepalive,
    readKeepalive,
)
where

import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar)
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
import Core.Secrets (lookupEnvSecret, lookupEnvSecretB64)
import Core.Types.Time (Seconds (..))
import Data.Aeson (Value (..), eitherDecode, encode, object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Types qualified as AT
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, atomicWriteIORef, newIORef, readIORef)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TEE
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Network.HTTP.Types.URI (urlEncode)
import System.IO.Unsafe (unsafePerformIO)

-- ─── Credentials ───────────────────────────────────────────────────

data AirborneCreds = AirborneCreds
    { acClientId :: Text
    , acClientSecret :: Text
    }

{- | PAT credentials from the process environment (k8s Secret in prod,
local env file in dev) — never from the database.

* @SC_AIRBORNE_PAT_CLIENT_ID@
* @SC_AIRBORNE_PAT_CLIENT_SECRET_B64@ — the client_secret, base64-encoded.
-}
loadAirborneCreds :: (MonadFlow m) => m AirborneCreds
loadAirborneCreds = do
    mId <- lookupEnvSecret "SC_AIRBORNE_PAT_CLIENT_ID"
    mSecret <- lookupEnvSecretB64 "SC_AIRBORNE_PAT_CLIENT_SECRET_B64"
    case (mId, mSecret) of
        (Just cid, Just sec) -> pure (AirborneCreds cid sec)
        _ ->
            throwM . InternalError $
                "Airborne PAT credentials not configured "
                    <> "(SC_AIRBORNE_PAT_CLIENT_ID / SC_AIRBORNE_PAT_CLIENT_SECRET_B64)"

{- | Non-throwing credentials presence check. Status probes must be able to
tell "not configured" apart from "upstream is down" — 'loadAirborneCreds'
throws, which would otherwise render an unconfigured env as an outage.
-}
airborneConfigured :: (MonadFlow m) => m Bool
airborneConfigured = do
    mId <- lookupEnvSecret "SC_AIRBORNE_PAT_CLIENT_ID"
    mSecret <- lookupEnvSecretB64 "SC_AIRBORNE_PAT_CLIENT_SECRET_B64"
    pure (isJust mId && isJust mSecret)

-- ─── Keepalive outcome (read by GET /airborne/health) ──────────────

{- | Result of the last daily PAT re-issue. Process-local, like 'tokenCache':
written by Keepalive.hs, read by @healthH@ so the UI can flag a dying PAT
BEFORE cached tokens stop working. Not durable and not cross-replica — a
health request may land on a replica whose tick succeeded while another's
failed (same caveat as the mobile in-memory single-flight map).
-}
data KeepaliveOutcome = KeepaliveOutcome
    { koOk :: Bool
    , koAt :: UTCTime
    , koError :: Maybe Text
    }

{-# NOINLINE keepaliveRef #-}
keepaliveRef :: IORef (Maybe KeepaliveOutcome)
keepaliveRef = unsafePerformIO (newIORef Nothing)

recordKeepalive :: (MonadFlow m) => Bool -> Maybe Text -> m ()
recordKeepalive ok mErr = liftIO $ do
    now <- getCurrentTime
    atomicWriteIORef keepaliveRef (Just (KeepaliveOutcome ok now mErr))

readKeepalive :: (MonadFlow m) => m (Maybe KeepaliveOutcome)
readKeepalive = liftIO (readIORef keepaliveRef)

-- ─── Token cache (single-flight) ───────────────────────────────────

{-# NOINLINE tokenCache #-}
tokenCache :: MVar (Maybe (Text, UTCTime))
tokenCache = unsafePerformIO (newMVar Nothing)

{- | Valid bearer token, minting via @/api/token/issue@ when the cache is
empty or within 30s of expiry. 'modifyMVar' holds the lock across the mint,
so concurrent misses coalesce into one upstream call (single-flight).
-}
getToken :: (MonadFlow m) => m Text
getToken = do
    base <- airborneBase
    creds <- loadAirborneCreds
    now <- liftIO getCurrentTime
    result <- liftIO . modifyMVar tokenCache $ \cached ->
        case cached of
            Just (tok, expiry) | expiry > now -> pure (cached, Right tok)
            _ -> do
                minted <- issueToken base creds
                case minted of
                    Right (tok, ttl) ->
                        let expiry = addUTCTime (fromIntegral (max 30 ttl - 30)) now
                         in pure (Just (tok, expiry), Right tok)
                    Left err -> pure (Nothing, Left err)
    either (throwM . InternalError . ("airborne token issue failed: " <>)) pure result

{- | Drop the cached token; the next call mints fresh. Used by the daily
keepalive (the point is to exercise the offline session upstream).
-}
forceTokenRefresh :: (MonadFlow m) => m Text
forceTokenRefresh = do
    liftIO $ modifyMVar_ tokenCache (\_ -> pure Nothing)
    getToken

issueToken :: String -> AirborneCreds -> IO (Either Text (Text, Int))
issueToken base AirborneCreds{..} = do
    let req =
            (defaultReq (T.pack base <> "/api/token/issue"))
                { reqMethod = POST
                , reqHeaders = [("Content-Type", "application/json")]
                , reqBody =
                    Just . encode $
                        object ["client_id" .= acClientId, "client_secret" .= acClientSecret]
                , -- Short timeout + no retry: this runs under the token-cache
                  -- lock, so a slow mint would block every concurrent proxy call.
                  reqTimeout = Seconds 10
                , reqRetries = 0
                , reqLogTag = "airborne-token"
                }
    resp <- httpRaw req
    pure $ case resp of
        Left e -> Left (T.pack (show e))
        Right HttpResponse{respStatus = s, respBody = b}
            | s >= 400 -> Left ("HTTP " <> T.pack (show s) <> ": " <> previewBody b)
            | otherwise -> case eitherDecode b of
                Left err -> Left (T.pack err)
                Right v -> case parseToken v of
                    Nothing -> Left "token response missing access_token/expires_in"
                    Just tok -> Right tok
  where
    parseToken :: Value -> Maybe (Text, Int)
    parseToken v = AT.parseMaybe parser v
      where
        parser = A.withObject "UserToken" $ \o ->
            (,) <$> o A..: "access_token" <*> o A..: "expires_in"

-- ─── Proxied requests ──────────────────────────────────────────────

data UpstreamResult = UpstreamResult
    { urStatus :: Int
    , urBody :: Value
    -- ^ Decoded JSON body; 'Null' when empty or non-JSON.
    , urRequestId :: Maybe Text
    -- ^ Upstream @x-request-id@, stored in airborne_events for correlation.
    }

{- | One authenticated call to airborne. @extraHeaders@ carries
@x-organisation@ / @x-application@ / @x-dimension@; @query@ params are
URL-encoded here. On an upstream 401 the cached token is refreshed and the
call retried once — a second 401 is reported as an upstream error, never an
SCC 401.
-}
airborneRequest ::
    (MonadFlow m) =>
    Method ->
    Text ->
    [(Text, Text)] ->
    [(Text, Maybe Text)] ->
    Maybe Value ->
    m UpstreamResult
airborneRequest method path extraHeaders query mBody = do
    r1 <- doCall =<< getToken
    if urStatus r1 == 401
        then doCall =<< forceTokenRefresh
        else pure r1
  where
    doCall tok = do
        base <- airborneBase
        let req =
                (defaultReq (T.pack base <> path <> renderQuery query))
                    { reqMethod = method
                    , reqHeaders =
                        [("Authorization", "Bearer " <> tok), ("Content-Type", "application/json")]
                            <> extraHeaders
                    , reqBody = encode <$> mBody
                    , -- Never auto-retry mutations: a ramp/conclude/discard that
                      -- timed out may have succeeded upstream, so a retry would
                      -- double-apply (or 400 on an already-changed experiment).
                      reqRetries = if method == GET then 1 else 0
                    , reqLogTag = "airborne"
                    }
        resp <- liftIO (httpRaw req)
        case resp of
            Left e ->
                throwM . InternalError $
                    "airborne unreachable (" <> path <> "): " <> T.pack (show e)
            Right HttpResponse{respStatus = s, respBody = b, respHeaders = hs} ->
                pure
                    UpstreamResult
                        { urStatus = s
                        , urBody = either (const Null) id (eitherDecode b)
                        , urRequestId = lookup "x-request-id" [(T.toLower k, v) | (k, v) <- hs]
                        }

{- | Map a non-2xx upstream result onto a typed 'APIError' using airborne's
@{code, message}@ envelope; return the body on success. 401 maps to
'InternalError' deliberately — an SCC 401 would clear the user's session.
-}
expectOk :: (MonadFlow m) => UpstreamResult -> m Value
expectOk UpstreamResult{..}
    | urStatus < 400 = pure urBody
    | otherwise = throwM $ case urStatus of
        404 -> NotFound msg
        400 -> BadRequest msg
        403 -> Forbidden ("airborne: " <> msg)
        409 -> Conflict msg
        _ -> InternalError ("airborne upstream " <> T.pack (show urStatus) <> ": " <> msg)
  where
    msg = case urBody of
        Object o ->
            case AT.parseMaybe (A.withObject "err" (A..: "message")) (Object o) of
                Just m -> m
                Nothing -> fallback
        _ -> fallback
    fallback = "upstream error (HTTP " <> T.pack (show urStatus) <> ")"

-- ─── Analytics (separate, unauthenticated host) ────────────────────

{- | One call to the airborne ANALYTICS server. Unlike 'airborneRequest' this
sends NO PAT bearer and NO @x-organisation@/@x-application@ headers — the
analytics host is fully open and takes org/app as @org_id@/@app_id@ query
params. Read-only, so no 401-refresh loop. Throws a clean 'InternalError' if
@SC_AIRBORNE_ANALYTICS_URL@ is unset rather than hitting a bare @/analytics@.
-}
analyticsRequest ::
    (MonadFlow m) =>
    Method ->
    Text ->
    [(Text, Maybe Text)] ->
    m UpstreamResult
analyticsRequest method path query = do
    base <- analyticsBase
    if null base
        then throwM (InternalError "Airborne analytics not configured (SC_AIRBORNE_ANALYTICS_URL)")
        else do
            let req =
                    (defaultReq (T.pack base <> path <> renderQuery query))
                        { reqMethod = method
                        , reqHeaders = [("Content-Type", "application/json")]
                        , reqRetries = if method == GET then 1 else 0
                        , reqLogTag = "airborne-analytics"
                        }
            resp <- liftIO (httpRaw req)
            case resp of
                Left e ->
                    throwM . InternalError $
                        "airborne analytics unreachable (" <> path <> "): " <> T.pack (show e)
                Right HttpResponse{respStatus = s, respBody = b, respHeaders = hs} ->
                    pure
                        UpstreamResult
                            { urStatus = s
                            , urBody = either (const Null) id (eitherDecode b)
                            , urRequestId = lookup "x-request-id" [(T.toLower k, v) | (k, v) <- hs]
                            }

-- ─── Helpers ───────────────────────────────────────────────────────

airborneBase :: (MonadFlow m) => m String
airborneBase = do
    cfg <- getConfig
    pure (stripSlash (airborneUrl cfg))
  where
    stripSlash u = if not (null u) && last u == '/' then init u else u

analyticsBase :: (MonadFlow m) => m String
analyticsBase = do
    cfg <- getConfig
    pure (stripSlash (airborneAnalyticsUrl cfg))
  where
    stripSlash u = if not (null u) && last u == '/' then init u else u

renderQuery :: [(Text, Maybe Text)] -> Text
renderQuery params = case [(k, v) | (k, Just v) <- params] of
    [] -> ""
    kvs -> "?" <> T.intercalate "&" [enc k <> "=" <> enc v | (k, v) <- kvs]
  where
    enc = TE.decodeUtf8 . urlEncode True . TE.encodeUtf8

previewBody :: LBS.ByteString -> Text
previewBody = T.take 200 . TE.decodeUtf8With TEE.lenientDecode . LBS.toStrict . LBS.take 400

{- | The bot's org→app access tree from @GET /api/users@, as (org, app)
pairs. Throws on upstream error (callers catch to degrade). Single source of
the /api/users wire shape — used by both the access map and the keepalive
diff.
-}
fetchUpstreamApps :: (MonadFlow m) => m [(Text, Text)]
fetchUpstreamApps = do
    body <- expectOk =<< airborneRequest GET "/api/users" [] [] Nothing
    pure (fromMaybe [] (AT.parseMaybe parser body))
  where
    parser = A.withObject "User" $ \o -> do
        orgs <- o A..: "organisations"
        fmap concat . mapM parseOrg $ (orgs :: [Value])
    parseOrg = A.withObject "Org" $ \o -> do
        orgName <- o A..: "name"
        apps <- o A..:? "applications" A..!= ([] :: [Value])
        appNames <- mapM (A.withObject "App" (A..: "application")) apps
        pure [(orgName, a) | a <- appNames]
