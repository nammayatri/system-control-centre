-- | Shared release category types - re-exported from Autopilot workflow types
module Shared.Types.ReleaseCategory
  ( ReleaseCategory (..),
    getDefaultDeploymentTarget,
    migrateTrackerTypeToCategory,
    ReleaseWFStatus (..),
    migrateWorkflowStatusToReleaseWFStatus,
  )
where

import Products.Autopilot.Types.Workflow
