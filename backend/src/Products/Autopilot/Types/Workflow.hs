{- | Top-level workflow types

This module contains the high-level types for release workflows:
- ReleaseCategory: What type of release (BackendService, BackendScheduler, BackendConfig, VSEdit)
- ReleaseWFStatus: Generic workflow stages (INIT, DEPLOYING, MONITORING, DONE, etc.)

These types are deployment-target agnostic and apply to ALL releases.

Note: BackendCronJob, BackendJob, MobileAppAndroid, MobileAppIOS, WebApplication,
and Infrastructure constructors were removed because the corresponding workflows
are not currently in use. They will be re-added when those products are needed.
The four kept categories (BackendService, BackendScheduler, BackendConfig, VSEdit)
each have a working workflow / action handler in 'Products.Autopilot.Workflow.*'
or 'Products.Autopilot.Actions.*'.
-}
module Products.Autopilot.Types.Workflow (
    -- * Release Category
    ReleaseCategory (..),
    getDefaultDeploymentTarget,

    -- * Generic Workflow Stages
    ReleaseWFStatus (..),
)
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

-- ============================================================================
-- Release Category
-- ============================================================================

{- | Release category - categorizes the type of release

This determines:
- Which deployment workflow to use
- What DeploymentState type to create (K8sState or ConfigState)
- Which deployment backend/API to interact with

Terminology:
- product (field) = Service/app name (e.g., "Beckn")
- category (field) = ReleaseCategory (BackendService, BackendScheduler,
  BackendConfig, VSEdit)
-}
data ReleaseCategory
    = -- | Backend microservices (REST APIs, gRPC services)
      BackendService
    | -- | Backend scheduled jobs (run periodically, no VS/DR)
      BackendScheduler
    | -- | Configuration updates (ConfigMaps, Secrets) — managed via
      --   'Products.Autopilot.Actions.ConfigMap' + 'BackendConfigWorkflow'
      BackendConfig
    | -- | VirtualService edits (VS lock/unlock/apply/revert) — managed via
      --   'Products.Autopilot.Actions.VSEdit'
      VSEdit
    deriving (Eq, Show, Read, Generic, Ord)

instance ToJSON ReleaseCategory

instance FromJSON ReleaseCategory

-- | Get the default deployment target for a release category
getDefaultDeploymentTarget :: ReleaseCategory -> Text
getDefaultDeploymentTarget BackendService = "kubernetes"
getDefaultDeploymentTarget BackendScheduler = "kubernetes"
getDefaultDeploymentTarget BackendConfig = "kubernetes-config"
getDefaultDeploymentTarget VSEdit = "kubernetes"

-- ============================================================================
-- Generic Workflow Stages
-- ============================================================================

{- | Generic release workflow status

These stages apply to ALL release categories (backend services, mobile apps, configs, etc.)
Category-specific sub-stages are tracked in the targetState field.

Workflow progression:
INIT → PREPARING → DEPLOYING → MONITORING → FINALIZING → DONE
                                          ↓
                                     ROLLING_BACK (on error)
-}
data ReleaseWFStatus
    = -- | Validation and precondition checks
      -- Examples:
      -- - K8s: Validate manifests, check cluster capacity
      -- - Play Store: Validate APK, check signing keys
      -- - App Store: Validate bundle, check certificates
      INIT
    | -- | Pre-deployment preparation
      -- Examples:
      -- - K8s: Create namespace, apply ConfigMaps
      -- - Play Store: Upload APK to Play Console
      -- - App Store: Upload bundle to TestFlight
      PREPARING
    | -- | Active deployment/rollout
      -- Examples:
      -- - K8s: Create Deployment, apply VirtualService, progressive traffic shift
      -- - Play Store: Staged rollout (0% → 25% → 50% → 100%)
      -- - App Store: Phased release, TestFlight distribution
      DEPLOYING
    | -- | Post-deployment monitoring and health checks
      -- Examples:
      -- - K8s: Monitor pod health, latency, error rates
      -- - Play Store: Monitor crash rate, ANR rate, user ratings
      -- - App Store: Monitor crash reports, TestFlight feedback
      MONITORING
    | -- | Cleanup and finalization
      -- Examples:
      -- - K8s: Scale down old deployment, cleanup old resources
      -- - Play Store: Promote to full release, cleanup draft versions
      -- - App Store: Remove TestFlight build, archive old versions
      FINALIZING
    | -- | Successfully completed
      DONE
    | -- | Rollback in progress (error state)
      -- Examples:
      -- - K8s: Revert traffic to old version, scale down new deployment
      -- - Play Store: Halt rollout, revert to previous version
      -- - App Store: Halt phased release, submit emergency rollback
      ROLLING_BACK
    deriving (Eq, Show, Read, Generic, Ord)

instance ToJSON ReleaseWFStatus

instance FromJSON ReleaseWFStatus
