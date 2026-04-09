-- | Types for ConfigMap/Secret-only deployments (BackendConfig category).
module Products.Autopilot.Types.Target.Config (
    -- * Target State
    ConfigDeploymentState (..),
    emptyConfigState,

    -- * Workflow Status
    BackendConfigWFStatus (..),
)
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

-- | Detailed sub-stages inside the generic @ReleaseWFStatus@ for BackendConfig.
data BackendConfigWFStatus
    = BCInit
    | BCApplyConfigMap
    | BCApplySecret
    | BCRestartPods
    | BCMonitorRollout
    | BCVerifyConfig
    | BCDone
    | BCRevertConfig
    deriving (Eq, Show, Read, Generic, Ord)

instance ToJSON BackendConfigWFStatus

instance FromJSON BackendConfigWFStatus

data ConfigDeploymentState = ConfigDeploymentState
    { categoryWorkflowStatus :: BackendConfigWFStatus
    , configMapsUpdated :: [Text]
    , secretsUpdated :: [Text]
    , podsRestarted :: Bool
    , rolloutComplete :: Bool
    }
    deriving (Eq, Show, Generic)

instance ToJSON ConfigDeploymentState

instance FromJSON ConfigDeploymentState

emptyConfigState :: ConfigDeploymentState
emptyConfigState =
    ConfigDeploymentState
        { categoryWorkflowStatus = BCInit
        , configMapsUpdated = []
        , secretsUpdated = []
        , podsRestarted = False
        , rolloutComplete = False
        }
