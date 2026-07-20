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
    reconcileActiveRollouts,

    -- * Pure reconcile decision (unit-tested)
    ReconcileAction (..),
    androidReconcileAction,
    iosPhasedReconcileAction,
    ExternalReviewAction (..),
    externalReviewAction,
    reviewStateToStatus,
    pendingPublishRelease,
    PendingOutcome (..),
    pendingOutcome,
    retireOutcome,
    detectConsoleRollout,
    detectIosRelease,

    -- * App Release Monitoring (store_status cache)
    refreshStoreStatusOne,
    refreshAllStale,
    isBulkRefreshing,

    -- * Version ordering (semver-ish component compare; unit-tested via callers)
    versionOlderThan,
) where

import Control.Applicative ((<|>))
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar)
import Control.Concurrent.QSem (newQSem, signalQSem, waitQSem)
import Control.Exception (SomeException, bracket_)
import Control.Monad (forM_, unless, when)
import Control.Monad.Catch qualified as MC
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import Core.Environment (Flow, MonadFlow, logError, logInfo, logWarning, runFlow)
import Data.Aeson (object, (.=))
import Data.Int (Int32)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Products.Autopilot.Mobile.Lifecycle.Phase (ReleasePhase (..))
import Products.Autopilot.Mobile.Queries.AppCatalog (
    LatestBuildRow (..),
    derivedStoreTag,
    fetchLatestBuildsPerApp,
    listAppCatalog,
 )
import Products.Autopilot.Mobile.Queries.StoreStatus (
    StoreStatusUpsert (..),
    findProductionLiveCell,
    latestShippedVersionsPerApp,
    recordStoreSyncError,
    recordStoreSyncOk,
    secondsSinceLastSync,
    setProductionRolloutStatus,
    upsertStoreStatus,
 )
import Products.Autopilot.Mobile.Queries.Tracker (
    adoptDraftAsStoreBuild,
    appCatalogForRowRaw,
    completeExternalReviewRow,
    convergeStoreSyncRow,
    findAdoptableDraft,
    findActiveRolloutReleases,
    findExternalReviewRow,
    findExternalReviewRowForVersion,
    findMobileAwaitingRollout,
    findMobileVersionRow,
    logEvent,
    mkMobileTrackerRow,
    parseMobileTargetState,
    sccActiveReleaseExistsForVersion,
    setAscIds,
    applyExternalReviewPhase,
    closeExternalReviewRow,
    setPhase,
    storeSyncRowExistsForVersion,
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
    getIosVersionStateDump,
    getLiveAppStoreVersionAndBuild,
    getPhasedReleaseId,
    getPhasedReleaseState,
    loadAscCreds,
    loadAscCredsFor,
    renderAscErr,
 )
import Products.Autopilot.Mobile.Versioning.Play (
    PlayCreds (..),
    PlayRolloutState (..),
    ProdTrackRelease (..),
    StoreTrackSnapshot (..),
    TrackInfo (..),
    bodiesToProdReleases,
    bodiesToSnapshots,
    bodiesToTracks,
    fetchPlayTrackBodies,
    getProductionReleases,
    loadPlayCreds,
    renderPlayErr,
 )
import Products.Autopilot.Queries.ReleaseTracker (
    encodeJsonText,
    insertReleaseEvent,
    insertReleaseTrackerRowIfAbsent,
 )
import Products.Autopilot.RuntimeConfig (getMobileBuildType, getStoreRefreshCooldownSeconds, isStagedRolloutEnabled)
import Products.Autopilot.Types.Storage.Schema (ReleaseTrackerRow, ReleaseTrackerT (..))
import Products.Autopilot.Types.Target (TargetState (..))
import System.IO.Unsafe (unsafePerformIO)
import Text.Read (readMaybe)

type BuildMap = Map.Map (Text, Text, Text) LatestBuildRow

{- | Sync EVERY app in one pass — the backend for an explicit "refresh all". The
usual path is per-app on-demand refresh ('refreshStoreStatusOne', cooldown-gated);
this is the full sweep. Each app costs ONE Play edit (Android) via 'syncAppUnified'.
-}
runStoreSync :: Flow ()
runStoreSync = do
    logInfo "[STORE_SYNC] Starting store sync"
    -- ALL apps (not just enabled): the store_status monitor cache covers every
    -- app, while the release recorder + external-review rows are gated on
    -- 'acEnabled' inside 'syncAppUnified'.
    apps <- listAppCatalog
    builds <- fetchLatestBuildsPerApp
    expected <- latestShippedVersionsPerApp
    let buildMap =
            Map.fromList
                [ ((lbrAppGroup b, lbrSurface b, lbrPlatform b), b)
                | b <- builds
                ]
    mPlayCreds <- loadPlayCreds
    -- ASC creds are resolved per-app (per store account) inside 'syncAppUnified'.
    mapM_ (syncAppUnified mPlayCreds buildMap expected) apps
    logInfo $ "[STORE_SYNC] Finished — checked " <> T.pack (show (length apps)) <> " app(s)"

{- | Run an action, logging (but swallowing) any exception so one app's failure —
e.g. a @store_status@ upsert against a not-yet-migrated table — can't abort the
rest of the per-app sync.
-}
safely :: Text -> Flow () -> Flow ()
safely label act =
    MC.try @_ @SomeException act
        >>= either
            (\e -> logError $ "[STORE_MONITOR] " <> label <> " failed (continuing): " <> T.pack (show e))
            pure

-- | Coarse error code from a rendered Play/ASC message (the message keeps the detail).
classifyStoreErr :: Text -> Text
classifyStoreErr msg
    | anyIn ["429", "quota", "rate limit", "rate-limit", "ratelimit"] = "rate_limited"
    | anyIn ["401", "403", "unauthor", "unauthenticat", "forbidden"] = "asc_unauthorized"
    | anyIn ["404", "not found"] = "not_found"
    | otherwise = "api_error"
  where
    lower = T.toLower msg
    anyIn = any (`T.isInfixOf` lower)

{- | Sync ONE app from a single store read.

Android: one Play edit (`fetchPlayTrackBodies`) feeds all consumers — the
@store_status@ monitor cache (every app), the release recorder + external-review
detector (enabled apps only), and the rollout reconcile — via the pure @bodiesTo*@
projections. This is the quota fix: collapses the former ~3 edits/app to 1.

iOS is ASC-backed (no Play edit-creation quota), so the cache and the recorder
keep their own reads.
-}
syncAppUnified ::
    Maybe PlayCreds ->
    BuildMap ->
    Map.Map (Text, Text, Text) Text ->
    AppCatalog ->
    Flow ()
syncAppUnified mPlayCreds buildMap expected ac = do
    let key = (acName ac, acSurface ac, acPlatform ac)
        existing = Map.lookup key buildMap
        mExpected = Map.lookup key expected
        aid = acId ac
        noPkg = recordStoreSyncError aid "not_found" "No package / bundle id configured for this app"
    case acPlatform ac of
        "android" -> case mPlayCreds of
            Nothing -> do
                recordStoreSyncError aid "no_creds" "No Play Console credentials configured"
                logWarning $ "[STORE_SYNC] No Play Console creds — skipping " <> acName ac
            Just creds -> case acPackageName ac of
                Just pkg
                    | not (T.null pkg) ->
                        fetchPlayTrackBodies creds pkg >>= \case
                            Left e -> do
                                let msg = renderPlayErr e
                                recordStoreSyncError aid (classifyStoreErr msg) msg
                                logWarning $ "[STORE_SYNC] Play API error for " <> acName ac <> ": " <> msg
                            Right bodies -> do
                                let snaps = bodiesToSnapshots bodies
                                -- Pure store truth per cell — review is never overlaid here;
                                -- it lives on the release row (monitor Incoming / list badge).
                                safely ("store_status " <> acName ac) $
                                    forM_ snaps $ \s ->
                                        upsertStoreStatus (androidSnapToUpsert ac mExpected s)
                                when (acEnabled ac) $ do
                                    let (internal, production) = bodiesToTracks bodies
                                    -- Per-stage isolation (§16h-2): one failing stage
                                    -- (e.g. an identity conflict) must not abort the rest.
                                    safely ("record " <> acName ac) $
                                        recordAndroidTracks ac existing internal production
                                    safely ("prod-row " <> acName ac) $
                                        ensureProductionRolloutRow ac (bodiesToSnapshots bodies)
                                    safely ("external-review " <> acName ac) $
                                        reconcileAndroidExternalReviewFrom ac (bodiesToProdReleases bodies)
                                reconcileAndroidRolloutsFrom ac (bodiesToProdReleases bodies)
                                recordStoreSyncOk aid
                _ -> noPkg >> logWarning ("[STORE_SYNC] No package id for " <> acName ac <> ", skipping")
        -- Resolve the ASC key for THIS app's account (multi-account: different Apple
        -- teams). No fallback to the default key for a tagged app — it'd 403.
        "ios" ->
            loadAscCredsFor (acStoreAccount ac) >>= \case
                Nothing -> do
                    recordStoreSyncError aid "no_creds" ("No App Store Connect credentials for account '" <> fromMaybe "default" (acStoreAccount ac) <> "'")
                    logWarning $ "[STORE_SYNC] No ASC creds for account '" <> fromMaybe "default" (acStoreAccount ac) <> "' — skipping " <> acName ac
                Just creds -> case acPackageName ac of
                    Just bundleId
                        | not (T.null bundleId) ->
                            fetchAscSnapshots creds bundleId >>= \case
                                Left e -> do
                                    let msg = renderAscErr e
                                    recordStoreSyncError aid (classifyStoreErr msg) msg
                                    logWarning $ "[STORE_MONITOR] ASC snapshot error for " <> acName ac <> ": " <> msg
                                Right snaps -> do
                                    safely ("store_status " <> acName ac) $
                                        forM_ snaps $ \s ->
                                            upsertStoreStatus (iosSnapToUpsert ac mExpected s)
                                    when (acEnabled ac) $ do
                                        syncIos creds ac existing
                                        syncIosExternalReview creds ac
                                    reconcileIosRollouts creds ac
                                    recordStoreSyncOk aid
                    _ -> noPkg >> logWarning ("[STORE_SYNC] No bundle id for " <> acName ac <> ", skipping")
        p -> do
            recordStoreSyncError aid "api_error" ("Unknown platform " <> p)
            logWarning $ "[STORE_SYNC] Unknown platform " <> p <> " for " <> acName ac

-- | True when this @release_tracker@ row belongs to the given app catalog entry.
rowIsApp :: AppCatalog -> ReleaseTrackerRow -> Bool
rowIsApp ac row =
    rtAppGroup row == acName ac
        && rtService row == acSurface ac
        && rtEnv row == acPlatform ac

{- | Reconcile THIS Android app's staged rollouts from the production releases
already read in its single fetch — no extra Play edit. Mirrors %/halt and completes
at 100% for an SCC-owned active rollout, and adopts a rollout started in the Play
Console on a still-in-review row. Gated on the staged-rollout flag; per-row isolated
so one bad row can't abort the rest.

The production track can hold MULTIPLE releases at once — e.g. an older version
HALTED mid-rollout AND a freshly-submitted version parked at the near-zero review
fraction. So each row is reconciled against the release matching ITS OWN version
code (via 'rolloutStateForCode'), never a single collapsed track state: the collapsed
state picks the newest release, which would mis-attribute the new review fraction onto
the older halted rollout (the "rolling out 0.000001%" bug). A row whose version is no
longer on the track is left as-is.
-}
reconcileAndroidRolloutsFrom :: AppCatalog -> [ProdTrackRelease] -> Flow ()
reconcileAndroidRolloutsFrom ac releases = do
    staged <- isStagedRolloutEnabled
    when staged $ do
        active <- filter (rowIsApp ac) <$> findActiveRolloutReleases
        forM_ active $ \row ->
            safely ("rollout " <> rtId row) $
                forM_ (rowVersionCode row) $ \code ->
                    case rolloutStateForCode code releases of
                        Just rst -> execReconcile (rtId row) "play" row (androidReconcileAction rst)
                        -- Our version is gone from a SUCCESSFUL, non-empty track read →
                        -- it was superseded (a newer build replaced it). Retire the row
                        -- so it stops showing a phantom "rolling out". An empty list means
                        -- a brand-new app / no production yet → leave as-is, don't retire.
                        Nothing | not (null releases) -> retireSupersededRollout (rtId row)
                        Nothing -> pure ()
        awaiting <- filter (rowIsApp ac) <$> findMobileAwaitingRollout "android"
        forM_ awaiting $ \row ->
            safely ("console-rollout " <> rtId row) $
                forM_ (rowVersionCode row) $ \code ->
                    case rolloutStateForCode code releases of
                        Just rst -> mapM_ (adoptExternalRollout (rtId row) "play") (detectConsoleRollout androidPendingFractionThreshold code rst)
                        -- Our code is GONE from the track → classify the outcome
                        -- (§16h-1) instead of zombie-ing at "In review".
                        Nothing -> resolveVanishedSubmission row code releases

{- | Retire a SUPERSEDED rollout: an actively-rolling version that has dropped off
the production track because a newer build replaced it. setPhase Superseded sets
@rollout_status='superseded'@ (so it reads "Superseded", not a frozen "rolling X%")
and terminalizes via MBAborted (engine stops; USER_ABORTED, never COMPLETED, so
markReleaseRevertedBy stays unfired). 'superseded' also drops it from
'findActiveRolloutReleases', so it is never re-processed.
-}
retireSupersededRollout :: Text -> Flow ()
retireSupersededRollout rid = do
    now <- liftIO getCurrentTime
    setPhase now rid Superseded
    logInfo $ "[ROLLOUT_SYNC] " <> rid <> " version no longer on production track — retiring superseded rollout"
    logEvent rid "ROLLOUT_SUPERSEDED" (object ["reason" .= ("version_left_production_track" :: Text)])

-- | The Android version code recorded on a mobile release row (from its target state).
rowVersionCode :: ReleaseTrackerRow -> Maybe Int32
rowVersionCode row = parseMobileTargetState (rtTargetState row) >>= mbcVersionCode . mbContext

{- | Strict version-string ordering by dotted numeric components ("9.9.14" \< "9.9.15").
Non-numeric parts compare as 0. Used to confirm an iOS rollout row was superseded by a
strictly NEWER live version before retiring it.
-}
versionOlderThan :: Text -> Text -> Bool
versionOlderThan a b = comps a < comps b
  where
    comps = map (\p -> fromMaybe 0 (readMaybe (T.unpack p)) :: Int) . T.splitOn "."

{- | The live production rollout state of the release carrying THIS version code,
selected from the full production-track release list — so a multi-release track
(halted old version + near-zero new submission) reconciles each row against its own
release. 'Nothing' when our version is no longer on the track (superseded).
-}
rolloutStateForCode :: Int32 -> [ProdTrackRelease] -> Maybe PlayRolloutState
rolloutStateForCode code rels =
    (\r -> PlayRolloutState (ptrStatus r) (ptrUserFraction r) [T.pack (show (ptrCode r))])
        <$> find ((== code) . ptrCode) rels

{- | Reconcile THIS iOS app's staged rollouts. iOS uses ASC reads (phased / review
state) — no Play edit quota — so it reuses the existing per-row reconcilers,
app-scoped and triggered on demand. Gated on the staged-rollout flag.
-}
reconcileIosRollouts :: AscCreds -> AppCatalog -> Flow ()
reconcileIosRollouts creds ac = do
    staged <- isStagedRolloutEnabled
    when staged $ do
        active <- filter (rowIsApp ac) <$> findActiveRolloutReleases
        mapM_ (safeReconcile Nothing (Just creds)) active
        awaiting <- filter (rowIsApp ac) <$> findMobileAwaitingRollout "ios"
        mapM_ (safeDetectIosRelease creds) awaiting

{- | Record the leading Play track into a synthetic @release_tracker@ row from the
already-fetched tracks (no Play call of its own). The leading track owns the
row's version/badge: internal when its build code is ahead (an internal-only
build pending promotion), else production. The live prod/internal versions
themselves live in @store_status@ (the create page + changelog base read that),
so an unchanged leading row needs no metadata refresh here.
-}
recordAndroidTracks :: AppCatalog -> Maybe LatestBuildRow -> TrackInfo -> TrackInfo -> Flow ()
recordAndroidTracks ac existing internal production = do
    let internalAhead = tiCode internal > tiCode production
        (chosen, track) = if internalAhead then (internal, "internal") else (production, "production")
        chosenVer = tiName chosen
        chosenCode = Just (tiCode chosen)
        tagFor = chosenVer <> "+" <> T.pack (show (tiCode chosen))
    when (isNewerAndroid chosen existing) $ case existing of
        -- Same version, newer code: bump a store-sync snapshot in place. If there's
        -- none to bump, a MANUAL build owns this version and the observed code is a
        -- different, out-of-band build → give it its own row, never touch the MANUAL row.
        Just lb
            | lbrVersion lb == chosenVer -> do
                logInfo $ "[STORE_SYNC] Play build bump for " <> acName ac <> " (" <> track <> "): " <> tagFor
                bumped <- updateStoreSyncBuildCode ac chosenVer chosenCode (derivedStoreTag ac chosenVer chosenCode)
                unless bumped $ insertSyntheticRelease ac chosenVer chosenCode track
        -- New version → insert a fresh row.
        _ -> do
            logInfo $ "[STORE_SYNC] New Play version for " <> acName ac <> " (" <> track <> "): " <> tagFor
            insertSyntheticRelease ac chosenVer chosenCode track

{- | Ensure a mid-rollout production version has its own store-sync row so it appears
in the list. 'recordAndroidTracks' rows only the LEADING version (highest build code),
so a PREVIOUS version ramping on production — while a newer build sits on internal —
would otherwise have no row. The rollout % is NOT copied onto the row: it's read from
store_status (the SSOT) at response time. Only an in-flight ramp below 100% needs a row
here (a 100% rollout IS the leading production build, already rowed by recordAndroidTracks).
-}
ensureProductionRolloutRow :: AppCatalog -> [StoreTrackSnapshot] -> Flow ()
ensureProductionRolloutRow ac snaps =
    forM_ (find ((== "production") . stsTrack) snaps) $ \s ->
        when (isActiveRamp s) $ insertSyntheticRelease ac (stsVersion s) (stsCode s) "production"
  where
    isActiveRamp s =
        stsVersion s /= "0.0.0"
            && stsStatus s `elem` ["inProgress", "halted"]
            && maybe False (\pct -> pct >= androidRolloutFloorPercent && pct < 100) ((* 100) <$> stsFraction s)

{- | Write an App Store PHASED production rollout's % to store_status (the SSOT the
list/detail read) so it shows "Rolling out X%" / "Halted X%", not a stale TestFlight
badge. This is the ONLY path that surfaces a phased release started in App Store
Connect OUTSIDE SCC: the row was never promoted, so 'detectIosReleases' (promoted,
INPROGRESS rows only) never touches it. Apple's % is the phased current-day number
('applePhasedPercent' — 1/2/5/10/20/50/100). Ensures the version has a row first
(insert-if-absent), since a phased production version need not be the TestFlight
leader 'recordIosSnapshot' records; retires rows superseded by a newer live version.

Carries the live version's build number so both the minted row and the store_status
cell keep full (version, code) identity — writing a NULL code here used to clobber
the code the snapshot upsert had just recorded, breaking the (version, code) cell
match for code-stamped rows.
-}
reflectIosPhasedRollout :: AscCreds -> AppCatalog -> Text -> Maybe (Text, Maybe Int32) -> Flow ()
reflectIosPhasedRollout _ _ _ Nothing = pure ()
reflectIosPhasedRollout creds ac bundleId (Just (pv, mCode)) = do
    getPhasedReleaseState creds bundleId pv >>= \case
        Left e -> logWarning $ "[STORE_SYNC] iOS phased-state read error for " <> acName ac <> ": " <> renderAscErr e
        Right ps -> do
            let pct = maybe 0 applePhasedPercent (apsCurrentDay ps)
                inRamp st
                    | pct >= androidRolloutFloorPercent, pct < 100 = Just (st, pct)
                    | otherwise = Nothing
                mActive = case apsState ps of
                    "ACTIVE" -> inRamp "rolling_out"
                    "PAUSED" -> inRamp "halted"
                    _ -> Nothing
            -- Ensure the rolling version has a row (so it appears in the list) — but ONLY
            -- if none exists yet (version-level check: a legacy code-less row also counts,
            -- else we'd mint a duplicate beside it). The % lives in store_status, below.
            forM_ mActive $ \_ -> do
                mExisting <- findMobileVersionRow (acName ac) (acSurface ac) (acPlatform ac) pv Nothing
                case mExisting of
                    Just _ -> pure ()
                    Nothing -> insertSyntheticRelease ac pv mCode "production"
            forM_ mActive $ \(rs, p) ->
                setProductionRolloutStatus (acId ac) "ios" pv mCode (if rs == "halted" then "halted" else "inProgress") p
    stale <- filter (\r -> rtNewVersion r `versionOlderThan` pv) . filter (rowIsApp ac) <$> findActiveRolloutReleases
    forM_ stale (retireSupersededRollout . rtId)

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
            fetchAscBuildInfo creds bundleId >>= \case
                Left e ->
                    logWarning $ "[STORE_SYNC] ASC API error for " <> acName ac <> ": " <> renderAscErr e
                Right mBi -> do
                    -- Read the live App Store (production) version + its build number
                    -- INDEPENDENTLY of the TestFlight build. An app can be live on the App
                    -- Store with no recent TestFlight build (the prod read must not be gated
                    -- behind it, or the production version is never recorded for those apps).
                    mProd <- either (const Nothing) id <$> liftIO (getLiveAppStoreVersionAndBuild creds bundleId)
                    let mProdVer = fst <$> mProd
                        mProdCode = readMaybe . T.unpack =<< (snd =<< mProd) :: Maybe Int32
                        tfCode bi = abiBuildNumber bi >>= readMaybe . T.unpack :: Maybe Int32
                        tfDesc = maybe "none" (\bi -> abiVersion bi <> maybe "" (\c -> "+" <> T.pack (show c)) (tfCode bi)) mBi
                    logInfo $
                        "[STORE_SYNC] " <> acName ac <> " iOS → testflight=" <> tfDesc <> ", production=" <> fromMaybe "none" mProdVer
                    -- When no live production resolves, dump the version→state pairs so the
                    -- reason is visible (genuinely not live, or a different Apple account).
                    case mProdVer of
                        Just _ -> pure ()
                        Nothing ->
                            liftIO (getIosVersionStateDump creds bundleId) >>= \case
                                Right states -> logInfo $ "[STORE_SYNC] " <> acName ac <> " iOS no live production; appStoreVersions: " <> T.intercalate "; " states
                                Left e -> logWarning $ "[STORE_SYNC] " <> acName ac <> " iOS version-state dump failed: " <> renderAscErr e
                    case mBi of
                        -- TestFlight build present → it leads (the newest build); production secondary.
                        Just bi ->
                            let storeVer = abiVersion bi
                                mCode = tfCode bi
                             in recordIosSnapshot ac existing storeVer mCode "testflight"
                        -- No TestFlight build → the live production version leads (if the app is live).
                        Nothing -> case mProdVer of
                            Just pv -> recordIosSnapshot ac existing pv mProdCode "production"
                            Nothing -> logInfo $ "[STORE_SYNC] No ASC build or live version for " <> acName ac
                    -- Write an App Store PHASED rollout's % (incl. one started outside
                    -- SCC) to store_status so the list shows "Rolling out X%".
                    reflectIosPhasedRollout creds ac bundleId (fmap (\v -> (v, mProdCode)) mProdVer)

{- | Insert-or-update an iOS store-sync snapshot for whichever track leads —
TestFlight when a build exists, else production. Factored out so the live
production version is recorded even for an app with no recent TestFlight build.
-}
recordIosSnapshot :: AppCatalog -> Maybe LatestBuildRow -> Text -> Maybe Int32 -> Text -> Flow ()
recordIosSnapshot ac existing leadVer leadCode leadTrack =
    if isNewerIos leadVer existing
        then do
            logInfo $
                "[STORE_SYNC] New ASC version for "
                    <> acName ac
                    <> ": "
                    <> leadVer
                    <> maybe "" (\c -> " (build " <> T.pack (show c) <> ")") leadCode
            insertSyntheticRelease ac leadVer leadCode leadTrack
        else case (existing, leadCode) of
            -- Same version, new build number: bump a store-sync snapshot in place; if none
            -- (a MANUAL build owns it), the observed build is out-of-band → own row.
            (Just lb, Just newC)
                | lbrVersion lb == leadVer && Just newC /= lbrVersionCode lb -> do
                    logInfo $ "[STORE_SYNC] ASC build bump for " <> acName ac <> ": " <> leadVer <> "+" <> T.pack (show newC)
                    bumped <- updateStoreSyncBuildCode ac leadVer leadCode (derivedStoreTag ac leadVer leadCode)
                    unless bumped $ insertSyntheticRelease ac leadVer leadCode leadTrack
            _ -> pure ()

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
tracks the version (SCC owns that review). iOS only; Play review state is opaque.
-}
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
the row as if it published (documented; rejections surface via the Console).
-}
reconcileAndroidExternalReviewFrom :: AppCatalog -> [ProdTrackRelease] -> Flow ()
reconcileAndroidExternalReviewFrom ac releases = do
    existing <- findExternalReviewRow (acName ac) (acSurface ac) (acPlatform ac)
    let mPending = pendingPublishRelease androidPendingFractionThreshold releases
        -- Android can't distinguish in-review from approved-held, so a
        -- pending version always surfaces as MBInReview ("Pending review").
        mMapped = (\(version, _) -> (version, "in_review")) <$> mPending
    reconcileExternalReviewMapped ac (snd <$> mPending) True existing mMapped

{- | Below this production-rollout @userFraction@ a release is treated as "not yet
ramped" — a freshly-submitted / approved-held version parked at the near-zero
review fraction, not an active staged rollout. This deployment always submits at
~1e-6, so a 1% cutoff leaves wide margin while still excluding any real rollout
step. (Out-of-band rollouts ramped above this are intentionally not surfaced as
pending — they're past review and exposing users.)
-}
androidPendingFractionThreshold :: Double
androidPendingFractionThreshold = 0.01

{- | Pick the out-of-band "pending review/publish" version from the production
track: the highest-code @inProgress@ release sitting at a sub-threshold
@userFraction@ whose code is newer than the live (@completed@) version. 'Nothing'
when there's no such release — only a live version, or a version already rolling
out at a real fraction. Pure — unit-tested ([41]).
-}
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

{- | The fate of a watched submission, read from the production track (§16h-1).
Play never reports a review verdict; presence, serving state, and newer codes
disambiguate every outcome the track can't say in words.
-}
data PendingOutcome
    = -- | still on the track below the ramp floor — leave as-is
      PendingParked
    | -- | serving (completed) or ramping at/above the floor — it went live
      PendingPublished
    | -- | gone, and a newer code took the slot — superseded
      PendingReplaced
    | -- | gone without publishing — rejected or withdrawn in the console
      PendingWithdrawn
    deriving (Eq, Show)

{- | Classify a watched build code against a SUCCESSFUL production-track read.
'Nothing' on an empty read — a claim needs data, never absence of it. Pure —
unit-tested.
-}
pendingOutcome :: Double -> Int32 -> [ProdTrackRelease] -> Maybe PendingOutcome
pendingOutcome threshold code rels
    | null rels = Nothing
    | Just r <- find ((== code) . ptrCode) rels =
        Just $
            if ptrStatus r == "completed" || maybe False (>= threshold) (ptrUserFraction r)
                then PendingPublished
                else PendingParked
    | any ((> code) . ptrCode) rels = Just PendingReplaced
    | otherwise = Just PendingWithdrawn

{- | Classify a RETIRED external submission from the just-synced production cell —
platform-generic (the cell was written from this same pass's store read): if the
serving cell now carries the watched build it PUBLISHED; else a new pending
submission means it was REPLACED; else it left the store without publishing.
Inputs: the production cell as @(version, code, status, pct)@, whether a new
pending submission exists, and the watched build's identity. Pure — unit-tested.
-}
retireOutcome :: Maybe (Maybe Text, Maybe Int32, Maybe Text, Maybe Double) -> Bool -> Text -> Maybe Int32 -> PendingOutcome
retireOutcome mServing hasNewPending ver mCode
    | Just (sv, sc, sStatus, sPct) <- mServing
    , sv == Just ver
    , codeMatches sc
    , sStatus `elem` [Just "completed", Just "live"] || sPct /= Nothing =
        PendingPublished
    | hasNewPending = PendingReplaced
    | otherwise = PendingWithdrawn
  where
    -- Exact code match when both sides know it; a missing side degrades to the
    -- version match (legacy code-less rows / cells).
    codeMatches (Just s) | Just c <- mCode = s == c
    codeMatches _ = True

{- | Reconcile the external-review row against the live iOS in-flight review state.
iOS reads an authoritative review state from ASC (@inferred = False@), including
the attached build's number — so the surfaced row carries full (version, code)
identity and the review can never converge onto a different build of the same
version name.
-}
reconcileExternalReview :: AppCatalog -> Maybe ReleaseTrackerRow -> Maybe (Text, Maybe Int32, AscReviewState) -> Flow ()
reconcileExternalReview ac existing mInFlight =
    reconcileExternalReviewMapped ac (mInFlight >>= \(_, c, _) -> c) False existing $
        mInFlight >>= \(v, _, rs) -> (\rstatus -> (v, rstatus)) <$> reviewStateToStatus rs

{- | Reconcile the external-review row against an already-mapped @(version,
review_status)@ ('Nothing' = nothing to surface). Shared by the iOS
(authoritative) and Android (inferred) detectors. The decision is pure
('externalReviewAction'); this runs the side effects.

  * @mCode@     — the reviewed build's code. Stamped on a fresh row and used to
                  target the exact (version, code) row when converging (Android
                  from the track release; iOS from the attached build).
  * @inferred@  — whether the review state is inferred from the track rather than
                  read authoritatively (Android), which softens the row's label.
-}
reconcileExternalReviewMapped ::
    AppCatalog ->
    Maybe Int32 ->
    Bool ->
    Maybe ReleaseTrackerRow ->
    Maybe (Text, Text) ->
    Flow ()
reconcileExternalReviewMapped ac mCode inferred existing mMapped = do
    mVersionRow <- case mMapped of
        Just (version, _) -> findMobileVersionRow (acName ac) (acSurface ac) (acPlatform ac) version mCode
        Nothing -> pure Nothing
    let target = mVersionRow <|> existing
        mTargetId = rtId <$> target
        -- Carry the target row's operator-set review_status so an inferred pass
        -- can't downgrade an approve/reject (defaults to in_review if unset).
        mExisting = (\r -> (rtNewVersion r, fromMaybe "in_review" (rtReviewStatus r))) <$> target
    -- Only the dedup check needs a DB read, and only when there's a version to check.
    sccOwns <- case mMapped of
        Just (version, _) -> sccActiveReleaseExistsForVersion (acName ac) (acSurface ac) (acPlatform ac) version
        Nothing -> pure False
    -- Vanish rule (§16h-1): a retired watched submission is classified — not
    -- assumed published. The serving cell says Published; a new pending says
    -- Replaced; otherwise it left the store without publishing.
    let retire hasNewPending = forM_ target $ \r -> do
            serving <- findProductionLiveCell (acId ac) (acPlatform ac)
            case retireOutcome serving hasNewPending (rtNewVersion r) (rtVersionCode r) of
                PendingPublished -> completeExternalReviewRow (rtId r)
                PendingReplaced -> do
                    closeExternalReviewRow (rtId r) Superseded
                    logInfo $ "[STORE_SYNC] External review " <> rtId r <> " replaced by a newer submission — superseded"
                    logEvent (rtId r) "EXTERNAL_REVIEW_RETIRED" (object ["outcome" .= ("replaced" :: Text)])
                PendingWithdrawn -> do
                    closeExternalReviewRow (rtId r) (Rejected "Removed from the store before publishing (rejected or withdrawn in the store console)")
                    logInfo $ "[STORE_SYNC] External review " <> rtId r <> " left the store before publishing — rejected/withdrawn"
                    logEvent (rtId r) "EXTERNAL_REVIEW_RETIRED" (object ["outcome" .= ("rejected_or_withdrawn" :: Text)])
                PendingParked -> pure ()
    case externalReviewAction inferred mExisting mMapped sccOwns of
        ExtNoop -> pure ()
        -- SCC owns the version (it graduated to a rollout) → the external
        -- duplicate simply completes; otherwise a true vanish → classify.
        ExtComplete
            | sccOwns -> mapM_ completeExternalReviewRow mTargetId
            | otherwise -> retire False
        -- State change through the single writer (§16e-2): fills a missing code,
        -- advances a converged snapshot to INPROGRESS, setPhases the verdict.
        ExtUpdate reviewStatus -> mapM_ (\i -> applyExternalReviewPhase i reviewStatus mCode) mTargetId
        ExtInsert version reviewStatus -> insertExternalReviewRow ac mCode inferred version reviewStatus
        ExtRetireAndInsert version reviewStatus -> do
            retire True
            insertExternalReviewRow ac mCode inferred version reviewStatus

-- | What to do with the external-review row this pass. The verdict string is the
-- single source — the wf mirror is derived from it at the write site.
data ExternalReviewAction
    = ExtNoop
    | -- | complete the existing row
      ExtComplete
    | -- | update the existing row's verdict
      ExtUpdate Text
    | -- | insert a fresh row (version, verdict)
      ExtInsert Text Text
    | -- | complete the existing row (different version) + insert the new one
      ExtRetireAndInsert Text Text
    deriving (Eq, Show)

{- | Pure reconcile decision for the external-review row. Inputs: whether the
review state is @inferred@ (Android) rather than authoritative (iOS); the existing
row's @(version, review_status)@ (if any); the in-flight @(version, review_status)@
we'd surface ('Nothing' = nothing to surface — draft/live/unknown); and whether an
actual SCC release already owns that version. Unit-tested.

The @inferred@ guard protects an Android operator decision. Store sync can only
ever infer @"in_review"@ for Android, so once the operator has marked the row
@approved@ / @rejected@ it must NOT be downgraded back to @"in_review"@ on the
next pass — that was silently erasing the approval. iOS is authoritative, so its
state always wins (including a genuine rejected → resubmitted → in-review).
-}
externalReviewAction ::
    Bool ->
    Maybe (Text, Text) ->
    Maybe (Text, Text) ->
    Bool ->
    ExternalReviewAction
externalReviewAction inferred mExisting mMapped sccOwns = case mMapped of
    -- Nothing in review (only a live / draft version) → retire any stale row.
    Nothing -> retireExisting
    Just (version, reviewStatus)
        -- SCC already tracks this version → drop ours so it isn't double-shown.
        | sccOwns -> retireExisting
        | otherwise -> case mExisting of
            Nothing -> ExtInsert version reviewStatus
            Just (ev, eStatus)
                | ev /= version -> ExtRetireAndInsert version reviewStatus
                -- Never let an inferred "in_review" overwrite an operator's
                -- approve/reject on the same version (Android persistence fix).
                | inferred && isOperatorDecided eStatus && reviewStatus == "in_review" -> ExtNoop
                | otherwise -> ExtUpdate reviewStatus
  where
    retireExisting = maybe ExtNoop (const ExtComplete) mExisting
    isOperatorDecided s = s == "approved" || s == "rejected"

-- | Map a review state to a verdict; 'Nothing' for states we don't surface
-- (prepare-for-submission / live / unknown).
reviewStateToStatus :: AscReviewState -> Maybe Text
reviewStateToStatus = \case
    AscWaitingForReview -> Just "in_review"
    AscInReview -> Just "in_review"
    AscApproved -> Just "approved"
    AscRejected _ -> Just "rejected"
    _ -> Nothing

-- | The wf mirror for an external verdict — the same mapping 'phaseToWfStatus'
-- projects, derived from the one verdict source.
externalWf :: Text -> MobileBuildWFStatus
externalWf = \case
    "approved" -> MBReviewApproved
    "rejected" -> MBReviewRejected
    _ -> MBInReview

{- | The human-readable description / changelog for an external-review row.
@inferred@ (Android) softens it to "pending" because the review state is
derived from the track, not read authoritatively; iOS phrases by exact state.
-}
externalRowDescription :: Bool -> Text -> Text
externalRowDescription True _ =
    "Pending review/publish — submitted outside SCC (Android review state isn't exposed by Google)"
externalRowDescription False reviewStatus = case reviewStatus of
    "approved" -> "Approved — submitted outside SCC"
    "rejected" -> "Rejected — submitted outside SCC"
    _ -> "In review — submitted outside SCC"

{- | Insert a fresh @EXTERNAL_REVIEW@ row reflecting an out-of-band store review.
mode 'EXTERNAL_REVIEW' + no dispatch_id keeps it clear of the build runner, the
rollout reconciler, and the store-sync version dedup index. @mCode@ stamps the
build's version code (both platforms — identity is total, §16e-5); @inferred@
marks the review state as track-derived rather than authoritative (Android) —
surfaced in metadata so the UI labels it "Pending review", not "In review".

Identity guard: with no build code resolved (a degraded ASC read), skip the mint
and log — an identity-less row can't be converged/deduped correctly and caused
the wrong-row review overlays. The next sync retries with a fresh read.
-}
insertExternalReviewRow :: AppCatalog -> Maybe Int32 -> Bool -> Text -> Text -> Flow ()
insertExternalReviewRow ac Nothing _ version reviewStatus =
    logWarning $
        "[STORE_SYNC] Skipping identity-less external-review row for "
            <> acName ac
            <> " v"
            <> version
            <> " ("
            <> reviewStatus
            <> "): no build code resolved; retrying next sync"
insertExternalReviewRow ac mCode inferred version reviewStatus = do
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
                , mbcChangelogSummary = Nothing
                , mbcChangelogSummaryShort = Nothing
                }
        targetState =
            MobileBuildTargetState
                { mbWfStatus = externalWf reviewStatus
                , mbContext = ctx
                , mbExternalRunId = Nothing
                , mbMatrixJobStatus = Nothing
                , mbBuildStartedAt = Just now
                , mbBuildCompletedAt = Nothing
                , mbResolveAttempts = Nothing
                , mbReviewSubmittedAt = Just now
                , mbReviewLastPolledAt = Just now
                , mbBatchDispatch = Nothing
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
                , -- Review is a PRODUCTION-track lifecycle state (it's the incoming
                  -- version under review on the prod track), so the row lives on the
                  -- production track. The stage badge reads review_status, not track,
                  -- so it still shows "In review"/"Pending review", not "live".
                  rtStoreTrack = Just "production"
                , -- review_inferred (Android) flags the state as best-effort.
                  rtMetadata =
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
--
-- Identity guard: with no build code resolved (a degraded store read), skip the
-- mint and log — identity-less rows caused wrong-row convergence (§16e-5). The
-- next sync retries with a fresh read.
insertSyntheticRelease ::
    (MonadFlow m) =>
    AppCatalog ->
    Text ->
    Maybe Int32 ->
    -- | store track: "production" | "internal" | "testflight"
    Text ->
    m ()
insertSyntheticRelease ac version Nothing track =
    logWarning $
        "[STORE_SYNC] Skipping identity-less synthetic release for "
            <> acName ac
            <> " v"
            <> version
            <> " ("
            <> track
            <> "): no build code resolved; retrying next sync"
insertSyntheticRelease ac version mCode@(Just code) track = do
    -- An SCC draft that claimed this exact (version, code) but was never
    -- dispatched means the build shipped OUTSIDE SCC: adopt the draft (skip
    -- its build stages) instead of leaving it stale with phantom
    -- approve/dispatch buttons and minting nothing (identity index).
    adopted <- adoptManualDraft ac version code track
    unless adopted $ mintSyntheticRelease ac version mCode track

{- | Adopt a never-dispatched MANUAL draft whose identity just appeared on a
store track: flip it to INPROGRESS + @MBTagPushed@ with the derived store tag —
exactly the held-at-build-complete state the pipeline would have reached — so
promote takes over as the next step. Returns False when there is no such draft
(or a concurrent dispatch won the CAS) and the normal synthetic path should run.
-}
adoptManualDraft :: (MonadFlow m) => AppCatalog -> Text -> Int32 -> Text -> m Bool
adoptManualDraft ac version code track = do
    mDraft <- findAdoptableDraft (acName ac) (acSurface ac) (acPlatform ac) version code
    case mDraft of
        Just row
            | Just ts <- parseMobileTargetState (rtTargetState row) -> do
                now <- liftIO getCurrentTime
                let ts' =
                        ts
                            { mbWfStatus = MBTagPushed
                            , mbMatrixJobStatus = Just "completed"
                            , mbBuildCompletedAt = Just now
                            , mbContext = (mbContext ts){mbcTagPushed = derivedStoreTag ac version (Just code)}
                            }
                ok <-
                    adoptDraftAsStoreBuild
                        (rtId row)
                        track
                        (encodeJsonText (MobileBuildState ts'))
                        (fromMaybe now (rtStartTime row))
                        now
                when ok $ do
                    logInfo $
                        "[STORE_SYNC] Adopted SCC draft "
                            <> rtId row
                            <> " for "
                            <> acName ac
                            <> " v"
                            <> version
                            <> "+"
                            <> T.pack (show code)
                            <> " — build uploaded outside SCC ("
                            <> track
                            <> "); skipped to build-complete"
                    insertReleaseEvent (rtId row) "BUSINESS" "STORE_BUILD_ADOPTED" $
                        object
                            [ "app" .= acName ac
                            , "platform" .= acPlatform ac
                            , "version" .= version
                            , "version_code" .= code
                            , "track" .= track
                            , "note" .= ("build uploaded outside SCC; draft skipped to build-complete" :: Text)
                            ]
                pure ok
        _ -> pure False

mintSyntheticRelease :: (MonadFlow m) => AppCatalog -> Text -> Maybe Int32 -> Text -> m ()
mintSyntheticRelease ac version mCode track = do
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
                , mbcChangelogSummary = Nothing
                , mbcChangelogSummaryShort = Nothing
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
                , mbBatchDispatch = Nothing
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
                , rtMetadata = Just (buildStoreMeta track)
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
                , rtStoreTrack = Just track
                , rtVersionCode = mCode
                , rtTerminalStatus = Nothing
                , -- Singleton pseudo-group: addressable by URL, but excluded from
                  -- the groups list (mode=STORE_SYNC).
                  rtReleaseGroupId = Just groupId
                , rtReleaseGroupLabel = Nothing
                , rtCloudType = Nothing
                , rtCreatedAt = now
                , rtUpdatedAt = now
                }
    -- A build leaving external review already has a row (mode=EXTERNAL_REVIEW) for
    -- this exact version: transition THAT row in place — keep its date_created —
    -- instead of minting a duplicate and orphaning the review row. Skip when a
    -- STORE_SYNC row already exists (legacy dup) so the flip can't violate the index.
    mReview <- findExternalReviewRowForVersion (acName ac) (acSurface ac) (acPlatform ac) version mCode
    canAdopt <- case mReview of
        Just _ -> not <$> storeSyncRowExistsForVersion (acName ac) (acSurface ac) (acPlatform ac) version mCode
        Nothing -> pure False
    case mReview of
        Just r | canAdopt -> do
            convergeStoreSyncRow (rtId r) track mCode encodedCtx (buildStoreMeta track) now
            insertReleaseEvent (rtId r) "BUSINESS" "STORE_SYNC" $
                object
                    [ "app" .= acName ac
                    , "platform" .= acPlatform ac
                    , "version" .= version
                    , "version_code" .= mCode
                    , "build_type" .= ("release" :: Text)
                    , "transition" .= ("external_review->store_sync" :: Text)
                    ]
            logInfo $
                "[STORE_SYNC] Transitioned external-review row "
                    <> rtId r
                    <> " -> live ("
                    <> track
                    <> ") for "
                    <> acName ac
                    <> " v"
                    <> version
        -- No review row to adopt (or a STORE_SYNC row already owns this version):
        -- mint as before. ON CONFLICT DO NOTHING dedupes a concurrent / legacy row.
        _ -> do
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

{- | The metadata JSON a store-sync row carries: the leading @store_track@, which
drives the list/badge and marks the row as a store-sync snapshot. The live
prod/internal versions are read from @store_status@, not from here.
-}
buildStoreMeta :: Text -> Text
buildStoreMeta track =
    encodeJsonText (object ["store_track" .= track])

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
the view stops lagging reality.
-}
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
    case (acPackageName ac, rowVersionCode row) of
        (Just pkg, Just code)
            | not (T.null pkg) ->
                getProductionReleases creds pkg >>= \case
                    Left e -> logWarning $ "[ROLLOUT_SYNC] Console-rollout read error for " <> rtId row <> ": " <> renderPlayErr e
                    -- Match OUR version's release on the track (not the newest), so a
                    -- genuine Console rollout of this version is detected even when a
                    -- newer review submission sits ahead of it on the track.
                    Right releases -> case rolloutStateForCode code releases of
                        Just st -> mapM_ (adoptExternalRollout (rtId row) "play") (detectConsoleRollout androidPendingFractionThreshold code st)
                        -- Our code is GONE from the track → classify the outcome
                        -- (§16h-1) instead of zombie-ing at "In review".
                        Nothing -> resolveVanishedSubmission row code releases
        _ -> pure ()

{- | §16h-1 for SCC-promoted rows: the watched code VANISHED from a successful,
non-empty track read — stamp the outcome instead of leaving the row at
"In review" forever. Grace-guarded: a just-promoted row can postdate the track
read (the promote may land between the read and this reconcile), so rows
submitted <30 min ago are skipped; the next pass classifies them fresh.
-}
resolveVanishedSubmission :: ReleaseTrackerRow -> Int32 -> [ProdTrackRelease] -> Flow ()
resolveVanishedSubmission row code releases = do
    now <- liftIO getCurrentTime
    let recent = maybe True (\t -> diffUTCTime now t < 1800) (rtReviewSubmittedAt row)
        -- External rows have no runner Finalize — close their engine status too.
        close ph
            | rtMode row == Just "EXTERNAL_REVIEW" = closeExternalReviewRow (rtId row) ph
            | otherwise = setPhase now (rtId row) ph
    unless recent $
        forM_ (pendingOutcome androidPendingFractionThreshold code releases) $ \case
            PendingReplaced -> do
                close Superseded
                logInfo $ "[ROLLOUT_SYNC] " <> rtId row <> " submission replaced on the production track — superseded"
                logEvent (rtId row) "SUBMISSION_RETIRED" (object ["outcome" .= ("replaced" :: Text)])
            PendingWithdrawn -> do
                close (Rejected "Removed from the production track before publishing (rejected or withdrawn in Play Console)")
                logInfo $ "[ROLLOUT_SYNC] " <> rtId row <> " submission left the production track before publishing — rejected/withdrawn"
                logEvent (rtId row) "SUBMISSION_RETIRED" (object ["outcome" .= ("rejected_or_withdrawn" :: Text)])
            -- Parked/Published require the code to be PRESENT — unreachable from
            -- the vanished arm; kept for totality.
            _ -> pure ()

{- | Detect an App Store Connect "Release" (not from SCC) on an iOS release SCC
promoted but is still showing as in review / approved-held. Unlike Android, Apple
exposes an authoritative state: @READY_FOR_SALE@ ('AscLive') means the build is
live. SCC reads the live review + phased state and adopts it ('detectIosRelease')
— a phased release becomes @rolling_out@ at the ramp % (the Phase-7 reconciler
then tracks the 7-day schedule), a non-phased one completes. Still-held
(@PENDING_DEVELOPER_RELEASE@) or in-review versions are left untouched.
-}
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

{- | Best-effort backfill of @asc_phased_id@ from the store so the Phase-7
reconciler can track an adopted phased ramp (it reads the cached id to follow
Apple's 7-day schedule). A miss / error leaves it unset — the ramp still rolls
out at Apple; only SCC's % tracking would lag.
-}
backfillPhasedId :: AscCreds -> Text -> Text -> Text -> Flow ()
backfillPhasedId creds bundleId version rid =
    getPhasedReleaseId creds bundleId version >>= \case
        Right (Just pid) | not (T.null pid) -> do
            setAscIds rid Nothing (Just pid)
            logInfo $ "[ROLLOUT_SYNC] " <> rid <> " backfilled asc_phased_id from store (adopted phased ramp)"
        _ -> pure ()

{- | Apply an adopted out-of-band release/rollout: bring the row into SCC's rollout
lifecycle (rollout columns + MBRollingOut/MBCompleted) so the active reconciler
keeps it in sync from here on. @store@ is "play" | "asc" for the audit event.
-}

{- | Store-observed rollout status → phase ("halted" → Halted, else RollingOut).
Inputs are only the canonical "rolling_out" / "halted" carried by SetRollout.
-}
rolloutPhase :: Text -> Maybe Double -> ReleasePhase
rolloutPhase status mPct
    | status == "halted" = Halted frac
    | otherwise = RollingOut frac
  where
    frac = maybe 0 (/ 100) mPct

adoptExternalRollout :: Text -> Text -> ReconcileAction -> Flow ()
adoptExternalRollout rid store action = do
    now <- liftIO getCurrentTime
    case action of
        SetRollout status mPct -> do
            setPhase now rid (rolloutPhase status mPct)
            logInfo $ "[ROLLOUT_SYNC] " <> rid <> " external rollout detected (" <> store <> ") → " <> status <> maybe "" (\p -> " @ " <> T.pack (show p) <> "%") mPct
            logEvent rid "EXTERNAL_ROLLOUT_DETECTED" $ object ["store" .= store, "status" .= status, "percent" .= mPct]
        CompleteRollout -> do
            setPhase now rid Live
            logInfo $ "[ROLLOUT_SYNC] " <> rid <> " external release already at 100% (" <> store <> ") → completing"
            logEvent rid "EXTERNAL_ROLLOUT_DETECTED" $ object ["store" .= store, "status" .= ("completed" :: Text), "percent" .= (100 :: Double)]
        LeaveAsIs _ -> pure ()

{- | Reconcile one row, isolating failures so a single bad row (e.g. a missing
app-catalog join, or a one-off store error) never aborts the whole batch.
-}
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

{- | Android: read the production track; mirror its status + userFraction, and
complete the release when the rollout reaches 100% (status=completed).
| The decision a reconcile pass makes from a live store rollout state. Pure
so the mapping is unit-tested ([35]) without hitting a store.
-}
data ReconcileAction
    = -- | mirror the live status ("rolling_out" | "halted") + percent
      SetRollout Text (Maybe Double)
    | -- | reached 100% → finish the release
      CompleteRollout
    | -- | unrecognized store status (echoed back for logging)
      LeaveAsIs Text
    deriving (Eq, Show)

{- | Android production-track status → action. Play reports a 0–1 @userFraction@;
we store it as a 0–100 percent.
-}
androidReconcileAction :: PlayRolloutState -> ReconcileAction
androidReconcileAction st = case prsStatus st of
    "completed" -> CompleteRollout
    "halted" -> SetRollout "halted" pct
    "inProgress" -> SetRollout "rolling_out" pct
    other -> LeaveAsIs other
  where
    pct = fmap (* 100) (prsUserFraction st)

{- | iOS phased-release state + ramp day → action (Apple drives the %; we map the
day through 'applePhasedPercent').
-}
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
'androidReconcileAction' for the status → action mapping. Unit-tested ([43]).
-}
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
'Nothing' (leave the row as approved / in review). Unit-tested ([44]).
-}
detectIosRelease :: AscReviewState -> AscPhasedState -> Maybe ReconcileAction
detectIosRelease AscLive ps = Just $ case iosPhasedReconcileAction ps of
    LeaveAsIs _ -> CompleteRollout
    action -> action
detectIosRelease _ _ = Nothing

reconcileAndroid :: PlayCreds -> Text -> Text -> ReleaseTrackerRow -> Flow ()
reconcileAndroid creds rid storeId row = do
    res <- getProductionReleases creds storeId
    case res of
        Left e -> logWarning $ "[ROLLOUT_SYNC] Play read error for " <> rid <> ": " <> renderPlayErr e
        -- Version-match against OUR release on the (possibly multi-release) production
        -- track — never the newest one, else a freshly-submitted near-zero review
        -- version overwrites our halted/rolling %. Our version absent from a successful,
        -- non-empty read → superseded → retire it.
        Right releases ->
            forM_ (rowVersionCode row) $ \code ->
                case rolloutStateForCode code releases of
                    Just st -> execReconcile rid "play" row (androidReconcileAction st)
                    Nothing | not (null releases) -> retireSupersededRollout rid
                    Nothing -> pure ()

{- | iOS phased release: mirror Apple's ramp day → %, completing when Apple
finishes the 7-day schedule. Non-phased releases complete at /release time
(Phase 6), so a rolling_out row with no phased id has nothing to ramp.
-}
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

{- | Persist a rollout %/status update, logging + auditing only when it actually
changed (a refresh re-reads the live state, so most passes are no-ops).
-}
updateRollout :: Text -> Text -> Maybe Double -> ReleaseTrackerRow -> Flow ()
updateRollout rid newStatus mPct row = do
    now <- liftIO getCurrentTime
    setPhase now rid (rolloutPhase newStatus mPct)
    if Just newStatus /= rtRolloutStatus row || pctChanged mPct (rtRolloutPercent row)
        then do
            logInfo $ "[ROLLOUT_SYNC] " <> rid <> " → " <> newStatus <> maybe "" (\p -> " @ " <> T.pack (show p) <> "%") mPct
            logEvent rid "ROLLOUT_RECONCILED" $ object ["status" .= newStatus, "percent" .= mPct]
        else pure ()

{- | Rollout reached 100%: mark it completed and hand off to the runner's
Finalize stage, which flips the release to COMPLETED on the next tick.
-}
completeRollout :: Text -> Text -> Flow ()
completeRollout rid store = do
    now <- liftIO getCurrentTime
    setPhase now rid Live
    logInfo $ "[ROLLOUT_SYNC] " <> rid <> " rollout complete (100%) — finishing release"
    logEvent rid "ROLLOUT_COMPLETED" $ object ["store" .= store]

-- | Treat sub-0.01-point % moves as unchanged (avoids event spam on float jitter).
pctChanged :: Maybe Double -> Maybe Double -> Bool
pctChanged (Just a) (Just b) = abs (a - b) > 0.0001
pctChanged Nothing Nothing = False
pctChanged _ _ = True

-- ─── App Release Monitoring: on-demand store refresh ───────────────────

{- | Live re-poll a single app via ONE store read, then write everything that read
yields — @store_status@ monitor cache, the @release_tracker@ create-page snapshot,
external-review rows, AND the rollout reconcile — through 'syncAppUnified'. This is
the on-demand entry point: the ↻ refresh button and the pages' cold-start auto-refresh
drive it. A debug deployment has no production store data, so it's a no-op there —
never pull production store data into a debug deployment.
-}
refreshStoreStatusOne :: AppCatalog -> Flow ()
refreshStoreStatusOne ac = do
    buildType <- getMobileBuildType
    if isDebugBuildType buildType
        then logInfo "[STORE_MONITOR] Debug build env, skipping live refresh (release-only)"
        else do
            -- Cooldown: a Play track read costs a daily-quota'd edit. Within the
            -- window we serve the cache instead of re-polling — this caps the per-app
            -- edit rate against rapid / multi-user refresh-button mashing (each click
            -- would otherwise mint a fresh edit per app). Configurable via
            -- @store_refresh_cooldown_seconds@; same value the UI reads as its
            -- stale/auto-refresh threshold.
            cooldown <- fromIntegral <$> getStoreRefreshCooldownSeconds
            mAge <- secondsSinceLastSync (acId ac)
            case mAge of
                Just age
                    | age < cooldown ->
                        logInfo $
                            "[STORE_MONITOR] "
                                <> acName ac
                                <> " synced "
                                <> T.pack (show (round age :: Int))
                                <> "s ago (< "
                                <> T.pack (show (round cooldown :: Int))
                                <> "s cooldown) — serving cache, skipping live re-poll"
                _ -> withRefreshSingleFlight (acId ac) $ do
                    builds <- fetchLatestBuildsPerApp
                    expected <- latestShippedVersionsPerApp
                    let buildMap =
                            Map.fromList
                                [ ((lbrAppGroup b, lbrSurface b, lbrPlatform b), b)
                                | b <- builds
                                ]
                    mPlayCreds <- loadPlayCreds
                    -- ONE fetch → store_status + create-page snapshot + external-review
                    -- + rollout reconcile, all for this app. ASC creds resolved per
                    -- store account inside.
                    syncAppUnified mPlayCreds buildMap expected ac

{- | The backend fan-out for "refresh all": sweep every app through the per-app
on-demand path ('refreshStoreStatusOne' — cooldown-gated, single-flight, records its
own outcome), up to 'bulkRefreshConcurrency' apps in parallel. A process-global guard
coalesces concurrent kicks onto ONE sweep, and it runs DETACHED ('forkFlow') so it
outlives the triggering request (the operator navigating away).
-}
refreshAllStale :: Flow ()
refreshAllStale = do
    alreadyRunning <- liftIO $ modifyMVar bulkRefreshInflight (\b -> pure (True, b))
    if alreadyRunning
        then logInfo "[STORE_MONITOR] bulk refresh already running — coalescing"
        else
            ( do
                appSt <- ask
                apps <- listAppCatalog
                -- Bounded concurrency: distinct apps don't share per-app quota (the
                -- per-app cooldown + single-flight still cap each), so parallelising the
                -- store round-trips is safe — ~Nx faster than a sequential sweep.
                sem <- liftIO (newQSem bulkRefreshConcurrency)
                liftIO $ Async.forConcurrently_ apps $ \ac ->
                    bracket_ (waitQSem sem) (signalQSem sem) $
                        runFlow appSt (safely ("bulk refresh " <> acName ac) (refreshStoreStatusOne ac))
            )
                `MC.finally` liftIO (modifyMVar_ bulkRefreshInflight (const (pure False)))

{- | How many apps the bulk store-refresh sweep reads in parallel (distinct apps only —
per-app quota is still capped by the cooldown + single-flight).
-}
bulkRefreshConcurrency :: Int
bulkRefreshConcurrency = 5

-- | Whether a bulk sweep is in progress (surfaced to the UI as a 'refreshing' hint).
isBulkRefreshing :: Flow Bool
isBulkRefreshing = liftIO (readMVar bulkRefreshInflight)

-- | Process-global guard: at most one full sweep at a time (per instance).
{-# NOINLINE bulkRefreshInflight #-}
bulkRefreshInflight :: MVar Bool
bulkRefreshInflight = unsafePerformIO (newMVar False)

{- | Process-global in-flight registry for on-demand refreshes: @app_catalog_id →
barrier@. Coalesces concurrent refreshes of the SAME app — without it, several
users clicking Refresh on one app in the same instant all pass the (DB) cooldown
check before any of them writes @synced_at@, then each spends its own Play edit.
With it, the first caller fetches and the rest wait for it and serve the (now
fresh) cache. Caps the per-app live read at ONE concurrent fetch.

In-memory, so it coalesces within a single backend process. Multiple replicas
would each elect their own leader; a Postgres advisory lock keyed on the package
is the cross-instance evolution.
-}
{-# NOINLINE refreshInflight #-}
refreshInflight :: MVar (Map.Map Int32 (MVar ()))
refreshInflight = unsafePerformIO (newMVar Map.empty)

{- | Run @live@ for this app under single-flight. The first caller for @aid@ runs
it; concurrent callers block until it finishes, then return without re-fetching
(the leader's write already refreshed the shared cache). The barrier is always
released — even if @live@ throws — so followers never hang.
-}
withRefreshSingleFlight :: Int32 -> Flow () -> Flow ()
withRefreshSingleFlight aid live = do
    decision <- liftIO $ modifyMVar refreshInflight $ \m ->
        case Map.lookup aid m of
            Just barrier -> pure (m, Left barrier)
            Nothing -> do
                barrier <- newEmptyMVar
                pure (Map.insert aid barrier m, Right barrier)
    case decision of
        Left barrier -> do
            logInfo $ "[STORE_MONITOR] Refresh already in flight for app " <> T.pack (show aid) <> " — joining, serving cache"
            liftIO (readMVar barrier)
        Right barrier ->
            live
                `MC.finally` liftIO
                    ( do
                        modifyMVar_ refreshInflight (pure . Map.delete aid)
                        putMVar barrier ()
                    )

{- | Map a Play track snapshot → a @store_status@ upsert: pure store truth only.
Production carries the live staged-rollout % (the near-zero "pending" fraction
reads as a tiny %, which the badge treats as not-yet-ramped); internal testing
has no rollout. Review is never written — it lives on the release row (§16).
-}
androidSnapToUpsert :: AppCatalog -> Maybe Text -> StoreTrackSnapshot -> StoreStatusUpsert
androidSnapToUpsert ac mExpected s =
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
            , ssuReleaseNotes = stsNotes s
            , ssuExpectedVersion = mExpected
            }

{- | Production rollout floor (percent). Below this, a live @userFraction@ is the
parked review/pending fraction, not a real ramp — the 0–100 mirror of
'androidPendingFractionThreshold' (0.01 fraction = 1%).
-}
androidRolloutFloorPercent :: Double
androidRolloutFloorPercent = androidPendingFractionThreshold * 100

{- | Map an ASC snapshot → a @store_status@ upsert: pure store truth only. The
snapshot carries no rollout % (Apple exposes the phased ramp separately), so the
production cell's % is written right after by 'reflectIosPhasedRollout' in the
same pass; between syncs an SCC rollout action mirrors its own edit. Review is
never written — it lives on the release row (§16).
-}
iosSnapToUpsert :: AppCatalog -> Maybe Text -> AscSnapshot -> StoreStatusUpsert
iosSnapToUpsert ac mExpected s =
    StoreStatusUpsert
        { ssuAppCatalogId = acId ac
        , ssuPlatform = "ios"
        , ssuTrack = ascTrack s
        , ssuVersionName = nonEmptyVersion (ascVersion s)
        , ssuVersionCode = ascCode s
        , ssuStatus = Just (ascStatus s)
        , ssuRolloutPercent = Nothing
        , ssuReleaseNotes = ascNotes s
        , ssuExpectedVersion = mExpected
        }

-- | A snapshot's placeholder "no build on this track" markers → 'Nothing'.
nonEmptyVersion :: Text -> Maybe Text
nonEmptyVersion v
    | v `elem` ["", "0.0.0", "none"] = Nothing
    | otherwise = Just v
