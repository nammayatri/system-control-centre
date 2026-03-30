-- | Configuration target types
--
-- This module contains all types related to configuration-only deployments:
-- - ConfigDeploymentState: State tracking for ConfigMap/Secret updates
-- - BackendConfigWFStatus: Detailed config-specific workflow stages
module NammaAP.Types.Target.Config
  ( -- * Target State
    ConfigDeploymentState (..)
  , emptyConfigState

    -- * Workflow Status
  , BackendConfigWFStatus (..)
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

-- ============================================================================
-- Config Workflow Status
-- ============================================================================

-- | Backend config workflow status (K8s ConfigMap/Secret-specific)
--
-- Tracks ConfigMap/Secret updates and pod restarts.
-- This provides detailed progress within the generic ReleaseWFStatus stages.
data BackendConfigWFStatus
  = BCInit                      -- ^ Validate config changes
  | BCApplyConfigMap            -- ^ Apply ConfigMap updates
  | BCApplySecret               -- ^ Apply Secret updates
  | BCRestartPods               -- ^ Restart affected pods
  | BCMonitorRollout            -- ^ Monitor config propagation
  | BCVerifyConfig              -- ^ Verify config loaded correctly
  | BCDone                      -- ^ Complete
  | BCRevertConfig              -- ^ Revert config changes
  deriving (Eq, Show, Read, Generic, Ord)

instance ToJSON BackendConfigWFStatus
instance FromJSON BackendConfigWFStatus

-- ============================================================================
-- Config Deployment State
-- ============================================================================

-- | Configuration deployment state
--
-- Tracks ConfigMap and Secret updates and rollout status
data ConfigDeploymentState = ConfigDeploymentState
  { categoryWorkflowStatus :: BackendConfigWFStatus
    -- ^ Granular config-specific workflow progress

  , configMapsUpdated :: [Text]
    -- ^ Names of updated ConfigMaps

  , secretsUpdated :: [Text]
    -- ^ Names of updated Secrets

  , podsRestarted :: Bool
    -- ^ Whether affected pods were restarted

  , rolloutComplete :: Bool
    -- ^ Whether config rollout completed across all pods
  } deriving (Eq, Show, Generic)

instance ToJSON ConfigDeploymentState
instance FromJSON ConfigDeploymentState

-- | Empty config deployment state (initial state)
emptyConfigState :: ConfigDeploymentState
emptyConfigState = ConfigDeploymentState
  { categoryWorkflowStatus = BCInit
  , configMapsUpdated = []
  , secretsUpdated = []
  , podsRestarted = False
  , rolloutComplete = False
  }
