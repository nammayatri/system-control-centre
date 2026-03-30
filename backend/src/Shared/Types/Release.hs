{- | Shared release types - re-exported from Autopilot types

This module re-exports the core release types so that shared query modules
and other products can import from Shared.Types.Release without
depending on Products.Autopilot directly.
-}
module Shared.Types.Release (
    -- * Release Types
    RolloutStep (..),
    RolloutHistory (..),
    ReleaseTracker (..),

    -- * Release Status
    ReleaseStatus (..),
    isTerminalStatus,
    isAbortedStatus,
    validateStatusTransition,
    validateGlobalStatusTransition,

    -- * Common Enums
    Decision (..),
    Mode (..),
)
where

import Products.Autopilot.Types.Release
