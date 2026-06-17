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
    getProductionReleaseNotes,
    loadPlayCreds,
    renderPlayErr,

    -- * Staged rollout (promote → set/halt/resume/complete → read)
    PlayRolloutState (..),
    promoteToProduction,
    setTrackRollout,
    haltTrackRollout,
    resumeTrackRollout,
    completeTrackRollout,
    getTrackRolloutState,
    userFractionInRange,
    parseRolloutState,
    parseProdReleaseNotes,

    -- * Out-of-band pending-publish detection (production-track read)
    ProdTrackRelease (..),
    getProductionReleases,
    parseProdTrackReleases,

    -- * Per-track snapshots (App Release Monitoring)
    StoreTrackSnapshot (..),
    fetchTrackSnapshots,
    parseTrackSnapshot,

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
import Core.Secrets (lookupEnvSecretB64)
import Core.Types.Time (Seconds (..))
import Data.Aeson (
    FromJSON (..),
    ToJSON (..),
    Value (..),
    decode,
    eitherDecode,
    encode,
    object,
    withObject,
    (.!=),
    (.:),
    (.:?),
    (.=),
 )
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int32)
import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import GHC.Generics (Generic)
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
    | -- | A staged-rollout userFraction outside the open interval (0,1).
      PlayInvalidFraction Double
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
    , rUserFraction :: Maybe Double
    , rVersionCodes :: [Text]
    , rReleaseNotes :: [Text]
    -- ^ per-locale "What's New" texts (@releaseNotes[].text@), if any.
    }

-- | One @releaseNotes[]@ entry — we only need its @text@.
newtype RNote = RNote (Maybe Text)

instance FromJSON RNote where
    parseJSON = withObject "RNote" $ \o -> RNote <$> o .:? "text"

instance FromJSON TrackBody where
    parseJSON = withObject "TrackBody" $ \o -> do
        rels <- o .:? "releases"
        pure (TrackBody (fromMaybe [] rels))

instance FromJSON Release where
    parseJSON = withObject "Release" $ \o -> do
        n <- o .:? "name"
        s <- o .:? "status"
        uf <- o .:? "userFraction"
        codes <- o .:? "versionCodes"
        notes <- o .:? "releaseNotes" .!= []
        pure (Release n s uf (fromMaybe [] (codes :: Maybe [Text])) (mapMaybe (\(RNote t) -> t) notes))

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
     in TrackInfo name (maxVersionCode (rVersionCodes chosen))

{- | The highest parseable @versionCodes[]@ entry (Play lists multiple codes when
a release ships several ABIs). 0 when none parse. Shared by the next-version
read and the pending-publish detection. -}
maxVersionCode :: [Text] -> Int32
maxVersionCode codes =
    case [n | t <- codes, [(n, "")] <- [reads (T.unpack t) :: [(Int32, String)]]] of
        [] -> 0
        xs -> maximum xs

-- ─── Staged rollout: promote / set / halt / resume / complete / read ───────

{- | Current production-track rollout snapshot, read from the active release in
@releases[]@. @prsStatus@ is the raw Play status
(@inProgress@ | @halted@ | @completed@ | @draft@), or @none@ when the track has
no release yet.
-}
data PlayRolloutState = PlayRolloutState
    { prsStatus :: Text
    , prsUserFraction :: Maybe Double
    , prsVersionCodes :: [Text]
    }
    deriving (Eq, Show, Generic)

instance ToJSON PlayRolloutState
instance FromJSON PlayRolloutState

{- | Play accepts a staged-rollout @userFraction@ strictly between 0 and 1. 0, 1
and out-of-range are rejected — for 100% use 'completeTrackRollout'
(status=completed, no fraction), never @userFraction = 1.0@.
-}
userFractionInRange :: Double -> Bool
userFractionInRange f = f > 0 && f < 1

-- | The production-track release object we PUT (the sole entry in @releases[]@).
data ProdRelease = ProdRelease
    { prVersionCodes :: [Text]
    , prStatus :: Text
    , prUserFraction :: Maybe Double
    , prReleaseNotes :: Maybe [(Text, Text)]
    -- ^ (language, text); set only on promote.
    }

instance ToJSON ProdRelease where
    toJSON pr =
        object $
            [ "versionCodes" .= prVersionCodes pr
            , "status" .= prStatus pr
            ]
                <> maybe [] (\f -> ["userFraction" .= f]) (prUserFraction pr)
                <> maybe [] (\ns -> ["releaseNotes" .= map noteObj ns]) (prReleaseNotes pr)
      where
        noteObj (lang, txt) = object ["language" .= lang, "text" .= txt]

{- | Promote the built (internal-track) build to the PRODUCTION track at an
effectively-zero rollout and send it to review. The near-zero @userFraction@
(config @android_review_rollout_fraction@, default 1e-9) means approval exposes
no users — the operator later bumps it via 'setTrackRollout'. The commit does
NOT pass @changesNotSentForReview@, so Google reviews it.
-}
promoteToProduction ::
    (MonadFlow m) =>
    PlayCreds ->
    -- | package name
    Text ->
    -- | version code
    Text ->
    -- | initial (≈0) rollout fraction
    Double ->
    -- | release notes (language, text)
    [(Text, Text)] ->
    m (Either PlayApiError ())
promoteToProduction creds pkg vc frac notes =
    applyProductionRelease creds pkg (ProdRelease [vc] "inProgress" (Just frac) (Just notes))

-- | Set the production rollout to @frac@ (0 < frac < 1); status stays inProgress.
setTrackRollout :: (MonadFlow m) => PlayCreds -> Text -> Text -> Double -> m (Either PlayApiError ())
setTrackRollout creds pkg vc frac =
    applyProductionRelease creds pkg (ProdRelease [vc] "inProgress" (Just frac) Nothing)

-- | Pause the rollout (status=halted) at its current fraction.
haltTrackRollout :: (MonadFlow m) => PlayCreds -> Text -> Text -> Double -> m (Either PlayApiError ())
haltTrackRollout creds pkg vc frac =
    applyProductionRelease creds pkg (ProdRelease [vc] "halted" (Just frac) Nothing)

-- | Resume a halted rollout (status=inProgress) at @frac@.
resumeTrackRollout :: (MonadFlow m) => PlayCreds -> Text -> Text -> Double -> m (Either PlayApiError ())
resumeTrackRollout creds pkg vc frac =
    applyProductionRelease creds pkg (ProdRelease [vc] "inProgress" (Just frac) Nothing)

-- | Finish the rollout — 100% of users (status=completed, no fraction).
completeTrackRollout :: (MonadFlow m) => PlayCreds -> Text -> Text -> m (Either PlayApiError ())
completeTrackRollout creds pkg vc =
    applyProductionRelease creds pkg (ProdRelease [vc] "completed" Nothing Nothing)

{- | create edit → PUT the production-track release → commit (→ review). A
fraction outside (0,1) is rejected before any API call.
-}
applyProductionRelease ::
    (MonadFlow m) => PlayCreds -> Text -> ProdRelease -> m (Either PlayApiError ())
applyProductionRelease creds pkg pr
    | Just f <- prUserFraction pr
    , not (userFractionInRange f) =
        pure (Left (PlayInvalidFraction f))
    | otherwise = liftIO $ withPlayToken creds $ \token -> do
        eEdit <- createEdit token pkg
        case eEdit of
            Left e -> pure (Left e)
            Right editId -> do
                ePut <- putProductionTrack token pkg editId pr
                case ePut of
                    Left e -> do
                        _ <- try @SomeException (deleteEdit token pkg editId)
                        pure (Left e)
                    Right () -> commitEdit token pkg editId

-- | Read the current production rollout state (status + fraction + version codes).
getTrackRolloutState ::
    (MonadFlow m) => PlayCreds -> Text -> m (Either PlayApiError PlayRolloutState)
getTrackRolloutState creds pkg = liftIO $ withPlayToken creds $ \token -> do
    eEdit <- createEdit token pkg
    case eEdit of
        Left e -> pure (Left e)
        Right editId -> do
            res <- getProductionTrack token pkg editId
            _ <- try @SomeException (deleteEdit token pkg editId) -- read-only: discard edit
            pure res

{- | Read the current production-track "What's New" / release notes (first
non-empty locale text of the live/last release). Used to pre-fill the promote
dialog for a store-synced release, where SCC has no changelog of its own.
'Nothing' when the track has no release with notes. Read-only: the throwaway
edit is abandoned. -}
getProductionReleaseNotes ::
    (MonadFlow m) => PlayCreds -> Text -> m (Either PlayApiError (Maybe Text))
getProductionReleaseNotes creds pkg = liftIO $ withPlayToken creds $ \token -> do
    eEdit <- createEdit token pkg
    case eEdit of
        Left e -> pure (Left e)
        Right editId -> do
            res <- getProductionTrackNotes token pkg editId
            _ <- try @SomeException (deleteEdit token pkg editId) -- read-only: discard edit
            pure res

-- | GET the production track and parse the first non-empty release-notes text.
getProductionTrackNotes :: Text -> Text -> Text -> IO (Either PlayApiError (Maybe Text))
getProductionTrackNotes token pkg editId = do
    let url = playBase <> pkg <> "/edits/" <> editId <> "/tracks/production"
        req =
            (defaultReq url)
                { reqMethod = GET
                , reqHeaders = [("Authorization", "Bearer " <> token)]
                , reqTimeout = Seconds 30
                , reqLogTag = "play-track-notes"
                }
    resp <- httpRaw req
    pure $ case resp of
        Right HttpResponse{respStatus = s, respBody = b}
            | s == 200 -> Right (parseProdReleaseNotes b)
            | s == 401 || s == 403 -> Left PlayUnauthorized
            | s == 404 -> Right Nothing
            | otherwise -> Left (PlayHttpError s (TE.decodeUtf8 (LBS.toStrict b)))
        Left e -> Left (PlayHttpError 0 (T.pack (show e)))

-- | First non-empty release-notes text from a production-track GET body. Prefers
-- the @completed@ release, else the first release. Exposed for unit testing.
parseProdReleaseNotes :: LBS.ByteString -> Maybe Text
parseProdReleaseNotes bs = do
    TrackBody rels <- decode bs
    chosen <- case filter (\r -> rStatus r == Just "completed") rels of
        (r : _) -> Just r
        [] -> listToMaybe rels
    find (not . T.null . T.strip) (rReleaseNotes chosen)

-- ─── Out-of-band pending-publish detection (production-track read) ──────────

{- | One production-track release, flattened for pending-publish detection:
its name, highest version code, raw Play @status@ (@inProgress@ | @halted@ |
@completed@ | @draft@) and @userFraction@ (present only for a staged rollout).

Unlike 'PlayRolloutState' (which collapses the track to a single chosen
release), this keeps every release so the caller can compare an in-flight
submission against the live (@completed@) one. -}
data ProdTrackRelease = ProdTrackRelease
    { ptrName :: Text
    , ptrCode :: Int32
    , ptrStatus :: Text
    , ptrUserFraction :: Maybe Double
    }
    deriving (Eq, Show, Generic)

instance ToJSON ProdTrackRelease
instance FromJSON ProdTrackRelease

{- | Read every release on the production track (name, code, status, fraction).
Read-only: the throwaway edit is abandoned, like 'getProductionReleaseNotes'.
404 (no production track yet) → an empty list. -}
getProductionReleases ::
    (MonadFlow m) => PlayCreds -> Text -> m (Either PlayApiError [ProdTrackRelease])
getProductionReleases creds pkg = liftIO $ withPlayToken creds $ \token -> do
    eEdit <- createEdit token pkg
    case eEdit of
        Left e -> pure (Left e)
        Right editId -> do
            res <- getProductionTrackReleases token pkg editId
            _ <- try @SomeException (deleteEdit token pkg editId) -- read-only: discard edit
            pure res

-- | GET the production track and parse all of its releases.
getProductionTrackReleases :: Text -> Text -> Text -> IO (Either PlayApiError [ProdTrackRelease])
getProductionTrackReleases token pkg editId = do
    let url = playBase <> pkg <> "/edits/" <> editId <> "/tracks/production"
        req =
            (defaultReq url)
                { reqMethod = GET
                , reqHeaders = [("Authorization", "Bearer " <> token)]
                , reqTimeout = Seconds 30
                , reqLogTag = "play-track-pending"
                }
    resp <- httpRaw req
    pure $ case resp of
        Right HttpResponse{respStatus = s, respBody = b}
            | s == 200 -> Right (parseProdTrackReleases b)
            | s == 401 || s == 403 -> Left PlayUnauthorized
            | s == 404 -> Right []
            | otherwise -> Left (PlayHttpError s (TE.decodeUtf8 (LBS.toStrict b)))
        Left e -> Left (PlayHttpError 0 (T.pack (show e)))

{- | Pure parse of a production-track GET body into every release it lists.
Missing @name@ → "0.0.0"; missing @status@ → "draft". Exposed for unit testing.
A body that doesn't decode → an empty list (no releases). -}
parseProdTrackReleases :: LBS.ByteString -> [ProdTrackRelease]
parseProdTrackReleases bs = case decode bs :: Maybe TrackBody of
    Nothing -> []
    Just (TrackBody rels) -> map toPTR rels
  where
    toPTR r =
        ProdTrackRelease
            { ptrName = fromMaybe "0.0.0" (rName r)
            , ptrCode = maxVersionCode (rVersionCodes r)
            , ptrStatus = fromMaybe "draft" (rStatus r)
            , ptrUserFraction = rUserFraction r
            }

-- ─── Per-track snapshots (App Release Monitoring) ──────────────────────────

{- | A single store track's current state for the release-monitoring dashboard:
the leading release's version / code / status / staged-rollout fraction, plus the
first non-empty "What's New" note. -}
data StoreTrackSnapshot = StoreTrackSnapshot
    { stsTrack :: Text
    -- ^ "production" | "internal"
    , stsVersion :: Text
    , stsCode :: Maybe Int32
    , stsStatus :: Text
    -- ^ completed | inProgress | halted | draft | none
    , stsFraction :: Maybe Double
    -- ^ staged-rollout userFraction (production only)
    , stsNotes :: Maybe Text
    }
    deriving (Eq, Show, Generic)

instance ToJSON StoreTrackSnapshot
instance FromJSON StoreTrackSnapshot

{- | Fetch the production + internal track snapshots for a Play package in one edit
round-trip (create edit → GET both tracks → discard edit). Read-only. -}
fetchTrackSnapshots ::
    (MonadFlow m) => PlayCreds -> Text -> m (Either PlayApiError [StoreTrackSnapshot])
fetchTrackSnapshots (PlayCreds saJson) packageName =
    case parseServiceAccount saJson of
        Left e -> do
            logError $ "[play-console] bad service-account JSON: " <> T.pack e
            pure (Left PlayUnauthorized)
        Right sa -> liftIO (runFetchSnapshots sa packageName)

runFetchSnapshots :: ServiceAccount -> Text -> IO (Either PlayApiError [StoreTrackSnapshot])
runFetchSnapshots sa packageName = do
    eToken <- mintAndExchange sa
    case eToken of
        Left err -> pure (Left err)
        Right token -> do
            eEdit <- createEdit token packageName
            case eEdit of
                Left err -> pure (Left err)
                Right editId -> do
                    eInternal <- fetchTrackBody token packageName editId "internal"
                    eProd <- fetchTrackBody token packageName editId "production"
                    _ <- try @SomeException (deleteEdit token packageName editId)
                    pure $
                        (\i p -> [parseTrackSnapshot "internal" i, parseTrackSnapshot "production" p])
                            <$> eInternal
                            <*> eProd

-- | GET a track and return the raw body (404 → "{}" so it parses to the "none"
-- snapshot). Like 'fetchTrack', but defers parsing to 'parseTrackSnapshot'.
fetchTrackBody :: Text -> Text -> Text -> Text -> IO (Either PlayApiError LBS.ByteString)
fetchTrackBody token packageName editId trackName = do
    let url = playBase <> packageName <> "/edits/" <> editId <> "/tracks/" <> trackName
        req =
            (defaultReq url)
                { reqMethod = GET
                , reqHeaders = [("Authorization", "Bearer " <> token)]
                , reqTimeout = Seconds 30
                , reqLogTag = "play-track-snapshot"
                }
    resp <- httpRaw req
    pure $ case resp of
        Right HttpResponse{respStatus = s, respBody = b}
            | s == 200 -> Right b
            | s == 401 || s == 403 -> Left PlayUnauthorized
            | s == 404 -> Right "{}"
            | otherwise -> Left (PlayHttpError s (TE.decodeUtf8 (LBS.toStrict b)))
        Left e -> Left (PlayHttpError 0 (T.pack (show e)))

{- | Parse a track GET body into a 'StoreTrackSnapshot' — the leading release
(active staged rollout if any, else the latest) with its version / code / status /
fraction / first non-empty note. Empty / undecodable → the "none" snapshot.
Exposed for unit testing. -}
parseTrackSnapshot :: Text -> LBS.ByteString -> StoreTrackSnapshot
parseTrackSnapshot track bs = case decode bs :: Maybe TrackBody of
    Just (TrackBody rels)
        | Just r <- pickRolloutRelease rels ->
            StoreTrackSnapshot
                { stsTrack = track
                , stsVersion = fromMaybe "0.0.0" (rName r)
                , stsCode = case maxVersionCode (rVersionCodes r) of 0 -> Nothing; n -> Just n
                , stsStatus = fromMaybe "draft" (rStatus r)
                , stsFraction = rUserFraction r
                , stsNotes = find (not . T.null . T.strip) (rReleaseNotes r)
                }
    _ -> StoreTrackSnapshot track "0.0.0" Nothing "none" Nothing Nothing

-- ── IO helpers ──

-- | Run an IO action with a fresh OAuth token minted from the creds.
withPlayToken :: PlayCreds -> (Text -> IO (Either PlayApiError a)) -> IO (Either PlayApiError a)
withPlayToken (PlayCreds saJson) k =
    case parseServiceAccount saJson of
        Left _ -> pure (Left PlayUnauthorized)
        Right sa -> do
            eTok <- mintAndExchange sa
            case eTok of
                Left e -> pure (Left e)
                Right tok -> k tok

putProductionTrack :: Text -> Text -> Text -> ProdRelease -> IO (Either PlayApiError ())
putProductionTrack token pkg editId pr = do
    let url = playBase <> pkg <> "/edits/" <> editId <> "/tracks/production"
        payload = encode (object ["track" .= ("production" :: Text), "releases" .= [pr]])
        req =
            (defaultReq url)
                { reqMethod = PUT
                , reqHeaders =
                    [ ("Authorization", "Bearer " <> token)
                    , ("Content-Type", "application/json")
                    ]
                , reqBody = Just payload
                , reqTimeout = Seconds 30
                , reqLogTag = "play-track-put"
                , reqRetries = 0
                }
    classifyEmpty pkg <$> httpRaw req

{- | Commit the edit, sending it to review. Deliberately NO
@changesNotSentForReview@ query param — that flag would hold it back from review.
-}
commitEdit :: Text -> Text -> Text -> IO (Either PlayApiError ())
commitEdit token pkg editId = do
    let url = playBase <> pkg <> "/edits/" <> editId <> ":commit"
        req =
            (defaultReq url)
                { reqMethod = POST
                , reqHeaders =
                    [ ("Authorization", "Bearer " <> token)
                    , ("Content-Type", "application/json")
                    ]
                , reqBody = Just "{}"
                , reqTimeout = Seconds 60
                , reqLogTag = "play-edits-commit"
                , reqRetries = 0
                }
    classifyEmpty pkg <$> httpRaw req

getProductionTrack :: Text -> Text -> Text -> IO (Either PlayApiError PlayRolloutState)
getProductionTrack token pkg editId = do
    let url = playBase <> pkg <> "/edits/" <> editId <> "/tracks/production"
        req =
            (defaultReq url)
                { reqMethod = GET
                , reqHeaders = [("Authorization", "Bearer " <> token)]
                , reqTimeout = Seconds 30
                , reqLogTag = "play-track-get"
                }
    resp <- httpRaw req
    pure $ case resp of
        Right HttpResponse{respStatus = s, respBody = b}
            | s == 200 -> case parseRolloutState b of
                Just st -> Right st
                Nothing -> Left (PlayHttpError s "could not decode production track")
            | s == 401 || s == 403 -> Left PlayUnauthorized
            | s == 404 -> Right emptyRolloutState
            | otherwise -> Left (PlayHttpError s (TE.decodeUtf8 (LBS.toStrict b)))
        Left e -> Left (PlayHttpError 0 (T.pack (show e)))

-- | Map an empty-body Play response to @()@ / a typed error.
classifyEmpty :: Text -> Either HttpError HttpResponse -> Either PlayApiError ()
classifyEmpty pkg resp = case resp of
    Right HttpResponse{respStatus = s, respBody = b}
        | s >= 200 && s < 300 -> Right ()
        | s == 401 || s == 403 -> Left PlayUnauthorized
        | s == 404 -> Left (PlayPackageNotFound pkg)
        | otherwise -> Left (PlayHttpError s (TE.decodeUtf8 (LBS.toStrict b)))
    Left e -> Left (PlayHttpError 0 (T.pack (show e)))

emptyRolloutState :: PlayRolloutState
emptyRolloutState = PlayRolloutState "none" Nothing []

{- | Pure parse of a production-track GET body into a 'PlayRolloutState'. Picks
the active staged release (status inProgress/halted), else the first release,
else the empty/none state. Exposed for unit testing.
-}
parseRolloutState :: LBS.ByteString -> Maybe PlayRolloutState
parseRolloutState bs = do
    TrackBody rels <- decode bs
    pure $ case pickRolloutRelease rels of
        Nothing -> emptyRolloutState
        Just r ->
            PlayRolloutState
                { prsStatus = fromMaybe "draft" (rStatus r)
                , prsUserFraction = rUserFraction r
                , prsVersionCodes = rVersionCodes r
                }

pickRolloutRelease :: [Release] -> Maybe Release
pickRolloutRelease rels =
    case filter (\r -> rStatus r `elem` [Just "inProgress", Just "halted"]) rels of
        (r : _) -> Just r
        [] -> case rels of
            (r : _) -> Just r
            [] -> Nothing

-- ─── Server-config helper ──────────────────────────────────────────

{- | Read the Play Console service-account JSON from the process
__environment__ — @SC_PLAY_SA_JSON_B64@ (the JSON, base64-encoded). Injected
from a k8s Secret in prod; from @local-mobile-secrets.env@ in dev. Returns
'Nothing' if not configured — caller surfaces a clear error to the user.
-}
loadPlayCreds :: (MonadFlow m) => m (Maybe PlayCreds)
loadPlayCreds = fmap (fmap PlayCreds) (lookupEnvSecretB64 "SC_PLAY_SA_JSON_B64")

-- ─── Dispatcher entry point ────────────────────────────────────────

{- | Render a 'PlayApiError' to a stable, machine-readable tag for use in
HTTP responses and audit events. (Lifted out of @Handlers.Versions@
because the dispatcher in @Versioning@ needs the same rendering for
consistent error tags across platforms.)
-}
renderPlayErr :: PlayApiError -> Text
renderPlayErr PlayUnauthorized = "play_unauthorized"
renderPlayErr (PlayPackageNotFound pkg) = "play_package_not_found:" <> pkg
renderPlayErr (PlayInvalidFraction f) = "play_invalid_fraction:" <> T.pack (show f)
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
            pure (Left "Play service-account JSON not configured (set SC_PLAY_SA_JSON_B64)")
        Just creds -> do
            res <- fetchPlayTracks creds packageName
            case res of
                Left e -> pure (Left (renderPlayErr e))
                Right (internal, production) ->
                    pure (Right (computeNextVersion internal production))
