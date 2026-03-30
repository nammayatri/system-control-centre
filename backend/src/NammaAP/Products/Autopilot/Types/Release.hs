module NammaAP.Products.Autopilot.Types.Release
  ( -- * Release Types
    RolloutStep (..)
  , RolloutHistory (..)
  , ReleaseTracker (..)

  -- * Release Status
  , ReleaseStatus (..)
  , isTerminalStatus
  , isAbortedStatus
  , validateStatusTransition
  , validateGlobalStatusTransition

  -- * Common Enums
  , Decision (..)
  , Mode (..)
  ) where

import Data.Aeson (FromJSON, ToJSON, Value)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import GHC.Generics (Generic)
import GHC.Int (Int32)
import NammaAP.Products.Autopilot.Types.Workflow (ReleaseCategory, ReleaseWFStatus)

-- ============================================================================
-- Common Types (Used Across All Releases)
-- ============================================================================

data Decision = Continue | Wait | Abort
  deriving (Eq, Show, Read, Generic)
instance ToJSON Decision
instance FromJSON Decision

data Mode = Auto | Manual
  deriving (Eq, Show, Read, Generic)
instance ToJSON Mode
instance FromJSON Mode

-- ============================================================================
-- Release Status (user-facing lifecycle states)
-- ============================================================================

-- | Release lifecycle status
--
-- These are the user-facing states that apply to ALL release types.
-- Platform-specific workflow progress is tracked separately in targetState.
--
-- Lifecycle:
--   Created → InProgress → Completed
--                        → Paused → InProgress (resume)
--                        → Aborting → Aborted / UserAborted
--                        → Reverting → Reverted
--   Created → Discarding → Discarded
data ReleaseStatus
  = Created       -- ^ Initial state, awaiting approval or scheduling
  | InProgress    -- ^ Actively executing
  | Completed     -- ^ Successfully finished
  | Aborted       -- ^ System-initiated abort (errors, health check failures, etc.)
  | UserAborted   -- ^ User-initiated abort
  | Discarded     -- ^ Discarded before execution
  | Discarding    -- ^ Transitioning to Discarded (async cleanup)
  | Paused        -- ^ Paused by user, can be resumed
  | Aborting      -- ^ Abort in progress (transitioning to Aborted/UserAborted)
  | Reverting     -- ^ Reverting a completed release back to previous version
  | Reverted      -- ^ Revert completed successfully
  | Restarting    -- ^ Resuming after pause or transient failure
  deriving (Eq, Show, Read, Generic)
instance ToJSON ReleaseStatus
instance FromJSON ReleaseStatus

-- ============================================================================
-- Status Helpers
-- ============================================================================

isTerminalStatus :: ReleaseStatus -> Bool
isTerminalStatus s = s `elem` [Aborted, UserAborted, Completed, Discarded, Reverted]

isAbortedStatus :: ReleaseStatus -> Bool
isAbortedStatus s = s `elem` [Aborted, UserAborted, Aborting]

validateStatusTransition :: ReleaseStatus -> ReleaseStatus -> Bool
validateStatusTransition from to = to `elem` allowed from
  where
    allowed Created     = [InProgress, Discarded]
    allowed InProgress  = [Aborted, UserAborted, Completed, Paused, Aborting]
    allowed Aborted     = []
    allowed UserAborted = []
    allowed Completed   = []
    allowed Discarded   = []
    allowed Paused      = [Aborting, UserAborted, InProgress]
    allowed Aborting    = [Aborting, Aborted, UserAborted, Reverting]
    allowed Reverting   = [Reverted, UserAborted]
    allowed Reverted    = []
    allowed _           = []

validateGlobalStatusTransition :: ReleaseStatus -> ReleaseStatus -> Bool
validateGlobalStatusTransition from to = to `elem` allowed from
  where
    allowed Created     = [InProgress, Discarded, Discarding]
    allowed InProgress  = [Aborted, UserAborted, Completed, Paused, Aborting, Reverting, Discarded, Restarting]
    allowed Restarting  = [InProgress, UserAborted, Aborted, Reverting, Paused]
    allowed Aborted     = []
    allowed UserAborted = []
    allowed Completed   = [Reverting]
    allowed Discarded   = []
    allowed Paused      = [Aborting, Reverting, UserAborted, InProgress, Restarting]
    allowed Aborting    = [Aborting, Discarded, Aborted, UserAborted, Reverting, Restarting, Completed]
    allowed Reverting   = [Reverted, UserAborted, Paused, Restarting]
    allowed Discarding  = [Discarded]
    allowed _           = []

-- ============================================================================
-- Release Data Types
-- ============================================================================

data RolloutStep = RolloutStep
  { rolloutPercent :: Int
  , cooloffSeconds :: Int
  , podPercent :: Int
  } deriving (Eq, Show, Generic)
instance ToJSON RolloutStep
instance FromJSON RolloutStep

data RolloutHistory = RolloutHistory
  { historyRolloutPercent :: Int
  , historyCooloffSeconds :: Int
  , historyPodsPercent :: Int
  , historyDecision :: Maybe Decision
  , historyDecisionReason :: Maybe Text
  , historyStartedAt :: UTCTime
  , historyCompletedAt :: Maybe UTCTime
  , historyManualOverride :: Bool
  , historyDecisionHs :: Maybe Decision
  , historyDecisionHsReason :: Maybe Text
  } deriving (Eq, Show, Generic)
instance ToJSON RolloutHistory
instance FromJSON RolloutHistory

data ReleaseTracker = ReleaseTracker
  { releaseId :: Text
  , product :: Text
    -- ^ Service/app name (e.g., "Beckn", "rider-app", "BecknSchedulers")
    -- This is the WHAT - which service or app is being released

  , service :: Text
    -- ^ Alias for product (for backward compatibility)

  , env :: Text
  , category :: ReleaseCategory
    -- ^ Release category: BackendService, MobileAppAndroid, BackendConfig, etc.
    -- This is the HOW/WHERE - how/where to deploy it

  , status :: ReleaseStatus
    -- ^ Current release status: Created, InProgress, Completed, Aborted, etc.

  , releaseWFStatus :: ReleaseWFStatus
    -- ^ Generic workflow stage: Init, Preparing, Deploying, Monitoring, Finalizing, Done
    -- Applies to ALL release categories (K8s, Play Store, App Store, etc.)

  , mode :: Mode
  , createdBy :: Text
  , approvedBy :: Maybe Text
  , isApproved :: Bool
  , isInfraApproved :: Bool
  , releaseTag :: Maybe Text
  , scheduleTime :: Maybe UTCTime
  , dateCreated :: Maybe UTCTime
  , lastUpdated :: Maybe UTCTime
  , startTime :: Maybe UTCTime
  , endTime :: Maybe UTCTime
  , rolloutStrategy :: [RolloutStep]
  , rolloutHistory :: [RolloutHistory]
  , oldVersion :: Text
    -- ^ Previous version (generic, applies to all release types)
  , newVersion :: Text
    -- ^ New version being released (generic, applies to all release types)
  , info :: Maybe Text
  , description :: Maybe Text
  , changeLog :: Maybe Text
  , metadata :: Maybe Value
  , priority :: Int32
  , globalId :: Maybe Text
  , udf1 :: Maybe Text
  , udf2 :: Maybe Text
  , udf3 :: Maybe Text
  } deriving (Eq, Show, Generic)
instance ToJSON ReleaseTracker
instance FromJSON ReleaseTracker
