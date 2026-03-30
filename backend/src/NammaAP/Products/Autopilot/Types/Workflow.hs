-- | Top-level workflow types
--
-- This module contains the high-level types for release workflows:
-- - ReleaseCategory: What type of release (BackendService, MobileAppAndroid, etc.)
-- - ReleaseWFStatus: Generic workflow stages (Init, Deploying, Monitoring, Done, etc.)
--
-- These types are deployment-target agnostic and apply to ALL releases.
module NammaAP.Products.Autopilot.Types.Workflow
  ( -- * Release Category
    ReleaseCategory (..)
  , getDefaultDeploymentTarget
  , migrateTrackerTypeToCategory

    -- * Generic Workflow Stages
  , ReleaseWFStatus (..)
  , migrateWorkflowStatusToReleaseWFStatus
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

-- ============================================================================
-- Release Category
-- ============================================================================

-- | Release category - categorizes the type of release
--
-- This determines:
-- - Which deployment workflow to use
-- - What DeploymentState type to create (K8sState, PlayStoreState, etc.)
-- - Which deployment backend/API to interact with
--
-- Terminology:
-- - product (field) = Service/app name (e.g., "Beckn", "rider-android")
-- - category (field) = ReleaseCategory (e.g., BackendService, MobileAppAndroid)
data ReleaseCategory
  = BackendService        -- ^ Backend microservices (REST APIs, gRPC services)
  | BackendScheduler      -- ^ Backend scheduled jobs (run periodically)
  | BackendCronJob        -- ^ Backend cron jobs (cron-triggered)
  | BackendJob            -- ^ Backend one-off jobs (batch processing)
  | BackendConfig         -- ^ Configuration updates (ConfigMaps, Secrets)
  | MobileAppAndroid      -- ^ Android mobile apps (Play Store)
  | MobileAppIOS          -- ^ iOS mobile apps (App Store)
  | WebApplication        -- ^ Web frontends (S3/CDN deployment)
  | Infrastructure        -- ^ Infrastructure as code (Terraform, CloudFormation)
  deriving (Eq, Show, Read, Generic, Ord)

instance ToJSON ReleaseCategory
instance FromJSON ReleaseCategory

-- | Get the default deployment target for a release category
getDefaultDeploymentTarget :: ReleaseCategory -> Text
getDefaultDeploymentTarget BackendService = "kubernetes"
getDefaultDeploymentTarget BackendScheduler = "kubernetes"
getDefaultDeploymentTarget BackendCronJob = "kubernetes"
getDefaultDeploymentTarget BackendJob = "kubernetes"
getDefaultDeploymentTarget BackendConfig = "kubernetes-config"
getDefaultDeploymentTarget MobileAppAndroid = "play-store"
getDefaultDeploymentTarget MobileAppIOS = "app-store"
getDefaultDeploymentTarget WebApplication = "s3-cdn"
getDefaultDeploymentTarget Infrastructure = "terraform"

-- | Migrate old TrackerType to new ReleaseCategory
migrateTrackerTypeToCategory :: Text -> ReleaseCategory
migrateTrackerTypeToCategory "Service" = BackendService
migrateTrackerTypeToCategory "Scheduler" = BackendScheduler
migrateTrackerTypeToCategory "CronJob" = BackendCronJob
migrateTrackerTypeToCategory "Job" = BackendJob
migrateTrackerTypeToCategory "ConfigMapRelease" = BackendConfig
migrateTrackerTypeToCategory "AppBundle" = MobileAppAndroid
migrateTrackerTypeToCategory _ = BackendService

-- ============================================================================
-- Generic Workflow Stages
-- ============================================================================

-- | Generic release workflow status
--
-- These stages apply to ALL release categories (backend services, mobile apps, configs, etc.)
-- Category-specific sub-stages are tracked in the targetState field.
--
-- Workflow progression:
-- Init → Preparing → Deploying → Monitoring → Finalizing → Done
--                                              ↓
--                                         RollingBack (on error)
data ReleaseWFStatus
  = Init
    -- ^ Validation and precondition checks
    -- Examples:
    -- - K8s: Validate manifests, check cluster capacity
    -- - Play Store: Validate APK, check signing keys
    -- - App Store: Validate bundle, check certificates

  | Preparing
    -- ^ Pre-deployment preparation
    -- Examples:
    -- - K8s: Create namespace, apply ConfigMaps
    -- - Play Store: Upload APK to Play Console
    -- - App Store: Upload bundle to TestFlight

  | Deploying
    -- ^ Active deployment/rollout
    -- Examples:
    -- - K8s: Create Deployment, apply VirtualService, progressive traffic shift
    -- - Play Store: Staged rollout (0% → 25% → 50% → 100%)
    -- - App Store: Phased release, TestFlight distribution

  | Monitoring
    -- ^ Post-deployment monitoring and health checks
    -- Examples:
    -- - K8s: Monitor pod health, latency, error rates
    -- - Play Store: Monitor crash rate, ANR rate, user ratings
    -- - App Store: Monitor crash reports, TestFlight feedback

  | Finalizing
    -- ^ Cleanup and finalization
    -- Examples:
    -- - K8s: Scale down old deployment, cleanup old resources
    -- - Play Store: Promote to full release, cleanup draft versions
    -- - App Store: Remove TestFlight build, archive old versions

  | Done
    -- ^ Successfully completed

  | RollingBack
    -- ^ Rollback in progress (error state)
    -- Examples:
    -- - K8s: Revert traffic to old version, scale down new deployment
    -- - Play Store: Halt rollout, revert to previous version
    -- - App Store: Halt phased release, submit emergency rollback

  deriving (Eq, Show, Read, Generic, Ord)

instance ToJSON ReleaseWFStatus
instance FromJSON ReleaseWFStatus

-- | Migrate old WorkflowStatus to new generic ReleaseWFStatus
migrateWorkflowStatusToReleaseWFStatus :: String -> ReleaseWFStatus
migrateWorkflowStatusToReleaseWFStatus "Init" = Init
migrateWorkflowStatusToReleaseWFStatus "CreateDeployment" = Preparing
migrateWorkflowStatusToReleaseWFStatus "UpdateService" = Deploying
migrateWorkflowStatusToReleaseWFStatus "ApplyConfigMap" = Preparing
migrateWorkflowStatusToReleaseWFStatus "ApplyDestinationRule" = Preparing
migrateWorkflowStatusToReleaseWFStatus "FlipVirtualService" = Deploying
migrateWorkflowStatusToReleaseWFStatus "Monitoring" = Monitoring
migrateWorkflowStatusToReleaseWFStatus "Stabilize" = Finalizing
migrateWorkflowStatusToReleaseWFStatus "Done" = Done
migrateWorkflowStatusToReleaseWFStatus "Rollback" = RollingBack
migrateWorkflowStatusToReleaseWFStatus _ = Deploying
