{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | App Store Connect (Apple) client + version-bump logic for iOS.

Mirrors the shape of "Products.Autopilot.Mobile.Versioning.Play":

* Pure algorithm 'computeNextIosVersion' bumps the patch component of
  the latest TestFlight version. Same heuristic as the iOS workflow's
  inline Python (@fastlane.yaml:261-346@).
* IO-side ('fetchAscVersions') signs an ES256 JWT with the @.p8@
  private key from @server_config@, looks up the numeric ASC app id by
  bundle id, then asks the App Store Connect API for the latest
  pre-release (TestFlight) build.

JWT signing is **inlined here** (no separate @Apple/Auth.hs@) to match
Play's shape — Play also signs its JWT inline in this same directory's
@Play.hs@. The trade-off is no IORef-backed token cache: ASC version
resolution happens at most a handful of times per release row, so the
cost of re-minting a fresh JWT per call is negligible. If iOS volume
grows and ASC starts throttling, lift the signer into a sibling
@Apple\/Auth.hs@ module with caching — see @Mobile\/Github\/Auth.hs@ for
the pattern.

Unlike Play, the ASC JWT is **used directly as the bearer token**;
there is no OAuth exchange step. Apple's API auth model is one
JWT-per-request, max 20-minute expiry.
-}
module Products.Autopilot.Mobile.Versioning.Apple (
    -- * Pure version-bump algorithm
    computeNextIosVersion,

    -- * App Store Connect API client
    AscCreds (..),
    AscError (..),
    fetchAscVersions,
    loadAscCreds,
    mintAscToken,
    renderAscErr,

    -- * Staged review + rollout (submit → poll → release → phased)
    AscReviewState (..),
    AscPhasedState (..),
    AscVersion (..),
    appStoreStateToReview,
    applePhasedPercent,
    parseAscVersion,
    getAscReviewState,
    submitVersionForReview,
    releaseApprovedVersion,
    getBuildProcessingState,
    enablePhasedRelease,
    pausePhasedRelease,
    resumePhasedRelease,
    completePhasedRelease,
    getPhasedReleaseState,

    -- * Dispatcher entry points
    resolve,
    resolveWithToken,
) where

import Control.Exception (Exception)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Core.Environment (MonadFlow)
import Core.Http.Client (
    HttpError (..),
    HttpReq (..),
    HttpResponse (..),
    Method (..),
    defaultReq,
    httpJson,
    httpRaw,
 )
import Core.Secrets (lookupEnvSecret, lookupEnvSecretB64)
import Core.Types.Time (Seconds (..))
import Crypto.Hash.Algorithms (SHA256 (..))
import qualified Crypto.PubKey.ECC.ECDSA as ECDSA
import qualified Crypto.PubKey.ECC.Types as ECC
import qualified Crypto.Random.Types as CRT
import Data.ASN1.BinaryEncoding (DER (..))
import Data.ASN1.Encoding (decodeASN1')
import Data.ASN1.Types (
    ASN1 (End, IntVal, OID, OctetString, Other, Start),
    ASN1ConstructionType (Container, Sequence),
 )
import Data.Aeson (
    FromJSON (..),
    Value,
    decode,
    encode,
    object,
    withObject,
    (.:),
    (.:?),
    (.=),
 )
import Data.Bits (shiftR, (.&.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Base64.URL as B64U
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime)

-- ─── Pure algorithm ────────────────────────────────────────────────

{- | Bump the patch component of the latest TestFlight version, or
return @"1.0.0"@ if there's no TestFlight history.

Mirrors the iOS workflow's inline Python (@fastlane.yaml:332-339@):
@if testflight_version is None: next = "1.0.0" else: bump patch@.

The iOS build number is NOT computed here — the workflow's
@fastlane fetch_build_number@ resolves it inside the runner. SCC only
provides the @version_number@ semver string; the build number lands on
the row later via the pushed tag's @+NNN@ suffix.
-}
computeNextIosVersion :: Maybe Text -> Text
computeNextIosVersion Nothing = "1.0.0"
computeNextIosVersion (Just tf) = bumpPatch tf

{- | Increment the last dotted numeric component. Non-numeric tail is
left untouched (caller-controlled input). Matches the bump logic in
@Versioning.Play.bumpPatch@ — duplicated rather than shared so each
module is fully self-contained.
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

-- ─── ASC credentials + errors ──────────────────────────────────────

{- | App Store Connect API key, read from the process environment via
'loadAscCreds' (never the DB):

* @SC_ASC_ISSUER_ID@   — UUID from "Users and Access → Integrations".
* @SC_ASC_KEY_ID@      — 10-char string next to the generated key.
* @SC_ASC_PRIVATE_KEY_P8_B64@ — the @.p8@ PEM, base64-encoded.
-}
data AscCreds = AscCreds
    { acIssuerId :: Text
    , acKeyId :: Text
    , acP8 :: Text
    }

data AscError
    = -- | Missing one or more of the three @app_store_connect_*@ rows.
      AscCredsMissing
    | -- | JWT couldn't be signed (malformed @.p8@).
      AscJwtSigningFailed Text
    | -- | The bundle id doesn't match any app the configured key can see —
      -- likely either a wrong bundle id, or the key's Apple team doesn't
      -- have access to this app.
      AscAppNotFound Text
    | -- | API auth failed (401/403).
      AscUnauthorized
    | -- | No App Store version matched the requested versionString.
      AscVersionNotFound Text
    | -- | The attached build is not done processing (not VALID) — can't submit yet.
      AscBuildNotReady Text
    | -- | Any other HTTP error.
      AscHttpError Int Text
    deriving (Show)

instance Exception AscError

{- | Fetch the latest TestFlight build version for a given iOS bundle id.

Steps:

1. Mint an ES256-signed JWT (20-minute expiry).
2. @GET \/v1\/apps?filter[bundleId]=<bundle_id>@ → take @data[0].id@
   as the numeric ASC app id. Errors with 'AscAppNotFound' if the list
   is empty.
3. @GET \/v1\/builds?filter[app]=<asc_id>&sort=-uploadedDate&limit=1
   &include=preReleaseVersion@ → take the included
   @preReleaseVersion.attributes.version@.

Returns @Right Nothing@ if there is no TestFlight history for the app
(first-ever release case; caller defaults to @"1.0.0"@). Returns
@Right (Just v)@ if a TestFlight version exists.
-}
fetchAscVersions ::
    (MonadFlow m) =>
    AscCreds ->
    -- | iOS bundle id (from @app_catalog.package_name@ on iOS rows).
    Text ->
    m (Either AscError (Maybe Text))
fetchAscVersions creds bundleId = liftIO (runFetch creds bundleId)

-- ─── Live ASC call (IO-only) ───────────────────────────────────────

runFetch :: AscCreds -> Text -> IO (Either AscError (Maybe Text))
runFetch creds bundleId = do
    eToken <- mintAscToken creds
    case eToken of
        Left err -> pure (Left err)
        Right token -> runFetchWithToken token bundleId

runFetchWithToken :: Text -> Text -> IO (Either AscError (Maybe Text))
runFetchWithToken token bundleId = do
    eAppId <- lookupAppByBundleId token bundleId
    case eAppId of
        Left err -> pure (Left err)
        Right appId -> fetchLatestTestFlightVersion token appId

-- ─── JWT minting (ES256, inlined) ──────────────────────────────────

{- | Sign an ES256 JWT for the App Store Connect API.

Token shape (per Apple's docs):

* Header: @{ alg: "ES256", kid: <ascKeyId>, typ: "JWT" }@.
* Payload: @{ iss: <ascIssuerId>, iat: now, exp: now + 1200,
  aud: "appstoreconnect-v1" }@.

The token IS the bearer — no OAuth exchange step (unlike Play).

Implementation:

1. Parse the .p8 PEM into a P-256 ECDSA private key. Apple's
   distributed @.p8@ files are PKCS#8 PrivateKeyInfo (RFC 5208)
   wrapping an ECPrivateKey (RFC 5915) on the @secp256r1@ / @P-256@
   curve. See 'parseEcP256PrivateKey'.
2. Build the JWS signing input: @base64url(header) <> \".\" <> base64url(claims)@.
3. SHA-256 + ECDSA-sign with the P-256 key.
4. Convert the ASN.1-encoded ECDSA signature into the JWS wire format
   (raw R || S, 64 bytes total, big-endian, zero-padded). See
   'ecdsaSigToRaw'.
5. Concatenate: @signing_input <> \".\" <> base64url(signature)@.

Built on @cryptonite@ — no new dependency. PyJWT does the same thing
in the iOS workflow's auto-detect (fastlane.yaml:290-298).
-}
mintAscToken :: AscCreds -> IO (Either AscError Text)
mintAscToken AscCreds{..} = do
    case parseEcP256PrivateKey acP8 of
        Left e -> pure (Left (AscJwtSigningFailed (T.pack e)))
        Right privKey -> do
            nowSec <- (round :: Double -> Integer) . realToFrac <$> getPOSIXTime
            let header :: Value
                header = object ["alg" .= ("ES256" :: Text), "kid" .= acKeyId, "typ" .= ("JWT" :: Text)]
                claims :: Value
                claims =
                    object
                        [ "iss" .= acIssuerId
                        , "iat" .= nowSec
                        , "exp" .= (nowSec + 1200) -- 20 min, Apple's max
                        , "aud" .= ("appstoreconnect-v1" :: Text)
                        ]
                headerB64 = b64url (LBS.toStrict (encode header))
                claimsB64 = b64url (LBS.toStrict (encode claims))
                signingInput = headerB64 <> "." <> claimsB64
            -- cryptonite's ECDSA.sign uses the supplied MonadRandom for
            -- the nonce. CRT.MonadRandom IO uses the system entropy
            -- source, which is what we want for production signing.
            asn1Sig <- ECDSA.sign privKey SHA256 signingInput
            let rawSig = ecdsaSigToRaw asn1Sig
                token = signingInput <> "." <> b64url rawSig
            pure (Right (TE.decodeUtf8 token))

-- ─── ES256 signing helpers ─────────────────────────────────────────

-- | Base64url-encode without padding (RFC 7515 §2 \"Base64url Encoding\").
b64url :: BS.ByteString -> BS.ByteString
b64url = B64U.encodeUnpadded

{- | Convert cryptonite's ASN.1 (r, s) ECDSA signature into the JWS
ES256 wire format: 64 bytes total = 32-byte big-endian @r@ followed by
32-byte big-endian @s@. Apple's API expects this format (the JWS spec,
RFC 7515 §3.4).
-}
ecdsaSigToRaw :: ECDSA.Signature -> BS.ByteString
ecdsaSigToRaw (ECDSA.Signature r s) = pad32 r <> pad32 s
  where
    pad32 :: Integer -> BS.ByteString
    pad32 n =
        let bs = integerToBE n
            l = BS.length bs
         in if l >= 32 then BS.drop (l - 32) bs else BS.replicate (32 - l) 0 <> bs

    -- Big-endian unsigned integer → bytes. Always produces at least one byte.
    integerToBE :: Integer -> BS.ByteString
    integerToBE n0
        | n0 == 0 = BS.singleton 0
        | otherwise = BS.pack (go n0 [])
      where
        go 0 acc = acc
        go n acc = go (n `shiftR` 8) (fromIntegral (n .&. 0xff) : acc)

{- | Parse a PKCS#8 PEM-encoded EC private key on the P-256 curve.

Apple's @.p8@ file format:

@
-----BEGIN PRIVATE KEY-----
<base64 of PKCS#8 PrivateKeyInfo>
-----END PRIVATE KEY-----
@

ASN.1 structure (RFC 5208 + RFC 5915):

> PrivateKeyInfo ::= SEQUENCE {
>   version              INTEGER 0,
>   privateKeyAlgorithm  AlgorithmIdentifier (id-ecPublicKey + namedCurve),
>   privateKey           OCTET STRING wrapping ECPrivateKey
> }
>
> ECPrivateKey ::= SEQUENCE {
>   version      INTEGER 1,
>   privateKey   OCTET STRING (the raw 32-byte scalar),
>   parameters   [0] EXPLICIT ECParameters OPTIONAL,
>   publicKey    [1] EXPLICIT BIT STRING OPTIONAL
> }

We don't validate the embedded curve OID — Apple only issues P-256
keys for App Store Connect, so we assume P-256. If a non-P-256 key
ever sneaks in, the downstream ECDSA.sign will produce a signature
Apple rejects with a clear 401, and the runner will surface it as
@asc_unauthorized@.
-}
parseEcP256PrivateKey :: Text -> Either String ECDSA.PrivateKey
parseEcP256PrivateKey pem = do
    body <- stripPemHeaders (TE.encodeUtf8 pem)
    -- Apple's .p8 files are standard base64 (with padding). Try standard
    -- first; fall back to base64url for any pasted/mangled keys.
    der <- case extractBase64Standard body of
        Right ok -> Right ok
        Left _ ->
            case B64U.decodeUnpadded body of
                Right ok -> Right ok
                Left e -> Left ("could not decode PEM body as base64: " <> show e)
    asn1 <- mapLeft show (decodeASN1' DER der)
    scalar <- extractScalar asn1
    let curve = ECC.getCurveByName ECC.SEC_p256r1
    Right (ECDSA.PrivateKey curve scalar)
  where
    mapLeft :: (a -> b) -> Either a c -> Either b c
    mapLeft f (Left a) = Left (f a)
    mapLeft _ (Right c) = Right c

{- | Strip `-----BEGIN ... -----` / `-----END ... -----` lines and any
whitespace from a PEM blob, returning just the inner base64 body.
Tolerant of CRLF and trailing whitespace.
-}
stripPemHeaders :: BS.ByteString -> Either String BS.ByteString
stripPemHeaders raw =
    let ls = BC.split '\n' raw
        notHeader l =
            let s = BC.dropWhile (`elem` (" \t\r" :: String)) l
             in not (BS.isPrefixOf "-----" s)
        body = BS.concat (map (BS.filter (\c -> c /= 10 && c /= 13 && c /= 32 && c /= 9)) (filter notHeader ls))
     in if BS.null body
            then Left "PEM body is empty"
            else Right body

-- | Decode standard base64 (handles padding).
extractBase64Standard :: BS.ByteString -> Either String BS.ByteString
extractBase64Standard input =
    case B64.decode input of
        Right b -> Right b
        Left e -> Left ("base64 decode failed: " <> e)

{- | Walk the PKCS#8 ASN.1 tree and pull out the EC private key scalar.

The structure we expect (only relevant elements shown — anything else
is ignored):

> Start Sequence                            -- PrivateKeyInfo
>   IntVal 0                                -- version
>   Start Sequence                          -- AlgorithmIdentifier
>     OID [1,2,840,10045,2,1]               -- id-ecPublicKey
>     OID [1,2,840,10045,3,1,7]             -- secp256r1
>   End Sequence
>   OctetString (encoded ECPrivateKey)      -- inner PKCS#1
> End Sequence

The inner OCTET STRING is itself an ASN.1 SEQUENCE (the ECPrivateKey
type) that contains the 32-byte private key as its second element
(after the integer version).
-}
extractScalar :: [ASN1] -> Either String Integer
extractScalar asn1 = do
    inner <- findInnerOctetString asn1
    innerAsn1 <- mapLeft show (decodeASN1' DER inner)
    findScalarInECPrivateKey innerAsn1
  where
    mapLeft f (Left a) = Left (f a)
    mapLeft _ (Right c) = Right c

{- | Walk the outer PrivateKeyInfo SEQUENCE; return the raw OCTET STRING
bytes that wrap the ECPrivateKey.
-}
findInnerOctetString :: [ASN1] -> Either String BS.ByteString
findInnerOctetString =
    -- The PKCS#8 OCTET STRING appears as an 'Other'-class primitive in
    -- some encodings, or directly as a primitive byte string in others.
    -- We pattern-match against the typical decoded shape.
    \case
        (Start Sequence : IntVal _ : Start Sequence : _algIdentRest) ->
            -- Skip past the AlgorithmIdentifier and find the next
            -- OCTET STRING (the inner ECPrivateKey).
            findOctetAfterAlgId _algIdentRest
        other ->
            Left ("unexpected PKCS#8 shape (no outer SEQUENCE/version/alg-seq): " <> show (take 4 other))
  where
    findOctetAfterAlgId :: [ASN1] -> Either String BS.ByteString
    findOctetAfterAlgId xs = case dropWhile notEndOfAlgId xs of
        (End Sequence : rest) -> takeOctet rest
        _ -> Left "could not locate end of AlgorithmIdentifier in PKCS#8"

    notEndOfAlgId :: ASN1 -> Bool
    notEndOfAlgId (End Sequence) = False
    notEndOfAlgId _ = True

    takeOctet :: [ASN1] -> Either String BS.ByteString
    takeOctet (OctetString bs : _) = Right bs
    -- Some encoders emit OCTET STRING as a context-specific 'Other' primitive
    -- (e.g. when wrapped in an EXPLICIT tag). Accept that shape too.
    takeOctet (Other _ _ bs : _) = Right bs
    takeOctet (x : _) =
        Left ("expected OCTET STRING after AlgorithmIdentifier, got: " <> take 80 (show x))
    takeOctet [] = Left "PKCS#8 PrivateKey field missing"

{- | Inside the ECPrivateKey SEQUENCE, the scalar is the second element
(after `INTEGER 1` version), encoded as an OCTET STRING. Convert its
raw bytes (big-endian) to an Integer. We also accept the 'Other'
primitive form for the same reason as in 'findInnerOctetString'.
-}
findScalarInECPrivateKey :: [ASN1] -> Either String Integer
findScalarInECPrivateKey =
    \case
        (Start Sequence : IntVal _ : OctetString bs : _) -> Right (beToInteger bs)
        (Start Sequence : IntVal _ : Other _ _ bs : _) -> Right (beToInteger bs)
        (Start (Container _ _) : IntVal _ : OctetString bs : _) -> Right (beToInteger bs)
        (Start (Container _ _) : IntVal _ : Other _ _ bs : _) -> Right (beToInteger bs)
        other ->
            Left ("unexpected ECPrivateKey shape: " <> show (take 4 other))
  where
    -- Convert big-endian unsigned bytes to Integer.
    beToInteger :: BS.ByteString -> Integer
    beToInteger = BS.foldl' (\acc b -> acc * 256 + fromIntegral b) 0

-- ─── ASC endpoints ─────────────────────────────────────────────────

ascBase :: Text
ascBase = "https://api.appstoreconnect.apple.com/v1"

lookupAppByBundleId :: Text -> Text -> IO (Either AscError Text)
lookupAppByBundleId token bundleId = do
    -- Apple's ASC API uses bracketed filter syntax (`filter[bundleId]=...`).
    -- Haskell's http-client rejects raw `[` / `]` in URLs with
    -- 'InvalidUrlException' (RFC 3986 strict mode). Percent-encode the
    -- brackets to `%5B` / `%5D`; the bundleId itself only contains dots and
    -- alphanumerics, which need no encoding.
    let url = ascBase <> "/apps?filter%5BbundleId%5D=" <> bundleId
        req =
            (defaultReq url)
                { reqMethod = GET
                , reqHeaders = [("Authorization", "Bearer " <> token)]
                , reqTimeout = Seconds 30
                , reqLogTag = "asc-app-lookup"
                }
    resp <- httpRaw req
    pure $ case resp of
        Right HttpResponse{respStatus = s, respBody = b}
            | s == 200 -> case decode b :: Maybe AppsListResp of
                Just (AppsListResp refs) -> case listToMaybe refs of
                    Just (AppRef appId) -> Right appId
                    Nothing -> Left (AscAppNotFound bundleId)
                Nothing -> Left (AscHttpError s "could not decode /v1/apps response")
            | s == 401 -> Left AscUnauthorized
            | s == 403 -> Left AscUnauthorized
            | otherwise -> Left (AscHttpError s (TE.decodeUtf8 (LBS.toStrict b)))
        Left e -> Left (AscHttpError 0 (T.pack (show e)))

fetchLatestTestFlightVersion :: Text -> Text -> IO (Either AscError (Maybe Text))
fetchLatestTestFlightVersion token appId = do
    -- Same bracket-encoding rationale as 'lookupAppByBundleId'. Brackets
    -- in `filter[app]` and `filter[expired]` need to be percent-encoded
    -- (`%5B` / `%5D`) so http-client accepts the URL.
    let url =
            ascBase
                <> "/builds?filter%5Bapp%5D="
                <> appId
                <> "&filter%5Bexpired%5D=false&sort=-uploadedDate&limit=1&include=preReleaseVersion"
        req =
            (defaultReq url)
                { reqMethod = GET
                , reqHeaders = [("Authorization", "Bearer " <> token)]
                , reqTimeout = Seconds 30
                , reqLogTag = "asc-builds"
                }
    resp <- httpJson @BuildsResp req
    pure $ case resp of
        Right (BuildsResp version) -> Right version
        Left (HttpStatusError 401 _) -> Left AscUnauthorized
        Left (HttpStatusError 403 _) -> Left AscUnauthorized
        Left (HttpStatusError s b) ->
            Left (AscHttpError s (TE.decodeUtf8 (LBS.toStrict b)))
        Left e -> Left (AscHttpError 0 (T.pack (show e)))

-- ─── Response decoding ─────────────────────────────────────────────

-- | One element of @data[]@ in @/v1/apps?filter[bundleId]=…@.
newtype AppRef = AppRef {arId :: Text}

instance FromJSON AppRef where
    parseJSON = withObject "AppRef" $ \o -> AppRef <$> o .: "id"

-- | Wrapper for @{"data": [...]}@.
newtype AppsListResp = AppsListResp [AppRef]

instance FromJSON AppsListResp where
    parseJSON = withObject "AppsListResp" $ \o -> AppsListResp <$> o .: "data"

{- | One element of @included[]@ from a /v1/builds response with
@include=preReleaseVersion@. We only care about
@type == "preReleaseVersions"@ and its @attributes.version@.
-}
data IncludedItem = IncludedItem
    { iiType :: Text
    , iiAttrs :: Maybe IncludedAttrs
    }

newtype IncludedAttrs = IncludedAttrs {iaVersion :: Maybe Text}

instance FromJSON IncludedItem where
    parseJSON = withObject "IncludedItem" $ \o ->
        IncludedItem
            <$> o .: "type"
            <*> o .:? "attributes"

instance FromJSON IncludedAttrs where
    parseJSON = withObject "IncludedAttrs" $ \o ->
        IncludedAttrs <$> o .:? "version"

{- | From @\/v1\/builds@ with @include=preReleaseVersion@, extract the
@version@ string from the first included @preReleaseVersions@ record.
Returns 'Nothing' if there are no builds yet.
-}
newtype BuildsResp = BuildsResp (Maybe Text)

instance FromJSON BuildsResp where
    parseJSON = withObject "BuildsResp" $ \o -> do
        items <- fromMaybe [] <$> o .:? "included"
        let versions =
                mapMaybe
                    (\it -> if iiType it == "preReleaseVersions" then iiAttrs it >>= iaVersion else Nothing)
                    items
        pure (BuildsResp (listToMaybe versions))

-- ─── Staged review + rollout ───────────────────────────────────────

-- | IO-Either bind: short-circuit on the first 'Left'. ExceptT-lite, no transformer.
(>>?) :: IO (Either e a) -> (a -> IO (Either e b)) -> IO (Either e b)
m >>? f = m >>= either (pure . Left) f
infixl 1 >>?

-- | App Store review state, derived from a version's @appStoreState@.
data AscReviewState
    = AscPrepareForSubmission
    | -- | submitted, queued
      AscWaitingForReview
    | AscInReview
    | -- | PENDING_DEVELOPER_RELEASE (held) or READY_FOR_SALE (live)
      AscApproved
    | -- | REJECTED / METADATA_REJECTED / DEVELOPER_REJECTED (raw state as reason)
      AscRejected Text
    | -- | any other raw appStoreState
      AscOther Text
    deriving (Eq, Show)

-- | Map a raw @appStoreState@ to an 'AscReviewState'. Pure; unit-tested.
appStoreStateToReview :: Text -> AscReviewState
appStoreStateToReview = \case
    "PREPARE_FOR_SUBMISSION" -> AscPrepareForSubmission
    "WAITING_FOR_REVIEW" -> AscWaitingForReview
    "IN_REVIEW" -> AscInReview
    "PENDING_DEVELOPER_RELEASE" -> AscApproved
    "READY_FOR_SALE" -> AscApproved
    "REJECTED" -> AscRejected "REJECTED"
    "METADATA_REJECTED" -> AscRejected "METADATA_REJECTED"
    "DEVELOPER_REJECTED" -> AscRejected "DEVELOPER_REJECTED"
    other -> AscOther other

-- | Apple's fixed 7-day phased-release schedule: day 0–6 → cumulative %.
applePhasedPercent :: Int -> Double
applePhasedPercent d = case d of
    0 -> 1
    1 -> 2
    2 -> 5
    3 -> 10
    4 -> 20
    5 -> 50
    _ -> 100

-- | Phased-release snapshot.
data AscPhasedState = AscPhasedState
    { apsState :: Text
    -- ^ INACTIVE | ACTIVE | PAUSED | COMPLETE
    , apsCurrentDay :: Maybe Int
    -- ^ currentDayNumber (0–6)
    }
    deriving (Eq, Show)

-- | A located App Store version: its id + raw @appStoreState@.
data AscVersion = AscVersion
    { avId :: Text
    , avState :: Text
    }
    deriving (Eq, Show)

-- ── response parsers (JSON:API) ──

newtype AscVersionsResp = AscVersionsResp [AscVersion]

instance FromJSON AscVersionsResp where
    parseJSON = withObject "AscVersionsResp" $ \o ->
        AscVersionsResp <$> (o .: "data" >>= mapM pv)
      where
        pv = withObject "version" $ \d ->
            AscVersion <$> d .: "id" <*> (d .: "attributes" >>= withObject "attrs" (.: "appStoreState"))

-- | Parse an @appStoreVersions@ list → first version {id, appStoreState}. Pure; tested.
parseAscVersion :: LBS.ByteString -> Maybe AscVersion
parseAscVersion bs = decode bs >>= \(AscVersionsResp vs) -> listToMaybe vs

newtype CreatedId = CreatedId Text

instance FromJSON CreatedId where
    parseJSON = withObject "CreatedId" $ \o -> CreatedId <$> (o .: "data" >>= withObject "data" (.: "id"))

parseCreatedId :: LBS.ByteString -> Maybe Text
parseCreatedId bs = (\(CreatedId i) -> i) <$> decode bs

-- @data.id@ of a single-resource relationship (@.:?@ treats null/absent as Nothing).
newtype RelData = RelData (Maybe Text)

instance FromJSON RelData where
    parseJSON = withObject "RelData" $ \o ->
        RelData <$> (o .:? "data" >>= traverse (withObject "rel" (.: "id")))

parseRelId :: LBS.ByteString -> Maybe Text
parseRelId bs = decode bs >>= \(RelData m) -> m

newtype LocIds = LocIds [Text]

instance FromJSON LocIds where
    parseJSON = withObject "LocIds" $ \o -> LocIds <$> (o .: "data" >>= mapM (withObject "loc" (.: "id")))

parseLocIds :: LBS.ByteString -> [Text]
parseLocIds bs = maybe [] (\(LocIds xs) -> xs) (decode bs)

newtype ProcState = ProcState Text

instance FromJSON ProcState where
    parseJSON = withObject "ProcState" $ \o ->
        ProcState <$> (o .: "data" >>= withObject "d" (\d -> d .: "attributes" >>= withObject "a" (.: "processingState")))

data PhasedAttrs = PhasedAttrs Text (Maybe Int)

instance FromJSON PhasedAttrs where
    parseJSON = withObject "PhasedAttrs" $ \o ->
        o .: "data" >>= withObject "d" (\d -> d .: "attributes" >>= withObject "a" (\a -> PhasedAttrs <$> a .: "phasedReleaseState" <*> a .:? "currentDayNumber"))

-- ── HTTP helpers ──

-- | A JSON:API resource-identifier object: @{data:{type,id}}@.
relRef :: Text -> Text -> Value
relRef ty i = object ["data" .= object ["type" .= ty, "id" .= i]]

-- | POST/PATCH a JSON body; return the response body on 2xx (for id extraction).
ascSend :: Method -> Text -> Text -> LBS.ByteString -> Text -> IO (Either AscError LBS.ByteString)
ascSend method url token body logTag = do
    let req =
            (defaultReq url)
                { reqMethod = method
                , reqHeaders = [("Authorization", "Bearer " <> token), ("Content-Type", "application/json")]
                , reqBody = Just body
                , reqTimeout = Seconds 30
                , reqLogTag = logTag
                , reqRetries = 0
                }
    classifyBody <$> httpRaw req

ascGet :: Text -> Text -> Text -> IO (Either AscError LBS.ByteString)
ascGet url token logTag = do
    let req =
            (defaultReq url)
                { reqMethod = GET
                , reqHeaders = [("Authorization", "Bearer " <> token)]
                , reqTimeout = Seconds 30
                , reqLogTag = logTag
                }
    classifyBody <$> httpRaw req

classifyBody :: Either HttpError HttpResponse -> Either AscError LBS.ByteString
classifyBody resp = case resp of
    Right HttpResponse{respStatus = s, respBody = b}
        | s >= 200 && s < 300 -> Right b
        | s == 401 || s == 403 -> Left AscUnauthorized
        | otherwise -> Left (AscHttpError s (TE.decodeUtf8 (LBS.toStrict b)))
    Left e -> Left (AscHttpError 0 (T.pack (show e)))

-- | Mint a token, then run @k token@.
withAscToken :: AscCreds -> (Text -> IO (Either AscError a)) -> IO (Either AscError a)
withAscToken creds k = mintAscToken creds >>= either (pure . Left) k

-- | Mint a token, resolve the numeric app id, then run @k token appId@.
withAscApp :: AscCreds -> Text -> (Text -> Text -> IO (Either AscError a)) -> IO (Either AscError a)
withAscApp creds bundleId k =
    mintAscToken creds >>? \token ->
        lookupAppByBundleId token bundleId >>? \appId -> k token appId

-- | GET the IOS @appStoreVersion@ for @versionString@ → {id, appStoreState}.
getAppStoreVersion :: Text -> Text -> Text -> IO (Either AscError AscVersion)
getAppStoreVersion token appId versionString = do
    let url =
            ascBase
                <> "/apps/"
                <> appId
                <> "/appStoreVersions?filter%5BversionString%5D="
                <> versionString
                <> "&filter%5Bplatform%5D=IOS&limit=1"
    ascGet url token "asc-version-lookup" >>? \b ->
        pure (maybe (Left (AscVersionNotFound versionString)) Right (parseAscVersion b))

-- ── Public operations ──

-- | Poll the App Store review state of a version (maps @appStoreState@).
getAscReviewState :: (MonadFlow m) => AscCreds -> Text -> Text -> m (Either AscError AscReviewState)
getAscReviewState creds bundleId versionString = liftIO $ withAscApp creds bundleId $ \token appId ->
    fmap (fmap (appStoreStateToReview . avState)) (getAppStoreVersion token appId versionString)

-- | Read the processing state of the build attached to a version (@""@ if none).
getBuildProcessingState :: (MonadFlow m) => AscCreds -> Text -> Text -> m (Either AscError Text)
getBuildProcessingState creds bundleId versionString = liftIO $ withAscApp creds bundleId $ \token appId ->
    getAppStoreVersion token appId versionString >>? \ver -> buildProcessingStateIO token (avId ver)

buildProcessingStateIO :: Text -> Text -> IO (Either AscError Text)
buildProcessingStateIO token vid =
    ascGet (ascBase <> "/appStoreVersions/" <> vid <> "/build") token "asc-version-build" >>? \b ->
        case parseRelId b of
            Nothing -> pure (Right "") -- no build attached → can't gate, proceed
            Just buildId ->
                ascGet (ascBase <> "/builds/" <> buildId) token "asc-build" >>? \bb ->
                    pure (Right (maybe "" (\(ProcState s) -> s) (decode bb)))

{- | Fill What's New (every listed locale gets the same changelog), set release
type to MANUAL (so it won't auto-release), then submit via the modern
@reviewSubmissions@ flow (create → add item → mark submitted). Blocks if the
attached build is still processing.
-}
submitVersionForReview :: (MonadFlow m) => AscCreds -> Text -> Text -> Text -> m (Either AscError ())
submitVersionForReview creds bundleId versionString whatsNew = liftIO $ withAscApp creds bundleId $ \token appId ->
    getAppStoreVersion token appId versionString >>? \ver ->
        buildProcessingStateIO token (avId ver) >>? \pstate ->
            if pstate /= "" && pstate /= "VALID"
                then pure (Left (AscBuildNotReady pstate))
                else
                    setWhatsNewAllLocales token (avId ver) whatsNew >>? \_ ->
                        setReleaseTypeManual token (avId ver) >>? \_ ->
                            createReviewSubmission token appId >>? \subId ->
                                addReviewSubmissionItem token subId (avId ver) >>? \_ ->
                                    submitReviewSubmission token subId

setReleaseTypeManual :: Text -> Text -> IO (Either AscError ())
setReleaseTypeManual token vid =
    let body =
            encode $
                object
                    [ "data"
                        .= object
                            [ "type" .= ("appStoreVersions" :: Text)
                            , "id" .= vid
                            , "attributes" .= object ["releaseType" .= ("MANUAL" :: Text)]
                            ]
                    ]
     in void <$> ascSend PATCH (ascBase <> "/appStoreVersions/" <> vid) token body "asc-set-manual"

setWhatsNewAllLocales :: Text -> Text -> Text -> IO (Either AscError ())
setWhatsNewAllLocales token vid txt =
    ascGet (ascBase <> "/appStoreVersions/" <> vid <> "/appStoreVersionLocalizations") token "asc-locs" >>? \b ->
        go (parseLocIds b)
  where
    go [] = pure (Right ())
    go (lid : rest) =
        let body =
                encode $
                    object
                        [ "data"
                            .= object
                                [ "type" .= ("appStoreVersionLocalizations" :: Text)
                                , "id" .= lid
                                , "attributes" .= object ["whatsNew" .= txt]
                                ]
                        ]
         in (void <$> ascSend PATCH (ascBase <> "/appStoreVersionLocalizations/" <> lid) token body "asc-whatsnew") >>? \_ -> go rest

createReviewSubmission :: Text -> Text -> IO (Either AscError Text)
createReviewSubmission token appId =
    let body =
            encode $
                object
                    [ "data"
                        .= object
                            [ "type" .= ("reviewSubmissions" :: Text)
                            , "attributes" .= object ["platform" .= ("IOS" :: Text)]
                            , "relationships" .= object ["app" .= relRef "apps" appId]
                            ]
                    ]
     in ascSend POST (ascBase <> "/reviewSubmissions") token body "asc-review-create" >>? \b ->
            pure (maybe (Left (AscHttpError 0 "could not read reviewSubmission id")) Right (parseCreatedId b))

addReviewSubmissionItem :: Text -> Text -> Text -> IO (Either AscError ())
addReviewSubmissionItem token subId vid =
    let body =
            encode $
                object
                    [ "data"
                        .= object
                            [ "type" .= ("reviewSubmissionItems" :: Text)
                            , "relationships"
                                .= object
                                    [ "reviewSubmission" .= relRef "reviewSubmissions" subId
                                    , "appStoreVersion" .= relRef "appStoreVersions" vid
                                    ]
                            ]
                    ]
     in void <$> ascSend POST (ascBase <> "/reviewSubmissionItems") token body "asc-review-item"

submitReviewSubmission :: Text -> Text -> IO (Either AscError ())
submitReviewSubmission token subId =
    let body =
            encode $
                object
                    [ "data"
                        .= object
                            [ "type" .= ("reviewSubmissions" :: Text)
                            , "id" .= subId
                            , "attributes" .= object ["submitted" .= True]
                            ]
                    ]
     in void <$> ascSend PATCH (ascBase <> "/reviewSubmissions/" <> subId) token body "asc-review-submit"

-- | Release an approved (held) version — the iOS "Release" button.
releaseApprovedVersion :: (MonadFlow m) => AscCreds -> Text -> Text -> m (Either AscError ())
releaseApprovedVersion creds bundleId versionString = liftIO $ withAscApp creds bundleId $ \token appId ->
    getAppStoreVersion token appId versionString >>? \ver ->
        let body =
                encode $
                    object
                        [ "data"
                            .= object
                                [ "type" .= ("appStoreVersionReleaseRequests" :: Text)
                                , "relationships" .= object ["appStoreVersion" .= relRef "appStoreVersions" (avId ver)]
                                ]
                        ]
         in void <$> ascSend POST (ascBase <> "/appStoreVersionReleaseRequests") token body "asc-release-request"

-- | Turn on phased release for an approved version; returns the phasedRelease id.
enablePhasedRelease :: (MonadFlow m) => AscCreds -> Text -> Text -> m (Either AscError Text)
enablePhasedRelease creds bundleId versionString = liftIO $ withAscApp creds bundleId $ \token appId ->
    getAppStoreVersion token appId versionString >>? \ver ->
        let body =
                encode $
                    object
                        [ "data"
                            .= object
                                [ "type" .= ("appStoreVersionPhasedReleases" :: Text)
                                , "attributes" .= object ["phasedReleaseState" .= ("ACTIVE" :: Text)]
                                , "relationships" .= object ["appStoreVersion" .= relRef "appStoreVersions" (avId ver)]
                                ]
                        ]
         in ascSend POST (ascBase <> "/appStoreVersionPhasedReleases") token body "asc-phased-create" >>? \b ->
                pure (maybe (Left (AscHttpError 0 "could not read phasedRelease id")) Right (parseCreatedId b))

-- | Pause / resume / complete a phased release (by its cached id).
pausePhasedRelease, resumePhasedRelease, completePhasedRelease ::
    (MonadFlow m) => AscCreds -> Text -> m (Either AscError ())
pausePhasedRelease creds pid = liftIO $ withAscToken creds $ \token -> setPhasedState token pid "PAUSE"
resumePhasedRelease creds pid = liftIO $ withAscToken creds $ \token -> setPhasedState token pid "ACTIVE"
completePhasedRelease creds pid = liftIO $ withAscToken creds $ \token -> setPhasedState token pid "COMPLETE"

setPhasedState :: Text -> Text -> Text -> IO (Either AscError ())
setPhasedState token pid st =
    let body =
            encode $
                object
                    [ "data"
                        .= object
                            [ "type" .= ("appStoreVersionPhasedReleases" :: Text)
                            , "id" .= pid
                            , "attributes" .= object ["phasedReleaseState" .= st]
                            ]
                    ]
     in void <$> ascSend PATCH (ascBase <> "/appStoreVersionPhasedReleases/" <> pid) token body "asc-phased-patch"

-- | Read the phased-release state of a version (defaults to INACTIVE if none).
getPhasedReleaseState :: (MonadFlow m) => AscCreds -> Text -> Text -> m (Either AscError AscPhasedState)
getPhasedReleaseState creds bundleId versionString = liftIO $ withAscApp creds bundleId $ \token appId ->
    getAppStoreVersion token appId versionString >>? \ver ->
        ascGet (ascBase <> "/appStoreVersions/" <> avId ver <> "/appStoreVersionPhasedRelease") token "asc-phased-get" >>? \b ->
            pure (Right (maybe (AscPhasedState "INACTIVE" Nothing) (\(PhasedAttrs s d) -> AscPhasedState s d) (decode b)))

-- ─── Server-config helper ──────────────────────────────────────────

{- | Read the three App Store Connect secrets from the process __environment__
(k8s Secret in prod; @local-mobile-secrets.env@ in dev) — never from the DB.
Returns 'Nothing' if any is empty — caller surfaces a clear error.

* @SC_ASC_ISSUER_ID@
* @SC_ASC_KEY_ID@
* @SC_ASC_PRIVATE_KEY_P8_B64@ — the @.p8@ PEM, base64-encoded (single line).
-}
loadAscCreds :: (MonadFlow m) => m (Maybe AscCreds)
loadAscCreds = do
    mIssuer <- lookupEnvSecret "SC_ASC_ISSUER_ID"
    mKeyId <- lookupEnvSecret "SC_ASC_KEY_ID"
    mP8 <- lookupEnvSecretB64 "SC_ASC_PRIVATE_KEY_P8_B64"
    pure $ case (mIssuer, mKeyId, mP8) of
        (Just iss, Just kid, Just p8)
            | not (T.null iss) && not (T.null kid) && not (T.null p8) ->
                Just (AscCreds iss kid p8)
        _ -> Nothing

-- ─── Error rendering ───────────────────────────────────────────────

{- | Stable, machine-readable tag for use in HTTP responses and audit
events. Mirrors @Versioning.Play.renderPlayErr@.
-}
renderAscErr :: AscError -> Text
renderAscErr AscCredsMissing = "asc_creds_missing"
renderAscErr (AscJwtSigningFailed reason) = "asc_jwt_signing_failed:" <> reason
renderAscErr (AscAppNotFound bundleId) = "asc_app_not_found:" <> bundleId
renderAscErr AscUnauthorized = "asc_unauthorized"
renderAscErr (AscVersionNotFound v) = "asc_version_not_found:" <> v
renderAscErr (AscBuildNotReady st) = "asc_build_not_ready:" <> st
renderAscErr (AscHttpError s body) =
    "asc_http_error:" <> T.pack (show s) <> ":" <> body

-- ─── Dispatcher entry point ────────────────────────────────────────

{- | High-level entry point used by @Versioning.resolveNextVersion@.
Loads creds + calls 'fetchAscVersions' + runs 'computeNextIosVersion'.
Returns the next @version_number@ string. Build number is NOT
computed here — the iOS workflow's @fastlane fetch_build_number@
handles it.
-}
resolve ::
    (MonadFlow m) =>
    -- | iOS bundle id (from @app_catalog.package_name@).
    Text ->
    m (Either Text Text)
resolve bundleId = do
    mCreds <- loadAscCreds
    case mCreds of
        Nothing -> pure (Left (renderAscErr AscCredsMissing))
        Just creds -> do
            res <- fetchAscVersions creds bundleId
            case res of
                Left e -> pure (Left (renderAscErr e))
                Right mTfVersion -> pure (Right (computeNextIosVersion mTfVersion))

resolveWithToken ::
    (MonadFlow m) =>
    -- | Pre-minted ASC bearer token (shared across a batch).
    Text ->
    -- | iOS bundle id (from @app_catalog.package_name@).
    Text ->
    m (Either Text Text)
resolveWithToken token bundleId = do
    res <- liftIO (runFetchWithToken token bundleId)
    case res of
        Left e -> pure (Left (renderAscErr e))
        Right mTfVersion -> pure (Right (computeNextIosVersion mTfVersion))
