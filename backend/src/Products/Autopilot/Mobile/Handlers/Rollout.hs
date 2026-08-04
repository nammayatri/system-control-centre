{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | Phase 6 — promote-to-review + staged-rollout HTTP handlers.

The operator drives the last leg of a mobile release from SCC instead of the
Play Console / App Store Connect:

  build done (MBTagPushed, held) → /promote → MBInReview → (approved) →
  /release (iOS) or /rollout/set (Android) → MBRollingOut → /rollout/release-all → COMPLETED

Every handler is gated on @mobile_staged_rollout_enabled@ ('requireStaged'); with
the flag off these endpoints 400 and release builds keep auto-completing at
tag-push (the legacy behavior). Promote and rollout are __operator-gated__ (a
human clicks) — nothing here is triggered automatically.

Platform split:

  * __iOS__ has a clean review signal (@appStoreState@) and Apple-driven phased
    release. Approval is auto-detected by the Phase-5 poll stage; the operator
    clicks /release, then Apple ramps over 7 days (pause/resume/release-all).
  * __Android__ review is opaque (no API signal), so approval/rejection are
    recorded by the operator (/review/mark-approved | /review/mark-rejected),
    and the operator sets the staged rollout % directly (/rollout/set).
-}
module Products.Autopilot.Mobile.Handlers.Rollout (
    -- * Request / response types
    PromoteForm (..),
    PromoteReq (..),
    PromoteResp (..),
    RolloutDetail (..),
    RolloutSetReq (..),
    MarkRejectedReq (..),
    BulkPromoteItem (..),
    BulkPromoteReq (..),
    BulkRolloutItem (..),
    BulkRolloutReq (..),
    BulkItemResult (..),
    BulkActionResp (..),

    -- * Handlers
    promoteFormH,
    promoteH,
    rolloutDetailH,
    releaseH,
    rolloutSetH,
    rolloutHaltH,
    rolloutResumeH,
    rolloutReleaseAllH,
    markApprovedH,
    markRejectedH,
    withdrawH,
    bulkPromoteH,
    bulkRolloutH,
) where

import Control.Applicative ((<|>))
import Control.Exception (SomeException, displayException, fromException)
import Control.Monad (forM_, unless, when)
import Control.Monad.Catch (throwM)
import Control.Monad.Catch qualified as MC
import Control.Monad.IO.Class (liftIO)
import Core.AppError (APIError (..), ToAppError (..))
import Core.Auth.Protected (AuthedPerson (..))
import Data.Proxy (Proxy (..))
import Products.Autopilot.Mobile.Auth (requireAppPerm)
import Products.Mobile.Types.Permission (MobilePermission (..))
import Core.Environment (Flow)
import Data.Aeson (FromJSON, ToJSON, object, (.=))
import Data.Int (Int32)
import Data.List (find)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime, getCurrentTime)
import GHC.Generics (Generic)
import Products.Autopilot.Mobile.Lifecycle.BuildKind (buildKind)
import Products.Autopilot.Mobile.Lifecycle.Phase (Display (..), ReleasePhase (..), abortable, displayStatusInferred, phaseFromFields, phaseSlug, supersededIfBehind, variantSlug)
import Products.Autopilot.Mobile.Queries.AppCatalog (storeTrackOf)
import Products.Autopilot.Mobile.Queries.StoreStatus (
    findProductionLiveCell,
    findProductionStoreCell,
    resolveStoreState,
    secondsSinceLastSync,
    setProductionReleased,
    setProductionRolloutStatus,
    storeCellsForApp,
 )
import Products.Autopilot.Mobile.Queries.Supersession (convergeMobileSlots, retireOlderIncoming, supersedePreviousLive)
import Products.Autopilot.Mobile.Queries.Tracker (
    appCatalogForRowRaw,
    findMobileReleaseById,
    findRunSiblingsStillBuilding,
    heldRowsForApp,
    listIncomingMobileVersions,
    logEvent,
    markReleaseInProgress,
    retireOlderHeldInternal,
    setAscIds,
    setPhase,
 )
import Products.Autopilot.Mobile.StoreSync (atOrBelowProductionPure, releaseOrderBehind, releaseOrderStrictlyBehind)
import Products.Autopilot.Mobile.Types (
    MobileBuildContext (..),
    MobileBuildTargetState (..),
    MobileBuildWFStatus (..),
    isDebugBuildType,
 )
import Products.Autopilot.Mobile.Types.Storage (AppCatalog, AppCatalogT (..))
import Products.Autopilot.Mobile.Versioning.Apple (
    AscError (..),
    cancelReviewSubmission,
    completePhasedRelease,
    enablePhasedRelease,
    getLiveReleaseNotes,
    getPhasedReleaseId,
    loadAscCredsFor,
    lookupAscAppId,
    pausePhasedRelease,
    releaseApprovedVersion,
    renderAscErr,
    resumePhasedRelease,
    submitVersionForReview,
 )
import Products.Autopilot.Mobile.Versioning.Play (
    PlayCreds,
    ProdTrackRelease (..),
    completeTrackRollout,
    getProductionReleaseNotes,
    getProductionReleases,
    haltTrackRollout,
    loadPlayCreds,
    promoteToProduction,
    renderPlayErr,
    resumeTrackRollout,
    setTrackRollout,
    userFractionInRange,
 )
import Products.Autopilot.Queries.ReleaseTracker (parseJsonTextMaybe, reviewInferredOf)
import Products.Autopilot.RuntimeConfig (getAndroidReviewRolloutFraction, getStoreRefreshCooldownSeconds, isStagedRolloutEnabled)
import Products.Autopilot.Types.Storage.Schema (ReleaseTrackerRow, ReleaseTrackerT (..))
import Shared.API.Response (APISuccess (..))

-- ─── Request / response types ──────────────────────────────────────────

{- | GET /promote-form — what the FE pre-fills the promote dialog with. The
notes default to the release's stored changelog; the FE may swap in the
AI @summary_short@. The form is read-only ('pfLocked') once the app is in
review (Apple won't let notes change mid-review, §12.7).
-}
data PromoteForm = PromoteForm
    { pfReleaseId :: Text
    , pfPlatform :: Text
    -- ^ "android" | "ios"
    , pfAppLabel :: Text
    , pfVersion :: Text
    , pfReleaseNotes :: Text
    -- ^ Editable default — the current production "What's New" for a store-synced
    -- release, else the stored changelog.
    , pfReviewStatus :: Maybe Text
    , pfLocked :: Bool
    , pfPhasedSupported :: Bool
    -- ^ iOS only.
    , pfIsStoreSync :: Bool
    -- ^ True when this release was synced from the store (notes already default
    -- to the live production notes) → the FE must NOT swap in the AI summary.
    , pfAiShort :: Maybe Text
    -- ^ The AI short synopsis captured at CREATE time — describes the commits
    -- that went into this build (a live AI re-query would diff the branch
    -- head, which may have moved). The FE prefers this as the AI source.
    }
    deriving (Eq, Show, Generic)

instance ToJSON PromoteForm
instance FromJSON PromoteForm

{- | POST /promote body. v1 owns only the release notes (What's New); reviewer
info / demo account defer to the store (§4).
-}
data PromoteReq = PromoteReq
    { prReleaseNotes :: Text
    , prEnablePhasedRelease :: Maybe Bool
    -- ^ iOS only — turn on Apple's 7-day phased ramp at release time.
    , prInitialRolloutPercent :: Maybe Double
    -- ^ Android only — initial rollout % (0,100); omitted → the effectively-zero
    -- @android_review_rollout_fraction@ so approval exposes ~0 users.
    }
    deriving (Eq, Show, Generic)

instance ToJSON PromoteReq
instance FromJSON PromoteReq

{- | POST /promote response. The review submission either fully succeeds or the
whole call fails ('bad'), so there's no partial-failure result here EXCEPT the
best-effort phased-release enable: that can fail without undoing the (already
submitted) review, so it's surfaced as a non-fatal 'prWarning' the FE shows.
-}
data PromoteResp = PromoteResp
    { prResult :: Text
    , prWarning :: Maybe Text
    -- ^ non-fatal warning, e.g. "phased release could not be enabled".
    }
    deriving (Eq, Show, Generic)

instance ToJSON PromoteResp
instance FromJSON PromoteResp

-- | GET /rollout — the cached review + rollout state (no live store call).
data RolloutDetail = RolloutDetail
    { rdReleaseId :: Text
    , rdPlatform :: Text
    , rdMbStatus :: Text
    , rdStatusLabel :: Text
    -- ^ Canonical lifecycle label ("Rolling out 1%", "Approved · held") from the one
    -- backend displayStatus. The FE renders this instead of re-deriving the badge.
    , rdStatusVariant :: Text
    -- ^ Badge-variant slug for rdStatusLabel (success | info | warning | …).
    , rdPhase :: Text
    -- ^ Machine phase tag (building | in_review | rolling_out | …) — lets the FE
    -- branch (e.g. suppress the lifecycle badge while the build is still building).
    , rdReviewStatus :: Maybe Text
    , rdReviewRejectReason :: Maybe Text
    , rdReviewSubmittedAt :: Maybe UTCTime
    , rdReviewDecidedAt :: Maybe UTCTime
    , rdRolloutStatus :: Maybe Text
    , rdRolloutPercent :: Maybe Double
    , rdPhasedId :: Maybe Text
    -- ^ iOS cached phased-release id (present ⇒ phased ramp is on).
    , rdStoreTrack :: Maybe Text
    -- ^ store track ("production" | "internal" | "testflight") for store-sync rows;
    -- an un-promoted internal/testflight snapshot is offered the promote flow.
    , rdPromotable :: Bool
    -- ^ BE truth for "can this build be promoted right now": it's in a promotable
    -- stage (held at MBTagPushed, or an un-promoted internal/TestFlight snapshot) AND
    -- it isn't already live on production. The FE gates the promote UI on this instead
    -- of re-deriving it, so it never offers a promote the backend would reject.
    , rdPromoteBlock :: Maybe Text
    -- ^ WHY rdPromotable is False, when it is (promote stage only): "behind_production"
    -- | "behind_held" | "blocked_by_incoming" | "one_in_flight". The FE renders
    -- cause-specific copy from this instead of guessing one message for all gates.
    , rdPromoteBlockVersion :: Maybe Text
    -- ^ The blocking sibling's version (held/incoming/in-flight causes), when known.
    , rdAbortable :: Bool
    -- ^ BE truth for "can this build be aborted right now" — only while the build job
    -- can still be killed (wf before MBSubmittedToStore: nothing uploaded yet). A build
    -- whose artifact reached the store or that went terminal can't be un-shipped, so
    -- the FE hides Abort. Phase+wf derived; a stale status column can't resurrect it.
    , rdRunSiblings :: [Text]
    -- ^ OTHER apps still building in the same shared GH run (dispatch group). Aborting
    -- this row cancels the whole run — these builds die with it, so the FE lists them
    -- in the abort confirm. Empty for solo runs / already-uploaded siblings.
    , rdAppCatalogId :: Int32
    -- ^ The app's @app_catalog.id@ — lets the FE force a store-sync
    -- (@POST /mobile/store-monitor/:id/refresh@) before re-reading, so a just-published
    -- Managed-Publishing change is picked up and @rdLiveOnProduction@ flips.
    , rdLiveOnProduction :: Bool
    -- ^ BE truth for "is THIS build the one currently live on the production track",
    -- read from the synced @store_status@ production cell (code-first, version-name
    -- fallback). Under Play Managed Publishing a promoted Android build sits STAGED on
    -- production until the operator clicks Publish in the Console; until then this is
    -- False and the live cell still shows the previous version. The FE uses it to gate
    -- the Android approved-stage UI: not-live ⇒ show the "Publish in Play Console" link
    -- (a rollout % wouldn't apply yet); live ⇒ show the rollout controls. NOTE: it's a
    -- read of a CACHE, so it only flips once a sync runs — the FE Refresh forces one.
    , rdSyncedSecondsAgo :: Maybe Double
    -- ^ Seconds since this app's @store_status@ was last synced ('Nothing' = never).
    -- The publish gate surfaces it so the operator knows whether a Refresh will do a
    -- live store re-poll (age ≥ cooldown) or just serve cache (age < cooldown).
    , rdRefreshCooldownSeconds :: Int32
    -- ^ The per-app refresh cooldown (@store_refresh_cooldown_seconds@). A Refresh only
    -- triggers a live store re-poll once the last sync is older than this — within the
    -- window it serves cache (protects Play's per-app edit quota). Paired with
    -- @rdSyncedSecondsAgo@ so the FE can show "live re-check available in N s".
    }
    deriving (Eq, Show, Generic)

instance ToJSON RolloutDetail
instance FromJSON RolloutDetail

-- | POST /rollout/set body (Android) — the new rollout percent in (0,100].
newtype RolloutSetReq = RolloutSetReq {rsPercent :: Double}
    deriving (Eq, Show, Generic)

instance ToJSON RolloutSetReq
instance FromJSON RolloutSetReq

-- | POST /review/mark-rejected body (Android) — the operator-supplied reason.
newtype MarkRejectedReq = MarkRejectedReq {mrReason :: Text}
    deriving (Eq, Show, Generic)

instance ToJSON MarkRejectedReq
instance FromJSON MarkRejectedReq

-- ─── Handlers ──────────────────────────────────────────────────────────

-- | GET /releases/:id/promote-form — pre-fill + lock state for the promote dialog.
promoteFormH :: AuthedPerson -> Text -> Flow PromoteForm
promoteFormH _ap rid = do
    requireStaged
    (row, target, ac) <- loadPromotable rid
    let platform = rtEnv row
        isStoreSync = rtMode row == Just "STORE_SYNC"
    notes <- promoteDefaultNotes row target ac
    pure
        PromoteForm
            { pfReleaseId = rid
            , pfPlatform = platform
            , pfAppLabel = fromMaybe (acName ac) (acDisplayLabel ac)
            , pfVersion = rtNewVersion row
            , pfReleaseNotes = notes
            , pfReviewStatus = rtReviewStatus row
            , pfLocked = isPostPromote (mbWfStatus target)
            , pfPhasedSupported = platform == "ios"
            , pfIsStoreSync = isStoreSync
            , pfAiShort = mbcChangelogSummaryShort (mbContext target)
            }

{- | Best-effort fetch of the current production "What's New" from the store
(App Store live version / Play production track). 'Nothing' on any missing
creds / package name / store error / empty notes — the caller falls back.
-}
fetchProdReleaseNotes :: AppCatalog -> Text -> Flow (Maybe Text)
fetchProdReleaseNotes ac platform = case (platform, acPackageName ac) of
    ("ios", Just pkg) | not (T.null pkg) -> do
        mCreds <- loadAscCredsFor (acStoreAccount ac)
        case mCreds of
            Just creds -> either (const Nothing) id <$> liftIO (getLiveReleaseNotes creds pkg)
            Nothing -> pure Nothing
    ("android", Just pkg) | not (T.null pkg) -> do
        mCreds <- loadPlayCreds
        case mCreds of
            Just creds -> either (const Nothing) id <$> getProductionReleaseNotes creds pkg
            Nothing -> pure Nothing
    _ -> pure Nothing

{- | The default release notes for a promote: the current production "What's New"
pulled from the store, for EVERY row — store notes address users, not the build
pipeline, so the workflow changelog is only the last resort (store read failed /
nothing live yet). SCC-built rows may still get the AI short summary swapped in
by the FE. Shared by the promote form and bulk promote (where the operator
supplies no per-app notes).
-}
promoteDefaultNotes :: ReleaseTrackerRow -> MobileBuildTargetState -> AppCatalog -> Flow Text
promoteDefaultNotes row target ac = do
    let changelog = mbcChangeLog (mbContext target)
    fromMaybe changelog <$> fetchProdReleaseNotes ac (rtEnv row)

{- | POST /releases/:id/promote — fill the release notes and submit the app for
review. iOS: set What's New on every locale + releaseType MANUAL + submit, then
(optionally) enable phased release. Android: promote internal→production at the
effectively-zero review fraction so approval exposes ~0 users. The release moves
to @MBInReview@; the Phase-5 poll stage takes it from there (iOS auto, Android
awaits the operator's mark-*).
-}

{- | True when this build is NOT ahead of production, so it can't be promoted:
behind in release order (version-first, code tiebreak — 'releaseOrderBehind'),
OR — Android — an artifact Play itself would reject (code at/below the live
one; Play never checks version names). One shared predicate
('atOrBelowProductionPure') with the list's promotable flag, so the promote
gate, badge, and summary can never disagree. Reads the synced cache (no store
call); fails OPEN when the production version is unknown.
-}
atOrBelowProduction :: AppCatalog -> Text -> Maybe Int32 -> Flow Bool
atOrBelowProduction ac buildVer mCode = do
    mProd <- findProductionStoreCell (acId ac) (acPlatform ac)
    pure $ case mProd of
        Just (Just pVer, mpCode) -> atOrBelowProductionPure (acPlatform ac) buildVer mCode pVer mpCode
        _ -> False

{- | The release-order half of the gate alone — drives the Superseded display
fold ('supersededIfBehind'): a version-inverted held build reads Superseded,
while a version-NEWER build Play merely rejects (code too low) keeps its
truthful "Ready to promote" with the promote verb disabled.
-}
releaseOrderBehindProduction :: AppCatalog -> Text -> Maybe Int32 -> Flow Bool
releaseOrderBehindProduction ac buildVer mCode = do
    mProd <- findProductionStoreCell (acId ac) (acPlatform ac)
    pure $ case mProd of
        Just (Just pVer, mpCode) -> releaseOrderBehind buildVer mCode pVer mpCode
        _ -> False

{- | Is THIS build the version currently live & SERVING on the production track, per the
synced @store_status@ production cell? Two conditions, both required:

  1. Identity — the build matches the production cell. Compare by build CODE first (Android
     version codes are globally unique per build, so an exact-code match means it's literally
     this build), falling back to the marketing version name when either code is unknown.
  2. Serving — the cell is either fully released (@status = 'completed'@) OR rolling out
     above the 1% floor (a non-NULL @rollout_percent@; 'androidSnapToUpsert' only records one
     when the fraction clears the floor). A version merely present on the track but parked
     below 1% (held / staged for publishing) is NOT serving, so it reads NOT live and the
     publish gate stays up.

This is a read of a CACHE, not a live store call, so it only reflects reality as of the last
sync; the FE Refresh forces a sync before re-reading. Fails CLOSED (not live) when production
hasn't synced, so we never claim a build is live we can't prove.
-}
liveOnProduction :: AppCatalog -> Text -> Maybe Int32 -> Flow Bool
liveOnProduction ac buildVer mCode = do
    mProd <- findProductionLiveCell (acId ac) (acPlatform ac)
    pure $ case mProd of
        Just (mpVer, mpCode, mStatus, mPct) -> identityMatches && serving
          where
            identityMatches = case (mCode, mpCode) of
                (Just b, Just p) -> b == p
                _ -> fmap T.strip mpVer == Just (T.strip buildVer)
            -- completed = fully live; a non-NULL percent = a real ramp (>1% floor).
            serving = mStatus == Just "completed" || mPct /= Nothing
        Nothing -> False

promoteH :: AuthedPerson -> Text -> PromoteReq -> Flow PromoteResp
promoteH ap rid PromoteReq{..} = do
    requireStaged
    (row, target, ac) <- loadPromotable rid
    requireAppPerm (Proxy @'MB_RELEASE_PROMOTE) ap (acName ac) (acPlatform ac)
    -- Promotable from either:
    --   • an SCC release held at build-complete (MBTagPushed); or
    --   • a store-sync INTERNAL / TestFlight snapshot not yet promoted (Option A) —
    --     a COMPLETED row on a pre-production track with no review/rollout started.
    -- A failed submit only advances state on success, so the operator can retry.
    let storeTrack = storeTrackOf (rtMetadata row)
        isPrePromoteSnapshot =
            rtReviewStatus row == Nothing
                && rtRolloutStatus row == Nothing
                && storeTrack `elem` [Just "internal", Just "testflight"]
    unless (mbWfStatus target == MBTagPushed || isPrePromoteSnapshot) $
        bad
            ( "Cannot promote: release is at "
                <> tshow (mbWfStatus target)
                <> " and is not a promotable internal/TestFlight build."
            )
    when (T.null (T.strip prReleaseNotes)) $ bad "Release notes are required."
    storeId <- storeIdOf ac
    now <- liftIO getCurrentTime
    let version = rtNewVersion row
    -- Backstop (the FE also gates the promote UI on rdPromotable, computed from the same
    -- helper): only a build HIGHER than production can be promoted. Refuse one that's at or
    -- below production — it's already live (equal code) or older (lower code), so there's
    -- nothing to promote and a re-submit just spins a redundant store review.
    notAhead <- atOrBelowProduction ac version (rtVersionCode row)
    when notAhead $
        bad ("Version " <> version <> " is not ahead of the production build — nothing to promote.")
    -- Defect-6 fix: also gate against the INCOMING slot. This reads OUR rows
    -- (DB truth, never a stale store cache), so failing closed is safe — and
    -- blocking here is what lets Rule B stay strictly-older (a not-ahead
    -- promote used to silently retire the NEWER in-review build).
    incoming <- listIncomingMobileVersions
    let mineIncoming =
            [ i
            | i <- incoming
            , rtAppGroup i == rtAppGroup row
            , rtService i == rtService row
            , rtEnv i == rtEnv row
            , rtId i /= rid
            ]
        -- Android: codes decide when both are known (names never overrule);
        -- iOS / unknown codes: version-first with code tiebreak.
        notAheadOfIncoming :: ReleaseTrackerRow -> Bool
        notAheadOfIncoming i =
            atOrBelowProductionPure (rtEnv row) version (rtVersionCode row) (rtNewVersion i) (rtVersionCode i)
    forM_ (find notAheadOfIncoming mineIncoming) $ \i ->
        bad
            ( "Version "
                <> version
                <> " is not ahead of the build already in review ("
                <> rtNewVersion i
                <> maybe "" (\c -> " +" <> tshow c) (rtVersionCode i)
                <> ") — withdraw it or promote a newer build."
            )
    -- iOS one-in-flight pre-flight: Apple allows a single in-flight appStoreVersion
    -- per app and its API cannot cancel one that's already approved (that's UI-only),
    -- so submitting a DIFFERENT version now would always 409 at ASC. Read OUR
    -- incoming slot and answer with the next step instead of the raw 409. A
    -- same-version rebuild passes — ensureAppStoreVersion reuses the version.
    -- REJECTED rows pass too: a rejected/canceled version may or may not still
    -- occupy Apple's slot (our row can't tell), so fail open — a genuine conflict
    -- comes back as the mapped 409, and Rule B retires the old row on success.
    when (rtEnv row == "ios") $
        forM_ (find (\i -> rtNewVersion i /= version && rtReviewStatus i /= Just "rejected") mineIncoming) $ \i -> do
            let inflight = rtNewVersion i <> maybe "" (\c -> " +" <> tshow c) (rtVersionCode i)
            link <- ascConsoleLink ac
            bad $
                if rtReviewStatus i == Just "approved"
                    then
                        "Version "
                            <> inflight
                            <> " is approved and waiting to be released — Apple allows one in-flight version at a time. Release it from its row in SCC, or cancel the release in App Store Connect, then promote "
                            <> version
                            <> "."
                            <> link
                    else
                        "Version "
                            <> inflight
                            <> " is already in review — Apple allows one in-flight version at a time. Withdraw it from its row in SCC (or wait for the verdict), then promote "
                            <> version
                            <> "."
                            <> link
    -- Held-sibling gate: promoting a build a NEWER held build has overtaken is a
    -- dead end (it gets superseded on the next convergence pass). Same predicate
    -- as the display fold, so the gate and the badge cannot disagree.
    heldRows <- heldRowsForApp (rtAppGroup row) (rtService row) (rtEnv row)
    forM_ (find (\h -> rtId h /= rid && releaseOrderStrictlyBehind version (rtVersionCode row) (rtNewVersion h) (rtVersionCode h)) heldRows) $ \h ->
        bad
            ( "A newer build is already held ("
                <> rtNewVersion h
                <> maybe "" (\c -> " +" <> tshow c) (rtVersionCode h)
                <> ") — promote that one instead."
            )
    if rtEnv row == "ios"
        then do
            creds <- loadAscCredsFor (acStoreAccount ac) >>= maybe (bad "App Store Connect credentials not configured.") pure
            submitVersionForReview creds storeId version prReleaseNotes
                >>= either (\e -> bad =<< promoteSubmitErr ac version e) pure
            -- Phased release is opt-in and best-effort: a failure here must not
            -- undo the (already submitted) review — log it, surface a warning to
            -- the operator, and continue.
            (mPhasedId, phasedWarning) <-
                if prEnablePhasedRelease == Just True
                    then
                        enablePhasedRelease creds storeId version >>= \case
                            Right pid -> pure (Just pid, Nothing)
                            Left e -> do
                                logEvent rid "PHASED_ENABLE_FAILED" (object ["error" .= renderAscErr e])
                                pure
                                    ( Nothing
                                    , Just
                                        ( "Submitted for review, but phased release could not be enabled: "
                                            <> renderAscErr e
                                            <> ". Enable it manually in App Store Connect under \"Phased Release for Automatic Updates\"."
                                        )
                                    )
                    else pure (Nothing, Nothing)
            setAscIds rid Nothing mPhasedId
            setPhase now rid InReview
            when isPrePromoteSnapshot $ markReleaseInProgress rid
            retireOlderIncomingFor row -- Rule B: newer incoming supersedes any older one
            retireOlderHeldInternalFor row -- Rule C: retire older held-on-internal builds
            logEvent rid "REVIEW_SUBMITTED" $
                object ["store" .= ("asc" :: Text), "actor" .= apEmail ap, "phased" .= (mPhasedId /= Nothing), "from_snapshot" .= isPrePromoteSnapshot]
            pure (PromoteResp "Success" phasedWarning)
        else do
            creds <- loadPlayCreds >>= maybe (bad "Google Play credentials not configured.") pure
            vc <- versionCodeText target
            frac <- case prInitialRolloutPercent of
                Just p -> pure (p / 100)
                Nothing -> getAndroidReviewRolloutFraction
            unless (userFractionInRange frac) $
                bad ("initialRolloutPercent maps to fraction " <> tshow frac <> ", which must be strictly in (0,1).")
            -- Notes go to the app's primary listing language. Android requires the
            -- note language to match a listed locale; "en-US" is our apps' default.
            promoteToProduction creds storeId vc frac [("en-US", prReleaseNotes)]
                >>= either (\e -> bad ("Play promote failed: " <> renderPlayErr e)) pure
            setPhase now rid InReview
            when isPrePromoteSnapshot $ markReleaseInProgress rid
            retireOlderIncomingFor row -- Rule B: newer incoming supersedes any older one
            retireOlderHeldInternalFor row -- Rule C: retire older held-on-internal builds
            logEvent rid "REVIEW_SUBMITTED" $
                object ["store" .= ("play" :: Text), "actor" .= apEmail ap, "fraction" .= frac, "from_snapshot" .= isPrePromoteSnapshot]
            pure (PromoteResp "Success" Nothing)

{- | Best-effort App Store Connect deep link appended to operator guidance (the
FE lifts the trailing \" Open: <url>\" into a clickable toast action). Empty on
any creds/lookup miss — every message must read fine without it.
-}
ascConsoleLink :: AppCatalog -> Flow Text
ascConsoleLink ac =
    loadAscCredsFor (acStoreAccount ac) >>= \case
        Nothing -> pure ""
        Just creds -> do
            storeId <- storeIdOf ac
            lookupAscAppId creds storeId >>= \case
                Nothing -> pure ""
                Just appId -> pure (" Open: https://appstoreconnect.apple.com/apps/" <> appId <> "/distribution")

{- | Render an iOS submit failure for the operator. The one-in-flight 409 gets a
friendly message — it still reaches here (past the pre-flight) when the pending
version was submitted outside SCC, so we have no row for it.
-}
promoteSubmitErr :: AppCatalog -> Text -> AscError -> Flow Text
promoteSubmitErr ac version = \case
    AscHttpError 409 body
        | "You cannot create a new version" `T.isInfixOf` body -> do
            link <- ascConsoleLink ac
            pure $
                "Apple already has a version in flight (in review or approved & awaiting release), so "
                    <> version
                    <> " cannot be submitted yet. Release or cancel the pending version in App Store Connect, then retry."
                    <> link
    e -> pure ("App Store submit failed: " <> renderAscErr e)

-- | GET /releases/:id/rollout — cached review + rollout state for the FE panel.

{- | The phased-release id to surface in the rollout detail. Normally the
persisted @asc_phased_id@; but for an approved-held iOS version with none persisted
— e.g. a release whose phasing was configured in App Store Connect rather than
enabled through SCC (an externally-submitted version) — fall back to a best-effort
live read so the UI's "phased vs release-to-all" label matches what @/release@ will
actually do (releaseH does the same self-heal on the action path). Best-effort: any
miss / error / missing creds yields the persisted value.
-}
resolveDetailPhasedId :: AppCatalog -> ReleaseTrackerRow -> MobileBuildTargetState -> Flow (Maybe Text)
resolveDetailPhasedId ac row target
    | Just pid <- rtAscPhasedId row, not (T.null pid) = pure (Just pid)
    | rtEnv row == "ios"
    , mbWfStatus target == MBReviewApproved
    , Just bundleId <- acPackageName ac
    , not (T.null bundleId) =
        loadAscCredsFor (acStoreAccount ac) >>= \case
            Just creds -> either (const Nothing) id <$> getPhasedReleaseId creds bundleId (rtNewVersion row)
            Nothing -> pure Nothing
    | otherwise = pure (rtAscPhasedId row)

rolloutDetailH :: AuthedPerson -> Text -> Flow RolloutDetail
rolloutDetailH _ap rid = do
    requireStaged
    (row, target, ac) <- loadPromotable rid
    phasedId <- resolveDetailPhasedId ac row target
    -- review is the ROW's decision (setPhase-owned, immediate);
    -- rollout / % / track presence are store truth from store_status for this
    -- exact build, falling back to the row's columns when the build isn't on any
    -- store track (superseded / pre-store).
    cells <- storeCellsForApp (acId ac)
    let review = rtReviewStatus row
        (rollout, pct, storeTrack) =
            case resolveStoreState cells (rtNewVersion row) (rtVersionCode row) of
                Just derived -> derived
                -- Track fallback: the AUTHORITATIVE column first (promote/setPhase move it;
                -- the list reads the same one), the metadata mirror only as a legacy
                -- last resort — it's stamped at snapshot-mint and never updated, so a
                -- promoted row's mirror still says internal/testflight (stale).
                Nothing -> (rtRolloutStatus row, rtRolloutPercent row, rtStoreTrack row <|> storeTrackOf (rtMetadata row))
        -- Promotable = in a promotable stage (held at MBTagPushed, or an un-promoted
        -- internal/TestFlight snapshot with no review/rollout) AND not already live on
        -- production. Same checks promoteH enforces, so the FE never offers a promote the
        -- backend would reject.
        isPrePromoteSnapshot =
            review == Nothing
                && rollout == Nothing
                && storeTrack `elem` [Just "internal", Just "testflight"]
        promotableStage = mbWfStatus target == MBTagPushed || isPrePromoteSnapshot
        ph =
            phaseFromFields
                (buildKind (mbContext target))
                (mbWfStatus target)
                review
                rollout
                pct
                storeTrack
        canAbort = abortable (mbWfStatus target) ph
    notAhead <- atOrBelowProduction ac (rtNewVersion row) (rtVersionCode row)
    -- Mirror promoteH's REMAINING gates too (incoming slot + iOS one-in-flight),
    -- or rdPromotable offers a promote the handler is guaranteed to 400.
    incoming <- listIncomingMobileVersions
    let mineIncoming =
            [ i
            | i <- incoming
            , rtAppGroup i == rtAppGroup row
            , rtService i == rtService row
            , rtEnv i == rtEnv row
            , rtId i /= rid
            ]
        mBlockingIncoming =
            find (\i -> atOrBelowProductionPure (rtEnv row) (rtNewVersion row) (rtVersionCode row) (rtNewVersion i) (rtVersionCode i)) mineIncoming
        blockedByIncoming = isJust mBlockingIncoming
        mInflight
            | rtEnv row == "ios" =
                find (\i -> rtNewVersion i /= rtNewVersion row && rtReviewStatus i /= Just "rejected") mineIncoming
            | otherwise = Nothing
        iosInflight = isJust mInflight
    -- §15 fold: a held build behind production in release order — or behind a
    -- newer HELD sibling (a landed rebuild) — reads Superseded here too, the
    -- same label the list/groups enrichment shows.
    rob <- releaseOrderBehindProduction ac (rtNewVersion row) (rtVersionCode row)
    mRobHeld <- do
        heldRows <- heldRowsForApp (rtAppGroup row) (rtService row) (rtEnv row)
        pure $ find (\h -> rtId h /= rid && releaseOrderStrictlyBehind (rtNewVersion row) (rtVersionCode row) (rtNewVersion h) (rtVersionCode h)) heldRows
    let robHeld = isJust mRobHeld
    let phE = supersededIfBehind (rob || robHeld) ph
        disp = displayStatusInferred (reviewInferredOf (parseJsonTextMaybe (rtMetadata row))) phE
        -- WHY the promote gate is closed, permanent causes first, so the FE
        -- names the most fundamental blocker instead of guessing one message.
        promoteBlock
            | not promotableStage = Nothing
            | notAhead = Just ("behind_production", Nothing)
            | robHeld = Just ("behind_held", rtNewVersion <$> mRobHeld)
            | blockedByIncoming = Just ("blocked_by_incoming", rtNewVersion <$> mBlockingIncoming)
            | iosInflight = Just ("one_in_flight", rtNewVersion <$> mInflight)
            | otherwise = Nothing
    liveProd <- liveOnProduction ac (rtNewVersion row) (rtVersionCode row)
    syncedAgo <- secondsSinceLastSync (acId ac)
    cooldown <- fromIntegral <$> getStoreRefreshCooldownSeconds
    -- Shared-run blast radius: aborting cancels the whole GH run, so surface
    -- the sibling apps still building in it. Only fetched while Abort is live.
    runSiblings <-
        if canAbort
            then case rtDispatchId row of
                Just did | not (T.null did) -> findRunSiblingsStillBuilding did rid
                _ -> pure []
            else pure []
    pure
        RolloutDetail
            { rdReleaseId = rid
            , rdPlatform = rtEnv row
            , rdMbStatus = tshow (mbWfStatus target)
            , rdStatusLabel = dLabel disp
            , rdStatusVariant = variantSlug (dVariant disp)
            , rdPhase = phaseSlug phE
            , rdReviewStatus = review
            , rdReviewRejectReason = rtReviewRejectReason row
            , rdReviewSubmittedAt = rtReviewSubmittedAt row
            , rdReviewDecidedAt = rtReviewDecidedAt row
            , rdRolloutStatus = rollout
            , rdRolloutPercent = pct
            , rdPhasedId = phasedId
            , rdStoreTrack = storeTrack
            , rdPromotable = promotableStage && not notAhead && not blockedByIncoming && not iosInflight && not robHeld
            , rdPromoteBlock = fst <$> promoteBlock
            , rdPromoteBlockVersion = snd =<< promoteBlock
            , rdAbortable = canAbort
            , rdRunSiblings = runSiblings
            , rdAppCatalogId = acId ac
            , rdLiveOnProduction = liveProd
            , rdSyncedSecondsAgo = syncedAgo
            , rdRefreshCooldownSeconds = cooldown
            }

{- | POST /releases/:id/release — the iOS "Release" button. Releases an approved
(held, PENDING_DEVELOPER_RELEASE) version. If phased release was enabled at
promote time, Apple then ramps over 7 days; otherwise it goes fully live.
-}
releaseH :: AuthedPerson -> Text -> Flow APISuccess
releaseH ap rid = do
    requireStaged
    (row, target, ac) <- loadPromotable rid
    requireAppPerm (Proxy @'MB_RELEASE_ROLLOUT) ap (acName ac) (acPlatform ac)
    unless (rtEnv row == "ios") $ bad "Release is iOS-only; Android uses /rollout/set."
    unless (mbWfStatus target == MBReviewApproved) $
        bad ("Cannot release: state is " <> tshow (mbWfStatus target) <> ", expected approved (MBReviewApproved).")
    storeId <- storeIdOf ac
    creds <- loadAscCredsFor (acStoreAccount ac) >>= maybe (bad "App Store Connect credentials not configured.") pure
    releaseApprovedVersion creds storeId (rtNewVersion row)
        >>= either (\e -> bad ("App Store release failed: " <> renderAscErr e)) pure
    -- Decide phased vs non-phased from the STORE, not just the stored id: a
    -- promote-time enable can succeed at Apple yet fail to persist the id here
    -- (e.g. a duplicate-create 409), which would otherwise mis-release a phased
    -- version as a full 100% rollout. Re-read it and self-heal when present.
    mPhasedId <- case rtAscPhasedId row of
        Just pid | not (T.null pid) -> pure (Just pid)
        _ ->
            getPhasedReleaseId creds storeId (rtNewVersion row) >>= \case
                Right (Just pid) -> do
                    setAscIds rid Nothing (Just pid)
                    logEvent rid "PHASED_ID_BACKFILLED" (object ["phased_id" .= pid])
                    pure (Just pid)
                Right Nothing -> pure Nothing
                -- A READ FAILURE is not "non-phased": stamping Live/100% on a
                -- version Apple may be ramping loses every SCC pause/complete
                -- lever for the 7-day ramp, with no reconciler path back. The
                -- version is already released at Apple — fail here and let the
                -- next store sync adopt the real state and backfill the id.
                Left e ->
                    bad
                        ( "Released at Apple, but the phased-release state could not be read ("
                            <> renderAscErr e
                            <> "). Refresh the store status — the release will pick up its live rollout state from Apple."
                        )
    now <- liftIO getCurrentTime
    case mPhasedId of
        Just _ -> do
            -- Phased: Apple ramps over 7 days; the Phase-7 reconciler tracks the live
            -- % and completes the release when the ramp finishes. Seed at the day-1
            -- phased % (1%) and mirror it onto the monitor cache, so the list AND the
            -- App Monitor both read "Rolling out 1%" the instant Release is clicked
            -- (the reconciler then refines the % as Apple ramps) — matching Android,
            -- which updates SCC immediately and reconciles from the store afterward.
            setPhase now rid (RollingOut 0.01)
            mirrorProdRollout ac row target "inProgress" 1
            logEvent rid "ROLLOUT_RELEASED" (object ["store" .= ("asc" :: Text), "actor" .= apEmail ap, "phased" .= True])
        Nothing -> do
            -- Non-phased: the version goes fully live on release → done.
            setPhase now rid Live
            mirrorProdReleased ac row target
            logEvent rid "ROLLOUT_RELEASED" (object ["store" .= ("asc" :: Text), "actor" .= apEmail ap, "phased" .= False])
    supersedePreviousLiveFor row -- Rule A: this version releasing supersedes the previous live one
    convergeSlotsAfterGoLive row
    pure Success

{- | POST /releases/:id/rollout/set — Android staged rollout. Sets the production
@userFraction@ to @percent/100@; @percent >= 100@ completes the rollout (status
completed, no fraction → 100% of users) and finishes the release.
-}
rolloutSetH :: AuthedPerson -> Text -> RolloutSetReq -> Flow APISuccess
rolloutSetH ap rid RolloutSetReq{..} = do
    requireStaged
    (row, target, ac) <- loadPromotable rid
    requireAppPerm (Proxy @'MB_RELEASE_ROLLOUT) ap (acName ac) (acPlatform ac)
    unless (rtEnv row == "android") $ bad "/rollout/set is Android-only; iOS uses phased release."
    -- Adopt a rollout started OUTSIDE SCC: a store-sync snapshot SCC only OBSERVED as
    -- rolling out (mb_wf_status MBCompleted) can be taken over here, mirroring how a
    -- pre-promote internal snapshot is adopted in 'promoteH'. The normal lifecycle
    -- path keeps its guard.
    adopt <- isObservedRollout ac row target
    unless adopt $ ensureAndroidRollable (mbWfStatus target)
    when (rsPercent <= 0 || rsPercent > 100) $ bad "percent must be in (0, 100]."
    storeId <- storeIdOf ac
    vc <- versionCodeText target
    creds <- loadPlayCreds >>= maybe (bad "Google Play credentials not configured.") pure
    if rsPercent >= 100
        then
            completeTrackRollout creds storeId vc
                >>= either (\e -> bad ("Play complete failed: " <> renderPlayErr e)) pure
        else
            setTrackRollout creds storeId vc (rsPercent / 100)
                >>= either (\e -> bad ("Play rollout failed: " <> renderPlayErr e)) pure
    -- Adopting an observed rollout brings the COMPLETED store-sync snapshot INTO the
    -- rollout lifecycle: flip it INPROGRESS so the Phase-7 reconciler keeps it in sync
    -- from here (and store-sync stops reflecting it — that path only touches COMPLETED
    -- rows). Mirrors 'promoteH's snapshot adoption.
    when adopt $ markReleaseInProgress rid
    -- Record the just-applied % NOW (only reached after the Play write above
    -- succeeded) so every view reflects it immediately. The Phase-7 reconciler
    -- still reads the LIVE track on the next refresh and reconciles to the true
    -- value — correcting it if Managed Publishing held the commit (the live track
    -- hasn't moved yet) or completing the release when it reaches 100%.
    now <- liftIO getCurrentTime
    setPhase now rid (RollingOut (rsPercent / 100))
    -- Mirror the new state into store_status too, so the App Monitor (which reads that
    -- cache, not release_tracker) matches the release list immediately — no extra Play
    -- edit. At 100% it reads as live (review overlay cleared); below 100% it's ramping.
    if rsPercent >= 100
        then mirrorProdReleased ac row target
        else mirrorProdRollout ac row target "inProgress" rsPercent
    supersedePreviousLiveFor row -- Rule A: this version rolling out supersedes the previous live one
    convergeSlotsAfterGoLive row
    logEvent rid "ROLLOUT_SET" (object ["percent" .= rsPercent, "actor" .= apEmail ap, "adopted" .= adopt])
    pure Success

-- | POST /releases/:id/rollout/halt — pause the rollout (iOS phased PAUSE; Android halted).
rolloutHaltH :: AuthedPerson -> Text -> Flow APISuccess
rolloutHaltH ap rid = do
    requireStaged
    (row, target, ac) <- loadPromotable rid
    requireAppPerm (Proxy @'MB_RELEASE_ROLLOUT) ap (acName ac) (acPlatform ac)
    if rtEnv row == "ios"
        then do
            pid <- requirePhasedId row
            creds <- loadAscCredsFor (acStoreAccount ac) >>= maybe (bad "App Store Connect credentials not configured.") pure
            pausePhasedRelease creds pid
                >>= either (\e -> bad ("App Store pause failed: " <> renderAscErr e)) pure
            now <- liftIO getCurrentTime
            setPhase now rid (Halted (maybe 0 (/ 100) (rtRolloutPercent row)))
            -- Mirror onto the monitor cache when we know the phased %.
            forM_ (rtRolloutPercent row) $ \p -> mirrorProdRollout ac row target "halted" p
            logEvent rid "ROLLOUT_HALTED" (object ["store" .= ("asc" :: Text), "actor" .= apEmail ap])
            pure Success
        else do
            -- Halt pauses an ACTIVE rollout. An in-review build also carries a
            -- production fraction (the parked ~0% review submission), so the
            -- fraction read alone is no gate: halting it would null the review
            -- lifecycle and let /rollout/set ramp a never-approved build.
            adopt <- isObservedRollout ac row target
            unless (adopt || mbWfStatus target == MBRollingOut) $
                bad "Nothing is rolling out — halt pauses an active rollout. An in-review build can only be superseded by promoting a newer one."
            storeId <- storeIdOf ac
            vc <- versionCodeText target
            creds <- loadPlayCreds >>= maybe (bad "Google Play credentials not configured.") pure
            -- §12.10: read the live fraction, halt AT it — never trust the cached %.
            frac <- liveAndroidFraction creds storeId (mbcVersionCode (mbContext target))
            haltTrackRollout creds storeId vc frac
                >>= either (\e -> bad ("Play halt failed: " <> renderPlayErr e)) pure
            -- Adopt an observed (Console-started) rollout on first action, same
            -- as /rollout/set: INPROGRESS hands it to the Phase-7 reconciler.
            when adopt $ markReleaseInProgress rid
            now <- liftIO getCurrentTime
            setPhase now rid (Halted frac)
            -- Reflect the halt on the App Monitor immediately (it reads store_status,
            -- not release_tracker) — same fraction we just halted at, no extra edit.
            mirrorProdRollout ac row target "halted" (frac * 100)
            logEvent rid "ROLLOUT_HALTED" (object ["store" .= ("play" :: Text), "actor" .= apEmail ap])
            pure Success

-- | POST /releases/:id/rollout/resume — resume a paused rollout at its current fraction.
rolloutResumeH :: AuthedPerson -> Text -> Flow APISuccess
rolloutResumeH ap rid = do
    requireStaged
    (row, target, ac) <- loadPromotable rid
    requireAppPerm (Proxy @'MB_RELEASE_ROLLOUT) ap (acName ac) (acPlatform ac)
    if rtEnv row == "ios"
        then do
            pid <- requirePhasedId row
            creds <- loadAscCredsFor (acStoreAccount ac) >>= maybe (bad "App Store Connect credentials not configured.") pure
            resumePhasedRelease creds pid
                >>= either (\e -> bad ("App Store resume failed: " <> renderAscErr e)) pure
            now <- liftIO getCurrentTime
            setPhase now rid (RollingOut (maybe 0 (/ 100) (rtRolloutPercent row)))
            forM_ (rtRolloutPercent row) $ \p -> mirrorProdRollout ac row target "inProgress" p
            logEvent rid "ROLLOUT_RESUMED" (object ["store" .= ("asc" :: Text), "actor" .= apEmail ap])
            pure Success
        else do
            -- Same in-review protection as halt: the parked review fraction
            -- satisfies the fraction read, and resuming would equally null the
            -- review lifecycle (setPhase RollingOut) for a never-approved build.
            adopt <- isObservedRollout ac row target
            unless (adopt || mbWfStatus target == MBRollingOut) $
                bad "Nothing is halted — resume restarts a paused rollout. An in-review build can only be superseded by promoting a newer one."
            storeId <- storeIdOf ac
            vc <- versionCodeText target
            creds <- loadPlayCreds >>= maybe (bad "Google Play credentials not configured.") pure
            frac <- liveAndroidFraction creds storeId (mbcVersionCode (mbContext target))
            resumeTrackRollout creds storeId vc frac
                >>= either (\e -> bad ("Play resume failed: " <> renderPlayErr e)) pure
            when adopt $ markReleaseInProgress rid
            now <- liftIO getCurrentTime
            setPhase now rid (RollingOut frac)
            -- Back to ramping on the monitor cache too.
            mirrorProdRollout ac row target "inProgress" (frac * 100)
            logEvent rid "ROLLOUT_RESUMED" (object ["store" .= ("play" :: Text), "actor" .= apEmail ap])
            pure Success

{- | POST /releases/:id/rollout/release-all — jump to 100% and finish the release.
iOS completes the phased ramp; Android completes the staged rollout. Both paths
must reach the store (or prove there's a rollout to finish) BEFORE the Live
stamp: this handler previously accepted any state and, with no phased id, stamped
Live with zero store calls — SCC read "Released · 100%" while the store kept
serving the old version, and convergence then superseded the genuinely live row.
-}
rolloutReleaseAllH :: AuthedPerson -> Text -> Flow APISuccess
rolloutReleaseAllH ap rid = do
    requireStaged
    (row, target, ac) <- loadPromotable rid
    requireAppPerm (Proxy @'MB_RELEASE_ROLLOUT) ap (acName ac) (acPlatform ac)
    storeId <- storeIdOf ac
    adopt <- isObservedRollout ac row target
    if rtEnv row == "ios"
        then do
            -- Only an active ramp (SCC-released or adopted from the store) can be
            -- completed. An approved-held build goes live via /release; a
            -- non-phased release is already fully live and never needs this verb.
            unless (adopt || mbWfStatus target == MBRollingOut) $
                bad "Nothing is rolling out — release the approved build first, then release-all finishes a phased ramp."
            creds <- loadAscCredsFor (acStoreAccount ac) >>= maybe (bad "App Store Connect credentials not configured.") pure
            -- The persisted phased id, else a live ASC lookup — the promote-time
            -- enable can succeed at Apple while the id fails to persist.
            pid <- case rtAscPhasedId row of
                Just p | not (T.null p) -> pure p
                _ ->
                    getPhasedReleaseId creds storeId (rtNewVersion row) >>= \case
                        Left e -> bad ("Could not read the phased-release state: " <> renderAscErr e)
                        Right (Just p) -> pure p
                        Right Nothing -> bad "No phased release found for this version at App Store Connect — refresh the store status and retry."
            completePhasedRelease creds pid
                >>= either (\e -> bad ("App Store complete failed: " <> renderAscErr e)) pure
        else do
            -- Same lifecycle gate as /rollout/set: adopt an observed external
            -- rollout, otherwise require approved/rolling — never in-review.
            unless adopt $ ensureAndroidRollable (mbWfStatus target)
            vc <- versionCodeText target
            creds <- loadPlayCreds >>= maybe (bad "Google Play credentials not configured.") pure
            completeTrackRollout creds storeId vc
                >>= either (\e -> bad ("Play complete failed: " <> renderPlayErr e)) pure
    -- Adopting an observed rollout brings the snapshot into the lifecycle so the
    -- reconciler owns it from here (mirrors /rollout/set).
    when adopt $ markReleaseInProgress rid
    now <- liftIO getCurrentTime
    setPhase now rid Live
    -- Closes audit defect 2: this handler previously fired no supersession.
    convergeSlotsAfterGoLive row
    -- Reflect "fully live" on the App Monitor immediately (clears the review overlay).
    mirrorProdReleased ac row target
    logEvent rid "ROLLOUT_RELEASED_ALL" (object ["actor" .= apEmail ap])
    pure Success

{- | POST /releases/:id/review/mark-approved — Android only. Records the
operator's confirmation that the opaque Play review went live (§12a). iOS
approval is auto-detected by the poll stage, so this is Android-only.
-}
markApprovedH :: AuthedPerson -> Text -> Flow APISuccess
markApprovedH ap rid = do
    requireStaged
    (row, target, ac) <- loadPromotable rid
    requireAppPerm (Proxy @'MB_RELEASE_PROMOTE) ap (acName ac) (acPlatform ac)
    unless (rtEnv row == "android") $ bad "mark-approved is Android-only (iOS approval is auto-detected)."
    ensureInReview (mbWfStatus target)
    now <- liftIO getCurrentTime
    setPhase now rid Approved
    logEvent rid "REVIEW_APPROVED" (object ["store" .= ("play" :: Text), "manual" .= True, "actor" .= apEmail ap])
    pure Success

{- | POST /releases/:id/review/mark-rejected — Android only. Records a store
rejection + reason; the release becomes @MBReviewRejected@ (terminal → ABORTED).
-}
markRejectedH :: AuthedPerson -> Text -> MarkRejectedReq -> Flow APISuccess
markRejectedH ap rid MarkRejectedReq{..} = do
    requireStaged
    (row, target, ac) <- loadPromotable rid
    requireAppPerm (Proxy @'MB_RELEASE_PROMOTE) ap (acName ac) (acPlatform ac)
    unless (rtEnv row == "android") $ bad "mark-rejected is Android-only (iOS rejection is auto-detected)."
    when (T.null (T.strip mrReason)) $ bad "Rejection reason is required."
    ensureInReview (mbWfStatus target)
    now <- liftIO getCurrentTime
    setPhase now rid (Rejected mrReason)
    logEvent rid "REVIEW_REJECTED" (object ["reason" .= mrReason, "manual" .= True, "actor" .= apEmail ap])
    pure Success

{- | POST /releases/:id/withdraw — iOS only. Cancels the in-flight App Store
review (ASC @reviewSubmission@ → @canceled@), then drives the release terminal
(@MBAborted@ → USER_ABORTED at Finalize). Because the store review is actually
cancelled, store-sync won't re-surface it as an out-of-band review. Valid only
while the review is pending. Google Play has no cancel-review API, so this 400s
for Android — withdraw is impossible there.
-}
withdrawH :: AuthedPerson -> Text -> Flow APISuccess
withdrawH ap rid = do
    requireStaged
    (row, target, ac) <- loadPromotable rid
    requireAppPerm (Proxy @'MB_RELEASE_PROMOTE) ap (acName ac) (acPlatform ac)
    unless (rtEnv row == "ios") $
        bad "Withdraw from review is iOS-only — Google Play has no API to cancel a review."
    ensureInReview (mbWfStatus target)
    bundleId <- storeIdOf ac
    creds <- loadAscCredsFor (acStoreAccount ac) >>= maybe (bad "App Store Connect credentials not configured.") pure
    cancelReviewSubmission creds bundleId
        >>= either (\e -> bad ("App Store withdraw failed: " <> renderAscErr e)) pure
    now <- liftIO getCurrentTime
    setPhase now rid Aborted
    logEvent rid "REVIEW_WITHDRAWN" (object ["store" .= ("asc" :: Text), "actor" .= apEmail ap])
    pure Success

-- ─── Bulk promote / rollout ────────────────────────────────────────────
--
-- One operator action over MANY apps: select the apps, click once. These are a
-- THIN layer over the single-item handlers ('promoteH' / 'rolloutSetH') — every
-- state guard, store call, audit event, and RBAC check is reused verbatim, so the
-- bulk path can never drift from the single path. Each item is isolated with 'try':
-- a failure (wrong state, missing creds, Play quota) is recorded against that
-- release and the rest of the batch continues. Items run SEQUENTIALLY so Android
-- promotes respect Play's one-edit-per-app quota and iOS reuses the cached ASC
-- token (no burst). For large waves this would move to a background job + poll;
-- the per-item core stays identical.

{- | One app in a bulk promote. @bpiReleaseNotes@ omitted ⇒ the server fills the
per-app default (store "What's New" / changelog), so the operator types nothing.
-}
data BulkPromoteItem = BulkPromoteItem
    { bpiReleaseId :: Text
    , bpiReleaseNotes :: Maybe Text
    , bpiEnablePhasedRelease :: Maybe Bool
    , bpiInitialRolloutPercent :: Maybe Double
    }
    deriving (Eq, Show, Generic)

instance ToJSON BulkPromoteItem
instance FromJSON BulkPromoteItem

newtype BulkPromoteReq = BulkPromoteReq {bpItems :: [BulkPromoteItem]}
    deriving (Eq, Show, Generic)

instance ToJSON BulkPromoteReq
instance FromJSON BulkPromoteReq

-- | One app in a bulk rollout (Android staged-rollout %, in (0,100]).
data BulkRolloutItem = BulkRolloutItem
    { briReleaseId :: Text
    , briPercent :: Double
    }
    deriving (Eq, Show, Generic)

instance ToJSON BulkRolloutItem
instance FromJSON BulkRolloutItem

newtype BulkRolloutReq = BulkRolloutReq {brItems :: [BulkRolloutItem]}
    deriving (Eq, Show, Generic)

instance ToJSON BulkRolloutReq
instance FromJSON BulkRolloutReq

{- | Per-app outcome in a bulk action: @birOk@ False carries the reason in
@birMessage@; a successful promote may carry a non-fatal @birWarning@.
-}
data BulkItemResult = BulkItemResult
    { birReleaseId :: Text
    , birOk :: Bool
    , birMessage :: Text
    , birWarning :: Maybe Text
    }
    deriving (Eq, Show, Generic)

instance ToJSON BulkItemResult
instance FromJSON BulkItemResult

-- | The batch summary the FE shows ("N ok, M failed") plus per-app detail.
data BulkActionResp = BulkActionResp
    { barTotal :: Int
    , barSucceeded :: Int
    , barFailed :: Int
    , barResults :: [BulkItemResult]
    }
    deriving (Eq, Show, Generic)

instance ToJSON BulkActionResp
instance FromJSON BulkActionResp

{- | Run one bulk item, isolating any failure into a per-app result instead of
aborting the batch. The action returns the optional non-fatal warning to surface.
-}
runBulkItem :: Text -> Flow (Maybe Text) -> Flow BulkItemResult
runBulkItem rid act = do
    res <- MC.try @_ @SomeException act
    pure $ case res of
        Right mWarn -> BulkItemResult rid True "Success" mWarn
        Left e -> BulkItemResult rid False (renderBulkErr e) Nothing

{- | A clean per-item message: the typed APIError text ('bad' messages) when it is
one, else the raw exception string.
-}
renderBulkErr :: SomeException -> Text
renderBulkErr e = case fromException e :: Maybe APIError of
    Just apiErr -> toErrorMessage apiErr
    Nothing -> T.pack (displayException e)

summarizeBulk :: [BulkItemResult] -> BulkActionResp
summarizeBulk rs =
    BulkActionResp
        { barTotal = length rs
        , barSucceeded = length (filter birOk rs)
        , barFailed = length (filter (not . birOk) rs)
        , barResults = rs
        }

{- | POST /mobile/bulk/promote — submit many apps for review in one click. Each app
reuses 'promoteH'; omitted notes are filled with the per-app store default.
-}
bulkPromoteH :: AuthedPerson -> BulkPromoteReq -> Flow BulkActionResp
bulkPromoteH ap (BulkPromoteReq items) = do
    requireStaged
    summarizeBulk <$> mapM (\it -> runBulkItem (bpiReleaseId it) (promoteOne it)) items
  where
    promoteOne it = do
        let rid = bpiReleaseId it
        notes <- case bpiReleaseNotes it of
            Just n | not (T.null (T.strip n)) -> pure n
            _ -> do
                (row, target, ac) <- loadPromotable rid
                promoteDefaultNotes row target ac
        prWarning
            <$> promoteH
                ap
                rid
                (PromoteReq notes (bpiEnablePhasedRelease it) (bpiInitialRolloutPercent it))

{- | POST /mobile/bulk/rollout — set the Android staged-rollout % for many apps in
one click. Each app reuses 'rolloutSetH' (same %, or a different % per app).
-}
bulkRolloutH :: AuthedPerson -> BulkRolloutReq -> Flow BulkActionResp
bulkRolloutH ap (BulkRolloutReq items) = do
    requireStaged
    summarizeBulk
        <$> mapM
            (\it -> runBulkItem (briReleaseId it) (Nothing <$ rolloutSetH ap (briReleaseId it) (RolloutSetReq (briPercent it))))
            items

-- ─── Internal helpers ──────────────────────────────────────────────────

{- | 400 unless the staged-rollout flag is on. Keeps every endpoint a no-op
(clean error) until ops opt in.
-}
requireStaged :: Flow ()
requireStaged = do
    on <- isStagedRolloutEnabled
    unless on $ bad "Staged rollout is disabled (set mobile_staged_rollout_enabled)."

{- | Load + validate a promotable mobile release: it must exist, parse as a
mobile build, and not be a debug build (debug never goes to the stores). Returns
the raw tracker row (carries the review/rollout columns), the parsed target
state, and the app-catalog entry.
-}
loadPromotable :: Text -> Flow (ReleaseTrackerRow, MobileBuildTargetState, AppCatalog)
loadPromotable rid = do
    mRel <- findMobileReleaseById rid
    (row, mTarget) <- maybe (bad ("Mobile release not found: " <> rid)) pure mRel
    target <- maybe (bad ("Not a parseable mobile release: " <> rid)) pure mTarget
    when (isDebugBuildType (mbcBuildType (mbContext target))) $
        bad "Debug builds are not promoted to the stores."
    ac <- appCatalogForRowRaw row
    pure (row, target, ac)

-- | The store identifier (Play package name / iOS bundle id) for an app.
storeIdOf :: AppCatalog -> Flow Text
storeIdOf ac = case acPackageName ac of
    Just p | not (T.null p) -> pure p
    _ -> bad ("App " <> acName ac <> " has no package_name / bundle id configured.")

{- | Mirror an in-flight production rollout (status + %) for this release onto the
@store_status@ cache so the App Monitor reflects the action immediately. Fills the
app id / version / code from the row. @status@ is "inProgress" (ramping/resumed) or
"halted" (paused).
-}
mirrorProdRollout :: AppCatalog -> ReleaseTrackerRow -> MobileBuildTargetState -> Text -> Double -> Flow ()
mirrorProdRollout ac row target status pct =
    setProductionRolloutStatus (acId ac) (rtEnv row) (rtNewVersion row) (mbcVersionCode (mbContext target)) status pct

-- | Mirror a completed (100%, fully live) production release onto the cache.
mirrorProdReleased :: AppCatalog -> ReleaseTrackerRow -> MobileBuildTargetState -> Flow ()
mirrorProdReleased ac row target =
    setProductionReleased (acId ac) (rtEnv row) (rtNewVersion row) (mbcVersionCode (mbContext target))

{- | Rule A (migration 0034): @row@ just started rolling out, so freeze the previous
live version of this app and move it to history as @superseded@.
-}
supersedePreviousLiveFor :: ReleaseTrackerRow -> Flow ()
supersedePreviousLiveFor row = do
    ids <- supersedePreviousLive (rtAppGroup row) (rtService row) (rtEnv row) (rtId row)
    forM_ ids $ \i ->
        logEvent i "ROLLOUT_SUPERSEDED" (object ["by_version" .= rtNewVersion row, "reason" .= ("newer_version_rolling_out" :: Text)])

{- | Post-go-live slot convergence anchored on the row that just went live:
retires stale live-slot rows (incl. completed older versions), incoming rows
not ahead of it, and overtaken internal builds — the gaps Rule A leaves.
-}
convergeSlotsAfterGoLive :: ReleaseTrackerRow -> Flow ()
convergeSlotsAfterGoLive row = do
    (live, incoming, held) <-
        convergeMobileSlots
            (rtAppGroup row)
            (rtService row)
            (rtEnv row)
            (Just (rtNewVersion row, rtVersionCode row))
    forM_ (live <> incoming <> held) $ \i ->
        logEvent i "SLOT_CONVERGED" (object ["by_version" .= rtNewVersion row, "reason" .= ("go_live" :: Text)])

{- | Rule B (migration 0034): @row@ just entered the incoming (review) slot, so drop
any older incoming version of this app to history.
-}
retireOlderIncomingFor :: ReleaseTrackerRow -> Flow ()
retireOlderIncomingFor row = do
    ids <- retireOlderIncoming (rtAppGroup row) (rtService row) (rtEnv row) (rtId row) (rtNewVersion row) (rtVersionCode row)
    forM_ ids $ \i ->
        logEvent i "INCOMING_SUPERSEDED" (object ["by_version" .= rtNewVersion row])

{- | Rule C: @row@ is being promoted, so retire any held-on-internal build of this
app sitting behind it in release order — such a build can no longer reach production.
-}
retireOlderHeldInternalFor :: ReleaseTrackerRow -> Flow ()
retireOlderHeldInternalFor row = do
    ids <-
        retireOlderHeldInternal (rtAppGroup row) (rtService row) (rtEnv row) (rtId row) $
            \v c -> releaseOrderBehind v c (rtNewVersion row) (rtVersionCode row)
    forM_ ids $ \i ->
        logEvent i "HELD_SUPERSEDED" (object ["by_version" .= rtNewVersion row])

-- | The Android version code as text (required to address the production release).
versionCodeText :: MobileBuildTargetState -> Flow Text
versionCodeText target = case mbcVersionCode (mbContext target) of
    Just vc -> pure (tshow vc)
    Nothing -> bad "Android release has no version code recorded."

-- | The cached iOS phased-release id, or a clear error if phased release is off.
requirePhasedId :: ReleaseTrackerRow -> Flow Text
requirePhasedId row = case rtAscPhasedId row of
    Just p | not (T.null p) -> pure p
    _ -> bad "No phased release is enabled for this version — promote with enablePhasedRelease to get a pausable ramp."

{- | Read the live Android production rollout fraction OF OUR VERSION (§12.10);
error if there is no in-progress fraction to act on. The production track can carry
several releases at once (e.g. our rolling/halted version AND a freshly-submitted
review version parked at the near-zero fraction), so we MUST pick our own version
code's release — never the newest on the track, or a halt/resume would read the
wrong release's fraction and, say, halt our 51% rollout down to ~0%.
-}
liveAndroidFraction :: PlayCreds -> Text -> Maybe Int32 -> Flow Double
liveAndroidFraction creds storeId mCode = do
    code <- maybe (bad "Android release has no version code recorded.") pure mCode
    getProductionReleases creds storeId >>= \case
        Left e -> bad ("Could not read live Play rollout state: " <> renderPlayErr e)
        Right releases -> case find ((== code) . ptrCode) releases of
            Nothing -> bad "This version is not currently on the production track (it may have completed or been superseded)."
            Just r -> case ptrUserFraction r of
                Just f -> pure f
                Nothing -> bad "No in-progress rollout fraction to act on (rollout is at 0% or already complete)."

{- | Android rollout requires an explicit approval first. The Play API can't see
review state, so SCC won't let a still-in-review build start a rollout: that
would read as "rolling out" while Google still gates it, and a later rejection
(Play reverts the track to the prior version, status=completed) could be
misread by the reconciler as a finished rollout. The operator must confirm in
the Play Console that Google approved, then Mark approved.
-}
ensureAndroidRollable :: MobileBuildWFStatus -> Flow ()
ensureAndroidRollable = \case
    MBReviewApproved -> pure ()
    MBRollingOut -> pure ()
    MBInReview ->
        bad
            "Cannot set a rollout while the release is still in review. Confirm in the Play Console that Google approved it, then use \"Mark approved\" first."
    s -> bad ("Cannot set rollout from state " <> tshow s <> "; promote and approve the release first.")

{- | An Android rollout that was started OUTSIDE SCC (in the Play Console) and that
store-sync only OBSERVED: a @STORE_SYNC@ snapshot still at @MBCompleted@ while the
store shows an active production rollout. Such a row can be ADOPTED by the rollout
verbs — act on it and take it into SCC's lifecycle — without the
'ensureAndroidRollable' approval gate, since the Play review already happened out
of band. The active-ramp check reads the @store_status@ CELL (the SSOT — since the
store-status refactor, observation rows keep NULL rollout columns and the cell holds
the truth; the old column check silently never fired, which surfaced as
\"Cannot set rollout from state MBCompleted\" on a visibly rolling-out row). The row
columns remain a fallback for legacy rows. A genuinely finished release (cell reads
live/completed) is NOT matched, so it can't be mistaken for an in-flight rollout.
-}
isObservedRollout :: AppCatalog -> ReleaseTrackerRow -> MobileBuildTargetState -> Flow Bool
isObservedRollout ac row target
    | rtMode row == Just "STORE_SYNC" && mbWfStatus target == MBCompleted = do
        cells <- storeCellsForApp (acId ac)
        let mRollout = case resolveStoreState cells (rtNewVersion row) (rtVersionCode row) of
                Just (mr, _, _) -> mr
                Nothing -> rtRolloutStatus row
        pure (mRollout `elem` [Just "rolling_out", Just "halted"])
    | otherwise = pure False

-- | mark-approved / mark-rejected are only valid while the review is pending.
ensureInReview :: MobileBuildWFStatus -> Flow ()
ensureInReview = \case
    MBInReview -> pure ()
    MBSubmittingForReview -> pure ()
    s -> bad ("Cannot record a review decision from state " <> tshow s <> "; the release is not in review.")

-- | True once the release has been promoted (notes locked, §12.7).
isPostPromote :: MobileBuildWFStatus -> Bool
isPostPromote = \case
    MBSubmittingForReview -> True
    MBInReview -> True
    MBReviewApproved -> True
    MBRollingOut -> True
    MBCompleted -> True
    _ -> False

bad :: Text -> Flow a
bad = throwM . BadRequest

tshow :: (Show a) => a -> Text
tshow = T.pack . show
