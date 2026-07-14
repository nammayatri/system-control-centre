{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Domain types for mobile (React Native) releases — the context, target state,
and fine-grained workflow status used by the MobileBuild release category.
-}
module Products.Autopilot.Mobile.Types (
    MobileBuildContext (..),
    MobileBuildTargetState (..),
    MobileBuildWFStatus (..),
    ReviewStatus (..),
    RolloutStatus (..),
    RolloutStage (..),
    reviewStatusToText,
    reviewStatusFromText,
    rolloutStatusToText,
    rolloutStatusFromText,
    isDebugBuildType,
    validMBTransition,
    isMBTerminal,
    isFailedMBTerminal,
    releasesIdentitySlot,
) where

import Data.Aeson (FromJSON (..), Options (..), ToJSON (..), defaultOptions, genericParseJSON, genericToJSON, object, withObject, (.:), (.:?), (.=))
import Data.Char (toLower)
import Data.Int (Int32)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)

{- | True for debug build types. Debug builds (Firebase / TestFlight) skip
store version resolution and tag confirmation; release builds (Google Play
/ App Store) run the full pipeline. The build type is fixed per deployment
environment (master = debug, production = release) via the
@mobile_build_type@ server_config flag and stamped onto each release at
creation time.
-}
isDebugBuildType :: Text -> Bool
isDebugBuildType = (== "debug")

data MobileBuildContext = MobileBuildContext
    { mbcVersionCode :: Maybe Int32
    , mbcChangeLog :: Text
    , mbcBuildType :: Text
    , mbcReleaseGroupId :: Text
    , mbcMatrixJobName :: Text
    , mbcOtaNamespace :: Maybe Text
    , mbcTagPushed :: Maybe Text
    , mbcDestination :: Maybe Text
    , mbcChangelogSummary :: Maybe Text
    , mbcChangelogSummaryShort :: Maybe Text
    }
    deriving (Eq, Show, Generic)

instance ToJSON MobileBuildContext where
    toJSON c =
        object
            [ "kind" .= ("mobile_build" :: Text)
            , "version_code" .= mbcVersionCode c
            , "change_log" .= mbcChangeLog c
            , "build_type" .= mbcBuildType c
            , "release_group_id" .= mbcReleaseGroupId c
            , "matrix_job_name" .= mbcMatrixJobName c
            , "ota_namespace" .= mbcOtaNamespace c
            , "tag_pushed" .= mbcTagPushed c
            , "destination" .= mbcDestination c
            , "changelog_summary" .= mbcChangelogSummary c
            , "changelog_summary_short" .= mbcChangelogSummaryShort c
            ]

instance FromJSON MobileBuildContext where
    parseJSON = withObject "MobileBuildContext" $ \o -> do
        -- Backward-compat: rows persisted before the build_type field used a
        -- "destination" string. Map the two debug destinations to "debug",
        -- everything else (incl. absent) to "release". The same "destination"
        -- key now also carries the provider-prod-Android store choice
        -- ("GooglePlay"/"Firebase"); since new rows always set "build_type",
        -- the first case below wins and this legacy inference only runs for
        -- pre-build_type rows (which never had a provider destination).
        mBuildType <- o .:? "build_type"
        mDest <- o .:? "destination"
        let buildType = case (mBuildType :: Maybe Text, mDest :: Maybe Text) of
                (Just bt, _) -> bt
                (Nothing, Just d) | d == "Firebase" || d == "TestFlight" -> "debug"
                _ -> "release"
        MobileBuildContext
            <$> o .:? "version_code"
            <*> o .: "change_log"
            <*> pure buildType
            <*> o .: "release_group_id"
            <*> o .: "matrix_job_name"
            <*> o .:? "ota_namespace"
            <*> o .:? "tag_pushed"
            <*> pure mDest
            -- absent in rows persisted before this field → Nothing (not opted in)
            <*> o .:? "changelog_summary"
            <*> o .:? "changelog_summary_short"

data MobileBuildWFStatus
    = MBInit
    | MBVersionResolved
    | MBDispatched
    | MBRunIdResolved
    | MBBuilding
    | MBSubmittedToStore
    | MBTagPushed
    | MBSubmittingForReview
    | MBInReview
    | MBReviewApproved
    | MBReviewRejected
    | MBRollingOut
    | MBCompleted
    | MBAborting
    | MBAborted
    | MBFailed Text
    deriving (Eq, Show, Generic)

instance ToJSON MobileBuildWFStatus
instance FromJSON MobileBuildWFStatus

data MobileBuildTargetState = MobileBuildTargetState
    { mbWfStatus :: MobileBuildWFStatus
    , mbContext :: MobileBuildContext
    , mbExternalRunId :: Maybe Text
    , mbMatrixJobStatus :: Maybe Text
    , mbBuildStartedAt :: Maybe UTCTime
    , mbBuildCompletedAt :: Maybe UTCTime
    , mbResolveAttempts :: Maybe Int
    -- ^ Counter incremented by the ResolveRunId workflow stage each time
    -- it polls GitHub for the dispatched run. Bounded retry budget; the
    -- worker uses this to give up after N attempts. 'Nothing' is treated
    -- as zero by callers — backward-compatible with rows persisted before
    -- this field existed.
    , mbReviewSubmittedAt :: Maybe UTCTime
    -- ^ When the release was submitted to store review (set on entry to
    -- MBInReview by the promote endpoint). Anchors the 7-day soft timeout.
    , mbReviewLastPolledAt :: Maybe UTCTime
    -- ^ When the review-poll stage last hit the store. Throttle anchor
    -- (@review_poll_interval_sec@). Backward-compatible Maybe (old rows → Nothing).
    , mbBatchDispatch :: Maybe Bool
    -- ^ Just True = dispatched in a multi-app run WITHOUT version inputs (each
    -- matrix job auto-versions; ConfirmTag adopts the code from the pushed tag).
    -- Nothing / Just False = single dispatch with explicit version inputs.
    -- Backward-compatible Maybe (old rows → Nothing).
    }
    deriving (Eq, Show, Generic)

instance ToJSON MobileBuildTargetState
instance FromJSON MobileBuildTargetState

isMBTerminal :: MobileBuildWFStatus -> Bool
isMBTerminal = \case
    MBCompleted -> True
    MBAborted -> True
    MBReviewRejected -> True
    MBFailed{} -> True
    _ -> False

-- | Failed terminals: user-aborted or build-failed.
isFailedMBTerminal :: MobileBuildWFStatus -> Bool
isFailedMBTerminal = \case
    MBAborted -> True
    MBFailed{} -> True
    _ -> False

-- | Releases its (version, code) slot only if it aborted/failed BEFORE uploading an
-- artifact (no tag pushed). A build that reached a store track keeps its slot — the
-- store owns that code, so a same-version+code rebuild would clash.
releasesIdentitySlot :: MobileBuildTargetState -> Bool
releasesIdentitySlot s = isFailedMBTerminal (mbWfStatus s) && isNothing (mbcTagPushed (mbContext s))

{- | Pure transition predicate. Mirrors validateStatusTransition's style.
Note: MBFailed _ is allowed from any non-terminal state. Specific
non-fail target states are listed in allowedNonFail.
-}
validMBTransition :: MobileBuildWFStatus -> MobileBuildWFStatus -> Bool
validMBTransition from to
    | isMBTerminal from = False
    | otherwise = case to of
        MBFailed _ -> True -- already filtered out terminals
        _ -> to `elem` allowedNonFail from
  where
    allowedNonFail MBInit = [MBVersionResolved]
    allowedNonFail MBVersionResolved = [MBDispatched]
    allowedNonFail MBDispatched = [MBRunIdResolved]
    allowedNonFail MBRunIdResolved = [MBBuilding]
    allowedNonFail MBBuilding = [MBSubmittedToStore, MBAborting]
    allowedNonFail MBSubmittedToStore = [MBTagPushed]
    -- After the build's tag is confirmed: promote to store review (release builds)
    -- or finish directly (debug builds, which skip review entirely).
    allowedNonFail MBTagPushed = [MBSubmittingForReview, MBCompleted]
    allowedNonFail MBSubmittingForReview = [MBInReview]
    allowedNonFail MBInReview = [MBReviewApproved, MBReviewRejected]
    allowedNonFail MBReviewApproved = [MBRollingOut, MBCompleted]
    allowedNonFail MBRollingOut = [MBCompleted]
    allowedNonFail MBAborting = [MBAborted]
    allowedNonFail _ = []

-- ─── Store review + staged rollout (migration 0027) ─────────────────────────

{- | Store-review state of a promoted release. Persisted as text in
@release_tracker.review_status@. iOS uses in_review / approved / rejected (from
the store's @appStoreState@); Android — whose review is opaque — uses
submitted / live.
-}
data ReviewStatus = RSSubmitted | RSInReview | RSApproved | RSRejected | RSLive
    deriving (Eq, Show, Generic)

reviewStatusToText :: ReviewStatus -> Text
reviewStatusToText = \case
    RSSubmitted -> "submitted"
    RSInReview -> "in_review"
    RSApproved -> "approved"
    RSRejected -> "rejected"
    RSLive -> "live"

reviewStatusFromText :: Text -> Maybe ReviewStatus
reviewStatusFromText = \case
    "submitted" -> Just RSSubmitted
    "in_review" -> Just RSInReview
    "approved" -> Just RSApproved
    "rejected" -> Just RSRejected
    "live" -> Just RSLive
    _ -> Nothing

-- | Staged-rollout state. Persisted as text in @release_tracker.rollout_status@.
data RolloutStatus = ROSRollingOut | ROSHalted | ROSCompleted
    deriving (Eq, Show, Generic)

rolloutStatusToText :: RolloutStatus -> Text
rolloutStatusToText = \case
    ROSRollingOut -> "rolling_out"
    ROSHalted -> "halted"
    ROSCompleted -> "completed"

rolloutStatusFromText :: Text -> Maybe RolloutStatus
rolloutStatusFromText = \case
    "rolling_out" -> Just ROSRollingOut
    "halted" -> Just ROSHalted
    "completed" -> Just ROSCompleted
    _ -> Nothing

{- | One step in a release's rollout timeline; the list is persisted as JSON in
@release_tracker.store_rollout_history@. JSON keys are camelCase (@percent@,
@startedAt@, …) to match the frontend contract.
-}
data RolloutStage = RolloutStage
    { rsPercent :: Double
    , rsStartedAt :: UTCTime
    , rsEndedAt :: Maybe UTCTime
    , rsNotes :: Maybe Text
    , rsActor :: Text
    }
    deriving (Eq, Show, Generic)

rolloutStageOptions :: Options
rolloutStageOptions = defaultOptions{fieldLabelModifier = lowerFirst . drop 2}
  where
    lowerFirst (c : cs) = toLower c : cs
    lowerFirst [] = []

instance ToJSON RolloutStage where
    toJSON = genericToJSON rolloutStageOptions

instance FromJSON RolloutStage where
    parseJSON = genericParseJSON rolloutStageOptions
