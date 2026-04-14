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

    -- * Service State (per-service lifecycle, not per-release)
    ServiceState (..),
    isServiceModifiable,
    serviceStateText,
    parseServiceStateText,

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

{- | Decision-engine verdict, merged across experiments via 'decisionPriority'
(lower = wins). @WaitForMoreIteration@ is distinct from @Wait@: the former
means the engine lacks enough samples to score yet, the latter means it's
still computing. Most responses collapse to @Wait@.
-}
data Decision = WaitForMoreIteration | Continue | Wait | Abort
    deriving (Eq, Show, Read, Generic)

instance ToJSON Decision

instance FromJSON Decision

-- | Lower number = higher priority in multi-experiment merge.
decisionPriority :: Decision -> Int
decisionPriority Abort = 0
decisionPriority Wait = 1
decisionPriority WaitForMoreIteration = 2
decisionPriority Continue = 3

data Mode = AUTO | MANUAL
    deriving (Eq, Show, Read, Generic)

instance ToJSON Mode

instance FromJSON Mode

{- | User-facing release lifecycle status (applies to all categories).
Platform-specific workflow progress lives in 'targetState'.

Backend/config:
@CREATED → INPROGRESS → COMPLETED | PAUSED | ABORTING → (USER_)ABORTED | REVERTING → REVERTED@
@CREATED → DISCARDING → DISCARDED@

VSEdit (same table, category='VSEdit'):
@CREATED → LOCKED → APPLIED → COMPLETED | UNLOCKED@
-}
data ReleaseStatus
    = CREATED
    | INPROGRESS
    | COMPLETED
    | ABORTED
    | USER_ABORTED
    | DISCARDED
    | DISCARDING
    | PAUSED
    | ABORTING
    | REVERTING
    | REVERTED
    | RESTARTING
    | -- | Aborted by decision engine (HS/AB), distinct from user abort.
      GCLT_ABORTED
    | LOCKED
    | UNLOCKED
    | APPLIED
    deriving (Eq, Show, Read, Generic, Enum, Bounded)

instance ToJSON ReleaseStatus

instance FromJSON ReleaseStatus

-- | Canonical text form — identical to constructor and JSON wire format.
releaseStatusText :: ReleaseStatus -> Text
releaseStatusText = T.pack . show

-- | Case-insensitive text → 'ReleaseStatus'. Unknown values default to 'CREATED'.
parseReleaseStatusText :: Text -> ReleaseStatus
parseReleaseStatusText t =
    fromMaybe CREATED (lookup (T.toUpper t) releaseStatusLookup)
  where
    releaseStatusLookup :: [(Text, ReleaseStatus)]
    releaseStatusLookup =
        [ (T.toUpper (releaseStatusText s), s)
        | s <- [minBound .. maxBound :: ReleaseStatus]
        ]

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
    allowed LOCKED = [APPLIED, UNLOCKED, DISCARDED]
    allowed APPLIED = [COMPLETED, UNLOCKED]
    allowed UNLOCKED = []
    allowed REVERTED = []

data RolloutStep = RolloutStep
    { rolloutPercent :: Int
    -- ^ Traffic percentage shifted to the new version at this step (0-100).
    , cooloffMinutes :: Int
    -- ^ Cooloff duration in minutes (workflow multiplies by 60 before use).
    , podCount :: Int
    -- ^ Absolute pod count (not a percentage) for the new deployment at
    -- this step; used as operatorFloor input to scaleNewDeploymentForStage.
    }
    deriving (Eq, Show, Generic)

instance ToJSON RolloutStep

instance FromJSON RolloutStep

data RolloutHistory = RolloutHistory
    { historyRolloutPercent :: Int
    , historyCooloffMinutes :: Int
    , historyPodsCount :: Int
    -- ^ Snapshot of 'RolloutStep.podCount' at the time the step ran.
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
    -- ^ App group being released (e.g. "Beckn", "rider-app").
    , service :: Text
    , env :: Text
    , category :: ReleaseCategory
    , status :: ReleaseStatus
    , releaseWFStatus :: ReleaseWFStatus
    -- ^ Generic workflow stage (applies across K8s, mobile, etc.).
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
    , newVersion :: Text
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

{- | Per-service lifecycle state (distinct from per-release ReleaseStatus).
Used to track whether a service is currently being modified,
preventing concurrent modifications via a DB-level guard.

CREATING   → Service being deployed for first time (new deployment)
MODIFYING  → Service currently being rolled out/updated
AVAILABLE  → Service stable, ready for new operations
TERMINATING→ Service being decommissioned
TERMINATED → Service has been removed from infrastructure
-}
data ServiceState
    = CREATING
    | MODIFYING
    | AVAILABLE
    | TERMINATING
    | TERMINATED
    deriving (Eq, Show, Read, Generic, Enum, Bounded)

instance ToJSON ServiceState

instance FromJSON ServiceState

-- | Text representation for DB storage.
serviceStateText :: ServiceState -> Text
serviceStateText = T.pack . show

-- | Parse text from DB with case-insensitive matching.
parseServiceStateText :: Text -> Maybe ServiceState
parseServiceStateText t =
    lookup (T.toUpper t) serviceStateLookup
  where
    serviceStateLookup :: [(Text, ServiceState)]
    serviceStateLookup =
        [ (T.toUpper (serviceStateText s), s)
        | s <- [minBound .. maxBound :: ServiceState]
        ]

{- | Can this service state accept a new modification?
Returns False if service is already in a mutable state.
-}
isServiceModifiable :: ServiceState -> Bool
isServiceModifiable AVAILABLE = True
isServiceModifiable TERMINATED = True
isServiceModifiable _ = False
