module NammaAP.Workflow.Types where

import Control.Monad.Except (ExceptT)
import Control.Monad.State.Strict (StateT)
import Data.Aeson (Value)
import NammaAP.Utils.FlowMonad (Flow)
import NammaAP.Types (Decision, ReleaseTracker)
import NammaAP.Types.Target (TargetState)
import NammaAP.Workflow.Recorded (Recorded)

data WorkFlowError
  = DomainError String
  | RetriableError String
  deriving (Eq, Show)

-- | Universal workflow state
--
-- Used by ALL product workflows (K8s, Play Store, App Store, Config, etc.)
data ReleaseState = ReleaseState
  { releaseTracker :: ReleaseTracker
    -- ^ The release being executed (universal fields)

  , targetState :: Maybe TargetState
    -- ^ Target platform-specific state
    -- This tracks the state specific to WHERE the product is deployed:
    -- - BackendService/Scheduler/CronJob/Job → K8sState (Kubernetes)
    -- - MobileAppAndroid → PlayStoreState (Play Store)
    -- - MobileAppIOS → AppStoreState (App Store)
    -- - BackendConfig → ConfigState (ConfigMap/Secret)

  , workflowMetadata :: Maybe Value
    -- ^ Workflow-specific temporary data (not persisted to DB)
    -- Used for passing data between workflow steps
  } deriving (Show)

type StateFlow = StateT ReleaseState Flow
type ReleaseWorkFlow = ExceptT WorkFlowError (Recorded ReleaseState Flow)

data StageOutcome = StageSuccess | StageWaiting | StageAbort deriving (Eq, Show)

data MonitoringResult = MonitoringResult
  { decision :: Decision
  , reason :: String
  , hsDecision :: Maybe Decision
  , hsReason :: Maybe String
  } deriving (Eq, Show)
