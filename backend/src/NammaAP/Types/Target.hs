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
module NammaAP.Types.Target
  ( -- * Top-level Target State
    TargetState (..)

    -- * Kubernetes Types
  , module NammaAP.Types.Target.Kubernetes

    -- * Play Store Types
  , module NammaAP.Types.Target.PlayStore

    -- * App Store Types
  , module NammaAP.Types.Target.AppStore

    -- * Config Types
  , module NammaAP.Types.Target.Config
  ) where

import Data.Aeson (FromJSON, ToJSON)
import GHC.Generics (Generic)

-- Import and re-export target-specific modules
import NammaAP.Types.Target.Kubernetes
import NammaAP.Types.Target.PlayStore
import NammaAP.Types.Target.AppStore
import NammaAP.Types.Target.Config

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
  = K8sState K8sDeploymentState
    -- ^ Kubernetes deployment state (for backend services)

  | PlayStoreState PlayStoreDeploymentState
    -- ^ Google Play Store deployment state (for Android apps)

  | AppStoreState AppStoreDeploymentState
    -- ^ Apple App Store deployment state (for iOS apps)

  | ConfigState ConfigDeploymentState
    -- ^ Configuration deployment state (for config-only releases)

  deriving (Eq, Show, Generic)

instance ToJSON TargetState
instance FromJSON TargetState
