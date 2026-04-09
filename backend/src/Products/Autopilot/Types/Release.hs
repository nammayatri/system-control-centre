module Products.Autopilot.Types.Release (
    -- * Release Types
    RolloutStep (..),
    RolloutHistory (..),
    ReleaseTracker (..),

    -- * Release Status
    ReleaseStatus (..),
    isTerminalStatus,
    isAbortedStatus,
    validateStatusTransition,
    validateGlobalStatusTransition,
    releaseStatusText,
    parseReleaseStatusText,

    -- * Common Enums
    Decision (..),
    decisionPriority,
    Mode (..),
)
where

import Data.Aeson (FromJSON, ToJSON, Value)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime)
import GHC.Generics (Generic)
import GHC.Int (Int32)
import Products.Autopilot.Types.Workflow (ReleaseCategory, ReleaseWFStatus)

-- ============================================================================
-- Common Types (Used Across All Releases)
-- ============================================================================

{- | Decision-engine verdict. Julia parity (decision/runner.jl ABDecision):
five variants with priority ordering used to merge multi-experiment results.

Priority (lower = wins in merge):
  WaitForMoreIteration = 0  -- engine wants more samples; takes precedence over a Continue
  Continue             = 1  -- safe to advance
  Wait                 = 2  -- engine still computing, hold cooloff
  Abort                = 3  -- rollback, highest priority

@WaitForMoreIteration@ is distinct from @Wait@: the former specifically
signals that the engine has insufficient data to score (sample volume
floor not yet hit), and the workflow should poll again on the next
cooloff iteration WITHOUT advancing. Most engine responses don't
distinguish — they collapse to plain @Wait@ — but Julia engines that
report verdict code @2@ vs @3@ can be modeled distinctly.
-}
data Decision = WaitForMoreIteration | Continue | Wait | Abort
    deriving (Eq, Show, Read, Generic)

instance ToJSON Decision

instance FromJSON Decision

{- | Lower number = higher priority in multi-experiment merge.
Julia parity (decision/runner.jl ABDecision priority field).
-}
decisionPriority :: Decision -> Int
decisionPriority Abort = 0
decisionPriority Wait = 1
decisionPriority WaitForMoreIteration = 2
decisionPriority Continue = 3

data Mode = AUTO | MANUAL
    deriving (Eq, Show, Read, Generic)

instance ToJSON Mode

instance FromJSON Mode

-- ============================================================================
-- Release Status (user-facing lifecycle states)
-- ============================================================================

{- | Release lifecycle status

These are the user-facing states that apply to ALL release types.
Platform-specific workflow progress is tracked separately in targetState.

Lifecycle (backend/config releases):
CREATED → INPROGRESS → COMPLETED
                    → PAUSED → INPROGRESS (resume)
                    → ABORTING → ABORTED / USER_ABORTED / GCLT_ABORTED
                    → REVERTING → REVERTED
CREATED → DISCARDING → DISCARDED

VSEdit states (same table, category='VSEdit'):
CREATED → LOCKED → APPLIED → COMPLETED
                → UNLOCKED (abort / expiry / discard)
-}
data ReleaseStatus
    = -- | Initial state, awaiting approval or scheduling
      CREATED
    | -- | Actively executing
      INPROGRESS
    | -- | Successfully finished
      COMPLETED
    | -- | System-initiated abort (errors, health check failures, etc.)
      ABORTED
    | -- | User-initiated abort
      USER_ABORTED
    | -- | DISCARDED before execution
      DISCARDED
    | -- | Transitioning to DISCARDED (async cleanup)
      DISCARDING
    | -- | PAUSED by user, can be resumed
      PAUSED
    | -- | Abort in progress (transitioning to ABORTED/USER_ABORTED)
      ABORTING
    | -- | REVERTING a completed release back to previous version
      REVERTING
    | -- | Revert completed successfully
      REVERTED
    | -- | Resuming after pause or transient failure
      RESTARTING
    | -- | ABORTED by decision engine (HS/AB) — distinct from user-initiated abort
      GCLT_ABORTED
    | -- | VSEdit: lock held on target virtual service
      LOCKED
    | -- | VSEdit: lock released (abort/expiry/discard)
      UNLOCKED
    | -- | VSEdit: edit applied to virtual service
      APPLIED
    deriving (Eq, Show, Read, Generic, Enum, Bounded)

instance ToJSON ReleaseStatus

instance FromJSON ReleaseStatus

{- | Canonical text form of a 'ReleaseStatus' — identical to the constructor
name and to the JSON wire format (Aeson default @allNullaryToStringTag@).
Single source of truth: both the DB layer and the JSON layer agree by
construction, no lookup tables to drift.
-}
releaseStatusText :: ReleaseStatus -> Text
releaseStatusText = T.pack . show

{- | Case-insensitive text → 'ReleaseStatus'. Derived from 'Enum'+'Bounded',
so adding a new constructor to 'ReleaseStatus' is the ONLY edit needed.
Unknown values default to 'CREATED'.
-}
parseReleaseStatusText :: Text -> ReleaseStatus
parseReleaseStatusText t =
    fromMaybe CREATED (lookup (T.toUpper t) releaseStatusLookup)
  where
    releaseStatusLookup :: [(Text, ReleaseStatus)]
    releaseStatusLookup =
        [ (T.toUpper (releaseStatusText s), s)
        | s <- [minBound .. maxBound :: ReleaseStatus]
        ]

-- ============================================================================
-- Status Helpers
-- ============================================================================

isTerminalStatus :: ReleaseStatus -> Bool
isTerminalStatus s = s `elem` [ABORTED, USER_ABORTED, GCLT_ABORTED, COMPLETED, DISCARDED, REVERTED, UNLOCKED]

isAbortedStatus :: ReleaseStatus -> Bool
isAbortedStatus s = s `elem` [ABORTED, USER_ABORTED, GCLT_ABORTED, ABORTING]

validateStatusTransition :: ReleaseStatus -> ReleaseStatus -> Bool
validateStatusTransition from to = to `elem` allowed from
  where
    allowed CREATED = [INPROGRESS, DISCARDED, LOCKED]
    allowed INPROGRESS = [ABORTED, USER_ABORTED, GCLT_ABORTED, COMPLETED, PAUSED, ABORTING]
    allowed ABORTED = []
    allowed USER_ABORTED = []
    allowed GCLT_ABORTED = []
    allowed COMPLETED = []
    allowed DISCARDED = []
    allowed PAUSED = [ABORTING, USER_ABORTED, INPROGRESS]
    allowed ABORTING = [ABORTING, ABORTED, USER_ABORTED, GCLT_ABORTED, REVERTING]
    allowed REVERTING = [REVERTED, USER_ABORTED]
    allowed REVERTED = []
    allowed RESTARTING = [INPROGRESS, ABORTED, USER_ABORTED, GCLT_ABORTED]
    allowed DISCARDING = [DISCARDED]
    -- VSEdit transitions
    allowed LOCKED = [APPLIED, UNLOCKED, DISCARDED]
    allowed APPLIED = [COMPLETED, UNLOCKED]
    allowed UNLOCKED = []

validateGlobalStatusTransition :: ReleaseStatus -> ReleaseStatus -> Bool
validateGlobalStatusTransition from to = to `elem` allowed from
  where
    allowed CREATED = [INPROGRESS, DISCARDED, DISCARDING, LOCKED]
    allowed INPROGRESS = [ABORTED, USER_ABORTED, GCLT_ABORTED, COMPLETED, PAUSED, ABORTING, REVERTING, DISCARDED, RESTARTING]
    allowed RESTARTING = [INPROGRESS, USER_ABORTED, ABORTED, GCLT_ABORTED, REVERTING, PAUSED]
    allowed ABORTED = []
    allowed USER_ABORTED = []
    allowed GCLT_ABORTED = []
    allowed COMPLETED = [REVERTING]
    allowed DISCARDED = []
    allowed PAUSED = [ABORTING, REVERTING, USER_ABORTED, INPROGRESS, RESTARTING]
    allowed ABORTING = [ABORTING, DISCARDED, ABORTED, USER_ABORTED, GCLT_ABORTED, REVERTING, RESTARTING, COMPLETED]
    allowed REVERTING = [REVERTED, USER_ABORTED, PAUSED, RESTARTING]
    allowed DISCARDING = [DISCARDED]
    -- VSEdit transitions
    allowed LOCKED = [APPLIED, UNLOCKED, DISCARDED]
    allowed APPLIED = [COMPLETED, UNLOCKED]
    allowed UNLOCKED = []
    allowed REVERTED = []

-- ============================================================================
-- Release Data Types
-- ============================================================================

data RolloutStep = RolloutStep
    { rolloutPercent :: Int
    , cooloffMinutes :: Int
    -- ^ Cooloff duration in MINUTES. Matches Julia production semantics:
    -- the workflow multiplies by 60 before use.
    , podPercent :: Int
    }
    deriving (Eq, Show, Generic)

instance ToJSON RolloutStep

instance FromJSON RolloutStep

data RolloutHistory = RolloutHistory
    { historyRolloutPercent :: Int
    , historyCooloffMinutes :: Int
    -- ^ Cooloff duration in minutes (same unit as 'cooloffMinutes').
    , historyPodsPercent :: Int
    , historyDecision :: Maybe Decision
    , historyDecisionReason :: Maybe Text
    , historyStartedAt :: UTCTime
    , historyCompletedAt :: Maybe UTCTime
    , historyManualOverride :: Bool
    , historyDecisionHs :: Maybe Decision
    , historyDecisionHsReason :: Maybe Text
    }
    deriving (Eq, Show, Generic)

instance ToJSON RolloutHistory

instance FromJSON RolloutHistory

data ReleaseTracker = ReleaseTracker
    { releaseId :: Text
    , appGroup :: Text
    -- ^ App group name (e.g., "Beckn", "rider-app", "BecknSchedulers")
    -- This is the WHAT - which group/product is being released
    , service :: Text
    -- ^ Alias for product (for backward compatibility)
    , env :: Text
    , category :: ReleaseCategory
    -- ^ Release category: BackendService, MobileAppAndroid, BackendConfig, etc.
    -- This is the HOW/WHERE - how/where to deploy it
    , status :: ReleaseStatus
    -- ^ Current release status: CREATED, INPROGRESS, COMPLETED, ABORTED, etc.
    , releaseWFStatus :: ReleaseWFStatus
    -- ^ Generic workflow stage: INIT, PREPARING, DEPLOYING, MONITORING, FINALIZING, DONE
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
    , syncEnabled :: Maybe Text
    , envOverrideData :: Maybe Text
    , slackThreadTs :: Maybe Text
    , releaseContext :: Maybe Value
    }
    deriving (Eq, Show, Generic)

instance ToJSON ReleaseTracker

instance FromJSON ReleaseTracker
