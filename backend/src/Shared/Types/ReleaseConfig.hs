-- | Shared DeploymentConfig type - re-exported from Schema
-- (Previously ReleaseConfig, now unified as DeploymentConfig)
module Shared.Types.ReleaseConfig (
    DeploymentConfigT (..),
    DeploymentConfig,
)
where

import Shared.Types.Storage.Schema (DeploymentConfig, DeploymentConfigT (..))
