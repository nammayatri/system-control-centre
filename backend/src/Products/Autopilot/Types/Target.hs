{- | Target platform state types

This module provides the top-level TargetState discriminated union
that contains target-platform-specific state.

"Target" refers to WHERE/HOW the release is deployed (the execution platform).
Currently two targets are supported:

- K8sState     — Kubernetes deployments (BackendService, BackendScheduler)
- ConfigState  — Kubernetes ConfigMap / Secret applies (BackendConfig)

The Play Store / App Store variants were removed when the corresponding
release categories (MobileAppAndroid / MobileAppIOS) were retired — they will
be re-added when those products are needed.

This module re-exports all target-specific types from submodules.
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

-- Import and re-export target-specific modules

import Products.Autopilot.Types.Target.Config
import Products.Autopilot.Types.Target.Kubernetes

-- ============================================================================
-- Top-level Target State
-- ============================================================================

{- | Target state (discriminated by target platform)

This is a discriminated union containing state specific to each deployment target.
The TargetState variant determines which platform-specific fields are available.

Mapping (ReleaseCategory → TargetState):
- BackendService / BackendScheduler → K8sState
- BackendConfig                     → ConfigState
- VSEdit                            → K8sState (handled out-of-band, but uses K8s context)
-}
data TargetState
    = -- | Kubernetes deployment state (for backend services + schedulers)
      K8sState K8sDeploymentState
    | -- | Configuration deployment state (for ConfigMap / Secret releases)
      ConfigState ConfigDeploymentState
    deriving (Eq, Show, Generic)

instance ToJSON TargetState

instance FromJSON TargetState
