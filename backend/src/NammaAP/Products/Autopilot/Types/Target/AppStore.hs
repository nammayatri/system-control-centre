-- | Apple App Store target types
--
-- This module contains all types related to App Store releases:
-- - AppStoreDeploymentState: State tracking for App Store releases
-- - MobileAppIOSWFStatus: Detailed App Store-specific workflow stages
-- - AppStoreStatus: App Store submission states
module NammaAP.Products.Autopilot.Types.Target.AppStore
  ( -- * Target State
    AppStoreDeploymentState (..)
  , emptyAppStoreState

    -- * Workflow Status
  , MobileAppIOSWFStatus (..)

    -- * App Store Status
  , AppStoreStatus (..)
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

-- ============================================================================
-- App Store Workflow Status
-- ============================================================================

-- | Mobile app iOS workflow status (App Store-specific)
--
-- Tracks App Store Connect upload, TestFlight, review, and phased release.
-- This provides detailed progress within the generic ReleaseWFStatus stages.
data MobileAppIOSWFStatus
  = MIInit                      -- ^ Validate bundle
  | MIUploadBundle              -- ^ Upload bundle to App Store Connect
  | MITestFlightDistribute      -- ^ Distribute to TestFlight
  | MISubmitForReview           -- ^ Submit for App Store review
  | MIWaitingReview             -- ^ Waiting for review
  | MIPhasedRelease             -- ^ Phased release (day 1→3→7→full)
  | MIMonitorCrashReports       -- ^ Monitor crash reports
  | MIPromoteToFull             -- ^ Promote to full release
  | MIDone                      -- ^ Complete
  | MIHaltRelease               -- ^ Halt phased release
  deriving (Eq, Show, Read, Generic, Ord)

instance ToJSON MobileAppIOSWFStatus
instance FromJSON MobileAppIOSWFStatus

-- ============================================================================
-- App Store Status
-- ============================================================================

-- | App Store submission status
data AppStoreStatus
  = ReadyForReview
  | WaitingForReview
  | InReview
  | ReviewApproved
  | ReviewRejected
  | Released
  | RemovedFromSale
  deriving (Eq, Show, Generic)

instance ToJSON AppStoreStatus
instance FromJSON AppStoreStatus

-- ============================================================================
-- App Store Deployment State
-- ============================================================================

-- | App Store deployment state
--
-- Tracks bundle upload, TestFlight distribution, review status, and phased release
data AppStoreDeploymentState = AppStoreDeploymentState
  { categoryWorkflowStatus :: MobileAppIOSWFStatus
    -- ^ Granular App Store-specific workflow progress

  , bundleUploaded :: Maybe Text
    -- ^ Build number of uploaded bundle

  , testFlightDistributed :: Bool
    -- ^ Whether distributed to TestFlight testers

  , appStoreStatus :: AppStoreStatus
    -- ^ Current App Store submission status

  , rolloutPercentage :: Int
    -- ^ Phased release percentage (0-100)

  , buildProcessed :: Bool
    -- ^ Whether Apple finished processing the build
  } deriving (Eq, Show, Generic)

instance ToJSON AppStoreDeploymentState
instance FromJSON AppStoreDeploymentState

-- | Empty App Store deployment state (initial state)
emptyAppStoreState :: AppStoreDeploymentState
emptyAppStoreState = AppStoreDeploymentState
  { categoryWorkflowStatus = MIInit
  , bundleUploaded = Nothing
  , testFlightDistributed = False
  , appStoreStatus = ReadyForReview
  , rolloutPercentage = 0
  , buildProcessed = False
  }
