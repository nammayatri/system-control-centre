-- | Shared release category types - re-exported from Autopilot workflow types
module NammaAP.Shared.Types.ReleaseCategory
  ( ReleaseCategory (..)
  , getDefaultDeploymentTarget
  , migrateTrackerTypeToCategory
  , ReleaseWFStatus (..)
  , migrateWorkflowStatusToReleaseWFStatus
  ) where

import NammaAP.Products.Autopilot.Types.Workflow
