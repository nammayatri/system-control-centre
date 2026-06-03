{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | GitHub App authentication for Mobile release dispatch.

The flow:

1. Mint a short-lived (10 minute) RS256-signed JWT whose @iss@ is the
   GitHub App's numeric @app_id@.
2. Exchange the JWT at @POST \/app\/installations\/{id}\/access_tokens@
   for an /installation token/ — a @ghs_*@ string that authorises every
   subsequent REST/Actions API call.
3. Cache the installation token in a module-global 'MVar' and reuse it
   until ~1 minute before it expires.

The cache is process-wide because GitHub rate-limits token minting and
the same token is valid for ~1 hour. Thread-safe via 'modifyMVar_'.

Three helpers are exported:

* 'getInstallationToken' — returns a valid bearer token, refreshing if
  needed.
* 'clearTokenCache' — wipes the cache (handy for tests / forced refresh).
* 'loadGhCreds' — pulls the three secrets out of @server_config@.
-}
module Products.Autopilot.Mobile.Github.Auth (
    -- * Credentials + cache
    GhAppCreds (..),
    InstallationToken (..),

    -- * Public API
    getInstallationToken,
    clearTokenCache,
    loadGhCreds,
) where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar)
import Control.Monad.Catch (throwM)
import Control.Monad.IO.Class (liftIO)
import Core.AppError (APIError (InternalError))
import Core.Environment (MonadFlow, logError)
import Core.Http.Client (
    HttpError (..),
    HttpReq (..),
    Method (..),
    defaultReq,
    httpJson,
 )
import Core.Secrets (lookupEnvSecret, lookupEnvSecretB64)
import Core.Types.Time (Seconds (..))
import Data.Aeson (FromJSON (..), withObject, (.:))
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import GHC.Generics (Generic)
import System.IO.Unsafe (unsafePerformIO)
import qualified Web.JWT as JWT

-- ─── Types ─────────────────────────────────────────────────────────

{- | GitHub App credentials needed to mint a JWT and exchange it for
an installation token. All three are read from the process environment
(@SC_GITHUB_APP_*@) via 'loadGhCreds' — never from the database.
-}
data GhAppCreds = GhAppCreds
    { gacAppId :: Text
    -- ^ Numeric GitHub App ID — used as the JWT @iss@ claim.
    , gacPrivateKeyPem :: Text
    -- ^ PEM-encoded RSA private key associated with the App.
    , gacInstallationId :: Text
    -- ^ The installation ID for the org/repo this App is installed on.
    }
    deriving (Eq, Show)

{- | A cached installation token returned by the App-installation
endpoint. @expires_at@ is parsed as ISO-8601 'UTCTime'.
-}
data InstallationToken = InstallationToken
    { itToken :: Text
    , itExpiresAt :: UTCTime
    }
    deriving (Eq, Show, Generic)

instance FromJSON InstallationToken where
    parseJSON = withObject "InstallationToken" $ \o ->
        InstallationToken
            <$> o .: "token"
            <*> o .: "expires_at"

-- ─── Module-global cache ───────────────────────────────────────────

{- | Process-wide cache for the most-recently-minted installation
token. Initialised to 'Nothing'; populated lazily on first use.
-}
{-# NOINLINE tokenCache #-}
tokenCache :: MVar (Maybe InstallationToken)
tokenCache = unsafePerformIO (newMVar Nothing)

-- ─── Public API ────────────────────────────────────────────────────

{- | Return a valid installation token, minting + exchanging a fresh
one if the cache is empty or the cached token is within 60 seconds of
expiry.

Thread-safe via 'modifyMVar_'. On any error during refresh, throws an
'InternalError' carrying a human-readable message.
-}
getInstallationToken :: (MonadFlow m) => GhAppCreds -> m Text
getInstallationToken creds = do
    now <- liftIO getCurrentTime
    cached <- liftIO (readMVar tokenCache)
    case cached of
        Just t | itExpiresAt t > addUTCTime 60 now -> pure (itToken t)
        _ -> refresh creds

-- | Drop the cached token. Next 'getInstallationToken' call will refresh.
clearTokenCache :: (MonadFlow m) => m ()
clearTokenCache = liftIO (modifyMVar_ tokenCache (\_ -> pure Nothing))

{- | Read the three GitHub-App secrets from the process __environment__
(injected from a k8s Secret in prod; from @local-mobile-secrets.env@ in dev) —
never from the database. Throws 'InternalError' if any is missing/empty;
callers treat this as a hard configuration error.

* @SC_GITHUB_APP_ID@
* @SC_GITHUB_APP_INSTALLATION_ID@
* @SC_GITHUB_APP_PRIVATE_KEY_B64@ — the PEM, base64-encoded (single line).
-}
loadGhCreds :: (MonadFlow m) => m GhAppCreds
loadGhCreds = do
    mAppId <- lookupEnvSecret "SC_GITHUB_APP_ID"
    mKey <- lookupEnvSecretB64 "SC_GITHUB_APP_PRIVATE_KEY_B64"
    mInstallId <- lookupEnvSecret "SC_GITHUB_APP_INSTALLATION_ID"
    case (mAppId, mKey, mInstallId) of
        (Just appId, Just key, Just instId)
            | not (T.null appId)
            , not (T.null key)
            , not (T.null instId) ->
                pure
                    GhAppCreds
                        { gacAppId = appId
                        , gacPrivateKeyPem = key
                        , gacInstallationId = instId
                        }
        _ -> do
            logError "[github-auth] missing GitHub App secrets in env (SC_GITHUB_APP_ID / SC_GITHUB_APP_INSTALLATION_ID / SC_GITHUB_APP_PRIVATE_KEY_B64)"
            throwM (InternalError "GitHub App credentials are not configured")

-- ─── Refresh: mint JWT + exchange for installation token ───────────

refresh :: (MonadFlow m) => GhAppCreds -> m Text
refresh creds = do
    jwt <- mintAppJwt creds
    new <- exchangeForInstallationToken creds jwt
    liftIO (modifyMVar_ tokenCache (\_ -> pure (Just new)))
    pure (itToken new)

{- | Mint a short-lived RS256 JWT using the GitHub App's private key.

Claims:

* @iss@ = numeric App ID
* @iat@ = now − 60 s (backdated per GitHub's recommendation to tolerate clock drift)
* @exp@ = now + 540 s (9 min 0 s — safely under GitHub's 10-min ceiling)
-}
mintAppJwt :: (MonadFlow m) => GhAppCreds -> m Text
mintAppJwt GhAppCreds{..} = do
    nowSec <- liftIO ((round :: Double -> Integer) . realToFrac <$> getPOSIXTime)
    case JWT.readRsaSecret (TE.encodeUtf8 gacPrivateKeyPem) of
        Nothing -> do
            logError "[github-auth] bad RSA private key (could not parse PEM)"
            throwM (InternalError "GitHub App private key is not a valid RSA PEM")
        Just rsa -> do
            let signer = JWT.EncodeRSAPrivateKey rsa
                iat = JWT.numericDate (fromInteger (nowSec - 60))
                expAt = JWT.numericDate (fromInteger (nowSec + 540))
                claims =
                    mempty
                        { JWT.iss = JWT.stringOrURI gacAppId
                        , JWT.iat = iat
                        , JWT.exp = expAt
                        }
            pure (JWT.encodeSigned signer mempty claims)

{- | POST the JWT to the installation-access-tokens endpoint and decode
the @{token, expires_at}@ response.
-}
exchangeForInstallationToken ::
    (MonadFlow m) =>
    GhAppCreds ->
    Text ->
    m InstallationToken
exchangeForInstallationToken GhAppCreds{..} jwt = do
    let url =
            "https://api.github.com/app/installations/"
                <> gacInstallationId
                <> "/access_tokens"
        req =
            (defaultReq url)
                { reqMethod = POST
                , reqHeaders =
                    [ ("Authorization", "Bearer " <> jwt)
                    , ("Accept", "application/vnd.github+json")
                    , ("X-GitHub-Api-Version", "2022-11-28")
                    , ("User-Agent", "system-control-centre")
                    ]
                , reqBody = Just (LBS.fromStrict (TE.encodeUtf8 ""))
                , reqTimeout = Seconds 30
                , reqLogTag = "gh-auth"
                , reqRetries = 1
                }
    resp <- liftIO (httpJson @InstallationToken req)
    case resp of
        Right t -> pure t
        Left e -> do
            logError $ "[github-auth] installation-token exchange failed: " <> T.pack (show e)
            throwM (InternalError ("GitHub installation-token exchange failed: " <> renderHttpError e))

renderHttpError :: HttpError -> Text
renderHttpError (HttpExceptionError m) = m
renderHttpError (HttpStatusError s b) =
    "HTTP " <> T.pack (show s) <> ": " <> TE.decodeUtf8 (LBS.toStrict b)
renderHttpError (HttpDecodeError m) = "decode error: " <> T.pack m
