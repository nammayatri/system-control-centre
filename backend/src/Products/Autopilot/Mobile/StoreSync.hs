{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | Periodic sync of live store versions into @release_tracker@.

Polls Google Play (production track) and App Store Connect for every
enabled app in @app_catalog@. If the store version is newer than the
latest COMPLETED row in @release_tracker@, inserts a synthetic
COMPLETED row so the "latest build" badges on the frontend stay fresh
even for releases shipped outside SCC.

Entry point: 'runStoreSync' — designed to be called from a long-interval
background loop in 'Products.Autopilot.Runner'.
-}
module Products.Autopilot.Mobile.StoreSync (
    runStoreSync,
    storeSyncLoop,
    reconcileActiveRollouts,
    -- * Pure reconcile decision (unit-tested)
    ReconcileAction (..),
    androidReconcileAction,
    iosPhasedReconcileAction,
    ExternalReviewAction (..),
    externalReviewAction,
    reviewStateToStatus,
    pendingPublishRelease,
    detectConsoleRollout,
    detectIosRelease,
    -- * App Release Monitoring (store_status cache)
    syncStoreStatus,
    refreshStoreStatusOne,
) where

import Control.Exception (SomeException)
import qualified Control.Monad.Catch as MC
import Control.Monad.IO.Class (liftIO)
import Core.Environment (Flow, MonadFlow, logError, logInfo, logWarning)
import Core.Types.Time (threadDelaySec)
import Data.Aeson (object, (.=))
import Data.Char (isAlphaNum)
import Data.Int (Int32)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Products.Autopilot.Mobile.Queries.AppCatalog (
    LatestBuildRow (..),
    TrackSnapshot (..),
    fetchLatestBuildsPerApp,
    listAppCatalog,
    listEnabledAppCatalog,
 )
import Products.Autopilot.Mobile.Queries.StoreStatus (
    ActiveMobileState (..),
    StoreStatusUpsert (..),
    findActiveMobileState,
    latestShippedVersionsPerApp,
    upsertStoreStatus,
 )
import Products.Autopilot.Mobile.Queries.Tracker (
    appCatalogForRowRaw,
    completeExternalReviewRow,
    findActiveRolloutReleases,
    findMobileAwaitingRollout,
    findExternalReviewRow,
    logEvent,
    mkMobileTrackerRow,
    parseMobileTargetState,
    sccActiveReleaseExistsForVersion,
    setAscIds,
    setExternalReviewState,
    setMobileWfStatus,
    setRolloutState,
    setStoreSyncMetadata,
    updateStoreSyncBuildCode,
 )
import Products.Autopilot.Mobile.Types (
    MobileBuildContext (..),
    MobileBuildTargetState (..),
    MobileBuildWFStatus (..),
    isDebugBuildType,
 )
import Products.Autopilot.Mobile.Types.Storage (AppCatalog, AppCatalogT (..))
import Products.Autopilot.Mobile.Versioning.Apple (
    AscBuildInfo (..),
    AscCreds,
    AscPhasedState (..),
    AscReviewState (..),
    AscSnapshot (..),
    applePhasedPercent,
    fetchAscBuildInfo,
    fetchAscSnapshots,
    getAscReviewState,
    getInFlightReview,
    getLiveAppStoreVersion,
    getPhasedReleaseId,
    getPhasedReleaseState,
    loadAscCreds,
    renderAscErr,
 )
import Text.Read (readMaybe)
import Products.Autopilot.Mobile.Versioning.Play (
    PlayCreds (..),
    PlayRolloutState (..),
    ProdTrackRelease (..),
    StoreTrackSnapshot (..),
    TrackInfo (..),
    fetchPlayTracks,
    fetchTrackSnapshots,
    getProductionReleases,
    getTrackRolloutState,
    loadPlayCreds,
    renderPlayErr,
 )
import Products.Autopilot.Queries.ReleaseTracker (
    encodeJsonText,
    insertReleaseEvent,
    insertReleaseTrackerRowIfAbsent,
 )
import Products.Autopilot.RuntimeConfig (getMobileBuildType, getStoreSyncIntervalMinutes, isStagedRolloutEnabled, isStoreSyncEnabled)
import Products.Autopilot.Types.Storage.Schema (ReleaseTrackerRow, ReleaseTrackerT (..))
import Products.Autopilot.Types.Target (TargetState (..))

type BuildMap = Map.Map (Text, Text, Text) LatestBuildRow

storeSyncLoop :: Flow ()
storeSyncLoop = do
    logInfo "[STORE_SYNC] Background loop started"
    loop
  where
    loop = do
        result <- MC.try @_ @SomeException $ do
            -- Store sync polls PRODUCTION stores and records release builds, so
            -- it only makes sense in a release env. In a debug env it's a no-op
            -- regardless of store_sync_enabled — never pull production data into
            -- a debug deployment.
            buildType <- getMobileBuildType
            if isDebugBuildType buildType
                then logInfo "[STORE_SYNC] Debug build env, skipping (release-only)"
                else do
                    enabled <- isStoreSyncEnabled
                    if enabled
                        then do
                            runStoreSync
                            -- App Release Monitoring: refresh the per-track
                            -- store_status cache (all apps, enabled or not).
                            -- Isolated so a cache failure (e.g. store_status not
                            -- yet migrated on a fresh deploy) can't starve the
                            -- staged-rollout reconcile that follows.
                            safeSyncStoreStatus
                        else logInfo "[STORE_SYNC] Disabled via server_config, skipping"
                    -- Phase 7: reconcile active staged rollouts with the live store
                    -- state (Apple's auto-ramp %, external halt/resume, completion).
                    -- Independent of store_sync_enabled — it's the staged-rollout
                    -- feature, gated on its own flag.
                    staged <- isStagedRolloutEnabled
                    if staged
                        then reconcileActiveRollouts
                        else pure ()
            interval <- getStoreSyncIntervalMinutes
            threadDelaySec (interval * 60)
        case result of
            Left e ->
                logError $
                    "[STORE_SYNC] Iteration failed (continuing): " <> T.pack (show e)
            Right () -> pure ()
        loop

runStoreSync :: Flow ()
runStoreSync = do
    logInfo "[STORE_SYNC] Starting store sync"
    apps <- listEnabledAppCatalog
    builds <- fetchLatestBuildsPerApp
    let buildMap =
            Map.fromList
                [ ((lbrAppGroup b, lbrSurface b, lbrPlatform b), b)
                | b <- builds
                ]
    mPlayCreds <- loadPlayCreds
    mAscCreds <- loadAscCreds
    mapM_ (syncApp mPlayCreds mAscCreds buildMap) apps
    logInfo $ "[STORE_SYNC] Finished — checked " <> T.pack (show (length apps)) <> " app(s)"

syncApp ::
    Maybe PlayCreds ->
    Maybe AscCreds ->
    BuildMap ->
    AppCatalog ->
    Flow ()
syncApp mPlayCreds mAscCreds buildMap ac = do
    let key = (acName ac, acSurface ac, acPlatform ac)
        existing = Map.lookup key buildMap
    case acPlatform ac of
        "android" -> case mPlayCreds of
            Nothing ->
                logWarning $ "[STORE_SYNC] No Play Console creds — skipping " <> acName ac
            Just creds -> do
                syncAndroid creds ac existing
                -- Also surface an out-of-band production submission pending review/publish.
                syncAndroidExternalReview creds ac
        "ios" -> case mAscCreds of
            Nothing ->
                logWarning $ "[STORE_SYNC] No ASC creds — skipping " <> acName ac
            Just creds -> do
                syncIos creds ac existing
                -- Also surface an App Store review that was started outside SCC.
                syncIosExternalReview creds ac
        p ->
            logWarning $ "[STORE_SYNC] Unknown platform " <> p <> " for " <> acName ac

syncAndroid :: PlayCreds -> AppCatalog -> Maybe LatestBuildRow -> Flow ()
syncAndroid creds ac existing = do
    pkgName <- case acPackageName ac of
        Just p | not (T.null p) -> pure p
        _ -> do
            logWarning $ "[STORE_SYNC] No package name for " <> acName ac <> ", skipping"
            pure ""
    if T.null pkgName
        then pure ()
        else do
            result <- fetchPlayTracks creds pkgName
            case result of
                Left e ->
                    logWarning $
                        "[STORE_SYNC] Play API error for "
                            <> acName ac
                            <> ": "
                            <> renderPlayErr e
                Right (internal, production) -> do
                    -- Record BOTH tracks. The leading track owns the synthetic row's
                    -- version/badge: internal when its build code is ahead (an
                    -- internal-only build pending promotion), else production. Both
                    -- tracks are written to metadata.tracks so the create page can show
                    -- and diff against either (default base = production).
                    let internalAhead = tiCode internal > tiCode production
                        (chosen, track) = if internalAhead then (internal, "internal") else (production, "production")
                        chosenVer = tiName chosen
                        chosenCode = Just (tiCode chosen)
                        tagFor = chosenVer <> "+" <> T.pack (show (tiCode chosen))
                        mkSnap ti =
                            TrackSnapshot
                                { tsVersion = tiName ti
                                , tsCode = Just (tiCode ti)
                                , tsTag = derivedStoreTag ac (tiName ti) (Just (tiCode ti))
                                }
                        -- internal is a distinct track only when ahead; otherwise
                        -- internal == production and one "production" entry suffices.
                        tracks =
                            Map.fromList $
                                ("production", mkSnap production)
                                    : [("internal", mkSnap internal) | internalAhead]
                        metaJson = buildStoreMeta track tracks
                    if isNewerAndroid chosen existing
                        then case existing of
                            -- Same version, build code bumped → update the snapshot's code +
                            -- tag in place (the version-keyed dedup index blocks a re-insert).
                            Just lb
                                | lbrVersion lb == chosenVer -> do
                                    logInfo $ "[STORE_SYNC] Play build bump for " <> acName ac <> " (" <> track <> "): " <> tagFor
                                    updateStoreSyncBuildCode ac chosenVer chosenCode (derivedStoreTag ac chosenVer chosenCode)
                                    setStoreSyncMetadata ac chosenVer metaJson
                            -- New version → insert a fresh row.
                            _ -> do
                                logInfo $ "[STORE_SYNC] New Play version for " <> acName ac <> " (" <> track <> "): " <> tagFor
                                insertSyntheticRelease ac chosenVer chosenCode track tracks
                        else
                            -- Leading row unchanged — still refresh metadata.tracks so a
                            -- moved production version doesn't lag the stored snapshot.
                            setStoreSyncMetadata ac chosenVer metaJson

syncIos :: AscCreds -> AppCatalog -> Maybe LatestBuildRow -> Flow ()
syncIos creds ac existing = do
    bundleId <- case acPackageName ac of
        Just p | not (T.null p) -> pure p
        _ -> do
            logWarning $ "[STORE_SYNC] No bundle id for " <> acName ac <> ", skipping"
            pure ""
    if T.null bundleId
        then pure ()
        else do
            result <- fetchAscBuildInfo creds bundleId
            case result of
                Left e ->
                    logWarning $
                        "[STORE_SYNC] ASC API error for "
                            <> acName ac
                            <> ": "
                            <> renderAscErr e
                Right Nothing ->
                    logInfo $ "[STORE_SYNC] No ASC version found for " <> acName ac
                Right (Just bi) -> do
                    -- The iOS tag is derived from the build number (CFBundleVersion), the same
                    -- way Android uses its version code, so the changelog has a baseline.
                    -- Unparseable build number → no code → no tag (graceful fallback).
                    let storeVer = abiVersion bi
                        mCode = abiBuildNumber bi >>= readMaybe . T.unpack :: Maybe Int32
                    -- Live App Store (production) version, best-effort — labels the
                    -- production track. We read only the version (no build code), so the
                    -- prod base carries a version but no tag: the create page shows it and
                    -- a prod-base diff falls back. TestFlight is the "internal" track.
                    mProdVer <- either (const Nothing) id <$> liftIO (getLiveAppStoreVersion creds bundleId)
                    let tfSnap =
                            TrackSnapshot
                                { tsVersion = storeVer
                                , tsCode = mCode
                                , tsTag = derivedStoreTag ac storeVer mCode
                                }
                        tracks =
                            Map.fromList $
                                ("internal", tfSnap)
                                    : maybe [] (\pv -> [("production", TrackSnapshot pv Nothing Nothing)]) mProdVer
                        metaJson = buildStoreMeta "testflight" tracks
                    if isNewerIos storeVer existing
                        then do
                            logInfo $
                                "[STORE_SYNC] New ASC version for "
                                    <> acName ac
                                    <> ": "
                                    <> storeVer
                                    <> maybe "" (\c -> " (build " <> T.pack (show c) <> ")") mCode
                            insertSyntheticRelease ac storeVer mCode "testflight" tracks
                        else case (existing, mCode) of
                            -- Same version, new TestFlight build number (e.g. 3.3.73(1) → (2)).
                            -- isNewerIos only compares the version name, so this is the only
                            -- path that catches a same-version rebuild → update code + tag in place.
                            (Just lb, Just newC)
                                | lbrVersion lb == storeVer && Just newC /= lbrVersionCode lb -> do
                                    logInfo $ "[STORE_SYNC] ASC build bump for " <> acName ac <> ": " <> storeVer <> "+" <> T.pack (show newC)
                                    updateStoreSyncBuildCode ac storeVer mCode (derivedStoreTag ac storeVer mCode)
                                    setStoreSyncMetadata ac storeVer metaJson
                            _ -> setStoreSyncMetadata ac storeVer metaJson

isNewerAndroid :: TrackInfo -> Maybe LatestBuildRow -> Bool
isNewerAndroid store Nothing = tiName store /= "0.0.0"
isNewerAndroid store (Just lb)
    | tiName store /= lbrVersion lb = tiName store /= "0.0.0"
    | otherwise = tiCode store > fromMaybe 0 (lbrVersionCode lb)

isNewerIos :: Text -> Maybe LatestBuildRow -> Bool
isNewerIos _ Nothing = True
isNewerIos ver (Just lb) = ver /= lbrVersion lb

-- ─── Out-of-band (external) review detection ───────────────────────

{- | Surface an App Store version that's in review but was submitted OUTSIDE SCC.
Each pass reads the in-flight (non-live) version + its review state, then
reconciles a single synthetic @EXTERNAL_REVIEW@ row against it — create / update /
complete — so the UI reflects reality. Skipped when an actual SCC release already
tracks the version (SCC owns that review). iOS only; Play review state is opaque. -}
syncIosExternalReview :: AscCreds -> AppCatalog -> Flow ()
syncIosExternalReview creds ac = case acPackageName ac of
    Just bundleId | not (T.null bundleId) -> do
        existing <- findExternalReviewRow (acName ac) (acSurface ac) (acPlatform ac)
        getInFlightReview creds bundleId >>= \case
            Left e -> logWarning $ "[STORE_SYNC] ASC in-flight review read error for " <> acName ac <> ": " <> renderAscErr e
            Right mInFlight -> reconcileExternalReview ac existing mInFlight
    _ -> pure ()

{- | Surface an out-of-band PRODUCTION submission that's pending review/publish but
was NOT submitted from SCC. Google's Publishing API exposes no review state, but
this deployment's workflow is consistent — every submission is staged at a near-
zero @userFraction@ with managed publishing on — so an @inProgress@ production
release sitting at that near-zero fraction, with a version code above the live
(@completed@) one, reliably means "submitted, awaiting review/publish" (covering
in-review and approved-but-held alike). Mapped to the same @EXTERNAL_REVIEW@ row
the iOS detector uses, but flagged @inferred@ since the state is derived from the
track, not read authoritatively. Skipped when an SCC release already owns the
version. The one blind spot — a rejected version reverting to @completed@ — clears
the row as if it published (documented; rejections surface via the Console). -}
syncAndroidExternalReview :: PlayCreds -> AppCatalog -> Flow ()
syncAndroidExternalReview creds ac = case acPackageName ac of
    Just pkg | not (T.null pkg) -> do
        existing <- findExternalReviewRow (acName ac) (acSurface ac) (acPlatform ac)
        getProductionReleases creds pkg >>= \case
            Left e -> logWarning $ "[STORE_SYNC] Play production-track read error for " <> acName ac <> ": " <> renderPlayErr e
            Right releases ->
                let mPending = pendingPublishRelease androidPendingFractionThreshold releases
                    -- Android can't distinguish in-review from approved-held, so a
                    -- pending version always surfaces as MBInReview ("Pending review").
                    mMapped = (\(version, _) -> (version, "in_review", MBInReview)) <$> mPending
                 in reconcileExternalReviewMapped ac (snd <$> mPending) True existing mMapped
    _ -> pure ()

{- | Below this production-rollout @userFraction@ a release is treated as "not yet
ramped" — a freshly-submitted / approved-held version parked at the near-zero
review fraction, not an active staged rollout. This deployment always submits at
~1e-6, so a 1% cutoff leaves wide margin while still excluding any real rollout
step. (Out-of-band rollouts ramped above this are intentionally not surfaced as
pending — they're past review and exposing users.) -}
androidPendingFractionThreshold :: Double
androidPendingFractionThreshold = 0.01

{- | Pick the out-of-band "pending review/publish" version from the production
track: the highest-code @inProgress@ release sitting at a sub-threshold
@userFraction@ whose code is newer than the live (@completed@) version. 'Nothing'
when there's no such release — only a live version, or a version already rolling
out at a real fraction. Pure — unit-tested ([41]). -}
pendingPublishRelease :: Double -> [ProdTrackRelease] -> Maybe (Text, Int32)
pendingPublishRelease threshold releases = case best of
    Just r | ptrCode r > liveCode -> Just (ptrName r, ptrCode r)
    _ -> Nothing
  where
    liveCode = maximum (0 : [ptrCode r | r <- releases, ptrStatus r == "completed"])
    -- inProgress + parked at a near-zero fraction (require an explicit fraction:
    -- a missing one is malformed, so don't surface it).
    pending =
        [ r
        | r <- releases
        , ptrStatus r == "inProgress"
        , maybe False (< threshold) (ptrUserFraction r)
        ]
    best = foldr higher Nothing pending
    higher r Nothing = Just r
    higher r (Just a) = Just (if ptrCode r >= ptrCode a then r else a)

-- | Reconcile the external-review row against the live iOS in-flight review state.
-- iOS reads an authoritative review state from ASC, so @inferred = False@ and the
-- version code is left unset (the release path self-heals the ASC ids).
reconcileExternalReview :: AppCatalog -> Maybe ReleaseTrackerRow -> Maybe (Text, AscReviewState) -> Flow ()
reconcileExternalReview ac existing mInFlight =
    reconcileExternalReviewMapped ac Nothing False existing $
        mInFlight >>= \(v, rs) -> (\(rstatus, wf) -> (v, rstatus, wf)) <$> reviewStateToStatus rs

-- | Reconcile the external-review row against an already-mapped @(version,
-- review_status, wf_status)@ ('Nothing' = nothing to surface). Shared by the iOS
-- (authoritative) and Android (inferred) detectors. The decision is pure
-- ('externalReviewAction'); this runs the side effects.
--
--   * @mCode@     — version code stamped on a fresh row (Android needs it to drive
--                   a later rollout; iOS passes 'Nothing').
--   * @inferred@  — whether the review state is inferred from the track rather than
--                   read authoritatively (Android), which softens the row's label.
reconcileExternalReviewMapped ::
    AppCatalog ->
    Maybe Int32 ->
    Bool ->
    Maybe ReleaseTrackerRow ->
    Maybe (Text, Text, MobileBuildWFStatus) ->
    Flow ()
reconcileExternalReviewMapped ac mCode inferred existing mMapped = do
    let mExistingId = rtId <$> existing
        -- Carry the existing row's operator-set review_status so an inferred pass
        -- can't downgrade an approve/reject (defaults to in_review if unset).
        mExisting = (\r -> (rtNewVersion r, fromMaybe "in_review" (rtReviewStatus r))) <$> existing
    -- Only the dedup check needs a DB read, and only when there's a version to check.
    sccOwns <- case mMapped of
        Just (version, _, _) -> sccActiveReleaseExistsForVersion (acName ac) (acSurface ac) (acPlatform ac) version
        Nothing -> pure False
    case externalReviewAction inferred mExisting mMapped sccOwns of
        ExtNoop -> pure ()
        ExtComplete -> mapM_ completeExternalReviewRow mExistingId
        ExtUpdate reviewStatus wf -> mapM_ (\i -> setExternalReviewState i reviewStatus wf) mExistingId
        ExtInsert version reviewStatus wf -> insertExternalReviewRow ac mCode inferred version reviewStatus wf
        ExtRetireAndInsert version reviewStatus wf -> do
            mapM_ completeExternalReviewRow mExistingId
            insertExternalReviewRow ac mCode inferred version reviewStatus wf

-- | What to do with the external-review row this pass.
data ExternalReviewAction
    = ExtNoop
    | -- | complete the existing row
      ExtComplete
    | -- | update the existing row's (review_status, wf-status)
      ExtUpdate Text MobileBuildWFStatus
    | -- | insert a fresh row (version, review_status, wf-status)
      ExtInsert Text Text MobileBuildWFStatus
    | -- | complete the existing row (different version) + insert the new one
      ExtRetireAndInsert Text Text MobileBuildWFStatus
    deriving (Eq, Show)

{- | Pure reconcile decision for the external-review row. Inputs: whether the
review state is @inferred@ (Android) rather than authoritative (iOS); the existing
row's @(version, review_status)@ (if any); the in-flight @(version, review_status,
wf_status)@ we'd surface ('Nothing' = nothing to surface — draft/live/unknown);
and whether an actual SCC release already owns that version. Unit-tested.

The @inferred@ guard protects an Android operator decision. Store sync can only
ever infer @"in_review"@ for Android, so once the operator has marked the row
@approved@ / @rejected@ it must NOT be downgraded back to @"in_review"@ on the
next pass — that was silently erasing the approval. iOS is authoritative, so its
state always wins (including a genuine rejected → resubmitted → in-review). -}
externalReviewAction ::
    Bool ->
    Maybe (Text, Text) ->
    Maybe (Text, Text, MobileBuildWFStatus) ->
    Bool ->
    ExternalReviewAction
externalReviewAction inferred mExisting mMapped sccOwns = case mMapped of
    -- Nothing in review (only a live / draft version) → retire any stale row.
    Nothing -> retireExisting
    Just (version, reviewStatus, mbStatus)
        -- SCC already tracks this version → drop ours so it isn't double-shown.
        | sccOwns -> retireExisting
        | otherwise -> case mExisting of
            Nothing -> ExtInsert version reviewStatus mbStatus
            Just (ev, eStatus)
                | ev /= version -> ExtRetireAndInsert version reviewStatus mbStatus
                -- Never let an inferred "in_review" overwrite an operator's
                -- approve/reject on the same version (Android persistence fix).
                | inferred && isOperatorDecided eStatus && reviewStatus == "in_review" -> ExtNoop
                | otherwise -> ExtUpdate reviewStatus mbStatus
  where
    retireExisting = maybe ExtNoop (const ExtComplete) mExisting
    isOperatorDecided s = s == "approved" || s == "rejected"

-- | Map a review state to @(review_status, mb_wf_status)@; 'Nothing' for states we
-- don't surface (prepare-for-submission / live / unknown).
reviewStateToStatus :: AscReviewState -> Maybe (Text, MobileBuildWFStatus)
reviewStateToStatus = \case
    AscWaitingForReview -> Just ("in_review", MBInReview)
    AscInReview -> Just ("in_review", MBInReview)
    AscApproved -> Just ("approved", MBReviewApproved)
    AscRejected _ -> Just ("rejected", MBReviewRejected)
    _ -> Nothing

-- | The human-readable description / changelog for an external-review row.
-- @inferred@ (Android) softens it to "pending" because the review state is
-- derived from the track, not read authoritatively; iOS phrases by exact state.
externalRowDescription :: Bool -> Text -> Text
externalRowDescription True _ =
    "Pending review/publish — submitted outside SCC (Android review state isn't exposed by Google)"
externalRowDescription False reviewStatus = case reviewStatus of
    "approved" -> "Approved — submitted outside SCC"
    "rejected" -> "Rejected — submitted outside SCC"
    _ -> "In review — submitted outside SCC"

-- | Insert a fresh @EXTERNAL_REVIEW@ row reflecting an out-of-band store review.
-- mode 'EXTERNAL_REVIEW' + no dispatch_id keeps it clear of the build runner, the
-- rollout reconciler, and the store-sync version dedup index. @mCode@ stamps the
-- version code (Android, for a later rollout); @inferred@ marks the review state
-- as track-derived rather than authoritative (Android) — surfaced in metadata so
-- the UI labels it "Pending review" instead of a confident "In review".
insertExternalReviewRow :: AppCatalog -> Maybe Int32 -> Bool -> Text -> Text -> MobileBuildWFStatus -> Flow ()
insertExternalReviewRow ac mCode inferred version reviewStatus mbStatus = do
    rid <- liftIO (UUID.toText <$> UUID.nextRandom)
    now <- liftIO getCurrentTime
    let desc = externalRowDescription inferred reviewStatus
        ctx =
            MobileBuildContext
                { mbcVersionCode = mCode
                , mbcChangeLog = desc
                , mbcBuildType = "release"
                , mbcReleaseGroupId = rid
                , mbcMatrixJobName = acName ac <> "-Review"
                , mbcOtaNamespace = Nothing
                , mbcTagPushed = Nothing
                , mbcDestination = Nothing
                }
        targetState =
            MobileBuildTargetState
                { mbWfStatus = mbStatus
                , mbContext = ctx
                , mbExternalRunId = Nothing
                , mbMatrixJobStatus = Nothing
                , mbBuildStartedAt = Just now
                , mbBuildCompletedAt = Nothing
                , mbResolveAttempts = Nothing
                , mbReviewSubmittedAt = Just now
                , mbReviewLastPolledAt = Just now
                }
        base = mkMobileTrackerRow rid ac targetState (Just version) Nothing "store-sync" now
        row =
            base
                { rtStatus = "INPROGRESS"
                , rtReleaseWFStatus = "INPROGRESS"
                , rtMode = Just "EXTERNAL_REVIEW"
                , rtIsApproved = Just True
                , rtIsInfraApproved = Just True
                , rtReviewStatus = Just reviewStatus
                , rtReviewSubmittedAt = Just now
                , rtDescription = Just desc
                -- No store_track: it's a pending submission, not live on a track,
                -- so don't let the UI badge it as a live production build.
                -- review_inferred (Android) flags the state as best-effort.
                , rtMetadata =
                    Just (encodeJsonText (object (["external" .= True] <> ["review_inferred" .= True | inferred])))
                }
    -- ON CONFLICT DO NOTHING against uq_release_tracker_external_review: if a
    -- concurrent pass / replica already recorded this app's external review, skip.
    inserted <- insertReleaseTrackerRowIfAbsent row
    if not inserted
        then logInfo $ "[STORE_SYNC] External review already recorded for " <> acName ac <> " (skipped)"
        else do
            logInfo $ "[STORE_SYNC] External review detected for " <> acName ac <> " v" <> version <> " (" <> reviewStatus <> ")"
            insertReleaseEvent rid "BUSINESS" "EXTERNAL_REVIEW_DETECTED" $
                object ["app" .= acName ac, "platform" .= acPlatform ac, "version" .= version, "review_status" .= reviewStatus, "inferred" .= inferred]

-- Store sync observes real store releases, so synthetic rows are always
-- "release" build type. The @track@ records which store track this build is the
-- current latest on ("production" | "internal" | "testflight") — surfaced as a
-- badge in the UI via @metadata.store_track@.
insertSyntheticRelease ::
    (MonadFlow m) =>
    AppCatalog ->
    Text ->
    Maybe Int32 ->
    -- | store track: "production" | "internal" | "testflight"
    Text ->
    -- | per-track snapshots written to @metadata.tracks@
    Map.Map Text TrackSnapshot ->
    m ()
insertSyntheticRelease ac version mCode track tracks = do
    rid <- liftIO (UUID.toText <$> UUID.nextRandom)
    groupId <- liftIO (UUID.toText <$> UUID.nextRandom)
    now <- liftIO getCurrentTime
    let derivedTag = derivedStoreTag ac version mCode
        ctx =
            MobileBuildContext
                { mbcVersionCode = mCode
                , mbcChangeLog = "Synced from store"
                , mbcBuildType = "release"
                , mbcReleaseGroupId = groupId
                , mbcMatrixJobName = acName ac <> "-Release"
                , mbcOtaNamespace = Nothing
                , mbcTagPushed = derivedTag
                , mbcDestination = Nothing
                }
        targetState =
            MobileBuildTargetState
                { mbWfStatus = MBCompleted
                , mbContext = ctx
                , mbExternalRunId = Nothing
                , mbMatrixJobStatus = Just "completed"
                , mbBuildStartedAt = Just now
                , mbBuildCompletedAt = Just now
                , mbResolveAttempts = Nothing
                , mbReviewSubmittedAt = Nothing
                , mbReviewLastPolledAt = Nothing
                }
        encodedCtx = encodeJsonText (MobileBuildState targetState)
        row =
            ReleaseTrackerT
                { rtId = rid
                , rtOldVersion = ""
                , rtNewVersion = version
                , rtAppGroup = acName ac
                , rtService = acSurface ac
                , rtPriority = 0
                , rtEnv = acPlatform ac
                , rtCategory = "MobileBuild"
                , rtStatus = "COMPLETED"
                , rtReleaseWFStatus = "COMPLETED"
                , rtMode = Just "STORE_SYNC"
                , rtCreatedBy = "store-sync"
                , rtApprovedBy = Nothing
                , rtIsApproved = Just True
                , rtIsInfraApproved = Just True
                , rtReleaseTag = Just rid
                , rtScheduleTime = Nothing
                , rtStartTime = Just now
                , rtEndTime = Just now
                , rtRolloutStrategy = Nothing
                , rtRolloutHistory = Nothing
                , rtTargetState = Just encodedCtx
                , rtInfo = Nothing
                , rtDescription = Just ("Imported from store (" <> track <> ")")
                , rtChangeLog = Nothing
                , rtMetadata = Just (buildStoreMeta track tracks)
                , rtGlobalId = Nothing
                , rtSyncEnabled = Nothing
                , rtEnvOverrideData = Nothing
                , rtSlackThreadTs = Nothing
                , rtDispatchId = Nothing
                , rtExternalRunId = Nothing
                , rtCommitSha = Nothing
                , rtSourceRef = Nothing
                , rtRevertsReleaseId = Nothing
                , rtAbValidation = Nothing
                , rtAbValidationStatus = Nothing
                , rtReviewStatus = Nothing
                , rtReviewSubmittedAt = Nothing
                , rtReviewDecidedAt = Nothing
                , rtReviewRejectReason = Nothing
                , rtRolloutStatus = Nothing
                , rtRolloutPercent = Nothing
                , rtStoreRolloutHistory = Nothing
                , rtAscVersionId = Nothing
                , rtAscPhasedId = Nothing
                , rtCreatedAt = now
                , rtUpdatedAt = now
                }
    -- ON CONFLICT DO NOTHING against uq_release_tracker_store_sync: if a
    -- concurrent pass / replica already recorded this app+version, skip cleanly.
    inserted <- insertReleaseTrackerRowIfAbsent row
    if not inserted
        then
            logInfo $
                "[STORE_SYNC] Skipped duplicate synthetic release for "
                    <> acName ac
                    <> " v"
                    <> version
                    <> " (already recorded)"
        else do
            insertReleaseEvent rid "BUSINESS" "STORE_SYNC" $
                object
                    [ "app" .= acName ac
                    , "platform" .= acPlatform ac
                    , "version" .= version
                    , "version_code" .= mCode
                    , "build_type" .= ("release" :: Text)
                    ]
            logInfo $
                "[STORE_SYNC] Inserted synthetic release "
                    <> rid
                    <> " for "
                    <> acName ac
                    <> " v"
                    <> version
                    <> maybe "" (\t -> " (tag: " <> t <> ")") derivedTag

-- | The metadata JSON a store-sync row carries: the leading @store_track@ (drives
-- the list/badge) plus the per-track @tracks@ snapshots (drive the create-page
-- production/internal badges + the changelog base selection).
buildStoreMeta :: Text -> Map.Map Text TrackSnapshot -> Text
buildStoreMeta track tracks =
    encodeJsonText (object ["store_track" .= track, "tracks" .= tracks])

-- | The git tag a store-sync row records, matching the CI tag scheme
-- (see Workflow.execConfirmTag):
--   consumer: {normalize(app)}/prod/{platform}/v{version}+{code}
--   provider: {acName}-v{version}-{code}
-- 'Nothing' when there's no build code (then the row has no changelog baseline).
derivedStoreTag :: AppCatalog -> Text -> Maybe Int32 -> Maybe Text
derivedStoreTag ac version mCode = case mCode of
    Just code
        | acSurface ac == "driver" ->
            Just (acName ac <> "-v" <> version <> "-" <> T.pack (show code))
        | otherwise ->
            Just (normalizeAppSegment (acName ac) <> "/prod/" <> acPlatform ac <> "/v" <> version <> "+" <> T.pack (show code))
    Nothing -> Nothing

normalizeAppSegment :: Text -> Text
normalizeAppSegment = collapseDashes . T.map step . T.toLower
  where
    step c
        | isAlphaNum c = c
        | otherwise = '-'
    collapseDashes :: Text -> Text
    collapseDashes t =
        T.dropWhile (== '-') $
            T.dropWhileEnd (== '-') $
                T.intercalate "-" $
                    filter (not . T.null) (T.splitOn "-" t)

-- ─── Phase 7: live rollout reconciler ──────────────────────────────────

{- | Pull the live store rollout state into the cached @rollout_*@ columns for
every release still rolling out, and finish those that have reached 100%.
Operators can halt / resume / bump from the Console and Apple ramps phased
releases automatically over 7 days — this keeps SCC's view truthful with nobody
clicking inside SCC. Completion sets @mb_wf_status = MBCompleted@; the runner's
Finalize stage then flips the release to COMPLETED on its next tick.

Reviews are not reconciled here (see 'findActiveRolloutReleases'): iOS review
advances via the Phase-5 poll stage, Android review is operator-marked.
-}
reconcileActiveRollouts :: Flow ()
reconcileActiveRollouts = do
    mPlayCreds <- loadPlayCreds
    mAscCreds <- loadAscCreds
    -- (a) Keep releases SCC is already rolling out in sync with the live store %.
    activeRows <- findActiveRolloutReleases
    if null activeRows
        then pure ()
        else do
            logInfo $ "[ROLLOUT_SYNC] Reconciling " <> T.pack (show (length activeRows)) <> " active rollout(s)"
            mapM_ (safeReconcile mPlayCreds mAscCreds) activeRows
    -- (b) Adopt a rollout started in the Play Console on an approved / in-review
    -- Android release SCC hasn't begun rolling out itself.
    detectConsoleRollouts mPlayCreds
    -- (c) Adopt an App Store Connect "Release" on an approved / in-review iOS
    -- release SCC hasn't released itself.
    detectIosReleases mAscCreds

{- | Detect a rollout that was started in the Play Console (not from SCC) on an
Android release SCC promoted but is still showing as in review / approved-held.
The Publishing API can't report review state, but a live production fraction
at/above the rollout floor — versus the ~0 review fraction — means the build was
approved AND ramped in the Console; SCC adopts it into its rollout lifecycle so
the view stops lagging reality. -}
detectConsoleRollouts :: Maybe PlayCreds -> Flow ()
detectConsoleRollouts Nothing = pure ()
detectConsoleRollouts (Just creds) = do
    rows <- findMobileAwaitingRollout "android"
    if null rows
        then pure ()
        else mapM_ (safeDetectConsoleRollout creds) rows

-- | Isolate per-row failures so one bad row never aborts the batch.
safeDetectConsoleRollout :: PlayCreds -> ReleaseTrackerRow -> Flow ()
safeDetectConsoleRollout creds row = do
    result <- MC.try @_ @SomeException (detectConsoleRolloutForRow creds row)
    case result of
        Left e -> logError $ "[ROLLOUT_SYNC] Console-rollout detect failed for " <> rtId row <> " (continuing): " <> T.pack (show e)
        Right () -> pure ()

detectConsoleRolloutForRow :: PlayCreds -> ReleaseTrackerRow -> Flow ()
detectConsoleRolloutForRow creds row = do
    ac <- appCatalogForRowRaw row
    let mCode = parseMobileTargetState (rtTargetState row) >>= mbcVersionCode . mbContext
    case (acPackageName ac, mCode) of
        (Just pkg, Just code)
            | not (T.null pkg) ->
                getTrackRolloutState creds pkg >>= \case
                    Left e -> logWarning $ "[ROLLOUT_SYNC] Console-rollout read error for " <> rtId row <> ": " <> renderPlayErr e
                    Right st -> mapM_ (adoptExternalRollout (rtId row) "play") (detectConsoleRollout androidPendingFractionThreshold code st)
        _ -> pure ()

{- | Detect an App Store Connect "Release" (not from SCC) on an iOS release SCC
promoted but is still showing as in review / approved-held. Unlike Android, Apple
exposes an authoritative state: @READY_FOR_SALE@ ('AscLive') means the build is
live. SCC reads the live review + phased state and adopts it ('detectIosRelease')
— a phased release becomes @rolling_out@ at the ramp % (the Phase-7 reconciler
then tracks the 7-day schedule), a non-phased one completes. Still-held
(@PENDING_DEVELOPER_RELEASE@) or in-review versions are left untouched. -}
detectIosReleases :: Maybe AscCreds -> Flow ()
detectIosReleases Nothing = pure ()
detectIosReleases (Just creds) = do
    rows <- findMobileAwaitingRollout "ios"
    if null rows
        then pure ()
        else mapM_ (safeDetectIosRelease creds) rows

-- | Isolate per-row failures so one bad row never aborts the batch.
safeDetectIosRelease :: AscCreds -> ReleaseTrackerRow -> Flow ()
safeDetectIosRelease creds row = do
    result <- MC.try @_ @SomeException (detectIosReleaseForRow creds row)
    case result of
        Left e -> logError $ "[ROLLOUT_SYNC] iOS release detect failed for " <> rtId row <> " (continuing): " <> T.pack (show e)
        Right () -> pure ()

detectIosReleaseForRow :: AscCreds -> ReleaseTrackerRow -> Flow ()
detectIosReleaseForRow creds row = do
    ac <- appCatalogForRowRaw row
    case acPackageName ac of
        Just bundleId
            | not (T.null bundleId) -> do
                let version = rtNewVersion row
                getAscReviewState creds bundleId version >>= \case
                    Left e -> logWarning $ "[ROLLOUT_SYNC] iOS review-state read error for " <> rtId row <> ": " <> renderAscErr e
                    -- Only act once the version is actually live; read the phased
                    -- state to choose rolling_out vs completed.
                    Right AscLive ->
                        getPhasedReleaseState creds bundleId version >>= \case
                            Left e -> logWarning $ "[ROLLOUT_SYNC] iOS phased read error for " <> rtId row <> ": " <> renderAscErr e
                            Right ps -> case detectIosRelease AscLive ps of
                                Nothing -> pure ()
                                Just action -> do
                                    -- A phased ramp (SetRollout) keeps advancing, so the
                                    -- Phase-7 reconciler needs asc_phased_id to track it —
                                    -- backfill it before adopting. A completed / non-phased
                                    -- release is terminal, so it needs no id.
                                    case action of
                                        SetRollout _ _ -> backfillPhasedId creds bundleId version (rtId row)
                                        _ -> pure ()
                                    adoptExternalRollout (rtId row) "asc" action
                    Right _ -> pure () -- held / in review / rejected → leave as-is
        _ -> pure ()

-- | Best-effort backfill of @asc_phased_id@ from the store so the Phase-7
-- reconciler can track an adopted phased ramp (it reads the cached id to follow
-- Apple's 7-day schedule). A miss / error leaves it unset — the ramp still rolls
-- out at Apple; only SCC's % tracking would lag.
backfillPhasedId :: AscCreds -> Text -> Text -> Text -> Flow ()
backfillPhasedId creds bundleId version rid =
    getPhasedReleaseId creds bundleId version >>= \case
        Right (Just pid) | not (T.null pid) -> do
            setAscIds rid Nothing (Just pid)
            logInfo $ "[ROLLOUT_SYNC] " <> rid <> " backfilled asc_phased_id from store (adopted phased ramp)"
        _ -> pure ()

-- | Apply an adopted out-of-band release/rollout: bring the row into SCC's rollout
-- lifecycle (rollout columns + MBRollingOut/MBCompleted) so the active reconciler
-- keeps it in sync from here on. @store@ is "play" | "asc" for the audit event.
adoptExternalRollout :: Text -> Text -> ReconcileAction -> Flow ()
adoptExternalRollout rid store = \case
    SetRollout status mPct -> do
        setRolloutState rid status mPct
        setMobileWfStatus rid MBRollingOut
        logInfo $ "[ROLLOUT_SYNC] " <> rid <> " external rollout detected (" <> store <> ") → " <> status <> maybe "" (\p -> " @ " <> T.pack (show p) <> "%") mPct
        logEvent rid "EXTERNAL_ROLLOUT_DETECTED" $ object ["store" .= store, "status" .= status, "percent" .= mPct]
    CompleteRollout -> do
        setRolloutState rid "completed" (Just 100)
        setMobileWfStatus rid MBCompleted
        logInfo $ "[ROLLOUT_SYNC] " <> rid <> " external release already at 100% (" <> store <> ") → completing"
        logEvent rid "EXTERNAL_ROLLOUT_DETECTED" $ object ["store" .= store, "status" .= ("completed" :: Text), "percent" .= (100 :: Double)]
    LeaveAsIs _ -> pure ()

-- | Reconcile one row, isolating failures so a single bad row (e.g. a missing
-- app-catalog join, or a one-off store error) never aborts the whole batch.
safeReconcile :: Maybe PlayCreds -> Maybe AscCreds -> ReleaseTrackerRow -> Flow ()
safeReconcile mPlay mAsc row = do
    result <- MC.try @_ @SomeException (reconcileRollout mPlay mAsc row)
    case result of
        Left e -> logError $ "[ROLLOUT_SYNC] Row " <> rtId row <> " failed (continuing): " <> T.pack (show e)
        Right () -> pure ()

reconcileRollout :: Maybe PlayCreds -> Maybe AscCreds -> ReleaseTrackerRow -> Flow ()
reconcileRollout mPlay mAsc row = do
    ac <- appCatalogForRowRaw row
    let rid = rtId row
    case acPackageName ac of
        Just storeId
            | not (T.null storeId) -> case rtEnv row of
                "android" -> case mPlay of
                    Just creds -> reconcileAndroid creds rid storeId row
                    Nothing -> logWarning $ "[ROLLOUT_SYNC] No Play creds — skipping " <> rid
                "ios" -> case mAsc of
                    Just creds -> reconcileIos creds rid storeId row
                    Nothing -> logWarning $ "[ROLLOUT_SYNC] No ASC creds — skipping " <> rid
                p -> logWarning $ "[ROLLOUT_SYNC] Unknown platform " <> p <> " for " <> rid
        _ -> logWarning $ "[ROLLOUT_SYNC] No store id for " <> rid <> ", skipping"

-- | Android: read the production track; mirror its status + userFraction, and
-- complete the release when the rollout reaches 100% (status=completed).
-- | The decision a reconcile pass makes from a live store rollout state. Pure
-- so the mapping is unit-tested ([35]) without hitting a store.
data ReconcileAction
    = -- | mirror the live status ("rolling_out" | "halted") + percent
      SetRollout Text (Maybe Double)
    | -- | reached 100% → finish the release
      CompleteRollout
    | -- | unrecognized store status (echoed back for logging)
      LeaveAsIs Text
    deriving (Eq, Show)

-- | Android production-track status → action. Play reports a 0–1 @userFraction@;
-- we store it as a 0–100 percent.
androidReconcileAction :: PlayRolloutState -> ReconcileAction
androidReconcileAction st = case prsStatus st of
    "completed" -> CompleteRollout
    "halted" -> SetRollout "halted" pct
    "inProgress" -> SetRollout "rolling_out" pct
    other -> LeaveAsIs other
  where
    pct = fmap (* 100) (prsUserFraction st)

-- | iOS phased-release state + ramp day → action (Apple drives the %; we map the
-- day through 'applePhasedPercent').
iosPhasedReconcileAction :: AscPhasedState -> ReconcileAction
iosPhasedReconcileAction (AscPhasedState st mDay) = case st of
    "COMPLETE" -> CompleteRollout
    "PAUSED" -> SetRollout "halted" pct
    "ACTIVE" -> SetRollout "rolling_out" pct
    other -> LeaveAsIs other
  where
    pct = fmap applePhasedPercent mDay

{- | Decide whether the live production track shows OUR Android build now actually
releasing — i.e. someone ramped it past the review fraction in the Play Console —
from the perspective of a row SCC still has as in review / approved-held. Reacts
only when the live release carries OUR version code (so a different version going
live, e.g. after a rejection-revert, is ignored). 'Nothing' = still at/near the
review fraction (in review or approved-held) → leave the row as-is. Reuses
'androidReconcileAction' for the status → action mapping. Unit-tested ([43]). -}
detectConsoleRollout :: Double -> Int32 -> PlayRolloutState -> Maybe ReconcileAction
detectConsoleRollout threshold ourCode st
    | T.pack (show ourCode) `notElem` prsVersionCodes st = Nothing
    | prsStatus st == "completed" = Just CompleteRollout
    | prsStatus st `elem` ["inProgress", "halted"]
    , maybe False (>= threshold) (prsUserFraction st) =
        Just (androidReconcileAction st)
    | otherwise = Nothing

{- | Pure decision for adopting an out-of-band iOS release: only @AscLive@
(@READY_FOR_SALE@) is adopted — a phased release maps through
'iosPhasedReconcileAction' (rolling_out / halted / complete), a non-phased one
(INACTIVE → 'LeaveAsIs') is fully live so it completes. Any non-live state →
'Nothing' (leave the row as approved / in review). Unit-tested ([44]). -}
detectIosRelease :: AscReviewState -> AscPhasedState -> Maybe ReconcileAction
detectIosRelease AscLive ps = Just $ case iosPhasedReconcileAction ps of
    LeaveAsIs _ -> CompleteRollout
    action -> action
detectIosRelease _ _ = Nothing

reconcileAndroid :: PlayCreds -> Text -> Text -> ReleaseTrackerRow -> Flow ()
reconcileAndroid creds rid storeId row = do
    res <- getTrackRolloutState creds storeId
    case res of
        Left e -> logWarning $ "[ROLLOUT_SYNC] Play read error for " <> rid <> ": " <> renderPlayErr e
        Right st -> execReconcile rid "play" row (androidReconcileAction st)

-- | iOS phased release: mirror Apple's ramp day → %, completing when Apple
-- finishes the 7-day schedule. Non-phased releases complete at /release time
-- (Phase 6), so a rolling_out row with no phased id has nothing to ramp.
reconcileIos :: AscCreds -> Text -> Text -> ReleaseTrackerRow -> Flow ()
reconcileIos creds rid bundleId row =
    case rtAscPhasedId row of
        Nothing ->
            logInfo $ "[ROLLOUT_SYNC] " <> rid <> " iOS non-phased, nothing to reconcile"
        Just _ -> do
            res <- getPhasedReleaseState creds bundleId (rtNewVersion row)
            case res of
                Left e -> logWarning $ "[ROLLOUT_SYNC] ASC read error for " <> rid <> ": " <> renderAscErr e
                Right ps -> execReconcile rid "asc" row (iosPhasedReconcileAction ps)

-- | Execute the pure reconcile decision against the DB.
execReconcile :: Text -> Text -> ReleaseTrackerRow -> ReconcileAction -> Flow ()
execReconcile rid storeTag row = \case
    CompleteRollout -> completeRollout rid storeTag
    SetRollout status mPct -> updateRollout rid status mPct row
    LeaveAsIs raw -> logInfo $ "[ROLLOUT_SYNC] " <> rid <> " store status '" <> raw <> "', leaving as-is"

-- | Persist a rollout %/status update, logging + auditing only when it actually
-- changed (the loop polls every store_sync_interval, so most passes are no-ops).
updateRollout :: Text -> Text -> Maybe Double -> ReleaseTrackerRow -> Flow ()
updateRollout rid newStatus mPct row = do
    setRolloutState rid newStatus mPct
    if Just newStatus /= rtRolloutStatus row || pctChanged mPct (rtRolloutPercent row)
        then do
            logInfo $ "[ROLLOUT_SYNC] " <> rid <> " → " <> newStatus <> maybe "" (\p -> " @ " <> T.pack (show p) <> "%") mPct
            logEvent rid "ROLLOUT_RECONCILED" $ object ["status" .= newStatus, "percent" .= mPct]
        else pure ()

-- | Rollout reached 100%: mark it completed and hand off to the runner's
-- Finalize stage, which flips the release to COMPLETED on the next tick.
completeRollout :: Text -> Text -> Flow ()
completeRollout rid store = do
    setRolloutState rid "completed" (Just 100)
    setMobileWfStatus rid MBCompleted
    logInfo $ "[ROLLOUT_SYNC] " <> rid <> " rollout complete (100%) — finishing release"
    logEvent rid "ROLLOUT_COMPLETED" $ object ["store" .= store]

-- | Treat sub-0.01-point % moves as unchanged (avoids event spam on float jitter).
pctChanged :: Maybe Double -> Maybe Double -> Bool
pctChanged (Just a) (Just b) = abs (a - b) > 0.0001
pctChanged Nothing Nothing = False
pctChanged _ _ = True

-- ─── App Release Monitoring: store_status cache poll ───────────────────

{- | Refresh the store-monitor cache for EVERY app in the catalog — enabled or
not, so the dashboard shows every app's live releases (the user's explicit ask).
Reads each app's live per-track state (version / code / status / rollout % /
notes) and upserts it into @store_status@, the table the monitor reads in one
shot. Distinct from 'runStoreSync' above, which writes synthetic @release_tracker@
rows only for enabled apps. -}
syncStoreStatus :: Flow ()
syncStoreStatus = do
    apps <- listAppCatalog
    expected <- latestShippedVersionsPerApp
    mPlayCreds <- loadPlayCreds
    mAscCreds <- loadAscCreds
    mapM_ (refreshStoreStatusForApp mPlayCreds mAscCreds expected) apps
    logInfo $ "[STORE_MONITOR] Synced store_status for " <> T.pack (show (length apps)) <> " app(s)"

{- | Live re-poll a single app (loads creds + the drift baseline, then refreshes
its @store_status@ rows). Backs the on-demand ↻ refresh endpoint. A debug
deployment has no production store data, so it's a no-op there — never pull
production store data into a debug deployment (matches the background poller). -}
refreshStoreStatusOne :: AppCatalog -> Flow ()
refreshStoreStatusOne ac = do
    buildType <- getMobileBuildType
    if isDebugBuildType buildType
        then logInfo "[STORE_MONITOR] Debug build env, skipping live refresh (release-only)"
        else do
            expected <- latestShippedVersionsPerApp
            mPlayCreds <- loadPlayCreds
            mAscCreds <- loadAscCreds
            refreshStoreStatusForApp mPlayCreds mAscCreds expected ac

{- | 'syncStoreStatus' wrapped so a cache failure can't abort the store-sync
iteration. Notably, on a fresh deploy where @store_status@ isn't migrated yet the
upsert throws — isolating it here keeps that from starving the staged-rollout
reconcile that runs later in the same loop tick. -}
safeSyncStoreStatus :: Flow ()
safeSyncStoreStatus = do
    result <- MC.try @_ @SomeException syncStoreStatus
    case result of
        Left e -> logError $ "[STORE_MONITOR] store_status sync failed (continuing): " <> T.pack (show e)
        Right () -> pure ()

{- | Poll ONE app's live store state and upsert each of its tracks into
@store_status@. Shared by the batch poll and the refresh endpoint. Missing creds
or a store error logs and leaves the existing cached row untouched (never blanks
it). @expected@ stamps the drift baseline; the active SCC review/rollout is
overlaid on the production cell. -}
refreshStoreStatusForApp ::
    Maybe PlayCreds ->
    Maybe AscCreds ->
    Map.Map (Text, Text, Text) Text ->
    AppCatalog ->
    Flow ()
refreshStoreStatusForApp mPlayCreds mAscCreds expected ac = case acPackageName ac of
    Just pkg | not (T.null pkg) -> do
        let mExpected = Map.lookup (acName ac, acSurface ac, acPlatform ac) expected
        mActive <- findActiveMobileState (acName ac) (acSurface ac) (acPlatform ac)
        case acPlatform ac of
            "android" -> case mPlayCreds of
                Nothing -> logWarning $ "[STORE_MONITOR] No Play creds — skipping " <> acName ac
                Just creds ->
                    fetchTrackSnapshots creds pkg >>= \case
                        Left e -> logWarning $ "[STORE_MONITOR] Play snapshot error for " <> acName ac <> ": " <> renderPlayErr e
                        Right snaps -> mapM_ (upsertStoreStatus . androidSnapToUpsert ac mExpected mActive) snaps
            "ios" -> case mAscCreds of
                Nothing -> logWarning $ "[STORE_MONITOR] No ASC creds — skipping " <> acName ac
                Just creds ->
                    fetchAscSnapshots creds pkg >>= \case
                        Left e -> logWarning $ "[STORE_MONITOR] ASC snapshot error for " <> acName ac <> ": " <> renderAscErr e
                        Right snaps -> mapM_ (upsertStoreStatus . iosSnapToUpsert ac mExpected mActive) snaps
            p -> logWarning $ "[STORE_MONITOR] Unknown platform " <> p <> " for " <> acName ac
    _ -> pure ()

{- | Map a Play track snapshot → a @store_status@ upsert. Production carries the
live staged-rollout % (the near-zero "pending" fraction reads as a tiny %, which
the badge treats as not-yet-ramped) and overlays SCC's review state — Play never
reports review, so this is the only way an Android "in review" surfaces; internal
testing has neither rollout nor review. -}
androidSnapToUpsert :: AppCatalog -> Maybe Text -> Maybe ActiveMobileState -> StoreTrackSnapshot -> StoreStatusUpsert
androidSnapToUpsert ac mExpected mActive s =
    let isProd = stsTrack s == "production"
        -- A production fraction below the rollout floor is the parked "pending"
        -- fraction (~1e-6) of a submitted / approved-held build under managed
        -- publishing — NOT an active ramp — so it stores as no %, and the badge
        -- reads it as "Approved · held" rather than "rolling out ~0%". The live
        -- track is authoritative (no optimistic fallback to SCC's cached %): if
        -- managed publishing holds a SET 10% at ~0%, the monitor truthfully shows
        -- it as held, surfacing the hold instead of masking it.
        realRollout = (fmap (* 100) (stsFraction s)) >>= \p -> if p >= androidRolloutFloorPercent then Just p else Nothing
     in StoreStatusUpsert
            { ssuAppCatalogId = acId ac
            , ssuPlatform = "android"
            , ssuTrack = stsTrack s
            , ssuVersionName = nonEmptyVersion (stsVersion s)
            , ssuVersionCode = stsCode s
            , ssuStatus = Just (stsStatus s)
            , ssuRolloutPercent = if isProd then realRollout else Nothing
            , ssuReviewStatus = if isProd then mActive >>= amsReviewStatus else Nothing
            , ssuReleaseNotes = stsNotes s
            , ssuExpectedVersion = mExpected
            }

-- | Production rollout floor (percent). Below this, a live @userFraction@ is the
-- parked review/pending fraction, not a real ramp — the 0–100 mirror of
-- 'androidPendingFractionThreshold' (0.01 fraction = 1%).
androidRolloutFloorPercent :: Double
androidRolloutFloorPercent = androidPendingFractionThreshold * 100

{- | Map an ASC snapshot → a @store_status@ upsert. The snapshot carries neither
rollout % nor review state, so production overlays SCC's phased % + review state;
TestFlight is build-only. -}
iosSnapToUpsert :: AppCatalog -> Maybe Text -> Maybe ActiveMobileState -> AscSnapshot -> StoreStatusUpsert
iosSnapToUpsert ac mExpected mActive s =
    let isProd = ascTrack s == "production"
     in StoreStatusUpsert
            { ssuAppCatalogId = acId ac
            , ssuPlatform = "ios"
            , ssuTrack = ascTrack s
            , ssuVersionName = nonEmptyVersion (ascVersion s)
            , ssuVersionCode = Nothing
            , ssuStatus = Just (ascStatus s)
            , ssuRolloutPercent = if isProd then mActive >>= amsRolloutPercent else Nothing
            , ssuReviewStatus = if isProd then mActive >>= amsReviewStatus else Nothing
            , ssuReleaseNotes = ascNotes s
            , ssuExpectedVersion = mExpected
            }

-- | A snapshot's placeholder "no build on this track" markers → 'Nothing'.
nonEmptyVersion :: Text -> Maybe Text
nonEmptyVersion v
    | v `elem` ["", "0.0.0", "none"] = Nothing
    | otherwise = Just v
