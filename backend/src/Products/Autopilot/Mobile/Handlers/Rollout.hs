{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Phase 6 — promote-to-review + staged-rollout HTTP handlers.

The operator drives the last leg of a mobile release from SCC instead of the
Play Console / App Store Connect:

  build done (MBTagPushed, held) → /promote → MBInReview → (approved) →
  /release (iOS) or /rollout/set (Android) → MBRollingOut → /rollout/release-all → COMPLETED

Every handler is gated on @mobile_staged_rollout_enabled@ ('requireStaged'); with
the flag off these endpoints 400 and release builds keep auto-completing at
tag-push (the legacy behavior). Promote and rollout are __operator-gated__ (a
human clicks) — nothing here is triggered automatically.

Platform split (see plan §5):

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
) where

import Control.Monad (unless, when)
import Control.Monad.Catch (throwM)
import Control.Monad.IO.Class (liftIO)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson (..))
import Core.Environment (Flow)
import Data.Aeson (FromJSON, ToJSON, object, (.=))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, getCurrentTime)
import GHC.Generics (Generic)
import Products.Autopilot.Mobile.Queries.AppCatalog (storeTrackOf)
import Products.Autopilot.Mobile.Queries.Tracker (
    appCatalogForRowRaw,
    findMobileReleaseById,
    logEvent,
    markReleaseInProgress,
    setAscIds,
    setMobileWfStatus,
    setReviewDecided,
    setReviewSubmitted,
    setRolloutState,
 )
import Products.Autopilot.Mobile.Types (
    MobileBuildContext (..),
    MobileBuildTargetState (..),
    MobileBuildWFStatus (..),
    isDebugBuildType,
 )
import Products.Autopilot.Mobile.Types.Storage (AppCatalog, AppCatalogT (..))
import Products.Autopilot.Mobile.Versioning.Apple (
    cancelReviewSubmission,
    completePhasedRelease,
    enablePhasedRelease,
    getLiveReleaseNotes,
    getPhasedReleaseId,
    loadAscCredsFor,
    pausePhasedRelease,
    releaseApprovedVersion,
    renderAscErr,
    resumePhasedRelease,
    submitVersionForReview,
 )
import Products.Autopilot.Mobile.Versioning.Play (
    PlayCreds,
    PlayRolloutState (..),
    completeTrackRollout,
    getProductionReleaseNotes,
    getTrackRolloutState,
    haltTrackRollout,
    loadPlayCreds,
    promoteToProduction,
    renderPlayErr,
    resumeTrackRollout,
    setTrackRollout,
    userFractionInRange,
 )
import Products.Autopilot.RuntimeConfig (getAndroidReviewRolloutFraction, isStagedRolloutEnabled)
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
        changelog = mbcChangeLog (mbContext target)
        isStoreSync = rtMode row == Just "STORE_SYNC"
    -- For a store-synced release SCC has no changelog of its own (the synthetic
    -- row reads "Synced from store"), so default the notes to the current
    -- production "What's New" pulled from the store. SCC-built releases keep
    -- their changelog (the FE may swap in the AI short summary). Best-effort:
    -- any store read failure falls back to the changelog.
    notes <-
        if isStoreSync
            then fromMaybe changelog <$> fetchProdReleaseNotes ac platform
            else pure changelog
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

{- | POST /releases/:id/promote — fill the release notes and submit the app for
review. iOS: set What's New on every locale + releaseType MANUAL + submit, then
(optionally) enable phased release. Android: promote internal→production at the
effectively-zero review fraction so approval exposes ~0 users. The release moves
to @MBInReview@; the Phase-5 poll stage takes it from there (iOS auto, Android
awaits the operator's mark-*).
-}
promoteH :: AuthedPerson -> Text -> PromoteReq -> Flow PromoteResp
promoteH ap rid PromoteReq{..} = do
    requireStaged
    (row, target, ac) <- loadPromotable rid
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
    if rtEnv row == "ios"
        then do
            creds <- loadAscCredsFor (acStoreAccount ac) >>= maybe (bad "App Store Connect credentials not configured.") pure
            submitVersionForReview creds storeId version prReleaseNotes
                >>= either (\e -> bad ("App Store submit failed: " <> renderAscErr e)) pure
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
            setReviewSubmitted rid "in_review" now
            when isPrePromoteSnapshot $ markReleaseInProgress rid
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
            setReviewSubmitted rid "submitted" now
            when isPrePromoteSnapshot $ markReleaseInProgress rid
            logEvent rid "REVIEW_SUBMITTED" $
                object ["store" .= ("play" :: Text), "actor" .= apEmail ap, "fraction" .= frac, "from_snapshot" .= isPrePromoteSnapshot]
            pure (PromoteResp "Success" Nothing)

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
    pure
        RolloutDetail
            { rdReleaseId = rid
            , rdPlatform = rtEnv row
            , rdMbStatus = tshow (mbWfStatus target)
            , rdReviewStatus = rtReviewStatus row
            , rdReviewRejectReason = rtReviewRejectReason row
            , rdReviewSubmittedAt = rtReviewSubmittedAt row
            , rdReviewDecidedAt = rtReviewDecidedAt row
            , rdRolloutStatus = rtRolloutStatus row
            , rdRolloutPercent = rtRolloutPercent row
            , rdPhasedId = phasedId
            , rdStoreTrack = storeTrackOf (rtMetadata row)
            }

{- | POST /releases/:id/release — the iOS "Release" button. Releases an approved
(held, PENDING_DEVELOPER_RELEASE) version. If phased release was enabled at
promote time, Apple then ramps over 7 days; otherwise it goes fully live.
-}
releaseH :: AuthedPerson -> Text -> Flow APISuccess
releaseH ap rid = do
    requireStaged
    (row, target, ac) <- loadPromotable rid
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
                _ -> pure Nothing
    case mPhasedId of
        Just _ -> do
            -- Phased: Apple ramps over 7 days; the Phase-7 reconciler tracks the
            -- live % and completes the release when the ramp finishes.
            setRolloutState rid "rolling_out" Nothing
            setMobileWfStatus rid MBRollingOut
            logEvent rid "ROLLOUT_RELEASED" (object ["store" .= ("asc" :: Text), "actor" .= apEmail ap, "phased" .= True])
        Nothing -> do
            -- Non-phased: the version goes fully live on release → done.
            setRolloutState rid "completed" (Just 100)
            setMobileWfStatus rid MBCompleted
            logEvent rid "ROLLOUT_RELEASED" (object ["store" .= ("asc" :: Text), "actor" .= apEmail ap, "phased" .= False])
    pure Success

{- | POST /releases/:id/rollout/set — Android staged rollout. Sets the production
@userFraction@ to @percent/100@; @percent >= 100@ completes the rollout (status
completed, no fraction → 100% of users) and finishes the release.
-}
rolloutSetH :: AuthedPerson -> Text -> RolloutSetReq -> Flow APISuccess
rolloutSetH ap rid RolloutSetReq{..} = do
    requireStaged
    (row, target, ac) <- loadPromotable rid
    unless (rtEnv row == "android") $ bad "/rollout/set is Android-only; iOS uses phased release."
    ensureAndroidRollable (mbWfStatus target)
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
    -- Track it as rolling out, but DON'T assert the requested %/completion here.
    -- With Managed Publishing on, the commit above is held in the Play Console's
    -- "Publishing overview" until someone clicks Publish — so the live track may not
    -- reflect it yet. The Phase-7 reconciler reads the LIVE track and sets the true
    -- % (or completes the release when the live track reaches 100%), so SCC shows
    -- what actually shipped rather than what we asked for. (`rollout_percent` stays
    -- NULL until that first reconcile, surfaced as "Rolling out" without a %.)
    setRolloutState rid "rolling_out" Nothing
    setMobileWfStatus rid MBRollingOut
    logEvent rid "ROLLOUT_SET" (object ["percent" .= rsPercent, "actor" .= apEmail ap])
    pure Success

-- | POST /releases/:id/rollout/halt — pause the rollout (iOS phased PAUSE; Android halted).
rolloutHaltH :: AuthedPerson -> Text -> Flow APISuccess
rolloutHaltH ap rid = do
    requireStaged
    (row, target, ac) <- loadPromotable rid
    if rtEnv row == "ios"
        then do
            pid <- requirePhasedId row
            creds <- loadAscCredsFor (acStoreAccount ac) >>= maybe (bad "App Store Connect credentials not configured.") pure
            pausePhasedRelease creds pid
                >>= either (\e -> bad ("App Store pause failed: " <> renderAscErr e)) pure
            setRolloutState rid "halted" (rtRolloutPercent row)
            logEvent rid "ROLLOUT_HALTED" (object ["store" .= ("asc" :: Text), "actor" .= apEmail ap])
            pure Success
        else do
            storeId <- storeIdOf ac
            vc <- versionCodeText target
            creds <- loadPlayCreds >>= maybe (bad "Google Play credentials not configured.") pure
            -- §12.10: read the live fraction, halt AT it — never trust the cached %.
            frac <- liveAndroidFraction creds storeId
            haltTrackRollout creds storeId vc frac
                >>= either (\e -> bad ("Play halt failed: " <> renderPlayErr e)) pure
            setRolloutState rid "halted" (Just (frac * 100))
            logEvent rid "ROLLOUT_HALTED" (object ["store" .= ("play" :: Text), "actor" .= apEmail ap])
            pure Success

-- | POST /releases/:id/rollout/resume — resume a paused rollout at its current fraction.
rolloutResumeH :: AuthedPerson -> Text -> Flow APISuccess
rolloutResumeH ap rid = do
    requireStaged
    (row, target, ac) <- loadPromotable rid
    if rtEnv row == "ios"
        then do
            pid <- requirePhasedId row
            creds <- loadAscCredsFor (acStoreAccount ac) >>= maybe (bad "App Store Connect credentials not configured.") pure
            resumePhasedRelease creds pid
                >>= either (\e -> bad ("App Store resume failed: " <> renderAscErr e)) pure
            setRolloutState rid "rolling_out" (rtRolloutPercent row)
            logEvent rid "ROLLOUT_RESUMED" (object ["store" .= ("asc" :: Text), "actor" .= apEmail ap])
            pure Success
        else do
            storeId <- storeIdOf ac
            vc <- versionCodeText target
            creds <- loadPlayCreds >>= maybe (bad "Google Play credentials not configured.") pure
            frac <- liveAndroidFraction creds storeId
            resumeTrackRollout creds storeId vc frac
                >>= either (\e -> bad ("Play resume failed: " <> renderPlayErr e)) pure
            setRolloutState rid "rolling_out" (Just (frac * 100))
            logEvent rid "ROLLOUT_RESUMED" (object ["store" .= ("play" :: Text), "actor" .= apEmail ap])
            pure Success

{- | POST /releases/:id/rollout/release-all — jump to 100% on both platforms and
finish the release. iOS completes the phased release (if any); Android completes
the staged rollout.
-}
rolloutReleaseAllH :: AuthedPerson -> Text -> Flow APISuccess
rolloutReleaseAllH ap rid = do
    requireStaged
    (row, target, ac) <- loadPromotable rid
    storeId <- storeIdOf ac
    if rtEnv row == "ios"
        then do
            creds <- loadAscCredsFor (acStoreAccount ac) >>= maybe (bad "App Store Connect credentials not configured.") pure
            -- A phased ramp is completed to 100%; a non-phased release is already
            -- fully live, so there's nothing more to call.
            case rtAscPhasedId row of
                Just pid
                    | not (T.null pid) ->
                        completePhasedRelease creds pid
                            >>= either (\e -> bad ("App Store complete failed: " <> renderAscErr e)) pure
                _ -> pure ()
        else do
            vc <- versionCodeText target
            creds <- loadPlayCreds >>= maybe (bad "Google Play credentials not configured.") pure
            completeTrackRollout creds storeId vc
                >>= either (\e -> bad ("Play complete failed: " <> renderPlayErr e)) pure
    setRolloutState rid "completed" (Just 100)
    setMobileWfStatus rid MBCompleted
    logEvent rid "ROLLOUT_RELEASED_ALL" (object ["actor" .= apEmail ap])
    pure Success

{- | POST /releases/:id/review/mark-approved — Android only. Records the
operator's confirmation that the opaque Play review went live (§12a). iOS
approval is auto-detected by the poll stage, so this is Android-only.
-}
markApprovedH :: AuthedPerson -> Text -> Flow APISuccess
markApprovedH ap rid = do
    requireStaged
    (row, target, _ac) <- loadPromotable rid
    unless (rtEnv row == "android") $ bad "mark-approved is Android-only (iOS approval is auto-detected)."
    ensureInReview (mbWfStatus target)
    now <- liftIO getCurrentTime
    setReviewDecided rid "approved" now Nothing
    setMobileWfStatus rid MBReviewApproved
    logEvent rid "REVIEW_APPROVED" (object ["store" .= ("play" :: Text), "manual" .= True, "actor" .= apEmail ap])
    pure Success

{- | POST /releases/:id/review/mark-rejected — Android only. Records a store
rejection + reason; the release becomes @MBReviewRejected@ (terminal → ABORTED).
-}
markRejectedH :: AuthedPerson -> Text -> MarkRejectedReq -> Flow APISuccess
markRejectedH ap rid MarkRejectedReq{..} = do
    requireStaged
    (row, target, _ac) <- loadPromotable rid
    unless (rtEnv row == "android") $ bad "mark-rejected is Android-only (iOS rejection is auto-detected)."
    when (T.null (T.strip mrReason)) $ bad "Rejection reason is required."
    ensureInReview (mbWfStatus target)
    now <- liftIO getCurrentTime
    setReviewDecided rid "rejected" now (Just mrReason)
    setMobileWfStatus rid MBReviewRejected
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
    unless (rtEnv row == "ios") $
        bad "Withdraw from review is iOS-only — Google Play has no API to cancel a review."
    ensureInReview (mbWfStatus target)
    bundleId <- storeIdOf ac
    creds <- loadAscCredsFor (acStoreAccount ac) >>= maybe (bad "App Store Connect credentials not configured.") pure
    cancelReviewSubmission creds bundleId
        >>= either (\e -> bad ("App Store withdraw failed: " <> renderAscErr e)) pure
    now <- liftIO getCurrentTime
    setReviewDecided rid "withdrawn" now Nothing
    setMobileWfStatus rid MBAborted
    logEvent rid "REVIEW_WITHDRAWN" (object ["store" .= ("asc" :: Text), "actor" .= apEmail ap])
    pure Success

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

-- | The Android version code as text (required to address the production release).
versionCodeText :: MobileBuildTargetState -> Flow Text
versionCodeText target = case mbcVersionCode (mbContext target) of
    Just vc -> pure (tshow vc)
    Nothing -> bad "Android release has no version code recorded."

-- | The cached iOS phased-release id, or a clear error if phased release is off.
requirePhasedId :: ReleaseTrackerRow -> Flow Text
requirePhasedId row = case rtAscPhasedId row of
    Just p | not (T.null p) -> pure p
    _ -> bad "No phased release is enabled for this version (promote with enablePhasedRelease, or use /rollout/release-all)."

{- | Read the live Android production rollout fraction (§12.10); error if there
is no in-progress fraction to act on.
-}
liveAndroidFraction :: PlayCreds -> Text -> Flow Double
liveAndroidFraction creds storeId =
    getTrackRolloutState creds storeId >>= \case
        Left e -> bad ("Could not read live Play rollout state: " <> renderPlayErr e)
        Right st -> case prsUserFraction st of
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
