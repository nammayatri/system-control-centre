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
    isDebugBuildType,
    validMBTransition,
    isMBTerminal,
) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=))
import Data.Int (Int32)
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
    -- ^ "debug" or "release" — set from the @mobile_build_type@ config at
    -- release creation and persisted so the release's build type reflects
    -- what it WAS, independent of the environment's current setting.
    , mbcReleaseGroupId :: Text
    , mbcMatrixJobName :: Text
    , mbcOtaNamespace :: Maybe Text
    , mbcTagPushed :: Maybe Text
    , mbcDestination :: Maybe Text
    -- ^ Play-store destination for provider PROD Android builds ONLY —
    -- "GooglePlay" or "Firebase" — chosen by the operator on the create form
    -- (mirrors provider-prod-apk-gen.yaml's required @destination@ input).
    -- 'Nothing' for every other build (consumer, iOS, debug, and provider
    -- rows created before this field existed); the dispatch falls back to
    -- "GooglePlay" in that case. Consumed solely by the provider prod Android
    -- @workflow_dispatch@ — ignored everywhere else.
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

data MobileBuildWFStatus
    = MBInit
    | MBVersionResolved
    | MBDispatched
    | MBRunIdResolved
    | MBBuilding
    | MBSubmittedToStore
    | MBTagPushed
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
    }
    deriving (Eq, Show, Generic)

instance ToJSON MobileBuildTargetState
instance FromJSON MobileBuildTargetState

isMBTerminal :: MobileBuildWFStatus -> Bool
isMBTerminal = \case
    MBCompleted -> True
    MBAborted -> True
    MBFailed{} -> True
    _ -> False

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
    allowedNonFail MBTagPushed = [MBCompleted]
    allowedNonFail MBAborting = [MBAborted]
    allowedNonFail _ = []
