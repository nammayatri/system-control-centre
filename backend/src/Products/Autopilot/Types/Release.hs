module Products.Autopilot.Types.Release
  ( -- * Release Types
    RolloutStep (..),
    RolloutHistory (..),
    ReleaseTracker (..),

    -- * Release Status
    ReleaseStatus (..),
    isTerminalStatus,
    isAbortedStatus,
    validateStatusTransition,
    validateGlobalStatusTransition,

    -- * Common Enums
    Decision (..),
    Mode (..),
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value, withText)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime)
import GHC.Generics (Generic)
import GHC.Int (Int32)
import Products.Autopilot.Types.Workflow (ReleaseCategory, ReleaseWFStatus)

-- ============================================================================
-- Common Types (Used Across All Releases)
-- ============================================================================

data Decision = Continue | Wait | Abort
  deriving (Eq, Show, Read, Generic)

instance ToJSON Decision

instance FromJSON Decision

data Mode = Auto | Manual
  deriving (Eq, Show, Read, Generic)

instance ToJSON Mode where
  toJSON Auto = "AUTO"
  toJSON Manual = "MANUAL"

instance FromJSON Mode where
  parseJSON = withText "Mode" $ \t ->
    case T.toUpper t of
      "AUTO" -> pure Auto
      "MANUAL" -> pure Manual
      _ -> pure Auto

-- ============================================================================
-- Release Status (user-facing lifecycle states)
-- ============================================================================

-- | Release lifecycle status
--
-- These are the user-facing states that apply to ALL release types.
-- Platform-specific workflow progress is tracked separately in targetState.
--
-- Lifecycle:
-- Created → InProgress → Completed
--                     → Paused → InProgress (resume)
--                     → Aborting → Aborted / UserAborted
--                     → Reverting → Reverted
-- Created → Discarding → Discarded
data ReleaseStatus
  = -- | Initial state, awaiting approval or scheduling
    Created
  | -- | Actively executing
    InProgress
  | -- | Successfully finished
    Completed
  | -- | System-initiated abort (errors, health check failures, etc.)
    Aborted
  | -- | User-initiated abort
    UserAborted
  | -- | Discarded before execution
    Discarded
  | -- | Transitioning to Discarded (async cleanup)
    Discarding
  | -- | Paused by user, can be resumed
    Paused
  | -- | Abort in progress (transitioning to Aborted/UserAborted)
    Aborting
  | -- | Reverting a completed release back to previous version
    Reverting
  | -- | Revert completed successfully
    Reverted
  | -- | Resuming after pause or transient failure
    Restarting
  | -- | Aborted by decision engine (HS/AB) — distinct from user-initiated abort
    GcltAborted
  deriving (Eq, Show, Read, Generic)

instance ToJSON ReleaseStatus where
  toJSON Created = "CREATED"
  toJSON InProgress = "INPROGRESS"
  toJSON Completed = "COMPLETED"
  toJSON Aborted = "ABORTED"
  toJSON UserAborted = "USER_ABORTED"
  toJSON Discarded = "DISCARDED"
  toJSON Discarding = "DISCARDING"
  toJSON Paused = "PAUSED"
  toJSON Aborting = "ABORTING"
  toJSON Reverting = "REVERTING"
  toJSON Reverted = "REVERTED"
  toJSON Restarting = "RESTARTING"
  toJSON GcltAborted = "GCLT_ABORTED"

instance FromJSON ReleaseStatus where
  parseJSON = withText "ReleaseStatus" $ \t ->
    case T.toUpper t of
      "CREATED" -> pure Created
      "INPROGRESS" -> pure InProgress
      "COMPLETED" -> pure Completed
      "ABORTED" -> pure Aborted
      "USER_ABORTED" -> pure UserAborted
      "USERABORTED" -> pure UserAborted
      "DISCARDED" -> pure Discarded
      "DISCARDING" -> pure Discarding
      "PAUSED" -> pure Paused
      "ABORTING" -> pure Aborting
      "REVERTING" -> pure Reverting
      "REVERTED" -> pure Reverted
      "RESTARTING" -> pure Restarting
      "GCLT_ABORTED" -> pure GcltAborted
      "GCLTABORTED" -> pure GcltAborted
      -- Legacy status mappings
      "RECORDING" -> pure InProgress
      "RECORDED" -> pure Completed
      "VS_APPLIED" -> pure InProgress
      "VSAPPLIED" -> pure InProgress
      _ -> pure Created

-- ============================================================================
-- Status Helpers
-- ============================================================================

isTerminalStatus :: ReleaseStatus -> Bool
isTerminalStatus s = s `elem` [Aborted, UserAborted, GcltAborted, Completed, Discarded, Reverted]

isAbortedStatus :: ReleaseStatus -> Bool
isAbortedStatus s = s `elem` [Aborted, UserAborted, GcltAborted, Aborting]

validateStatusTransition :: ReleaseStatus -> ReleaseStatus -> Bool
validateStatusTransition from to = to `elem` allowed from
  where
    allowed Created = [InProgress, Discarded]
    allowed InProgress = [Aborted, UserAborted, GcltAborted, Completed, Paused, Aborting]
    allowed Aborted = []
    allowed UserAborted = []
    allowed GcltAborted = []
    allowed Completed = []
    allowed Discarded = []
    allowed Paused = [Aborting, UserAborted, InProgress]
    allowed Aborting = [Aborting, Aborted, UserAborted, GcltAborted, Reverting]
    allowed Reverting = [Reverted, UserAborted]
    allowed Reverted = []
    allowed Restarting = [InProgress, Aborted, UserAborted, GcltAborted]
    allowed Discarding = [Discarded]

validateGlobalStatusTransition :: ReleaseStatus -> ReleaseStatus -> Bool
validateGlobalStatusTransition from to = to `elem` allowed from
  where
    allowed Created = [InProgress, Discarded, Discarding]
    allowed InProgress = [Aborted, UserAborted, GcltAborted, Completed, Paused, Aborting, Reverting, Discarded, Restarting]
    allowed Restarting = [InProgress, UserAborted, Aborted, GcltAborted, Reverting, Paused]
    allowed Aborted = []
    allowed UserAborted = []
    allowed GcltAborted = []
    allowed Completed = [Reverting]
    allowed Discarded = []
    allowed Paused = [Aborting, Reverting, UserAborted, InProgress, Restarting]
    allowed Aborting = [Aborting, Discarded, Aborted, UserAborted, GcltAborted, Reverting, Restarting, Completed]
    allowed Reverting = [Reverted, UserAborted, Paused, Restarting]
    allowed Discarding = [Discarded]
    allowed _ = []

-- ============================================================================
-- Release Data Types
-- ============================================================================

data RolloutStep = RolloutStep
  { rolloutPercent :: Int,
    cooloffSeconds :: Int,
    podPercent :: Int
  }
  deriving (Eq, Show, Generic)

instance ToJSON RolloutStep

instance FromJSON RolloutStep

data RolloutHistory = RolloutHistory
  { historyRolloutPercent :: Int,
    historyCooloffSeconds :: Int,
    historyPodsPercent :: Int,
    historyDecision :: Maybe Decision,
    historyDecisionReason :: Maybe Text,
    historyStartedAt :: UTCTime,
    historyCompletedAt :: Maybe UTCTime,
    historyManualOverride :: Bool,
    historyDecisionHs :: Maybe Decision,
    historyDecisionHsReason :: Maybe Text
  }
  deriving (Eq, Show, Generic)

instance ToJSON RolloutHistory

instance FromJSON RolloutHistory

data ReleaseTracker = ReleaseTracker
  { releaseId :: Text,
    -- | App group name (e.g., "Beckn", "rider-app", "BecknSchedulers")
    -- This is the WHAT - which group/product is being released
    appGroup :: Text,
    -- | Alias for product (for backward compatibility)
    service :: Text,
    env :: Text,
    -- | Release category: BackendService, MobileAppAndroid, BackendConfig, etc.
    -- This is the HOW/WHERE - how/where to deploy it
    category :: ReleaseCategory,
    -- | Current release status: Created, InProgress, Completed, Aborted, etc.
    status :: ReleaseStatus,
    -- | Generic workflow stage: Init, Preparing, Deploying, Monitoring, Finalizing, Done
    -- Applies to ALL release categories (K8s, Play Store, App Store, etc.)
    releaseWFStatus :: ReleaseWFStatus,
    mode :: Mode,
    createdBy :: Text,
    approvedBy :: Maybe Text,
    isApproved :: Bool,
    isInfraApproved :: Bool,
    releaseTag :: Maybe Text,
    scheduleTime :: Maybe UTCTime,
    dateCreated :: Maybe UTCTime,
    lastUpdated :: Maybe UTCTime,
    startTime :: Maybe UTCTime,
    endTime :: Maybe UTCTime,
    rolloutStrategy :: [RolloutStep],
    rolloutHistory :: [RolloutHistory],
    -- | Previous version (generic, applies to all release types)
    oldVersion :: Text,
    -- | New version being released (generic, applies to all release types)
    newVersion :: Text,
    info :: Maybe Text,
    description :: Maybe Text,
    changeLog :: Maybe Text,
    metadata :: Maybe Value,
    priority :: Int32,
    globalId :: Maybe Text,
    syncEnabled :: Maybe Text,
    envOverrideData :: Maybe Text,
    slackThreadTs :: Maybe Text,
    releaseContext :: Maybe Value
  }
  deriving (Eq, Show, Generic)

instance ToJSON ReleaseTracker

instance FromJSON ReleaseTracker
