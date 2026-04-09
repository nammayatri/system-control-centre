-- | K8s-specific types: deployment state, release context, workflow sub-stages.
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

-- | K8s-specific deployment context: cluster, namespace, Istio routing, scaling.
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

-- | K8s-specific product config, stored as JSON in @product_config.target_config@.
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

-- | K8s-specific service config, stored as JSON in @release_config.target_config@.
data K8sServiceConfig = K8sServiceConfig
    { serviceHost :: Maybe Text
    }
    deriving (Eq, Show, Generic)

instance ToJSON K8sServiceConfig

instance FromJSON K8sServiceConfig

-- | Granular K8s sub-stages inside the generic 'ReleaseWFStatus'.
data BackendServiceWFStatus
    = BSInit
    | BSCreateDeployment
    | BSUpdateService
    | BSApplyConfigMap
    | BSApplyDestinationRule
    | BSFlipVirtualService
    | BSProgressiveRollout
    | BSMonitoring
    | BSStabilize
    | BSScaleDownOld
    | BSDone
    | BSRollback
    deriving (Eq, Show, Read, Generic, Ord)

instance ToJSON BackendServiceWFStatus

instance FromJSON BackendServiceWFStatus

data K8sDeploymentState = K8sDeploymentState
    { context :: K8sReleaseContext
    , cronjobSuspend :: Bool
    , abHsStatus :: DecisionEngineHSStatus
    , newService :: Bool
    -- ^ True when no existing deployment is running for this service.
    , categoryWorkflowStatus :: BackendServiceWFStatus
    , deploymentCreated :: Bool
    , serviceCreated :: Bool
    , virtualServiceApplied :: Bool
    , destinationRuleApplied :: Bool
    , trafficPercentage :: Int
    -- ^ Current traffic percent to the new version (0-100).
    , hpaCreated :: Bool
    , configMapApplied :: Bool
    , oldDeploymentScaledDown :: Bool
    }
    deriving (Eq, Show, Generic)

instance ToJSON K8sDeploymentState

instance FromJSON K8sDeploymentState

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
