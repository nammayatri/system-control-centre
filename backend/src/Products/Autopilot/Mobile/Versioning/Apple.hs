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
    AscBuildInfo (..),
    fetchAscBuildInfo,
    AscSnapshot (..),
    fetchAscSnapshots,
    BuildsResp (..),
    getLiveAppStoreVersionAndBuild,
    getIosVersionStateDump,
    getLiveReleaseNotes,
    firstWhatsNew,
    loadAscCreds,
    loadAscCredsFor,
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
    cancelReviewSubmission,
    releaseApprovedVersion,
    getBuildProcessingState,
    enablePhasedRelease,
    pausePhasedRelease,
    resumePhasedRelease,
    completePhasedRelease,
    getPhasedReleaseState,
    getPhasedReleaseId,
    getInFlightReview,
    selectInFlightReview,
    parseVersionStatesWithBuild,

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
    Object,
    Value,
    decode,
    encode,
    object,
    withObject,
    (.!=),
    (.:),
    (.:?),
    (.=),
 )
import Data.Aeson.Types (Parser)
import Data.Bits (shiftR, (.&.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Base64.URL as B64U
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as LBS
import Data.Char (isAlphaNum)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int32)
import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.IO.Unsafe (unsafePerformIO)
import Text.Read (readMaybe)

-- ─── Pure algorithm ────────────────────────────────────────────────

{- | The next iOS @version_number@, made track-aware to mirror Android's
'Products.Autopilot.Mobile.Versioning.Play.computeNextVersion'. Given the latest
TestFlight version and the live App Store (READY_FOR_SALE) version:

  * no TestFlight history, no live version → @"1.0.0"@ (first-ever release).
  * no TestFlight history, app LIVE        → bump the live version's patch —
    TestFlight builds expire after 90 days, so an app that hasn't built recently
    reads as TF-empty while very much shipped; 1.0.0 here would be nonsense.
  * TestFlight __==__ live App Store version → bump the patch — the current build
    is already in production, so a new release needs a fresh version.
  * TestFlight __ahead__ of production (≠, or no live version yet) → __reuse__ the
    TestFlight version verbatim — a build already exists pending promotion, so we
    don't double-bump (submit/promote that build instead).

The iOS build number is still NOT computed here — the workflow's
@fastlane fetch_build_number@ resolves it inside the runner. SCC only provides the
@version_number@ semver string; the build number lands on the row later via the
pushed tag's @+NNN@ suffix.
-}
computeNextIosVersion :: Maybe Text -> Maybe Text -> Text
computeNextIosVersion Nothing Nothing = "1.0.0"
computeNextIosVersion Nothing (Just prod) = bumpPatch prod -- TF expired/empty but app is live
computeNextIosVersion (Just tf) mProd
    | mProd == Just tf = bumpPatch tf -- TestFlight in sync with production → bump
    | otherwise = tf -- TestFlight ahead (or no live prod) → reuse the existing build

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
2. @GET \/v1\/apps?filter[bundleId]=<bundle_id>@ → the entry whose
   @bundleId@ matches exactly (the filter also returns sibling bundles,
   e.g. \".debug\"). Errors with 'AscAppNotFound' when none matches.
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
fetchAscVersions creds bundleId =
    (fmap . fmap . fmap) abiVersion (fetchAscBuildInfo creds bundleId)

{- | Like 'fetchAscVersions' but also returns the latest build's __build number__
(CFBundleVersion). Store-sync uses it to derive the iOS git tag
(@{app}/prod/ios/v{version}+{buildNumber}@) so the changelog has a baseline on
the first SCC-built iOS release.
-}
fetchAscBuildInfo ::
    (MonadFlow m) =>
    AscCreds ->
    Text ->
    m (Either AscError (Maybe AscBuildInfo))
fetchAscBuildInfo creds bundleId = liftIO (runFetch creds bundleId)

-- | The latest TestFlight build's marketing version + build number.
data AscBuildInfo = AscBuildInfo
    { abiVersion :: Text
    -- ^ marketing version, e.g. @"3.3.73"@
    , abiBuildNumber :: Maybe Text
    -- ^ CFBundleVersion, e.g. @"458"@
    }
    deriving (Eq, Show)

-- | One iOS store track's current state for the App Release Monitoring dashboard.
data AscSnapshot = AscSnapshot
    { ascTrack :: Text
    -- ^ "production" | "testflight"
    , ascVersion :: Text
    , ascStatus :: Text
    -- ^ live | none | VALID
    , ascNotes :: Maybe Text
    , ascCode :: Maybe Int32
    -- ^ build number (CFBundleVersion) when known — populated for TestFlight from the
    -- latest build's @version@; 'Nothing' for the live App Store cell (its build number
    -- isn't read here). Lets the monitor show + dedup iOS builds by (version, build no.).
    }
    deriving (Eq, Show)

{- | Production + TestFlight snapshots for an iOS app: the live App Store version
(+ its "What's New") and the latest TestFlight build. Composes the existing
live-version / release-notes / build readers — read-only, no new auth. The
production rollout % is filled by the poller from @release_tracker@ (Phase 7), not
re-read here.
-}
fetchAscSnapshots :: (MonadFlow m) => AscCreds -> Text -> m (Either AscError [AscSnapshot])
fetchAscSnapshots creds bundleId = do
    eProd <- liftIO (getLiveAppStoreVersionAndBuild creds bundleId)
    case eProd of
        Left e -> pure (Left e)
        Right mProd -> do
            let mProdVer = fst <$> mProd
                mProdCode = (readMaybe . T.unpack =<< (mProd >>= snd))
            mNotes <- either (const Nothing) id <$> liftIO (getLiveReleaseNotes creds bundleId)
            eTf <- fetchAscBuildInfo creds bundleId
            case eTf of
                Left e -> pure (Left e)
                Right mTf ->
                    pure $
                        Right
                            [ AscSnapshot "production" (fromMaybe "0.0.0" mProdVer) (maybe "none" (const "live") mProdVer) mNotes mProdCode
                            , AscSnapshot "testflight" (maybe "0.0.0" abiVersion mTf) (maybe "none" (const "VALID") mTf) Nothing ((readMaybe . T.unpack =<< (abiBuildNumber =<< mTf)))
                            ]

-- ─── Live ASC call (IO-only) ───────────────────────────────────────

runFetch :: AscCreds -> Text -> IO (Either AscError (Maybe AscBuildInfo))
runFetch creds bundleId = do
    eToken <- mintAscToken creds
    case eToken of
        Left err -> pure (Left err)
        Right token -> runFetchWithToken token bundleId

runFetchWithToken :: Text -> Text -> IO (Either AscError (Maybe AscBuildInfo))
runFetchWithToken token bundleId = do
    eAppId <- lookupAppByBundleId token bundleId
    case eAppId of
        Left err -> pure (Left err)
        Right appId -> fetchLatestBuildInfo token appId

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

{- | ASC bearer-token validity (seconds). 15 min — well under Apple's 20-min cap,
leaving headroom for the @iat@ backdate + clock skew.
-}
ascTokenTtlSec :: Integer
ascTokenTtlSec = 840

{- | Re-mint when a cached token has less than this much validity left, so a reused
token is never close to expiry when it reaches Apple.
-}
ascTokenReuseFloorSec :: Integer
ascTokenReuseFloorSec = 180

{- | Process-global ASC token cache: @keyId → (token, expiresAtEpoch)@.

Apple's ASC API is designed for token REUSE — one signed JWT, valid up to 20 min,
sent on many requests. Minting a fresh JWT per call (which every read used to do)
churns auth: a single app refresh fans out ~8–10 calls, and a burst throws dozens
of distinct tokens at Apple in seconds, which it intermittently rejects with
401/403 (surfacing as @asc_unauthorized@). Caching one token per key and reusing it
collapses that to ~one mint per 15 min.
-}
{-# NOINLINE ascTokenCache #-}
ascTokenCache :: IORef (Map.Map Text (Text, Integer))
ascTokenCache = unsafePerformIO (newIORef Map.empty)

mintAscToken :: AscCreds -> IO (Either AscError Text)
mintAscToken creds@AscCreds{acKeyId = keyId} = do
    nowSec <- (round :: Double -> Integer) . realToFrac <$> getPOSIXTime
    cached <- Map.lookup keyId <$> readIORef ascTokenCache
    case cached of
        Just (tok, expAt) | expAt - nowSec > ascTokenReuseFloorSec -> pure (Right tok)
        _ ->
            signAscToken creds nowSec >>= \case
                Left e -> pure (Left e)
                Right tok -> do
                    atomicModifyIORef' ascTokenCache (\m -> (Map.insert keyId (tok, nowSec + ascTokenTtlSec) m, ()))
                    pure (Right tok)

{- | Sign a fresh ASC JWT. @iat@ is backdated and @exp@ kept well under Apple's
20-min cap so a forward clock drift can't make Apple see @iat@ in the future or
@exp@ out of range (both → 401). Callers should prefer 'mintAscToken' (cached).
-}
signAscToken :: AscCreds -> Integer -> IO (Either AscError Text)
signAscToken AscCreds{..} nowSec =
    case parseEcP256PrivateKey acP8 of
        Left e -> pure (Left (AscJwtSigningFailed (T.pack e)))
        Right privKey -> do
            let iatSec = nowSec - 60
                expSec = nowSec + ascTokenTtlSec
                header :: Value
                header = object ["alg" .= ("ES256" :: Text), "kid" .= acKeyId, "typ" .= ("JWT" :: Text)]
                claims :: Value
                claims =
                    object
                        [ "iss" .= acIssuerId
                        , "iat" .= iatSec
                        , "exp" .= expSec
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

{- | Process-global @bundleId → appId@ cache. An App Store app's numeric id is
permanent for a bundle, so a successful resolution is cached for the process
lifetime. Every ASC operation needs the appId, so without this each call re-runs
the @\/apps@ lookup — roughly DOUBLING the request volume (and auth churn) per
refresh. Only successful resolutions are cached; not-found / unauthorized are
never cached, so a fix (app published, key access granted) is picked up on retry.
-}
{-# NOINLINE ascAppIdCache #-}
ascAppIdCache :: IORef (Map.Map Text Text)
ascAppIdCache = unsafePerformIO (newIORef Map.empty)

{- | Resolve a bundle id to its App Store app id, served from 'ascAppIdCache' when
known. Falls through to the live @\/apps@ lookup on a miss and caches the result.
-}
lookupAppByBundleId :: Text -> Text -> IO (Either AscError Text)
lookupAppByBundleId token bundleId = do
    cached <- Map.lookup bundleId <$> readIORef ascAppIdCache
    case cached of
        Just appId -> pure (Right appId)
        Nothing ->
            fetchAppIdByBundleId token bundleId >>= \case
                Right appId -> do
                    atomicModifyIORef' ascAppIdCache (\m -> (Map.insert bundleId appId m, ()))
                    pure (Right appId)
                left -> pure left

fetchAppIdByBundleId :: Text -> Text -> IO (Either AscError Text)
fetchAppIdByBundleId token bundleId = do
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
                -- filter[bundleId] can return sibling bundles too (e.g. the
                -- ".debug" variant), in unstable order — match exactly, never data[0].
                Just (AppsListResp refs) ->
                    let exact = [arId r | r <- refs, arBundleId r == bundleId]
                        ci = [arId r | r <- refs, T.toLower (arBundleId r) == T.toLower bundleId]
                     in case exact <> ci of
                            (appId : _) -> Right appId
                            [] -> Left (AscAppNotFound bundleId)
                Nothing -> Left (AscHttpError s "could not decode /v1/apps response")
            | s == 401 -> Left AscUnauthorized
            | s == 403 -> Left AscUnauthorized
            | otherwise -> Left (AscHttpError s (TE.decodeUtf8 (LBS.toStrict b)))
        Left e -> Left (AscHttpError 0 (T.pack (show e)))

fetchLatestBuildInfo :: Text -> Text -> IO (Either AscError (Maybe AscBuildInfo))
fetchLatestBuildInfo token appId = do
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
        Right (BuildsResp mVer mBuild) -> Right (fmap (\v -> AscBuildInfo v mBuild) mVer)
        Left (HttpStatusError 401 _) -> Left AscUnauthorized
        Left (HttpStatusError 403 _) -> Left AscUnauthorized
        Left (HttpStatusError s b) ->
            Left (AscHttpError s (TE.decodeUtf8 (LBS.toStrict b)))
        Left e -> Left (AscHttpError 0 (T.pack (show e)))

-- ─── Response decoding ─────────────────────────────────────────────

-- | One element of @data[]@ in @/v1/apps?filter[bundleId]=…@.
data AppRef = AppRef {arId :: Text, arBundleId :: Text}

instance FromJSON AppRef where
    parseJSON = withObject "AppRef" $ \o ->
        AppRef
            <$> o .: "id"
            <*> (o .: "attributes" >>= (.: "bundleId"))

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

{- | One element of @data[]@ in a /v1/builds response. The build number
(CFBundleVersion) is at @attributes.version@ — reuse 'IncludedAttrs' (also @.version@).
-}
newtype BuildItem = BuildItem (Maybe IncludedAttrs)

instance FromJSON BuildItem where
    parseJSON = withObject "BuildItem" $ \o -> BuildItem <$> o .:? "attributes"

buildItemNumber :: BuildItem -> Maybe Text
buildItemNumber (BuildItem mAttrs) = mAttrs >>= iaVersion

{- | From @\/v1\/builds@ with @include=preReleaseVersion@: the marketing @version@
from the first included @preReleaseVersions@ record, plus the build number from
@data[0].attributes.version@. Either may be 'Nothing' (e.g. no builds yet).
-}
data BuildsResp = BuildsResp (Maybe Text) (Maybe Text)

instance FromJSON BuildsResp where
    parseJSON = withObject "BuildsResp" $ \o -> do
        items <- fromMaybe [] <$> o .:? "included"
        let mkt =
                listToMaybe $
                    mapMaybe
                        (\it -> if iiType it == "preReleaseVersions" then iiAttrs it >>= iaVersion else Nothing)
                        items
        builds <- fromMaybe [] <$> o .:? "data"
        pure (BuildsResp mkt (listToMaybe (mapMaybe buildItemNumber builds)))

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
    | -- | PENDING_DEVELOPER_RELEASE — approved, held for manual release (NOT live)
      AscApproved
    | -- | READY_FOR_SALE — released, live on the App Store
      AscLive
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
    "READY_FOR_SALE" -> AscLive
    "REJECTED" -> AscRejected "REJECTED"
    "METADATA_REJECTED" -> AscRejected "METADATA_REJECTED"
    "DEVELOPER_REJECTED" -> AscRejected "DEVELOPER_REJECTED"
    other -> AscOther other

-- | Apple's fixed 7-day phased-release schedule. @currentDayNumber@ is
-- 1-BASED (1–7) — verified against a live ACTIVE release (started Jul 6,
-- reported day 6 on Jul 11 ≈ 50%). Day 7 serves 100% until Apple
-- auto-completes. 0 is defensive (never observed) and reads as day 1.
applePhasedPercent :: Int -> Double
applePhasedPercent d = case d of
    0 -> 1
    1 -> 1
    2 -> 2
    3 -> 5
    4 -> 10
    5 -> 20
    6 -> 50
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

-- ── Provider iOS: create the App Store version (Phase 10) ──
--
-- The provider prod lane only runs @upload_to_testflight@, so there is NO App
-- Store version to submit — @getAppStoreVersion@ would 404 with
-- 'AscVersionNotFound'. Rather than change fastlane, SCC creates the version
-- itself and attaches the latest TestFlight build, so the same promote→review
-- flow works for provider apps. Consumer iOS already has the version (fastlane
-- ran @upload_to_app_store@), so for it this is a plain lookup.

{- | Find the App Store version for @versionString@, or create it + attach the
latest TestFlight build when it doesn't exist yet (provider iOS).
-}
ensureAppStoreVersion :: Text -> Text -> Text -> IO (Either AscError AscVersion)
ensureAppStoreVersion token appId versionString =
    getAppStoreVersion token appId versionString >>= \case
        -- Version exists (consumer iOS via fastlane, OR a leftover from a prior
        -- run that created it but failed to attach) → make sure it actually has a
        -- build before submitting; a buildless version can't be reviewed.
        Right ver -> ensureBuildAttached token appId versionString ver
        -- No version yet (provider iOS / store-sync) → create it, then attach.
        Left (AscVersionNotFound _) ->
            createAppStoreVersion token appId versionString >>? \_ ->
                getAppStoreVersion token appId versionString >>? \ver ->
                    ensureBuildAttached token appId versionString ver
        Left e -> pure (Left e)

{- | Ensure the App Store version has a (version-matching) build attached.

A version with no build — a fresh create, or a leftover from a prior run that
created the version but then failed to attach — can't be submitted: the review
call 409s with "the build associated with appStoreVersions … was not found". If a
build is already attached we keep it; otherwise we attach the latest non-expired
TestFlight build for this @versionString@. Makes the whole submit idempotent and
self-healing across retries.
-}
ensureBuildAttached :: Text -> Text -> Text -> AscVersion -> IO (Either AscError AscVersion)
ensureBuildAttached token appId versionString ver =
    getVersionBuildId token (avId ver) >>? \mExisting ->
        case mExisting of
            Just _ -> pure (Right ver)
            Nothing ->
                getLatestBuildIdForVersion token appId versionString >>? \mBuild ->
                    case mBuild of
                        Nothing ->
                            pure
                                ( Left
                                    ( AscBuildNotReady
                                        ("no usable TestFlight build for version " <> versionString <> " to attach")
                                    )
                                )
                        Just buildId ->
                            attachBuildToVersion token (avId ver) buildId >>? \_ -> pure (Right ver)

{- | The build id currently attached to an App Store version, or 'Nothing' if it
has none. (@parseRelId@ reads @data.id@ of the @/build@ relationship.)
-}
getVersionBuildId :: Text -> Text -> IO (Either AscError (Maybe Text))
getVersionBuildId token vid =
    ascGet (ascBase <> "/appStoreVersions/" <> vid <> "/build") token "asc-version-build-id"
        >>? \b -> pure (Right (parseRelId b))

{- | Newest non-expired TestFlight build id whose marketing version (the build's
@preReleaseVersion.version@) matches @versionString@, or 'Nothing'.

Apple requires the build attached to an App Store version to share that version's
@versionString@; attaching a build from a different marketing version fails with
@409 ENTITY_ERROR.RELATIONSHIP.INVALID@ ("the specified pre-release build could
not be added"). So we filter by @preReleaseVersion.version@ rather than taking the
globally-highest build number, which may belong to a newer marketing version.
-}
getLatestBuildIdForVersion :: Text -> Text -> Text -> IO (Either AscError (Maybe Text))
getLatestBuildIdForVersion token appId versionString =
    ascGet
        ( ascBase
            <> "/builds?filter%5Bapp%5D="
            <> appId
            <> "&filter%5BpreReleaseVersion.version%5D="
            <> versionString
            <> "&filter%5Bexpired%5D=false&sort=-version&limit=1"
        )
        token
        "asc-latest-build"
        >>? \b -> pure (Right (listToMaybe (parseLocIds b))) -- parseLocIds = data[].id

-- | Create an IOS App Store version (lands in "Prepare for Submission"); returns its id.
createAppStoreVersion :: Text -> Text -> Text -> IO (Either AscError Text)
createAppStoreVersion token appId versionString =
    let body =
            encode $
                object
                    [ "data"
                        .= object
                            [ "type" .= ("appStoreVersions" :: Text)
                            , "attributes"
                                .= object
                                    [ "platform" .= ("IOS" :: Text)
                                    , "versionString" .= versionString
                                    ]
                            , "relationships" .= object ["app" .= relRef "apps" appId]
                            ]
                    ]
     in ascSend POST (ascBase <> "/appStoreVersions") token body "asc-version-create" >>? \b ->
            pure (maybe (Left (AscHttpError 0 "could not read created appStoreVersion id")) Right (parseCreatedId b))

-- | Point an App Store version at a (TestFlight) build via its build relationship.
attachBuildToVersion :: Text -> Text -> Text -> IO (Either AscError ())
attachBuildToVersion token versionId buildId =
    let body = encode (relRef "builds" buildId)
     in void
            <$> ascSend
                PATCH
                (ascBase <> "/appStoreVersions/" <> versionId <> "/relationships/build")
                token
                body
                "asc-attach-build"

-- ── Live App Store version (for the track-aware iOS bump rule) ──

{- | @data[]@ element of an appStoreVersions response → its @versionString@ plus
whether it's the currently-live (distributable) version. "Live" accepts BOTH
the legacy @appStoreState == READY_FOR_SALE@ and the newer
@state == READY_FOR_DISTRIBUTION@ — Apple is migrating @appStoreState@ → @state@,
and many apps' live versions now report only the new field, so filtering on the
legacy one alone silently dropped their production version.
-}
data VsItem = VsItem (Maybe Text) Bool

instance FromJSON VsItem where
    parseJSON = withObject "VsItem" $ \o -> do
        ma <- o .:? "attributes"
        case ma of
            Nothing -> pure (VsItem Nothing False)
            Just attrs ->
                withObject
                    "attrs"
                    ( \a -> do
                        v <- a .:? "versionString"
                        legacy <- a .:? "appStoreState"
                        modern <- a .:? "state"
                        pure
                            ( VsItem
                                v
                                ( legacy == Just ("READY_FOR_SALE" :: Text)
                                    || modern == Just ("READY_FOR_DISTRIBUTION" :: Text)
                                )
                            )
                    )
                    attrs

newtype LiveVersionResp = LiveVersionResp (Maybe Text)

instance FromJSON LiveVersionResp where
    parseJSON = withObject "LiveVersionResp" $ \o -> do
        items <- fromMaybe [] <$> o .:? "data"
        -- Pick the live version's string (first item flagged live), not just the
        -- first item — the list also contains any in-flight (in-review / prepared)
        -- version.
        pure (LiveVersionResp (listToMaybe [v | VsItem (Just v) True <- items]))

-- ── Live App Store version + its build number (appStoreVersions?include=build) ──

-- | Dig @relationships.build.data.id@ off an appStoreVersions data[] item (the id of
-- the build attached to that store version), or 'Nothing' when no build is attached.
parseBuildRelId :: Object -> Parser (Maybe Text)
parseBuildRelId o = do
    mRels <- o .:? "relationships"
    case mRels :: Maybe Object of
        Nothing -> pure Nothing
        Just rels -> do
            mBuild <- rels .:? "build"
            case mBuild :: Maybe Object of
                Nothing -> pure Nothing
                Just bld -> do
                    mData <- bld .:? "data"
                    case mData :: Maybe Object of
                        Nothing -> pure Nothing
                        Just dd -> dd .:? "id"

-- | An appStoreVersions data[] item: version string, live flag, and the attached
-- build's relationship id.
data LiveVsRel = LiveVsRel (Maybe Text) Bool (Maybe Text)

instance FromJSON LiveVsRel where
    parseJSON = withObject "LiveVsRel" $ \o -> do
        mAttrs <- o .:? "attributes"
        (v, live) <- case mAttrs :: Maybe Object of
            Nothing -> pure (Nothing, False)
            Just a -> do
                vv <- a .:? "versionString"
                legacy <- a .:? "appStoreState"
                modern <- a .:? "state"
                pure
                    ( vv
                    , legacy == Just ("READY_FOR_SALE" :: Text) || modern == Just ("READY_FOR_DISTRIBUTION" :: Text)
                    )
        bid <- parseBuildRelId o
        pure (LiveVsRel v live bid)

-- | An included[] build record (type "builds"): id + version (CFBundleVersion).
data IncludedBuild = IncludedBuild Text (Maybe Text)

instance FromJSON IncludedBuild where
    parseJSON = withObject "IncludedBuild" $ \o -> do
        ty <- o .: "type" :: Parser Text
        bid <- o .: "id"
        mAttrs <- o .:? "attributes"
        pure (IncludedBuild bid (if ty == "builds" then mAttrs >>= iaVersion else Nothing))

-- | (live version string, its build number) from appStoreVersions?include=build.
newtype LiveVersionBuildResp = LiveVersionBuildResp (Maybe (Text, Maybe Text))

instance FromJSON LiveVersionBuildResp where
    parseJSON = withObject "LiveVersionBuildResp" $ \o -> do
        dataItems <- fromMaybe [] <$> o .:? "data"
        included <- fromMaybe [] <$> o .:? "included"
        let buildById = Map.fromList [(bid, mv) | IncludedBuild bid mv <- included]
            mLive = listToMaybe [(v, bid) | LiveVsRel (Just v) True bid <- dataItems]
        pure $
            LiveVersionBuildResp $
                fmap (\(v, mbid) -> (v, (mbid >>= \bid -> Map.lookup bid buildById) >>= id)) mLive

{- | The version string of the currently-live App Store version (legacy
@READY_FOR_SALE@ or the newer @READY_FOR_DISTRIBUTION@), or 'Nothing' if the app
has no live version yet. Fetches the recent iOS versions and selects the live one
rather than filtering server-side on the deprecated @appStoreState@ — that filter
returned nothing for apps whose live version reports only the new @state@. Drives
'computeNextIosVersion'’s bump-vs-reuse decision and the store-sync prod snapshot.
-}
getLiveAppStoreVersionString :: Text -> Text -> IO (Either AscError (Maybe Text))
getLiveAppStoreVersionString token appId =
    ascGet
        (ascBase <> "/apps/" <> appId <> "/appStoreVersions?filter%5Bplatform%5D=IOS&limit=10")
        token
        "asc-live-version"
        >>? \b -> pure (Right (decode b >>= \(LiveVersionResp v) -> v))

-- | The live App Store version string + its build number (CFBundleVersion), in ONE
-- call via @include=build@. Powers the production iOS cell's @+code@ on the monitor
-- and store sync's production snapshot / phased-rollout identity.
getLiveAppStoreVersionAndBuild :: AscCreds -> Text -> IO (Either AscError (Maybe (Text, Maybe Text)))
getLiveAppStoreVersionAndBuild creds bundleId =
    withAscApp creds bundleId $ \token appId ->
        ascGet
            (ascBase <> "/apps/" <> appId <> "/appStoreVersions?filter%5Bplatform%5D=IOS&include=build&fields%5Bbuilds%5D=version&limit=10")
            token
            "asc-live-version-build"
            >>? \b -> pure (Right (decode b >>= \(LiveVersionBuildResp r) -> r))

-- ── Diagnostic: iOS version → state dump ──────────────────────────────

-- | One appStoreVersions item for diagnostics: (versionString, appStoreState, state).
data VsDiag = VsDiag (Maybe Text) (Maybe Text) (Maybe Text)

instance FromJSON VsDiag where
    parseJSON = withObject "VsDiag" $ \o -> do
        ma <- o .:? "attributes"
        case ma of
            Nothing -> pure (VsDiag Nothing Nothing Nothing)
            Just attrs ->
                withObject
                    "attrs"
                    (\a -> VsDiag <$> a .:? "versionString" <*> a .:? "appStoreState" <*> a .:? "state")
                    attrs

newtype VsDiagResp = VsDiagResp [VsDiag]

instance FromJSON VsDiagResp where
    parseJSON = withObject "VsDiagResp" $ \o -> VsDiagResp . fromMaybe [] <$> o .:? "data"

{- | Diagnostic read: each recent iOS appStoreVersion's @(versionString,
appStoreState, state)@, formatted for a log line. Store sync logs this when it
can't resolve a live production version, so an operator can see exactly what the
App Store reports — a state we don't match, the new @state@ field absent, or
genuinely no live version.
-}
getIosVersionStateDump :: AscCreds -> Text -> IO (Either AscError [Text])
getIosVersionStateDump creds bundleId = withAscApp creds bundleId $ \token appId ->
    ascGet
        (ascBase <> "/apps/" <> appId <> "/appStoreVersions?filter%5Bplatform%5D=IOS&limit=10")
        token
        "asc-version-dump"
        >>? \b -> pure (Right (fmtDump (decode b)))
  where
    fmtDump (Just (VsDiagResp xs)) =
        [ fromMaybe "?" v <> " [appStoreState=" <> fromMaybe "-" l <> ", state=" <> fromMaybe "-" s <> "]"
        | VsDiag v l s <- xs
        ]
    fmtDump Nothing = ["<unparseable appStoreVersions response>"]

{- | Read the live (READY_FOR_SALE) App Store version's "What's New" text — the
first non-empty locale. Used to pre-fill the promote dialog for a store-synced
release (where SCC has no changelog of its own). 'Nothing' when there's no live
version or it carries no notes.
-}
getLiveReleaseNotes :: AscCreds -> Text -> IO (Either AscError (Maybe Text))
getLiveReleaseNotes creds bundleId = withAscApp creds bundleId $ \token appId ->
    getLiveAppStoreVersionString token appId >>? \mVer ->
        case mVer of
            Nothing -> pure (Right Nothing)
            Just ver ->
                getAppStoreVersion token appId ver >>? \v ->
                    ascGet
                        (ascBase <> "/appStoreVersions/" <> avId v <> "/appStoreVersionLocalizations")
                        token
                        "asc-locs-read"
                        >>? \b -> pure (Right (firstWhatsNew b))

-- | First non-empty @whatsNew@ across an appStoreVersionLocalizations GET body.
firstWhatsNew :: LBS.ByteString -> Maybe Text
firstWhatsNew bs = decode bs >>= \(WhatsNewLocs xs) -> find (not . T.null . T.strip) xs

newtype WhatsNewLocs = WhatsNewLocs [Text]

instance FromJSON WhatsNewLocs where
    parseJSON = withObject "WhatsNewLocs" $ \o ->
        WhatsNewLocs
            <$> ( o .: "data"
                    >>= mapM
                        (withObject "loc" (\l -> l .: "attributes" >>= withObject "attrs" (\a -> a .:? "whatsNew" .!= "")))
                )

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
    -- find-or-create: consumer iOS already has the version; provider iOS (TestFlight
    -- only) gets the version created + the latest build attached here (Phase 10).
    ensureAppStoreVersion token appId versionString >>? \ver ->
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

{- | Withdraw the app's in-flight App Store review — the inverse of
'submitVersionForReview'. Finds the active @reviewSubmission@ (READY / WAITING /
IN_REVIEW) for the app and PATCHes @canceled:true@ (→ CANCELING → CANCELED), pulling
the build out of review. 'Right ()' no-op if nothing is in flight. iOS only —
Google Play exposes no equivalent.
-}
cancelReviewSubmission :: (MonadFlow m) => AscCreds -> Text -> m (Either AscError ())
cancelReviewSubmission creds bundleId = liftIO $ withAscApp creds bundleId $ \token appId ->
    findActiveReviewSubmission token appId >>? \mSub ->
        maybe (pure (Right ())) (patchCancelReviewSubmission token) mSub

{- | The app's active (cancellable) reviewSubmission id, if any. Brackets +
commas are percent-encoded, matching the other ASC filter queries.
-}
findActiveReviewSubmission :: Text -> Text -> IO (Either AscError (Maybe Text))
findActiveReviewSubmission token appId =
    let url =
            ascBase
                <> "/reviewSubmissions?filter%5Bapp%5D="
                <> appId
                <> "&filter%5Bplatform%5D=IOS"
                <> "&filter%5Bstate%5D=READY_FOR_REVIEW%2CWAITING_FOR_REVIEW%2CIN_REVIEW"
                <> "&limit=1"
     in ascGet url token "asc-review-find" >>? \b ->
            pure (Right (listToMaybe (parseLocIds b))) -- parseLocIds = data[].id

patchCancelReviewSubmission :: Text -> Text -> IO (Either AscError ())
patchCancelReviewSubmission token subId =
    let body =
            encode $
                object
                    [ "data"
                        .= object
                            [ "type" .= ("reviewSubmissions" :: Text)
                            , "id" .= subId
                            , "attributes" .= object ["canceled" .= True]
                            ]
                    ]
     in void <$> ascSend PATCH (ascBase <> "/reviewSubmissions/" <> subId) token body "asc-review-cancel"

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

{- | Configure phased release on a version at submit time; returns the
phasedRelease id.

Created @INACTIVE@ — NOT @ACTIVE@. The version is still in review (not released),
and @ACTIVE@ means "actively ramping", which Apple only permits once the version
is @READY_FOR_SALE@; POSTing @ACTIVE@ on an in-review version is rejected, leaving
the release un-phased. @INACTIVE@ just records the intent; Apple auto-activates
the 7-day ramp when the version is released. Matches the state model in
'AscPhasedState' / 'getPhasedReleaseState' (default @INACTIVE@ → @ACTIVE@).
-}
enablePhasedRelease :: (MonadFlow m) => AscCreds -> Text -> Text -> m (Either AscError Text)
enablePhasedRelease creds bundleId versionString = liftIO $ withAscApp creds bundleId $ \token appId ->
    getAppStoreVersion token appId versionString >>? \ver ->
        getExistingPhasedReleaseId token (avId ver) >>? \mExisting ->
            case mExisting of
                -- Idempotent: a phasedRelease already exists for this version (a
                -- prior submit / retry created it) → reuse it. POSTing another 409s
                -- with ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE.
                Just pid -> pure (Right pid)
                Nothing -> createPhasedRelease token (avId ver)

{- | POST a new INACTIVE phasedRelease for a version; returns its id. (See
'enablePhasedRelease' for why INACTIVE rather than ACTIVE.)
-}
createPhasedRelease :: Text -> Text -> IO (Either AscError Text)
createPhasedRelease token vid =
    let body =
            encode $
                object
                    [ "data"
                        .= object
                            [ "type" .= ("appStoreVersionPhasedReleases" :: Text)
                            , "attributes" .= object ["phasedReleaseState" .= ("INACTIVE" :: Text)]
                            , "relationships" .= object ["appStoreVersion" .= relRef "appStoreVersions" vid]
                            ]
                    ]
     in ascSend POST (ascBase <> "/appStoreVersionPhasedReleases") token body "asc-phased-create" >>? \b ->
            pure (maybe (Left (AscHttpError 0 "could not read phasedRelease id")) Right (parseCreatedId b))

{- | The id of the phasedRelease already attached to a version, or 'Nothing'. The
to-one related-resource GET returns @{"data": null}@ (200) when none exists, so
'parseRelId' yields 'Nothing' there.
-}
getExistingPhasedReleaseId :: Text -> Text -> IO (Either AscError (Maybe Text))
getExistingPhasedReleaseId token vid =
    ascGet (ascBase <> "/appStoreVersions/" <> vid <> "/appStoreVersionPhasedRelease") token "asc-phased-existing"
        >>? \b -> pure (Right (parseRelId b))

-- | Pause / resume / complete a phased release (by its cached id).
pausePhasedRelease
    , resumePhasedRelease
    , completePhasedRelease ::
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

{- | The id of the phasedRelease attached to a version (by version string), or
'Nothing' if none exists. Used to self-heal a release whose promote-time enable
failed to persist the id (e.g. a duplicate-create 409 even though the phased
release exists) — so the release isn't later mistaken for non-phased.
-}
getPhasedReleaseId :: (MonadFlow m) => AscCreds -> Text -> Text -> m (Either AscError (Maybe Text))
getPhasedReleaseId creds bundleId versionString = liftIO $ withAscApp creds bundleId $ \token appId ->
    getAppStoreVersion token appId versionString >>? \ver ->
        getExistingPhasedReleaseId token (avId ver)

{- | Detect an App Store version that is in flight (not the live one) and report
its @(versionString, buildNumber, reviewState)@ — used by store sync to surface a
review that was submitted OUTSIDE SCC. The build number is the attached build's
CFBundleVersion (via @include=build@): the review belongs to that exact build, so
the surfaced row carries full (version, code) identity. Returns 'Nothing' when
there's no in-flight version (only a live @READY_FOR_SALE@ one) or none could be
read. Picks the newest non-live, non-superseded version; the caller decides which
states to surface.
-}
getInFlightReview :: (MonadFlow m) => AscCreds -> Text -> m (Either AscError (Maybe (Text, Maybe Int32, AscReviewState)))
getInFlightReview creds bundleId = liftIO $ withAscApp creds bundleId $ \token appId ->
    ascGet
        (ascBase <> "/apps/" <> appId <> "/appStoreVersions?filter%5Bplatform%5D=IOS&include=build&fields%5Bbuilds%5D=version&limit=5")
        token
        "asc-inflight-review"
        >>? \b -> pure (Right (selectInFlightReview (parseVersionStatesWithBuild b)))

{- | Pick the in-flight (non-live, non-superseded) version + its attached build
number + review state from a parsed @appStoreVersions@ list. Exposed for testing.
-}
selectInFlightReview :: [(Text, Text, Maybe Int32)] -> Maybe (Text, Maybe Int32, AscReviewState)
selectInFlightReview infos =
    listToMaybe
        [ (v, code, appStoreStateToReview s)
        | (v, s, code) <- infos
        , s /= "READY_FOR_SALE"
        , s /= "REPLACED_WITH_NEW_VERSION"
        ]

{- | Parse an @appStoreVersions?include=build@ list body into
@[(versionString, appStoreState, attached build number)]@. Items missing a
version/state are dropped; a missing or non-numeric build resolves to 'Nothing'.
-}
parseVersionStatesWithBuild :: LBS.ByteString -> [(Text, Text, Maybe Int32)]
parseVersionStatesWithBuild bs =
    maybe [] (\(VersionStatesResp xs) -> xs) (decode bs)

-- | One appStoreVersions data[] item: (versionString, appStoreState, build rel id).
data VsStateRel = VsStateRel (Maybe Text) (Maybe Text) (Maybe Text)

instance FromJSON VsStateRel where
    parseJSON = withObject "VsStateRel" $ \o -> do
        mAttrs <- o .:? "attributes"
        (v, s) <- case mAttrs :: Maybe Object of
            Nothing -> pure (Nothing, Nothing)
            Just a -> (,) <$> a .:? "versionString" <*> a .:? "appStoreState"
        bid <- parseBuildRelId o
        pure (VsStateRel v s bid)

newtype VersionStatesResp = VersionStatesResp [(Text, Text, Maybe Int32)]

instance FromJSON VersionStatesResp where
    parseJSON = withObject "VersionStatesResp" $ \o -> do
        items <- fromMaybe [] <$> o .:? "data"
        included <- fromMaybe [] <$> o .:? "included"
        let buildById = Map.fromList [(bid, mv) | IncludedBuild bid mv <- included]
            numOf mRel = readMaybe . T.unpack =<< ((mRel >>= (`Map.lookup` buildById)) >>= id)
        pure $ VersionStatesResp [(v, s, numOf bid) | VsStateRel (Just v) (Just s) bid <- items]

-- ─── Server-config helper ──────────────────────────────────────────

{- | Env-var suffix for a store account: 'Nothing' / blank → @""@ (the default,
unsuffixed key); @"cumta"@ → @"_CUMTA"@. Non-alphanumerics collapse to @_@.
-}
ascAccountSuffix :: Maybe Text -> String
ascAccountSuffix mAcct = case fmap T.strip mAcct of
    Just a | not (T.null a) -> "_" <> T.unpack (T.toUpper (T.map (\c -> if isAlphaNum c then c else '_') a))
    _ -> ""

{- | Read the App Store Connect secrets for a given account from the process
__environment__ (k8s Secret in prod; @local-mobile-secrets.env@ in dev) — never the
DB. The account selects the env suffix ('Nothing' → the default unsuffixed key):

* @SC_ASC_ISSUER_ID[_ACCOUNT]@
* @SC_ASC_KEY_ID[_ACCOUNT]@
* @SC_ASC_PRIVATE_KEY_P8_B64[_ACCOUNT]@ — the @.p8@ PEM, base64-encoded (single line).

Returns 'Nothing' if any is empty — caller surfaces a clear error. No fallback to
the default key for a tagged account: that would hit the wrong Apple team and 403.
-}
loadAscCredsFor :: (MonadFlow m) => Maybe Text -> m (Maybe AscCreds)
loadAscCredsFor mAcct = do
    let sfx = ascAccountSuffix mAcct
    mIssuer <- lookupEnvSecret ("SC_ASC_ISSUER_ID" <> sfx)
    mKeyId <- lookupEnvSecret ("SC_ASC_KEY_ID" <> sfx)
    mP8 <- lookupEnvSecretB64 ("SC_ASC_PRIVATE_KEY_P8_B64" <> sfx)
    pure $ case (mIssuer, mKeyId, mP8) of
        (Just iss, Just kid, Just p8)
            | not (T.null iss) && not (T.null kid) && not (T.null p8) ->
                Just (AscCreds iss kid p8)
        _ -> Nothing

{- | The default-account ASC creds (unsuffixed env). Back-compat for callers with no
app context; per-app callers should use 'loadAscCredsFor' with the app's account.
-}
loadAscCreds :: (MonadFlow m) => m (Maybe AscCreds)
loadAscCreds = loadAscCredsFor Nothing

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
    -- | Store account (@app_catalog.store_account@); 'Nothing' = default ASC key.
    Maybe Text ->
    -- | iOS bundle id (from @app_catalog.package_name@).
    Text ->
    m (Either Text Text)
resolve mAcct bundleId = do
    mCreds <- loadAscCredsFor mAcct
    case mCreds of
        Nothing -> pure (Left (renderAscErr AscCredsMissing))
        Just creds -> do
            res <- liftIO (mintAscToken creds >>? \token -> resolveIosVersionWithToken token bundleId)
            pure (either (Left . renderAscErr) Right res)

{- | Read TestFlight + the live App Store version for an app, then apply the
track-aware iOS bump rule ('computeNextIosVersion'). Shared by the two entry points.
-}
resolveIosVersionWithToken :: Text -> Text -> IO (Either AscError Text)
resolveIosVersionWithToken token bundleId =
    lookupAppByBundleId token bundleId >>? \appId ->
        fetchLatestBuildInfo token appId >>? \mTf ->
            getLiveAppStoreVersionString token appId >>? \mProd ->
                pure (Right (computeNextIosVersion (abiVersion <$> mTf) mProd))

resolveWithToken ::
    (MonadFlow m) =>
    -- | Pre-minted ASC bearer token (shared across a batch).
    Text ->
    -- | iOS bundle id (from @app_catalog.package_name@).
    Text ->
    m (Either Text Text)
resolveWithToken token bundleId = do
    res <- liftIO (resolveIosVersionWithToken token bundleId)
    pure (either (Left . renderAscErr) Right res)
