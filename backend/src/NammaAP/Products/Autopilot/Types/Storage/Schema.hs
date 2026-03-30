{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}

-- | Autopilot storage schema
--
-- This module re-exports all shared table schemas from NammaAP.Shared.Types.Storage.Schema.
-- The configmap_tracker table has been removed (merged into release_tracker with category='BackendConfig').
module NammaAP.Products.Autopilot.Types.Storage.Schema
  ( -- * Re-export all shared schemas
    module NammaAP.Shared.Types.Storage.Schema
  ) where

import NammaAP.Shared.Types.Storage.Schema
