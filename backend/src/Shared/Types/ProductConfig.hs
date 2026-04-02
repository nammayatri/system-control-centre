-- | Shared DeploymentConfig type - re-exported from Schema
-- (Previously ProductConfig, now unified as DeploymentConfig)
module Shared.Types.ProductConfig
  ( DeploymentConfigT (..),
    DeploymentConfig,
  )
where

import Shared.Types.Storage.Schema (DeploymentConfig, DeploymentConfigT (..))
