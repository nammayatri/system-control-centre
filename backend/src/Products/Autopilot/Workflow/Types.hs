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

{- | Workflow state shared by all Autopilot release categories.
  'targetState' carries the platform-specific view (K8s, Config, ...).
-}
data ReleaseState = ReleaseState
    { releaseTracker :: ReleaseTracker
    , targetState :: Maybe TargetState
    , workflowMetadata :: Maybe Value
    -- ^ Transient per-tick scratch space for passing data between stages;
    --   not persisted to DB.
    }
    deriving (Show)

type StateFlow = StateT ReleaseState Flow

type ReleaseWorkFlow = ExceptT WorkFlowError (Recorded ReleaseState Flow)
