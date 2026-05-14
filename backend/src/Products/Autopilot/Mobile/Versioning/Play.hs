{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | Play Console (Google Play Developer API) client + version-bump logic.

The pure 'computeNextVersion' mirrors the algorithm in
@fastlane-android.yaml@ (lines 124-189) used by the existing release
workflow. The IO-side ('fetchPlayTracks') mints a JWT for the supplied
service-account credentials, exchanges it for an OAuth access token,
then asks the Android Publisher API for the @internal@ and @production@
track release info — returning the highest version-name + version-code
on each track.

Pure logic is unit-tested via @backend/test/Main.hs@; the IO side is
covered by build + integration smoke tests (no live Play API in CI).
-}
module Products.Autopilot.Mobile.Versioning.Play (
    -- * Pure version-bump algorithm
    TrackInfo (..),
    computeNextVersion,

    -- * Play Console API client
    PlayCreds (..),
    PlayApiError (..),
    fetchPlayTracks,
    loadPlayCreds,
    renderPlayErr,

    -- * Dispatcher entry point
    resolve,
) where

import Control.Exception (Exception, SomeException, try)
import Control.Monad.IO.Class (liftIO)
import Core.Environment (MonadFlow, logError)
import Core.Http.Client (
    HttpError (..),
    HttpReq (..),
    HttpResponse (..),
    Method (..),
    defaultReq,
    httpJson,
    httpRaw,
 )
import Core.Types.Time (Seconds (..))
import Data.Aeson (
    FromJSON (..),
    ToJSON (..),
    Value (..),
    decode,
    eitherDecode,
    withObject,
    (.:),
    (.:?),
 )
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int32)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import GHC.Generics (Generic)
import Shared.Queries.ServerConfig (getEnabledServerConfigValueForProduct)
import qualified Web.JWT as JWT

-- ─── Pure algorithm ────────────────────────────────────────────────

{- | Snapshot of a Play Console track: the latest @releases[]@ entry's
name (semver-ish) and the highest version code that has shipped.
-}
data TrackInfo = TrackInfo
    { tiName :: Text
    , tiCode :: Int32
    }
    deriving (Eq, Show, Generic)

instance ToJSON TrackInfo
instance FromJSON TrackInfo

{- | The workflow's algorithm:

* If both internal and production are still at the @0.0.0@ baseline,
  return @("0.0.1", 1)@ — first-ever release.
* Else if internal name == production name AND production != "0.0.0",
  bump the patch component on the shared name.
* Else use internal's name verbatim (internal already moved ahead of
  production in some prior planning step).
* Version code is always @internal_code + 1@.
-}
computeNextVersion :: TrackInfo -> TrackInfo -> (Text, Int32)
computeNextVersion internal production
    | tiName internal == "0.0.0" && tiName production == "0.0.0" =
        ("0.0.1", 1)
    | tiName internal == tiName production && tiName production /= "0.0.0" =
        (bumpPatch (tiName internal), tiCode internal + 1)
    | otherwise =
        (tiName internal, tiCode internal + 1)

{- | Increment the last dotted numeric component. Non-numeric tail is
left untouched (caller-controlled input).
-}
bumpPatch :: Text -> Text
bumpPatch ver =
    let parts = T.splitOn "." ver
     in case reverse parts of
            [] -> ver
            (lastP : rest) ->
                let bumped = case reads (T.unpack lastP) :: [(Int, String)] of
                        [(n, "")] -> T.pack (show (n + 1))
                        _ -> lastP
                 in T.intercalate "." (reverse (bumped : rest))

-- ─── Play Console credentials + errors ─────────────────────────────

{- | Raw service-account JSON (the @key.json@ Google issues for the
service account). Parsed inside 'fetchPlayTracks' to extract
@client_email@ and @private_key@.
-}
newtype PlayCreds = PlayCreds {pcServiceAccountJson :: Text}

data PlayApiError
    = -- | OAuth token fetch failed (bad creds / wrong scope).
      PlayUnauthorized
    | -- | The package name does not exist in this developer account.
      PlayPackageNotFound Text
    | -- | Any other HTTP error, with a human-readable message.
      PlayHttpError Int Text
    deriving (Show)

instance Exception PlayApiError

{- | Fetch the (internal, production) tracks for a Play package.

Implementation order:

1. Parse the service-account JSON.
2. Mint an RS256-signed JWT with @aud=https://oauth2.googleapis.com/token@.
3. Exchange the JWT for an OAuth bearer token.
4. POST @\/edits@ to obtain a transient @editId@.
5. GET @\/edits/{editId}/tracks/internal@ and @\/tracks/production@.
6. DELETE @\/edits/{editId}@ as cleanup (errors ignored).

If a track has no releases, defaults to @TrackInfo "0.0.0" 0@.
-}
fetchPlayTracks ::
    (MonadFlow m) =>
    PlayCreds ->
    Text ->
    m (Either PlayApiError (TrackInfo, TrackInfo))
fetchPlayTracks (PlayCreds saJson) packageName = do
    case parseServiceAccount saJson of
        Left e -> do
            logError $ "[play-console] bad service-account JSON: " <> T.pack e
            pure (Left PlayUnauthorized)
        Right sa -> liftIO (runFetch sa packageName)

-- ─── Service account parsing ───────────────────────────────────────

data ServiceAccount = ServiceAccount
    { saClientEmail :: Text
    , saPrivateKey :: Text
    }

parseServiceAccount :: Text -> Either String ServiceAccount
parseServiceAccount raw =
    case eitherDecode (LBS.fromStrict (TE.encodeUtf8 raw)) of
        Left e -> Left e
        Right v -> case v :: Value of
            Object o -> do
                ce <- lookupT "client_email" o
                pk <- lookupT "private_key" o
                Right (ServiceAccount ce pk)
            _ -> Left "service-account JSON is not an object"
  where
    lookupT k o = case KM.lookup (K.fromText k) o of
        Just (String s) -> Right s
        _ -> Left ("missing string field: " <> T.unpack k)

-- ─── Live Play API call (IO-only) ──────────────────────────────────

runFetch :: ServiceAccount -> Text -> IO (Either PlayApiError (TrackInfo, TrackInfo))
runFetch sa packageName = do
    eToken <- mintAndExchange sa
    case eToken of
        Left err -> pure (Left err)
        Right token -> do
            eEdit <- createEdit token packageName
            case eEdit of
                Left err -> pure (Left err)
                Right editId -> do
                    eInternal <- fetchTrack token packageName editId "internal"
                    eProd <- fetchTrack token packageName editId "production"
                    -- Best-effort cleanup; ignore failures.
                    _ <- try @SomeException (deleteEdit token packageName editId)
                    case (eInternal, eProd) of
                        (Right i, Right p) -> pure (Right (i, p))
                        (Left e, _) -> pure (Left e)
                        (_, Left e) -> pure (Left e)

-- ─── JWT minting + OAuth exchange ──────────────────────────────────

mintAndExchange :: ServiceAccount -> IO (Either PlayApiError Text)
mintAndExchange ServiceAccount{..} = do
    nowSec <- (round :: Double -> Integer) . realToFrac <$> getPOSIXTime
    case JWT.readRsaSecret (TE.encodeUtf8 saPrivateKey) of
        Nothing -> pure (Left PlayUnauthorized)
        Just rsa -> do
            let signer = JWT.EncodeRSAPrivateKey rsa
                iat = JWT.numericDate (fromInteger nowSec)
                expAt = JWT.numericDate (fromInteger (nowSec + 3600))
                claims =
                    mempty
                        { JWT.iss = JWT.stringOrURI saClientEmail
                        , JWT.aud = Left <$> JWT.stringOrURI "https://oauth2.googleapis.com/token"
                        , JWT.iat = iat
                        , JWT.exp = expAt
                        , JWT.unregisteredClaims =
                            JWT.ClaimsMap $
                                Map.fromList
                                    [("scope", String "https://www.googleapis.com/auth/androidpublisher")]
                        }
                jwt = JWT.encodeSigned signer mempty claims
            exchangeJwtForToken jwt

exchangeJwtForToken :: Text -> IO (Either PlayApiError Text)
exchangeJwtForToken jwt = do
    let body =
            TE.encodeUtf8
                ( "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion="
                    <> jwt
                )
        req =
            (defaultReq "https://oauth2.googleapis.com/token")
                { reqMethod = POST
                , reqHeaders = [("Content-Type", "application/x-www-form-urlencoded")]
                , reqBody = Just (LBS.fromStrict body)
                , reqTimeout = Seconds 30
                , reqLogTag = "play-oauth"
                }
    resp <- httpJson @TokenResp req
    pure $ case resp of
        Right TokenResp{trAccessToken = t} -> Right t
        Left (HttpStatusError 401 _) -> Left PlayUnauthorized
        Left (HttpStatusError 403 _) -> Left PlayUnauthorized
        Left e -> Left (PlayHttpError 0 (T.pack (show e)))

newtype TokenResp = TokenResp {trAccessToken :: Text}

instance FromJSON TokenResp where
    parseJSON = withObject "TokenResp" $ \o -> TokenResp <$> o .: "access_token"

-- ─── Edits API ─────────────────────────────────────────────────────

playBase :: Text
playBase = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/"

createEdit :: Text -> Text -> IO (Either PlayApiError Text)
createEdit token packageName = do
    let url = playBase <> packageName <> "/edits"
        req =
            (defaultReq url)
                { reqMethod = POST
                , reqHeaders =
                    [ ("Authorization", "Bearer " <> token)
                    , ("Content-Type", "application/json")
                    ]
                , reqBody = Just "{}"
                , reqTimeout = Seconds 30
                , reqLogTag = "play-edits"
                , reqRetries = 0
                }
    resp <- httpJson @EditResp req
    pure $ case resp of
        Right EditResp{erId = eid} -> Right eid
        Left (HttpStatusError 401 _) -> Left PlayUnauthorized
        Left (HttpStatusError 404 _) -> Left (PlayPackageNotFound packageName)
        Left (HttpStatusError s b) ->
            Left (PlayHttpError s (TE.decodeUtf8 (LBS.toStrict b)))
        Left e -> Left (PlayHttpError 0 (T.pack (show e)))

newtype EditResp = EditResp {erId :: Text}

instance FromJSON EditResp where
    parseJSON = withObject "EditResp" $ \o -> EditResp <$> o .: "id"

fetchTrack ::
    Text ->
    Text ->
    Text ->
    Text ->
    IO (Either PlayApiError TrackInfo)
fetchTrack token packageName editId trackName = do
    let url = playBase <> packageName <> "/edits/" <> editId <> "/tracks/" <> trackName
        req =
            (defaultReq url)
                { reqMethod = GET
                , reqHeaders = [("Authorization", "Bearer " <> token)]
                , reqTimeout = Seconds 30
                , reqLogTag = "play-tracks"
                }
    resp <- httpRaw req
    pure $ case resp of
        Right HttpResponse{respStatus = s, respBody = b}
            | s == 200 -> case decode b :: Maybe TrackBody of
                Just tb -> Right (pickRelease tb)
                Nothing -> Left (PlayHttpError s "could not decode track body")
            | s == 401 -> Left PlayUnauthorized
            | s == 403 -> Left PlayUnauthorized
            | s == 404 -> Right (TrackInfo "0.0.0" 0)
            | otherwise -> Left (PlayHttpError s (TE.decodeUtf8 (LBS.toStrict b)))
        Left e -> Left (PlayHttpError 0 (T.pack (show e)))

deleteEdit :: Text -> Text -> Text -> IO ()
deleteEdit token packageName editId = do
    let url = playBase <> packageName <> "/edits/" <> editId
        req =
            (defaultReq url)
                { reqMethod = DELETE
                , reqHeaders = [("Authorization", "Bearer " <> token)]
                , reqTimeout = Seconds 30
                , reqLogTag = "play-edits-cleanup"
                , reqRetries = 0
                }
    _ <- httpRaw req
    pure ()

-- ─── Track body decoding ───────────────────────────────────────────

newtype TrackBody = TrackBody [Release]

data Release = Release
    { rName :: Maybe Text
    , rStatus :: Maybe Text
    , rVersionCodes :: [Text]
    }

instance FromJSON TrackBody where
    parseJSON = withObject "TrackBody" $ \o -> do
        rels <- o .:? "releases"
        pure (TrackBody (fromMaybe [] rels))

instance FromJSON Release where
    parseJSON = withObject "Release" $ \o -> do
        n <- o .:? "name"
        s <- o .:? "status"
        codes <- o .:? "versionCodes"
        pure (Release n s (fromMaybe [] (codes :: Maybe [Text])))

{- | Pick the release used for the next-version computation:

* Prefer the first release whose @status == "completed"@.
* Else fall back to the first release in the array.
* If no releases at all, return the @0.0.0@ / @0@ baseline.

The version code is the maximum across @versionCodes[]@ (Play stores a
list because a single release can ship multiple ABIs). Names default to
@0.0.0@ if missing — the bump algorithm handles that case explicitly.
-}
pickRelease :: TrackBody -> TrackInfo
pickRelease (TrackBody []) = TrackInfo "0.0.0" 0
pickRelease (TrackBody rels) =
    let chosen = case filter (\r -> rStatus r == Just "completed") rels of
            (r : _) -> r
            [] -> head rels
        name = fromMaybe "0.0.0" (rName chosen)
        codes :: [Int32]
        codes =
            [ n | t <- rVersionCodes chosen, [(n, "")] <- [reads (T.unpack t) :: [(Int32, String)]]
            ]
        code = case codes of
            [] -> 0
            xs -> maximum xs
     in TrackInfo name code

-- ─── Server-config helper ──────────────────────────────────────────

{- | Read @play_console_service_account_json@ (autopilot-scoped) from
@server_config@. Returns 'Nothing' if not configured — caller should
surface a clear error to the user.
-}
loadPlayCreds :: (MonadFlow m) => m (Maybe PlayCreds)
loadPlayCreds = do
    mVal <-
        getEnabledServerConfigValueForProduct
            "play_console_service_account_json"
            (Just "autopilot")
    pure (fmap PlayCreds mVal)

-- ─── Dispatcher entry point ────────────────────────────────────────

{- | Render a 'PlayApiError' to a stable, machine-readable tag for use in
HTTP responses and audit events. (Lifted out of @Handlers.Versions@
because the dispatcher in @Versioning@ needs the same rendering for
consistent error tags across platforms.)
-}
renderPlayErr :: PlayApiError -> Text
renderPlayErr PlayUnauthorized = "play_unauthorized"
renderPlayErr (PlayPackageNotFound pkg) = "play_package_not_found:" <> pkg
renderPlayErr (PlayHttpError s body) =
    "play_http_error:" <> T.pack (show s) <> ":" <> body

{- | High-level entry point used by @Versioning.resolveNextVersion@.
Loads creds + calls 'fetchPlayTracks' + runs 'computeNextVersion'.
Returns a stable error tag on the @Left@ side so callers can include it
in audit events and HTTP responses without a separate render step.
-}
resolve ::
    (MonadFlow m) =>
    -- | Bundle / package name (carried in @app_catalog.package_name@).
    Text ->
    m (Either Text (Text, Int32))
resolve packageName = do
    mCreds <- loadPlayCreds
    case mCreds of
        Nothing ->
            pure (Left "play_console_service_account_json not configured in server_config")
        Just creds -> do
            res <- fetchPlayTracks creds packageName
            case res of
                Left e -> pure (Left (renderPlayErr e))
                Right (internal, production) ->
                    pure (Right (computeNextVersion internal production))
