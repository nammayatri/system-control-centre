module Products.Autopilot.Workflow.Types where

import Control.Monad.Except (ExceptT)
import Control.Monad.State.Strict (StateT)
import Core.Utils.FlowMonad (Flow)
import Data.Aeson (Value)
import Products.Autopilot.Types (Decision, ReleaseTracker)
import Products.Autopilot.Types.Target (TargetState)
import Products.Autopilot.Workflow.Recorded (Recorded)

data WorkFlowError
  = DomainError String
  | RetriableError String
  deriving (Eq, Show)

-- | Universal workflow state
--
-- Used by ALL product workflows (K8s, Play Store, App Store, Config, etc.)
data ReleaseState = ReleaseState
  { -- | The release being executed (universal fields)
    releaseTracker :: ReleaseTracker,
    -- | Target platform-specific state
    -- This tracks the state specific to WHERE the product is deployed:
    -- - BackendService/Scheduler/CronJob/Job → K8sState (Kubernetes)
    -- - MobileAppAndroid → PlayStoreState (Play Store)
    -- - MobileAppIOS → AppStoreState (App Store)
    -- - BackendConfig → ConfigState (ConfigMap/Secret)
    targetState :: Maybe TargetState,
    -- | Workflow-specific temporary data (not persisted to DB)
    -- Used for passing data between workflow steps
    workflowMetadata :: Maybe Value
  }
  deriving (Show)

type StateFlow = StateT ReleaseState Flow

type ReleaseWorkFlow = ExceptT WorkFlowError (Recorded ReleaseState Flow)

data StageOutcome = StageSuccess | StageWaiting | StageAbort deriving (Eq, Show)

data MonitoringResult = MonitoringResult
  { decision :: Decision,
    reason :: String,
    hsDecision :: Maybe Decision,
    hsReason :: Maybe String
  }
  deriving (Eq, Show)
