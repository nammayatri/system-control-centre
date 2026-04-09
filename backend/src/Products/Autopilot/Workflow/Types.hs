module Products.Autopilot.Workflow.Types (
    -- * Re-exported from Core.Workflow.Types
    WorkFlowError (..),

    -- * Autopilot-specific workflow types
    ReleaseState (..),
    StateFlow,
    ReleaseWorkFlow,
) where

import Control.Monad.Except (ExceptT)
import Control.Monad.State.Strict (StateT)
import Core.Environment (Flow)
import Core.Workflow.Types (WorkFlowError (..))
import Data.Aeson (Value)
import Products.Autopilot.Types (ReleaseTracker)
import Products.Autopilot.Types.Target (TargetState)
import Products.Autopilot.Workflow.Recorded (Recorded)

{- | Universal workflow state

Used by ALL product workflows. Currently the supported targets are:

* BackendService / BackendScheduler → 'K8sState' (Kubernetes)
* BackendConfig                     → 'ConfigState' (ConfigMap / Secret)
* VSEdit                            → 'K8sState' (handled out-of-band)

The Play Store / App Store variants were removed when the corresponding
release categories were retired — they will be re-added when those products
are needed.
-}
data ReleaseState = ReleaseState
    { releaseTracker :: ReleaseTracker
    -- ^ The release being executed (universal fields)
    , targetState :: Maybe TargetState
    -- ^ Target platform-specific state
    , workflowMetadata :: Maybe Value
    -- ^ Workflow-specific temporary data (not persisted to DB)
    -- Used for passing data between workflow steps
    }
    deriving (Show)

type StateFlow = StateT ReleaseState Flow

type ReleaseWorkFlow = ExceptT WorkFlowError (Recorded ReleaseState Flow)

-- Note: 'StageOutcome' used to be defined here but was never used by any
-- production code (it was a stalled relic of an earlier stage refactor).
-- The canonical 'StageOutcome' now lives in 'Core.Workflow.Stage' and is
-- used by every 'Stage s' in every 'WorkflowSpec s'.
