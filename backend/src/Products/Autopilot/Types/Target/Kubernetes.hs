{- | Kubernetes target types

This module contains all types related to Kubernetes deployments:
- K8sDeploymentState: State tracking for K8s resources
- K8sReleaseContext: K8s-specific release context (cluster, namespace, etc.)
- BackendServiceWFStatus: Detailed K8s-specific workflow stages
- K8s-specific helper types
-}
module Products.Autopilot.Types.Target.Kubernetes (
    -- * Target State
    K8sDeploymentState (..),
    emptyK8sState,

    -- * Release Context
    K8sReleaseContext (..),
    defaultK8sReleaseContext,

    -- * Product / Service Config (JSON target_config)
    K8sProductConfig (..),
    defaultK8sProductConfig,
    K8sServiceConfig (..),

    -- * Workflow Status
    BackendServiceWFStatus (..),

    -- * K8s Enums
    DecisionEngineHSStatus (..),
    PodsScaleDownStatus (..),
    MatchDetails (..),
)
where

import Data.Aeson (FromJSON, ToJSON, Value)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import GHC.Generics (Generic)


-- ============================================================================
-- K8s Enums (moved from Release.hs)
-- ============================================================================

data DecisionEngineHSStatus
    = Uninitiated
    | ConfigFound
    | Started
    | Running
    | Stopped
    | AbHsException
    deriving (Eq, Show, Read, Generic)

instance ToJSON DecisionEngineHSStatus

instance FromJSON DecisionEngineHSStatus

data PodsScaleDownStatus
    = ScaleDownScheduled
    | ScaleDownInProgress
    | ScaleDownAborted
    | ScaleDownCompleted
    | ScaleDownDiscarded
    deriving (Eq, Show, Read, Generic)

instance ToJSON PodsScaleDownStatus

instance FromJSON PodsScaleDownStatus

data MatchDetails = MatchDetails
    { matchHost :: Text
    , matchRunningVersion :: Text
    , matchWeight :: Int
    }
    deriving (Eq, Show, Generic)

instance ToJSON MatchDetails

instance FromJSON MatchDetails

-- ============================================================================
-- K8s Release Context (moved from Release.hs, renamed from ReleaseContext)
-- ============================================================================

{- | Kubernetes release context

Contains all K8s-specific deployment configuration:
cluster, namespace, Istio routing, pod scaling, etc.
oldVersion/newVersion are kept here for K8s operations that need them
(they are also on ReleaseTracker for generic access).
-}
data K8sReleaseContext = K8sReleaseContext
    { cluster :: Text
    , namespace :: Text
    , deploymentName :: Text
    , serviceName :: Text
    , destinationRuleName :: Text
    , virtualServiceName :: Text
    , internalVirtualServiceName :: Maybe Text
    , containerName :: Text
    , oldVersion :: Text
    , newVersion :: Text
    , dockerImage :: Maybe Text
    , matches :: [MatchDetails]
    , podsScaleDownDelay :: Maybe Double
    , podsScaleDownTimestamp :: Maybe UTCTime
    , podsScaleDownStatus :: Maybe PodsScaleDownStatus
    , oldVersionPodCount :: Maybe Int
    , revert :: Maybe Int
    , abRunId :: Maybe Text
    , abStatus :: Maybe Text
    , cleanupAt :: Maybe UTCTime
    , cleanupTargetDeployment :: Maybe Text
    , cleanupStatus :: Maybe Text
    , deployFilePath :: Maybe Text
    , serviceFilePath :: Maybe Text
    , drFilePath :: Maybe Text
    , vsFilePath :: Maybe Text
    , prevAbHsDecision :: Maybe Value
    , postMonitoringDecisionMap :: Maybe Value
    , syncClusterEnvOverrideData :: Maybe Text
    , syncClusterRolloutStrategy :: Maybe Text
    , syncXForwardedEmail :: Maybe Text
    , syncXPomeriumJwt :: Maybe Text
    }
    deriving (Eq, Show, Generic)

instance ToJSON K8sReleaseContext

instance FromJSON K8sReleaseContext

-- | Default empty K8s release context
defaultK8sReleaseContext :: K8sReleaseContext
defaultK8sReleaseContext =
    K8sReleaseContext
        { cluster = ""
        , namespace = ""
        , deploymentName = ""
        , serviceName = ""
        , destinationRuleName = ""
        , virtualServiceName = ""
        , internalVirtualServiceName = Nothing
        , containerName = ""
        , oldVersion = ""
        , newVersion = ""
        , dockerImage = Nothing
        , matches = []
        , podsScaleDownDelay = Nothing
        , podsScaleDownTimestamp = Nothing
        , podsScaleDownStatus = Nothing
        , oldVersionPodCount = Nothing
        , revert = Nothing
        , abRunId = Nothing
        , abStatus = Nothing
        , cleanupAt = Nothing
        , cleanupTargetDeployment = Nothing
        , cleanupStatus = Nothing
        , deployFilePath = Nothing
        , serviceFilePath = Nothing
        , drFilePath = Nothing
        , vsFilePath = Nothing
        , prevAbHsDecision = Nothing
        , postMonitoringDecisionMap = Nothing
        , syncClusterEnvOverrideData = Nothing
        , syncClusterRolloutStrategy = Nothing
        , syncXForwardedEmail = Nothing
        , syncXPomeriumJwt = Nothing
        }

-- ============================================================================
-- K8s Product / Service Config (stored as JSON in target_config columns)
-- ============================================================================

-- | K8s-specific product configuration (stored as JSON in product_config.target_config)
data K8sProductConfig = K8sProductConfig
    { cluster :: Text
    , namespace :: Text
    , vsName :: Text
    , kubeContext :: Maybe Text
    , syncCluster :: Maybe Text
    , vsLockedBy :: Maybe Text
    , vsLockTimestamp :: Maybe UTCTime
    }
    deriving (Eq, Show, Generic)

instance ToJSON K8sProductConfig

instance FromJSON K8sProductConfig

defaultK8sProductConfig :: K8sProductConfig
defaultK8sProductConfig = K8sProductConfig "" "" "" Nothing Nothing Nothing Nothing

-- | K8s-specific service configuration (stored as JSON in release_config.target_config)
data K8sServiceConfig = K8sServiceConfig
    { serviceHost :: Maybe Text
    }
    deriving (Eq, Show, Generic)

instance ToJSON K8sServiceConfig

instance FromJSON K8sServiceConfig

-- ============================================================================
-- Kubernetes Workflow Status
-- ============================================================================

{- | Backend service workflow status (K8s-specific)

Tracks granular K8s resource creation and traffic shifting steps.
This provides detailed progress within the generic ReleaseWFStatus stages.
-}
data BackendServiceWFStatus
    = -- | Initial validation
      BSInit
    | -- | Create K8s Deployment
      BSCreateDeployment
    | -- | Update K8s Service
      BSUpdateService
    | -- | Apply ConfigMaps
      BSApplyConfigMap
    | -- | Apply Istio DestinationRule
      BSApplyDestinationRule
    | -- | Update Istio VirtualService for traffic
      BSFlipVirtualService
    | -- | Progressive traffic shift (0->25->50->100)
      BSProgressiveRollout
    | -- | Monitor pod health and metrics
      BSMonitoring
    | -- | Stabilization period
      BSStabilize
    | -- | Scale down old deployment
      BSScaleDownOld
    | -- | Complete
      BSDone
    | -- | Rollback in progress
      BSRollback
    deriving (Eq, Show, Read, Generic, Ord)

instance ToJSON BackendServiceWFStatus

instance FromJSON BackendServiceWFStatus

-- ============================================================================
-- Kubernetes Deployment State
-- ============================================================================

{- | Kubernetes deployment state

Tracks which K8s resources have been created/updated and the current
state of the deployment (traffic percentage, pod health, etc.)
Also includes K8s-specific operational fields that were previously
on ReleaseTracker (cronjobSuspend, abHsStatus, newService, isArtRecorder).
-}
data K8sDeploymentState = K8sDeploymentState
    { context :: K8sReleaseContext
    -- ^ K8s-specific release context (cluster, namespace, Istio config, etc.)
    , cronjobSuspend :: Bool
    -- ^ Whether to suspend CronJobs during release
    , abHsStatus :: DecisionEngineHSStatus
    -- ^ Decision engine health status
    , newService :: Bool
    -- ^ Whether this is a new service (no existing deployment)
    , categoryWorkflowStatus :: BackendServiceWFStatus
    -- ^ Granular K8s-specific workflow progress
    , deploymentCreated :: Bool
    -- ^ Whether Deployment resource was created
    , serviceCreated :: Bool
    -- ^ Whether Service resource was created
    , virtualServiceApplied :: Bool
    -- ^ Whether Istio VirtualService was applied
    , destinationRuleApplied :: Bool
    -- ^ Whether Istio DestinationRule was applied
    , trafficPercentage :: Int
    -- ^ Current traffic percentage to new version (0-100)
    , hpaCreated :: Bool
    -- ^ Whether HorizontalPodAutoscaler was created
    , configMapApplied :: Bool
    -- ^ Whether ConfigMap was applied
    , oldDeploymentScaledDown :: Bool
    -- ^ Whether old deployment was scaled down
    }
    deriving (Eq, Show, Generic)

instance ToJSON K8sDeploymentState

instance FromJSON K8sDeploymentState

-- | Empty K8s deployment state (initial state)
emptyK8sState :: K8sDeploymentState
emptyK8sState =
    K8sDeploymentState
        { context = defaultK8sReleaseContext
        , cronjobSuspend = False
        , abHsStatus = Uninitiated
        , newService = False
        , categoryWorkflowStatus = BSInit
        , deploymentCreated = False
        , serviceCreated = False
        , virtualServiceApplied = False
        , destinationRuleApplied = False
        , trafficPercentage = 0
        , hpaCreated = False
        , configMapApplied = False
        , oldDeploymentScaledDown = False
        }
