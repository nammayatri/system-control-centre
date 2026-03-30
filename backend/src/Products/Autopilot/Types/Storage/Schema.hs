{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}

{- | Autopilot storage schema

This module re-exports all shared table schemas from Shared.Types.Storage.Schema.
The configmap_tracker table has been removed (merged into release_tracker with category='BackendConfig').
-}
module Products.Autopilot.Types.Storage.Schema (
    -- * Re-export all shared schemas
    module Shared.Types.Storage.Schema,
)
where

import Shared.Types.Storage.Schema
