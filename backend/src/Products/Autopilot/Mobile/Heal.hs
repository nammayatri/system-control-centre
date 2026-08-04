{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- | Store-truth verification for failed mobile build jobs.

A GitHub job conclusion is a CLAIM about the build; the store is the FACT.
A job can fail on a post-upload step (tag push, notify) after the artifact
reached TestFlight / Play — marking such a release failed strands a live
store build. This module gathers the evidence to tell the two apart:

* Layer 1 ('classifyFailedJob') — free: the per-step conclusions already
  parsed from the jobs poll. Upload step green + a later step red ⇒ heal
  candidate; upload step red ⇒ genuine failure, skip everything else.
* Layer 2 ('fetchRunIdentity') — one GET: parse the exact version + build
  number the run computed out of its job log ("Using version_number=…" /
  "Generated build number: …" / "Using version_name=…, version_code=…").
  These are existing workflow echo lines, not a dedicated marker — if they
  are ever reworded, callers degrade to Layer 3's time heuristic.
* Layer 3 ('verifyStoreArtifact') — store truth: exact (version, build)
  confirmation. iOS via a read-only version-scoped ASC builds query
  (@uploadedDate@ disambiguates our upload from older same-version builds
  when the build number is unknown); Android via a cooldown-bypassing
  store_status refresh + (version, code) match.

Callers (the manual verify-store endpoint and the PollMatrixJobs auto-gate)
compose the layers; each layer only runs when the previous one passes.
-}
module Products.Autopilot.Mobile.Heal (
    JobFailureShape (..),
    classifyFailedJob,
    RunIdentity (..),
    parseRunIdentity,
    fetchRunIdentity,
    failedStepOf,
    extractFailureExcerpt,
    StoreVerifyResult (..),
    verifyStoreArtifact,
) where

import Core.Environment (Flow, MonadFlow)
import Data.Char (isDigit, isSpace)
import Data.Int (Int32, Int64)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime)
import Products.Autopilot.Mobile.Github (Job (..), JobStep (..), fetchJobLog)
import Products.Autopilot.Mobile.Github.Auth (GhAppCreds)
import Products.Autopilot.Mobile.Queries.StoreStatus (findStoreTracksForApp)
import Products.Autopilot.Mobile.StoreSync (refreshStoreStatusOneForced)
import Products.Autopilot.Mobile.Types.Storage (AppCatalog, AppCatalogT (..))
import Products.Autopilot.Mobile.Versioning.Apple (
    AscVersionBuild (..),
    fetchBuildsForVersion,
    loadAscCredsFor,
    renderAscErr,
 )
import Text.Read (readMaybe)

-- ─── Layer 1: step-shape classification ────────────────────────────

-- | Where a failed matrix job stopped, relative to its store-upload step.
data JobFailureShape
    = UploadSucceededPostFailure Text
    -- ^ Upload step green; the named later step failed ⇒ heal candidate.
    | UploadFailed
    -- ^ The upload step itself failed ⇒ genuine build failure.
    | UploadNotReached
    -- ^ Job died before the upload step ran ⇒ genuine failure.
    | UploadStepUnknown
    -- ^ No recognisable upload step (provider/custom workflow) — step
    -- evidence is inconclusive; callers may still consult the store.
    deriving (Eq, Show)

{- | Store-upload steps by workflow: consumer iOS runs @"Run Fastlane"@,
consumer Android @"Distribute app to Production 🚀"@ (prefix-matched so the
emoji stays a YAML concern, not ours).
-}
isUploadStep :: Text -> Bool
isUploadStep n =
    n == "Run Fastlane" || "Distribute app to Production" `T.isPrefixOf` n

classifyFailedJob :: Job -> JobFailureShape
classifyFailedJob j =
    case break (isUploadStep . jsName) (jSteps j) of
        (_, []) -> UploadStepUnknown
        (_, upload : after) -> case jsConclusion upload of
            Just "success" ->
                case [jsName s | s <- after, isFailedConclusion (jsConclusion s)] of
                    (s : _) -> UploadSucceededPostFailure s
                    -- Job failed but nothing after a green upload did — a shape
                    -- we can't explain; don't claim the artifact shipped.
                    [] -> UploadStepUnknown
            Just "failure" -> UploadFailed
            Just "timed_out" -> UploadFailed
            -- skipped / cancelled / still-null: the upload never completed.
            _ -> UploadNotReached
  where
    isFailedConclusion c = c `elem` [Just "failure", Just "timed_out", Just "cancelled"]

-- ─── Layer 2: identity from the job log ────────────────────────────

-- | The version identity a run computed for itself, recovered from its log.
data RunIdentity = RunIdentity
    { riVersionName :: Text
    , riVersionCode :: Maybe Int32
    -- ^ iOS build number / Android versionCode. 'Nothing' when the log had
    -- a version line but no parseable code line.
    }
    deriving (Eq, Show)

{- | Parse the workflow's own echo lines out of a raw job log.

The same lines appear twice in a GH log: once inside the @##[group]Run …@
command echo (unexpanded @$VARS@) and once as actual output (real values).
'versionish' (must start with a digit) filters the unexpanded copies, and
candidates are collected across ALL matching lines so one bad hit can't
shadow the real one.
-}
parseRunIdentity :: Text -> Maybe RunIdentity
parseRunIdentity logText =
    case (mIosVer, mAndroidVer) of
        (Just v, _) -> Just (RunIdentity v mIosCode)
        (_, Just v) -> Just (RunIdentity v mAndroidCode)
        _ -> Nothing
  where
    lns = T.lines logText
    valuesAfter needle =
        [ T.takeWhile (\c -> not (isSpace c) && c /= ',') (T.drop (T.length needle) rest)
        | ln <- lns
        , let (_, rest) = T.breakOn needle ln
        , not (T.null rest)
        ]
    versionish t = not (T.null t) && isDigit (T.head t)
    vals needle = filter versionish (valuesAfter needle)
    codeOf t = readMaybe @Int32 (T.unpack (T.takeWhile isDigit t))
    mIosVer = listToMaybe (vals "Using version_number=")
    mIosCode = listToMaybe (mapMaybe codeOf (vals "Generated build number: "))
    mAndroidVer = listToMaybe (vals "Using version_name=")
    mAndroidCode = listToMaybe (mapMaybe codeOf (vals "version_code="))

{- | Fetch a job's log and recover its 'RunIdentity'. 'Left' is always
"evidence unavailable" (log expired, transient 404, lines reworded) —
callers degrade to heuristics, never treat it as a failed heal.
-}
fetchRunIdentity ::
    (MonadFlow m) =>
    GhAppCreds ->
    Text -> -- owner
    Text -> -- repo
    Int64 -> -- job id
    m (Either Text RunIdentity)
fetchRunIdentity creds owner repo jobId = do
    eLog <- fetchJobLog creds owner repo jobId
    pure $ case eLog of
        Left e -> Left e
        Right logText ->
            maybe (Left "no identity lines found in job log") Right (parseRunIdentity logText)

-- ─── Failure detail (what the operator sees on the failed card) ────

-- | The first failed/timed-out step of a job, if any.
failedStepOf :: Job -> Maybe Text
failedStepOf j =
    listToMaybe
        [jsName s | s <- jSteps j, jsConclusion s `elem` [Just "failure", Just "timed_out"]]

{- | Pull the human-readable failure cause out of a raw job log. GH Actions
marks failures with @##[error]@ lines; the real cause (e.g. @fatal: tag …
already exists@, an OOM line) usually sits just above the first marker, so
the excerpt spans a few lines of lead-in through the last marker. Falls
back to trailing @fatal:@/@Error:@ lines when no marker exists. Timestamps
are stripped; output is capped so the UI block stays readable.
-}
extractFailureExcerpt :: Text -> Maybe Text
extractFailureExcerpt logText =
    let lns = map stripStamp (T.lines logText)
        errIdxs = [i | (i, l) <- zip [0 :: Int ..] lns, "##[error]" `T.isInfixOf` l]
        fallback = [l | l <- lns, "fatal:" `T.isInfixOf` l || "Error:" `T.isInfixOf` l]
        excerpt = case (errIdxs, fallback) of
            (i : _, _) ->
                let lo = max 0 (i - 5)
                    hi = last errIdxs
                 in filter (not . T.null) (take (hi - lo + 1) (drop lo lns))
            ([], _ : _) -> takeEnd 5 fallback
            _ -> []
        capped = map (T.take 300) (take 15 excerpt)
     in if null capped then Nothing else Just (T.take 1200 (T.intercalate "\n" capped))
  where
    -- "2026-08-04T10:32:27.1630380Z <content>" → "<content>"
    stripStamp l =
        let (stamp, rest) = T.breakOn " " l
         in if "Z" `T.isSuffixOf` stamp && T.any (== 'T') stamp then T.drop 1 rest else l
    takeEnd n xs = drop (max 0 (length xs - n)) xs

-- ─── Layer 3: store confirmation ───────────────────────────────────

data StoreVerifyResult
    = ArtifactFound (Maybe Int32)
    -- ^ The store has it; carries the observed build code when the store
    -- reports one (lets callers stamp @version_code@ on iOS rows).
    | ArtifactMissing
    -- ^ Fresh store read, no matching artifact — the CI failure was real.
    | VerifyErrored Text
    -- ^ Could not ask the store (creds/config/API) — inconclusive, retryable.
    deriving (Eq, Show)

{- | Does the store hold the SPECIFIC artifact this run claims to have
uploaded? Matching version alone is not enough — same-version rebuilds mean
an older build of the version may legitimately exist; the discriminator is
the exact code when known, else upload time after the build started.

iOS: read-only ASC query scoped to the version (no Play-style edit cost).
Android: forced store_status refresh (bypasses cooldown — a heal must not
read a minutes-old cache) + exact (version, code) match on this app's rows.
Debug deployments have no store; callers gate on destination/build type
before calling.
-}
verifyStoreArtifact ::
    AppCatalog ->
    Text -> -- version name, e.g. "3.3.151"
    Maybe Int32 -> -- exact build code when known (tag/log/dispatch)
    Maybe UTCTime -> -- build start; time anchor when the code is unknown
    Flow StoreVerifyResult
verifyStoreArtifact ac version mCode mSince
    | acPlatform ac == "ios" = do
        mCreds <- loadAscCredsFor (acStoreAccount ac)
        case (mCreds, acPackageName ac) of
            (Nothing, _) -> pure (VerifyErrored "asc credentials not configured for this store account")
            (_, Nothing) -> pure (VerifyErrored "app has no bundle id (app_catalog.package_name)")
            (Just creds, Just bundleId) -> do
                eBuilds <- fetchBuildsForVersion creds bundleId version
                pure $ case eBuilds of
                    Left e -> VerifyErrored (renderAscErr e)
                    Right builds ->
                        let codeOf b = readMaybe @Int32 . T.unpack =<< avbBuildNumber b
                            hits = case (mCode, mSince) of
                                (Just c, _) -> [b | b <- builds, codeOf b == Just c]
                                (Nothing, Just since) ->
                                    [b | b <- builds, maybe False (>= since) (avbUploadedDate b)]
                                -- No code and no time anchor: any same-version
                                -- build is too weak a claim to heal on.
                                (Nothing, Nothing) -> []
                         in case hits of
                                (b : _) -> ArtifactFound (codeOf b)
                                [] -> ArtifactMissing
    | otherwise = do
        refreshStoreStatusOneForced ac
        rows <- findStoreTracksForApp (acId ac)
        let hits =
                [ mObs
                | (_track, vName, mObs) <- rows
                , vName == version
                , maybe True (\c -> mObs == Just c) mCode
                ]
        pure $ case hits of
            (mObs : _) -> ArtifactFound mObs
            -- store_status keeps only each track's LATEST build: if a newer
            -- build landed after ours, ours can't be confirmed here — the
            -- operator sees "missing" and resolves manually. Rare, accepted.
            [] -> ArtifactMissing
