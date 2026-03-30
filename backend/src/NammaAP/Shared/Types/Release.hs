-- | Shared release types - re-exported from Autopilot types
--
-- This module re-exports the core release types so that shared query modules
-- and other products can import from NammaAP.Shared.Types.Release without
-- depending on Products.Autopilot directly.
module NammaAP.Shared.Types.Release
  ( -- * Release Types
    RolloutStep (..)
  , RolloutHistory (..)
  , ReleaseTracker (..)

  -- * Release Status
  , ReleaseStatus (..)
  , isTerminalStatus
  , isAbortedStatus
  , validateStatusTransition
  , validateGlobalStatusTransition

  -- * Common Enums
  , Decision (..)
  , Mode (..)
  ) where

import NammaAP.Products.Autopilot.Types.Release
