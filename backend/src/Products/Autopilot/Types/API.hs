module Products.Autopilot.Types.API where

import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), object, withObject, (.:), (.:?), (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Parser, (.!=))
import Data.Foldable (toList)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import GHC.Generics (Generic)
import GHC.Int (Int32)
import Products.Autopilot.Types (ReleaseCategory (..), RolloutStep (..))

data UpsertProductReq = UpsertProductReq
    { id :: Maybe Int32
    , product :: Text
    , cluster :: Text
    , namespace :: Text
    , vsName :: Text
    , repoName :: Maybe Text
    , productType :: Text
    , productAcronym :: Text
    , releaseBranch :: Maybe Text
    , syncCluster :: Maybe Text
    , needInfraApproval :: Maybe Bool
    }
    deriving (Show, Generic)

instance FromJSON UpsertProductReq where
    parseJSON = withObject "UpsertProductReq" $ \v ->
        UpsertProductReq
            <$> v .:? "id"
            <*> v .: "product"
            <*> (v .:? "cluster" .!= "")
            <*> (v .:? "namespace" .!= "default")
            <*> (v .:? "vsName" >>= \mv -> case mv of Just x -> pure x; Nothing -> v .:? "vs_name" .!= "")
            <*> (v .:? "repoName" >>= \mv -> case mv of Just x -> pure (Just x); Nothing -> v .:? "repo_name")
            <*> (v .:? "productType" >>= \mv -> case mv of Just x -> pure x; Nothing -> v .:? "product_type" .!= "SERVICE")
            <*> (v .:? "productAcronym" >>= \mv -> case mv of Just x -> pure x; Nothing -> v .:? "product_acronym" .!= "")
            <*> (v .:? "releaseBranch" >>= \mv -> case mv of Just x -> pure (Just x); Nothing -> v .:? "release_branch")
            <*> (v .:? "syncCluster" >>= \mv -> case mv of Just x -> pure (Just x); Nothing -> v .:? "sync_cluster")
            <*> (v .:? "needInfraApproval" >>= \mv -> case mv of Just x -> pure (Just x); Nothing -> v .:? "need_infra_approval")

instance ToJSON UpsertProductReq

data UpsertServiceReq = UpsertServiceReq
    { id :: Maybe Int32
    , emails :: Maybe Text
    , rolloutStrategyText :: Maybe Text
    , decisionConfigText :: Maybe Text
    , product :: Text
    , service :: Text
    , serviceType :: Text
    , serviceHost :: Maybe Text
    , bitbucketPath :: Maybe Text
    , revertStrategyText :: Maybe Text
    }
    deriving (Show, Generic)

instance FromJSON UpsertServiceReq

instance ToJSON UpsertServiceReq

data K8sCreateReleaseReq = K8sCreateReleaseReq
    { product :: Text
    , service :: Text
    , env :: Text
    , requestedCluster :: Maybe Text
    , trackerType :: ReleaseCategory
    , createdBy :: Text
    , approvedBy :: Maybe Text
    , releaseTag :: Maybe Text
    , scheduleTime :: Maybe UTCTime
    , oldVersion :: Text
    , newVersion :: Text
    , deployFilePath :: Maybe Text
    , serviceFilePath :: Maybe Text
    , drFilePath :: Maybe Text
    , vsFilePath :: Maybe Text
    , rolloutStrategy :: [RolloutStep]
    , info :: Maybe Text
    , description :: Maybe Text
    , metadata :: Maybe Value
    , mode :: Maybe Text
    , isApproved :: Maybe Bool
    , isInfraApproved :: Maybe Bool
    , priority :: Maybe Int32
    , globalId :: Maybe Text
    , newService :: Maybe Bool
    , isArtRecorder :: Maybe Int32
    , cronjobSuspend :: Maybe Bool
    , changeLog :: Maybe Text
    , udf1 :: Maybe Text
    , udf2 :: Maybe Text
    , udf3 :: Maybe Text
    , isReleaseSync :: Maybe Bool
    , isSystemTriggered :: Maybe Bool
    , syncClusterUdf2 :: Maybe Text
    , syncClusterRolloutStrategy :: Maybe Value
    }
    deriving (Show, Generic)

instance FromJSON K8sCreateReleaseReq where
    parseJSON = withObject "K8sCreateReleaseReq" $ \o -> do
        product <- o .: "product"
        service <- parseService o
        env <- o .:? "env" .!= "UAT"
        requestedCluster <- o .:? "requestedCluster" >>= maybe (o .:? "cluster") pure
        trackerType <- (o .:? "trackerType" >>= maybe (o .:? "tracker_type") pure) .!= BackendService
        createdBy <- (o .:? "createdBy" >>= maybe (o .:? "release_manager") pure) .!= "local_admin"
        approvedBy <- o .:? "approvedBy"
        releaseTag <- (o .:? "releaseTag" >>= maybe (o .:? "release_tag") pure)
        scheduleTime <- parseNullableTime o "scheduleTime" "schedule_time"
        oldVersion <- (o .:? "oldVersion" >>= maybe (o .:? "old_version") pure) .!= "unknown"
        newVersion <- (o .:? "newVersion" >>= maybe (o .:? "new_version") pure) .!= ""
        deployFilePath <- o .:? "deployFilePath"
        serviceFilePath <- o .:? "serviceFilePath"
        drFilePath <- o .:? "drFilePath"
        vsFilePath <- o .:? "vsFilePath"
        rolloutStrategy <- parseRollout o
        info <- parseNullableText o "info"
        description <- o .:? "description"
        metadata <- parseMetadata o
        mode <- o .:? "mode"
        isApproved <- parseBoolish o "is_approved"
        isInfraApproved <- parseBoolish o "is_infra_approved"
        priority <- o .:? "priority"
        globalId <- o .:? "global_id"
        newService <- o .:? "new_service"
        isArtRecorder <- o .:? "is_art_recorder"
        cronjobSuspend <- o .:? "cronjob_suspend"
        changeLog <- o .:? "change_log"
        udf1 <- o .:? "udf1"
        udf2 <- o .:? "udf2"
        udf3 <- o .:? "udf3"
        isReleaseSync <- o .:? "isReleaseSync"
        isSystemTriggered <- o .:? "isSystemTriggered"
        syncClusterUdf2 <- o .:? "syncClusterUdf2"
        syncClusterRolloutStrategy <- o .:? "syncClusterRolloutStrategy"
        pure K8sCreateReleaseReq{..}
      where
        parseService obj = do
            svcVal <- obj .: "service"
            case svcVal of
                String t -> pure t
                Array arr ->
                    case toList arr of
                        (String t : _) -> pure t
                        _ -> fail "service array must contain at least one string"
                _ -> fail "service must be string or [string]"
        parseNullableTime obj k1 k2 = do
            v1 <- obj .:? k1
            case v1 of
                Just (String t) | t == "" -> pure Nothing
                Just _ -> obj .:? k1
                Nothing -> do
                    v2 <- obj .:? k2
                    case v2 of
                        Just (String t) | t == "" -> pure Nothing
                        _ -> obj .:? k2
        parseNullableText obj k = do
            v <- obj .:? k
            case v of
                Just "" -> pure Nothing
                _ -> pure v
        parseBoolish obj k = do
            v <- obj .:? k
            case v of
                Nothing -> pure Nothing
                Just (Bool b) -> pure (Just b)
                Just (Number n) -> pure (Just (n /= 0))
                Just (String t) -> pure (Just (t == "true" || t == "1"))
                _ -> pure Nothing
        parseRollout obj = do
            v1 <- obj .:? "rolloutStrategy"
            case v1 of
                Just xs -> pure xs
                Nothing -> do
                    v2 <- obj .:? "rollout_strategy"
                    case v2 of
                        Nothing -> pure []
                        Just arrVal -> parseLegacyRollout arrVal
        parseLegacyRollout (Array arr) = mapM parseLegacyStep (toList arr)
        parseLegacyRollout _ = fail "rollout_strategy must be an array"
        parseLegacyStep = withObject "RolloutStepLegacy" $ \s -> do
            rolloutPercent <- s .:? "rolloutPercent" .!= 0
            legacyRollout <- s .:? "rollout" .!= rolloutPercent
            cooloffSeconds <- s .:? "cooloffSeconds" .!= 0
            legacyCooloff <- s .:? "cooloff" .!= cooloffSeconds
            podPercent <- s .:? "podPercent" .!= 0
            legacyPods <- s .:? "pods" .!= podPercent
            pure $
                RolloutStep
                    { rolloutPercent = legacyRollout
                    , cooloffSeconds = legacyCooloff
                    , podPercent = legacyPods
                    }
        parseMetadata obj = do
            direct <- obj .:? "metadata"
            case direct of
                Just v@(Object _) -> pure (Just v)
                _ -> do
                    dockerImage <- obj .:? "docker_image" :: Parser (Maybe Text)
                    case dockerImage of
                        Just img
                            | img /= "" ->
                                pure $ Just $ Object $ KM.fromList [(K.fromText "docker-image", String img)]
                        _ -> pure Nothing

instance ToJSON K8sCreateReleaseReq where
    toJSON K8sCreateReleaseReq{..} =
        object
            [ "product" .= product
            , "service" .= service
            , "env" .= env
            , "requestedCluster" .= requestedCluster
            , "trackerType" .= trackerType
            , "createdBy" .= createdBy
            , "approvedBy" .= approvedBy
            , "releaseTag" .= releaseTag
            , "scheduleTime" .= scheduleTime
            , "oldVersion" .= oldVersion
            , "newVersion" .= newVersion
            , "deployFilePath" .= deployFilePath
            , "serviceFilePath" .= serviceFilePath
            , "drFilePath" .= drFilePath
            , "vsFilePath" .= vsFilePath
            , "rolloutStrategy" .= rolloutStrategy
            , "info" .= info
            , "description" .= description
            , "metadata" .= metadata
            , "mode" .= mode
            , "is_approved" .= isApproved
            , "is_infra_approved" .= isInfraApproved
            , "priority" .= priority
            , "global_id" .= globalId
            , "new_service" .= newService
            , "is_art_recorder" .= isArtRecorder
            , "cronjob_suspend" .= cronjobSuspend
            , "change_log" .= changeLog
            , "udf1" .= udf1
            , "udf2" .= udf2
            , "udf3" .= udf3
            , "isReleaseSync" .= isReleaseSync
            , "isSystemTriggered" .= isSystemTriggered
            , "syncClusterUdf2" .= syncClusterUdf2
            , "syncClusterRolloutStrategy" .= syncClusterRolloutStrategy
            ]

data ApproveReleaseReq = ApproveReleaseReq
    { approvedBy :: Text
    , isInfraApproved :: Maybe Bool
    }
    deriving (Show, Generic)

instance FromJSON ApproveReleaseReq

instance ToJSON ApproveReleaseReq

data TriggerReleaseReq = TriggerReleaseReq
    { reason :: Maybe Text
    }
    deriving (Show, Generic)

instance FromJSON TriggerReleaseReq

instance ToJSON TriggerReleaseReq

data RevertReleaseReq = RevertReleaseReq
    { requestedBy :: Maybe Text
    , info :: Maybe Text
    , immediate :: Maybe Bool
    , isRevertSync :: Maybe Bool
    }
    deriving (Show, Generic)

instance FromJSON RevertReleaseReq

instance ToJSON RevertReleaseReq

data K8sUpdateTrackerReq = K8sUpdateTrackerReq
    { status :: Maybe Text
    , mode :: Maybe Text
    , releaseManager :: Maybe Text
    , priority :: Maybe Int32
    , scheduleTime :: Maybe UTCTime
    , description :: Maybe Text
    , info :: Maybe Text
    , rolloutStrategy :: Maybe [RolloutStep]
    , changeLog :: Maybe Text
    , isApproved :: Maybe Bool
    , isInfraApproved :: Maybe Bool
    , udf1 :: Maybe Text
    , udf2 :: Maybe Text
    , udf3 :: Maybe Text
    , dockerImage :: Maybe Text
    , podsScaleDownDelay :: Maybe Double
    }
    deriving (Show, Generic)

instance FromJSON K8sUpdateTrackerReq

instance ToJSON K8sUpdateTrackerReq

data DiscardReleaseReq = DiscardReleaseReq
    { reason :: Maybe Text
    }
    deriving (Show, Generic)

instance FromJSON DiscardReleaseReq

instance ToJSON DiscardReleaseReq

data APIResponse = APIResponse
    { status :: Text
    , message :: Text
    }
    deriving (Show, Generic)

instance ToJSON APIResponse

data ProductResponse = ProductResponse
    { product :: Text
    , cluster :: Text
    , namespace :: Text
    , vsName :: Text
    , productType :: Text
    , productAcronym :: Text
    , syncCluster :: Maybe Text
    }
    deriving (Show, Generic)

instance ToJSON ProductResponse

data ImmediateRevertReq = ImmediateRevertReq
    { requestedBy :: Maybe Text
    , info :: Maybe Text
    , isRevertSync :: Maybe Bool
    }
    deriving (Show, Generic)

instance FromJSON ImmediateRevertReq

instance ToJSON ImmediateRevertReq

data RestartReleaseReq = RestartReleaseReq
    { requestedBy :: Maybe Text
    , reason :: Maybe Text
    }
    deriving (Show, Generic)

instance FromJSON RestartReleaseReq

instance ToJSON RestartReleaseReq

data FastForwardReq = FastForwardReq
    { requestedBy :: Maybe Text
    , reason :: Maybe Text
    }
    deriving (Show, Generic)

instance FromJSON FastForwardReq

instance ToJSON FastForwardReq

data ServiceResponse = ServiceResponse
    { service :: Text
    , serviceHost :: Maybe Text
    , serviceType :: Text
    , source :: Text
    }
    deriving (Show, Generic)

instance ToJSON ServiceResponse

-- ── Product Config CRUD types ──────────────────────────────────────

data ProductConfigResponse = ProductConfigResponse
    { id :: Int32
    , product :: Text
    , repoName :: Text
    , productType :: Text
    , productAcronym :: Text
    , releaseBranch :: Text
    , needInfraApproval :: Maybe Bool
    , cluster :: Maybe Text
    , namespace :: Maybe Text
    , vsName :: Maybe Text
    , syncCluster :: Maybe Text
    }
    deriving (Show, Generic)

instance ToJSON ProductConfigResponse

-- ── Release Config CRUD types ──────────────────────────────────────

data ReleaseConfigResponse = ReleaseConfigResponse
    { id :: Int32
    , serviceName :: Text
    , serviceProduct :: Text
    , serviceType :: Text
    , emails :: Maybe Text
    , rolloutStrategy :: Maybe Text
    , decisionConfig :: Maybe Text
    , flags :: Maybe Text
    , slackWebhookUrls :: Maybe Text
    , serviceAcronym :: Maybe Text
    , bitbucketPath :: Maybe Text
    , microserviceType :: Maybe Text
    , revertStrategy :: Maybe Text
    , jiraWebhookUrl :: Maybe Text
    , serviceHost :: Maybe Text
    }
    deriving (Show, Generic)

instance ToJSON ReleaseConfigResponse

-- ── VS Edit Tracker types ──────────────────────────────────────────

data CreateVsEditTrackerReq = CreateVsEditTrackerReq
    { product :: Text
    , service :: Text
    , env :: Text
    , vsName :: Text
    , oldVsData :: Maybe Text
    , createdBy :: Text
    , info :: Maybe Text
    }
    deriving (Show, Generic)

instance FromJSON CreateVsEditTrackerReq

instance ToJSON CreateVsEditTrackerReq

data UpdateVsEditTrackerReq = UpdateVsEditTrackerReq
    { newVsData :: Maybe Text
    , status :: Maybe Text
    , approvedBy :: Maybe Text
    , info :: Maybe Text
    }
    deriving (Show, Generic)

instance FromJSON UpdateVsEditTrackerReq

instance ToJSON UpdateVsEditTrackerReq

data VsLockReq = VsLockReq
    { product :: Text
    , service :: Maybe Text
    , vsName :: Maybe Text
    , env :: Maybe Text
    , lockedBy :: Maybe Text
    , oldVsData :: Maybe Text
    , lockDurationMinutes :: Maybe Int
    }
    deriving (Show, Generic)

instance FromJSON VsLockReq where
    parseJSON = withObject "VsLockReq" $ \v ->
        VsLockReq
            <$> v .: "product"
            <*> v .:? "service"
            <*> (v .:? "vsName" >>= \mv -> case mv of Just x -> pure (Just x); Nothing -> v .:? "vs_name")
            <*> v .:? "env"
            <*> (v .:? "lockedBy" >>= \mv -> case mv of Just x -> pure (Just x); Nothing -> v .:? "locked_by")
            <*> (v .:? "oldVsData" >>= \mv -> case mv of Just x -> pure (Just x); Nothing -> v .:? "old_vs_data" >>= \mv2 -> case mv2 of Just x2 -> pure (Just x2); Nothing -> v .:? "vs_data")
            <*> (v .:? "lockDurationMinutes" >>= \mv -> case mv of Just x -> pure (Just x); Nothing -> v .:? "lock_duration_minutes")

instance ToJSON VsLockReq

data VsUnlockReq = VsUnlockReq
    { trackerId :: Maybe Text
    , product :: Maybe Text
    , vsName :: Maybe Text
    , env :: Maybe Text
    }
    deriving (Show, Generic)

instance FromJSON VsUnlockReq where
    parseJSON = withObject "VsUnlockReq" $ \v ->
        VsUnlockReq
            <$> (v .:? "trackerId" >>= \mv -> case mv of Just x -> pure (Just x); Nothing -> v .:? "tracker_id")
            <*> v .:? "product"
            <*> (v .:? "vsName" >>= \mv -> case mv of Just x -> pure (Just x); Nothing -> v .:? "vs_name")
            <*> v .:? "env"

instance ToJSON VsUnlockReq
