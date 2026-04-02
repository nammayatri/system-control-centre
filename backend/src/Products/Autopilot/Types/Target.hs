-- | Target platform state types
--
-- This module provides the top-level TargetState discriminated union
-- that contains target-platform-specific state.
--
-- "Target" refers to WHERE/HOW the release is deployed (the execution platform):
-- - K8sState: For Kubernetes deployments
-- - PlayStoreState: For Google Play Store releases
-- - AppStoreState: For Apple App Store releases
-- - ConfigState: For configuration-only deployments
--
-- This module re-exports all target-specific types from submodules.
module Products.Autopilot.Types.Target
  ( -- * Top-level Target State
    TargetState (..),

    -- * Kubernetes Types
    module Products.Autopilot.Types.Target.Kubernetes,

    -- * Play Store Types
    module Products.Autopilot.Types.Target.PlayStore,

    -- * App Store Types
    module Products.Autopilot.Types.Target.AppStore,

    -- * Config Types
    module Products.Autopilot.Types.Target.Config,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import GHC.Generics (Generic)
-- Import and re-export target-specific modules

import Products.Autopilot.Types.Target.AppStore
import Products.Autopilot.Types.Target.Config
import Products.Autopilot.Types.Target.Kubernetes
import Products.Autopilot.Types.Target.PlayStore

-- ============================================================================
-- Top-level Target State
-- ============================================================================

-- | Target state (discriminated by target platform)
--
-- This is a discriminated union containing state specific to each deployment target.
-- The TargetState variant determines which platform-specific fields are available.
--
-- Mapping (ReleaseCategory → TargetState):
-- - BackendService/Scheduler/CronJob/Job → K8sState
-- - MobileAppAndroid → PlayStoreState
-- - MobileAppIOS → AppStoreState
-- - BackendConfig → ConfigState
data TargetState
  = -- | Kubernetes deployment state (for backend services)
    K8sState K8sDeploymentState
  | -- | Google Play Store deployment state (for Android apps)
    PlayStoreState PlayStoreDeploymentState
  | -- | Apple App Store deployment state (for iOS apps)
    AppStoreState AppStoreDeploymentState
  | -- | Configuration deployment state (for config-only releases)
    ConfigState ConfigDeploymentState
  deriving (Eq, Show, Generic)

instance ToJSON TargetState

instance FromJSON TargetState
