{- | Google Play Store target types

This module contains all types related to Play Store releases:
- PlayStoreDeploymentState: State tracking for Play Store releases
- MobileAppAndroidWFStatus: Detailed Play Store-specific workflow stages
- ReviewStatus: Play Store review states
-}
module Products.Autopilot.Types.Target.PlayStore (
    -- * Target State
    PlayStoreDeploymentState (..),
    emptyPlayStoreState,

    -- * Workflow Status
    MobileAppAndroidWFStatus (..),

    -- * Review Status
    ReviewStatus (..),
)
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

-- ============================================================================
-- Play Store Workflow Status
-- ============================================================================

{- | Mobile app Android workflow status (Play Store-specific)

Tracks Play Store upload, review, and rollout steps.
This provides detailed progress within the generic ReleaseWFStatus stages.
-}
data MobileAppAndroidWFStatus
    = -- | Validate APK
      MAInit
    | -- | Upload APK to Play Console
      MAUploadAPK
    | -- | Submit for Play Store review
      MASubmitForReview
    | -- | Waiting for review approval
      MAWaitingReview
    | -- | Staged rollout (0→25→50→100)
      MAStagedRollout
    | -- | Monitor crash and ANR rates
      MAMonitorCrashRate
    | -- | Promote to 100% rollout
      MAPromoteToFull
    | -- | Complete
      MADone
    | -- | Halt rollout (error state)
      MAHaltRollout
    deriving (Eq, Show, Read, Generic, Ord)

instance ToJSON MobileAppAndroidWFStatus

instance FromJSON MobileAppAndroidWFStatus

-- ============================================================================
-- Review Status
-- ============================================================================

-- | Play Store review status
data ReviewStatus
    = NotSubmitted
    | UnderReview
    | Approved
    | Rejected
    deriving (Eq, Show, Generic)

instance ToJSON ReviewStatus

instance FromJSON ReviewStatus

-- ============================================================================
-- Play Store Deployment State
-- ============================================================================

{- | Play Store deployment state

Tracks APK upload, rollout percentage, and health metrics from Play Console
-}
data PlayStoreDeploymentState = PlayStoreDeploymentState
    { categoryWorkflowStatus :: MobileAppAndroidWFStatus
    -- ^ Granular Play Store-specific workflow progress
    , apkUploaded :: Maybe Text
    -- ^ Version code of uploaded APK
    , stagedRolloutPercent :: Int
    -- ^ Current rollout percentage (0-100)
    , reviewStatus :: ReviewStatus
    -- ^ Review status in Play Console
    , crashRate :: Maybe Double
    -- ^ Current crash rate (0.0 to 1.0)
    , anrRate :: Maybe Double
    -- ^ Current ANR (Application Not Responding) rate (0.0 to 1.0)
    , activeInstalls :: Maybe Int
    -- ^ Number of active installs
    , averageRating :: Maybe Double
    -- ^ Average user rating (1.0 to 5.0)
    }
    deriving (Eq, Show, Generic)

instance ToJSON PlayStoreDeploymentState

instance FromJSON PlayStoreDeploymentState

-- | Empty Play Store deployment state (initial state)
emptyPlayStoreState :: PlayStoreDeploymentState
emptyPlayStoreState =
    PlayStoreDeploymentState
        { categoryWorkflowStatus = MAInit
        , apkUploaded = Nothing
        , stagedRolloutPercent = 0
        , reviewStatus = NotSubmitted
        , crashRate = Nothing
        , anrRate = Nothing
        , activeInstalls = Nothing
        , averageRating = Nothing
        }
