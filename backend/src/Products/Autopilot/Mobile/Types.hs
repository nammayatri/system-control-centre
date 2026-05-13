{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Domain types for mobile (React Native) releases — the context, target state,
and fine-grained workflow status used by the MobileBuild release category.
-}
module Products.Autopilot.Mobile.Types (
    MobileBuildContext (..),
    MobileDestination (..),
    MobileBuildTargetState (..),
    MobileBuildWFStatus (..),
    validMBTransition,
    isMBTerminal,
) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=))
import qualified Data.Aeson as Aeson
import Data.Int (Int32)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)

data MobileDestination = MBGooglePlay | MBFirebase
    deriving (Eq, Show, Read, Generic)

instance ToJSON MobileDestination where
    toJSON MBGooglePlay = "GooglePlay"
    toJSON MBFirebase = "Firebase"

instance FromJSON MobileDestination where
    parseJSON = Aeson.withText "MobileDestination" $ \case
        "GooglePlay" -> pure MBGooglePlay
        "Firebase" -> pure MBFirebase
        other -> fail $ "unknown destination: " <> show other

data MobileBuildContext = MobileBuildContext
    { mbcVersionCode :: Maybe Int32
    , mbcChangeLog :: Text
    , mbcDestination :: MobileDestination
    , mbcReleaseGroupId :: Text
    , mbcMatrixJobName :: Text
    , mbcOtaNamespace :: Maybe Text
    , mbcTagPushed :: Maybe Text
    }
    deriving (Eq, Show, Generic)

instance ToJSON MobileBuildContext where
    toJSON c =
        object
            [ "kind" .= ("mobile_build" :: Text)
            , "version_code" .= mbcVersionCode c
            , "change_log" .= mbcChangeLog c
            , "destination" .= mbcDestination c
            , "release_group_id" .= mbcReleaseGroupId c
            , "matrix_job_name" .= mbcMatrixJobName c
            , "ota_namespace" .= mbcOtaNamespace c
            , "tag_pushed" .= mbcTagPushed c
            ]

instance FromJSON MobileBuildContext where
    parseJSON = withObject "MobileBuildContext" $ \o ->
        MobileBuildContext
            <$> o .:? "version_code"
            <*> o .: "change_log"
            <*> o .: "destination"
            <*> o .: "release_group_id"
            <*> o .: "matrix_job_name"
            <*> o .:? "ota_namespace"
            <*> o .:? "tag_pushed"

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
