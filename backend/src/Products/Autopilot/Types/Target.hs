{- | 'TargetState' is a discriminated union over deployment platforms
('K8sState' for K8s deployments, 'ConfigState' for ConfigMap/Secret
applies). Re-exports the target-specific submodules.
-}
module Products.Autopilot.Types.Target (
    -- * Top-level Target State
    TargetState (..),

    -- * Kubernetes Types
    module Products.Autopilot.Types.Target.Kubernetes,

    -- * Config Types
    module Products.Autopilot.Types.Target.Config,
)
where

import Data.Aeson (FromJSON, ToJSON)
import GHC.Generics (Generic)

import Products.Autopilot.Types.Target.Config
import Products.Autopilot.Types.Target.Kubernetes

{- | Category → variant:
BackendService/Scheduler/VSEdit → 'K8sState'; BackendConfig → 'ConfigState'.
-}
data TargetState
    = K8sState K8sDeploymentState
    | ConfigState ConfigDeploymentState
    deriving (Eq, Show, Generic)

instance ToJSON TargetState

instance FromJSON TargetState
