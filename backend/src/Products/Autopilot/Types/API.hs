{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.Types.API where

import Data.Aeson
    ( FromJSON (..)
    , Options (..)
    , ToJSON (..)
    , Value (..)
    , defaultOptions
    , genericParseJSON
    , genericToJSON
    , object
    , withObject
    , (.:)
    , (.:?)
    , (.=)
    )
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Parser, (.!=))
import Data.Foldable (toList)
import Data.Text (Text, pack)
import Data.Time.Clock (UTCTime)
import GHC.Generics (Generic)
import GHC.Int (Int32)
import Products.Autopilot.Types (ReleaseCategory (..), RolloutStep (..))
import Servant (FromHttpApiData)

-- ============================================================================
-- Newtypes for type-safe IDs
-- ============================================================================

newtype ReleaseId = ReleaseId { unReleaseId :: Text }
    deriving stock (Show, Eq)
    deriving newtype (FromJSON, ToJSON, FromHttpApiData)

newtype ProductSlug = ProductSlug { unProductSlug :: Text }
    deriving stock (Show, Eq)
    deriving newtype (FromJSON, ToJSON, FromHttpApiData)

newtype ServiceSlug = ServiceSlug { unServiceSlug :: Text }
    deriving stock (Show, Eq)
    deriving newtype (FromJSON, ToJSON, FromHttpApiData)

-- ============================================================================
-- Request Types
-- ============================================================================

data UpsertProductReq = UpsertProductReq
    { id :: Maybe Int32
    , appGroup :: Text
    , cluster :: Text
    , namespace :: Text
    , vsName :: Text
    , productType :: Text
    , productAcronym :: Text
    , syncCluster :: Maybe Text
    , needInfraApproval :: Maybe Bool
    }
    deriving (Show, Generic)

-- Manual FromJSON to accept both camelCase and snake_case from frontend
instance FromJSON UpsertProductReq where
    parseJSON = withObject "UpsertProductReq" $ \v ->
        UpsertProductReq
            <$> v .:? "id"
            <*> (v .:? "appGroup" >>= \mv -> case mv of Just x -> pure x; Nothing -> v .: "product")
            <*> (v .:? "cluster" .!= "")
            <*> (v .:? "namespace" .!= "default")
            <*> (v .:? "vsName" >>= \mv -> case mv of Just x -> pure x; Nothing -> v .:? "vs_name" .!= "")
            <*> (v .:? "productType" >>= \mv -> case mv of Just x -> pure x; Nothing -> v .:? "product_type" .!= "SERVICE")
            <*> (v .:? "productAcronym" >>= \mv -> case mv of Just x -> pure x; Nothing -> v .:? "product_acronym" .!= "")
            <*> (v .:? "syncCluster" >>= \mv -> case mv of Just x -> pure (Just x); Nothing -> v .:? "sync_cluster")
            <*> (v .:? "needInfraApproval" >>= \mv -> case mv of Just x -> pure (Just x); Nothing -> v .:? "need_infra_approval")

instance ToJSON UpsertProductReq where
    toJSON = genericToJSON defaultOptions { omitNothingFields = True }

data UpsertServiceReq = UpsertServiceReq
    { id :: Maybe Int32
    , rolloutStrategyText :: Maybe Text
    , decisionConfigText :: Maybe Text
    , appGroup :: Text
    , service :: Text
    , serviceType :: Text
    , serviceHost :: Maybe Text
    , revertStrategyText :: Maybe Text
    }
    deriving (Show, Generic)

instance FromJSON UpsertServiceReq where
    parseJSON = genericParseJSON defaultOptions { omitNothingFields = True }

instance ToJSON UpsertServiceReq where
    toJSON = genericToJSON defaultOptions { omitNothingFields = True }

data K8sCreateReleaseReq = K8sCreateReleaseReq
    { appGroup :: Text
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
    , cronjobSuspend :: Maybe Bool
    , changeLog :: Maybe Text
    , syncEnabled :: Maybe Text
    , envOverrideData :: Maybe Text
    , slackThreadTs :: Maybe Text
    , isReleaseSync :: Maybe Bool
    , isSystemTriggered :: Maybe Bool
    , syncClusterEnvOverrideData :: Maybe Text
    , syncClusterRolloutStrategy :: Maybe Value
    }
    deriving (Show, Generic)

-- Complex manual parser needed for legacy field names and special parsing logic
instance FromJSON K8sCreateReleaseReq where
    parseJSON = withObject "K8sCreateReleaseReq" $ \o -> do
        appGroup <- (o .:? "appGroup" >>= maybe (o .: "product") pure)
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
        cronjobSuspend <- o .:? "cronjob_suspend"
        changeLog <- o .:? "change_log"
        syncEnabled <- (o .:? "syncEnabled" >>= maybe (o .:? "udf1") (pure . Just))
        envOverrideData <- (o .:? "envOverrideData" >>= maybe (o .:? "udf2") (pure . Just))
        slackThreadTs <- (o .:? "slackThreadTs" >>= maybe (o .:? "udf3") (pure . Just))
        isReleaseSync <- o .:? "isReleaseSync"
        isSystemTriggered <- o .:? "isSystemTriggered"
        syncClusterEnvOverrideData <- (o .:? "syncClusterEnvOverrideData" >>= maybe (o .:? "syncClusterUdf2") (pure . Just))
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
            [ "appGroup" .= appGroup
            , "product" .= appGroup  -- backward compat alias
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
            , "cronjob_suspend" .= cronjobSuspend
            , "change_log" .= changeLog
            , "syncEnabled" .= syncEnabled
            , "udf1" .= syncEnabled  -- backward compat alias
            , "envOverrideData" .= envOverrideData
            , "udf2" .= envOverrideData  -- backward compat alias
            , "slackThreadTs" .= slackThreadTs
            , "udf3" .= slackThreadTs  -- backward compat alias
            , "isReleaseSync" .= isReleaseSync
            , "isSystemTriggered" .= isSystemTriggered
            , "syncClusterEnvOverrideData" .= syncClusterEnvOverrideData
            , "syncClusterUdf2" .= syncClusterEnvOverrideData  -- backward compat alias
            , "syncClusterRolloutStrategy" .= syncClusterRolloutStrategy
            ]

data ApproveReleaseReq = ApproveReleaseReq
    { approvedBy :: Text
    , isInfraApproved :: Maybe Bool
    }
    deriving (Show, Generic)

instance FromJSON ApproveReleaseReq where
    parseJSON = genericParseJSON defaultOptions { omitNothingFields = True }

instance ToJSON ApproveReleaseReq where
    toJSON = genericToJSON defaultOptions { omitNothingFields = True }

data TriggerReleaseReq = TriggerReleaseReq
    { reason :: Maybe Text
    }
    deriving (Show, Generic)

instance FromJSON TriggerReleaseReq where
    parseJSON = genericParseJSON defaultOptions { omitNothingFields = True }

instance ToJSON TriggerReleaseReq where
    toJSON = genericToJSON defaultOptions { omitNothingFields = True }

data RevertReleaseReq = RevertReleaseReq
    { requestedBy :: Maybe Text
    , info :: Maybe Text
    , immediate :: Maybe Bool
    , isRevertSync :: Maybe Bool
    }
    deriving (Show, Generic)

instance FromJSON RevertReleaseReq where
    parseJSON = genericParseJSON defaultOptions { omitNothingFields = True }

instance ToJSON RevertReleaseReq where
    toJSON = genericToJSON defaultOptions { omitNothingFields = True }

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
    , syncEnabled :: Maybe Text
    , envOverrideData :: Maybe Text
    , slackThreadTs :: Maybe Text
    , dockerImage :: Maybe Text
    , podsScaleDownDelay :: Maybe Double
    }
    deriving (Show, Generic)

instance FromJSON K8sUpdateTrackerReq where
    parseJSON = withObject "K8sUpdateTrackerReq" $ \o ->
        K8sUpdateTrackerReq
            <$> o .:? "status"
            <*> o .:? "mode"
            <*> o .:? "releaseManager"
            <*> o .:? "priority"
            <*> o .:? "scheduleTime"
            <*> o .:? "description"
            <*> o .:? "info"
            <*> o .:? "rolloutStrategy"
            <*> o .:? "changeLog"
            <*> o .:? "isApproved"
            <*> o .:? "isInfraApproved"
            <*> (o .:? "syncEnabled" >>= maybe (o .:? "udf1") (pure . Just))
            <*> (o .:? "envOverrideData" >>= maybe (o .:? "udf2") (pure . Just))
            <*> (o .:? "slackThreadTs" >>= maybe (o .:? "udf3") (pure . Just))
            <*> o .:? "dockerImage"
            <*> o .:? "podsScaleDownDelay"

instance ToJSON K8sUpdateTrackerReq where
    toJSON = genericToJSON defaultOptions { omitNothingFields = True }

data DiscardReleaseReq = DiscardReleaseReq
    { reason :: Maybe Text
    }
    deriving (Show, Generic)

instance FromJSON DiscardReleaseReq where
    parseJSON = genericParseJSON defaultOptions { omitNothingFields = True }

instance ToJSON DiscardReleaseReq where
    toJSON = genericToJSON defaultOptions { omitNothingFields = True }

data ImmediateRevertReq = ImmediateRevertReq
    { requestedBy :: Maybe Text
    , info :: Maybe Text
    , isRevertSync :: Maybe Bool
    }
    deriving (Show, Generic)

instance FromJSON ImmediateRevertReq where
    parseJSON = genericParseJSON defaultOptions { omitNothingFields = True }

instance ToJSON ImmediateRevertReq where
    toJSON = genericToJSON defaultOptions { omitNothingFields = True }

data RestartReleaseReq = RestartReleaseReq
    { requestedBy :: Maybe Text
    , reason :: Maybe Text
    }
    deriving (Show, Generic)

instance FromJSON RestartReleaseReq where
    parseJSON = genericParseJSON defaultOptions { omitNothingFields = True }

instance ToJSON RestartReleaseReq where
    toJSON = genericToJSON defaultOptions { omitNothingFields = True }

data FastForwardReq = FastForwardReq
    { requestedBy :: Maybe Text
    , reason :: Maybe Text
    }
    deriving (Show, Generic)

instance FromJSON FastForwardReq where
    parseJSON = genericParseJSON defaultOptions { omitNothingFields = True }

instance ToJSON FastForwardReq where
    toJSON = genericToJSON defaultOptions { omitNothingFields = True }

-- ============================================================================
-- VS Edit Tracker Request Types
-- ============================================================================

data CreateVsEditTrackerReq = CreateVsEditTrackerReq
    { appGroup :: Text
    , service :: Text
    , env :: Text
    , vsName :: Text
    , oldVsData :: Maybe Text
    , createdBy :: Text
    , info :: Maybe Text
    }
    deriving (Show, Generic)

instance FromJSON CreateVsEditTrackerReq where
    parseJSON = genericParseJSON defaultOptions { omitNothingFields = True }

instance ToJSON CreateVsEditTrackerReq where
    toJSON = genericToJSON defaultOptions { omitNothingFields = True }

data UpdateVsEditTrackerReq = UpdateVsEditTrackerReq
    { newVsData :: Maybe Text
    , status :: Maybe Text
    , approvedBy :: Maybe Text
    , info :: Maybe Text
    }
    deriving (Show, Generic)

instance FromJSON UpdateVsEditTrackerReq where
    parseJSON = genericParseJSON defaultOptions { omitNothingFields = True }

instance ToJSON UpdateVsEditTrackerReq where
    toJSON = genericToJSON defaultOptions { omitNothingFields = True }

-- Manual FromJSON for VsLockReq to accept both camelCase and snake_case
data VsLockReq = VsLockReq
    { appGroup :: Text
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
            <$> (v .:? "appGroup" >>= \mv -> case mv of Just x -> pure x; Nothing -> v .: "product")
            <*> v .:? "service"
            <*> (v .:? "vsName" >>= \mv -> case mv of Just x -> pure (Just x); Nothing -> v .:? "vs_name")
            <*> v .:? "env"
            <*> (v .:? "lockedBy" >>= \mv -> case mv of Just x -> pure (Just x); Nothing -> v .:? "locked_by")
            <*> (v .:? "oldVsData" >>= \mv -> case mv of Just x -> pure (Just x); Nothing -> v .:? "old_vs_data" >>= \mv2 -> case mv2 of Just x2 -> pure (Just x2); Nothing -> v .:? "vs_data")
            <*> (v .:? "lockDurationMinutes" >>= \mv -> case mv of Just x -> pure (Just x); Nothing -> v .:? "lock_duration_minutes")

instance ToJSON VsLockReq where
    toJSON = genericToJSON defaultOptions { omitNothingFields = True }

-- Manual FromJSON for VsUnlockReq to accept both camelCase and snake_case
data VsUnlockReq = VsUnlockReq
    { trackerId :: Maybe Text
    , appGroup :: Maybe Text
    , vsName :: Maybe Text
    , env :: Maybe Text
    }
    deriving (Show, Generic)

instance FromJSON VsUnlockReq where
    parseJSON = withObject "VsUnlockReq" $ \v ->
        VsUnlockReq
            <$> (v .:? "trackerId" >>= \mv -> case mv of Just x -> pure (Just x); Nothing -> v .:? "tracker_id")
            <*> (v .:? "appGroup" >>= \mv -> case mv of Just x -> pure (Just x); Nothing -> v .:? "product")
            <*> (v .:? "vsName" >>= \mv -> case mv of Just x -> pure (Just x); Nothing -> v .:? "vs_name")
            <*> v .:? "env"

instance ToJSON VsUnlockReq where
    toJSON = genericToJSON defaultOptions { omitNothingFields = True }

-- ============================================================================
-- Generic Response Type
-- ============================================================================

data APIResponse = APIResponse
    { status :: Text
    , message :: Text
    }
    deriving (Show, Generic)

instance ToJSON APIResponse where
    toJSON = genericToJSON defaultOptions

instance FromJSON APIResponse where
    parseJSON = genericParseJSON defaultOptions

-- ============================================================================
-- Product & Service Response Types
-- ============================================================================

data ProductResponse = ProductResponse
    { appGroup :: Text
    , cluster :: Text
    , namespace :: Text
    , vsName :: Text
    , productType :: Text
    , productAcronym :: Text
    , syncCluster :: Maybe Text
    }
    deriving (Show, Generic)

instance ToJSON ProductResponse where
    toJSON = genericToJSON defaultOptions { omitNothingFields = True }

data ServiceResponse = ServiceResponse
    { service :: Text
    , serviceHost :: Maybe Text
    , serviceType :: Text
    , source :: Text
    }
    deriving (Show, Generic)

instance ToJSON ServiceResponse where
    toJSON = genericToJSON defaultOptions { omitNothingFields = True }

-- ============================================================================
-- Product Config CRUD Response
-- ============================================================================

data ProductConfigResponse = ProductConfigResponse
    { id :: Int32
    , appGroup :: Text
    , productType :: Text
    , productAcronym :: Text
    , needInfraApproval :: Maybe Bool
    , cluster :: Maybe Text
    , namespace :: Maybe Text
    , vsName :: Maybe Text
    , syncCluster :: Maybe Text
    , vsLockedBy :: Maybe Text
    }
    deriving (Show, Generic)

instance ToJSON ProductConfigResponse where
    toJSON = genericToJSON defaultOptions { omitNothingFields = True }

-- ============================================================================
-- Release Config CRUD Response
-- ============================================================================

data ReleaseConfigResponse = ReleaseConfigResponse
    { id :: Int32
    , serviceName :: Text
    , serviceProduct :: Text
    , serviceType :: Text
    , rolloutStrategy :: Maybe Text
    , decisionConfig :: Maybe Text
    , flags :: Maybe Text
    , slackWebhookUrls :: Maybe Text
    , microserviceType :: Maybe Text
    , revertStrategy :: Maybe Text
    , jiraWebhookUrl :: Maybe Text
    , serviceHost :: Maybe Text
    }
    deriving (Show, Generic)

instance ToJSON ReleaseConfigResponse where
    toJSON = genericToJSON defaultOptions { omitNothingFields = True }

-- ============================================================================
-- Pod Health Response Types
-- ============================================================================

data PodInfo = PodInfo
    { piName :: Text
    , piStatus :: Text
    , piReady :: Bool
    , piRestarts :: Int
    , piAge :: Text
    , piVersion :: Text
    }
    deriving (Show, Generic)

-- JSON output: strip "pi" prefix, lowercase first char -> "name", "status", etc.
instance ToJSON PodInfo where
    toJSON (PodInfo n s r rst a v) =
        object
            [ "name" .= n
            , "status" .= s
            , "ready" .= r
            , "restarts" .= rst
            , "age" .= a
            , "version" .= v
            ]

data PodSummary = PodSummary
    { psTotal :: Int
    , psRunning :: Int
    , psPending :: Int
    , psFailed :: Int
    , psUnknown :: Int
    }
    deriving (Show, Generic)

instance ToJSON PodSummary where
    toJSON (PodSummary t r p f u) =
        object
            [ "total" .= t
            , "running" .= r
            , "pending" .= p
            , "failed" .= f
            , "unknown" .= u
            ]

data PodHealthResponse = PodHealthResponse
    { podsResult :: [PodInfo]
    , summaryResult :: PodSummary
    }
    deriving (Show, Generic)

instance ToJSON PodHealthResponse where
    toJSON (PodHealthResponse pods summary) =
        object
            [ "pods" .= pods
            , "summary" .= summary
            ]

-- ============================================================================
-- Diff Response Type
-- ============================================================================

data DiffResponse = DiffResponse
    { drOldfile :: Text
    , drNewfile :: Text
    , drMessage :: Text
    }
    deriving (Show, Generic)

instance ToJSON DiffResponse where
    toJSON (DiffResponse o n m) =
        object
            [ "oldfile" .= o
            , "newfile" .= n
            , "message" .= m
            ]

-- ============================================================================
-- Resources Response Type
-- ============================================================================

data ResourceSpec = ResourceSpec
    { rsCpu :: Maybe Text
    , rsMemory :: Maybe Text
    }
    deriving (Show, Generic)

instance ToJSON ResourceSpec where
    toJSON (ResourceSpec c m) =
        object
            [ "cpu" .= c
            , "memory" .= m
            ]

instance FromJSON ResourceSpec where
    parseJSON = withObject "ResourceSpec" $ \v ->
        ResourceSpec
            <$> v .:? "cpu"
            <*> v .:? "memory"

data ResourcesResponse = ResourcesResponse
    { rrRequests :: Maybe ResourceSpec
    , rrLimits :: Maybe ResourceSpec
    }
    deriving (Show, Generic)

instance ToJSON ResourcesResponse where
    toJSON (ResourcesResponse req lim) =
        object
            [ "requests" .= req
            , "limits" .= lim
            ]

instance FromJSON ResourcesResponse where
    parseJSON = withObject "ResourcesResponse" $ \v ->
        ResourcesResponse
            <$> v .:? "requests"
            <*> v .:? "limits"

-- ============================================================================
-- VS Edit Tracker Response Type
-- ============================================================================

data VsEditTrackerResponse = VsEditTrackerResponse
    { vetRespId :: Text
    , vetRespAppGroup :: Text
    , vetRespService :: Text
    , vetRespEnv :: Text
    , vetRespVsName :: Text
    , vetRespOldVsData :: Maybe Text
    , vetRespNewVsData :: Maybe Text
    , vetRespStatus :: Text
    , vetRespCreatedBy :: Text
    , vetRespApprovedBy :: Maybe Text
    , vetRespIsLocked :: Maybe Bool
    , vetRespLockedBy :: Maybe Text
    , vetRespLockedAt :: Maybe UTCTime
    , vetRespLockExpiry :: Maybe UTCTime
    , vetRespMonitoringEndTime :: Maybe UTCTime
    , vetRespInfo :: Maybe Text
    , vetRespCreatedAt :: UTCTime
    , vetRespUpdatedAt :: UTCTime
    }
    deriving (Show, Generic)

-- JSON output uses snake_case field names matching frontend expectations
instance ToJSON VsEditTrackerResponse where
    toJSON v =
        object
            [ "id" .= vetRespId v
            , "appGroup" .= vetRespAppGroup v
            , "product" .= vetRespAppGroup v  -- backward compat
            , "service" .= vetRespService v
            , "env" .= vetRespEnv v
            , "vs_name" .= vetRespVsName v
            , "old_vs_data" .= vetRespOldVsData v
            , "new_vs_data" .= vetRespNewVsData v
            , "status" .= vetRespStatus v
            , "created_by" .= vetRespCreatedBy v
            , "approved_by" .= vetRespApprovedBy v
            , "is_locked" .= vetRespIsLocked v
            , "locked_by" .= vetRespLockedBy v
            , "locked_at" .= vetRespLockedAt v
            , "lock_expiry" .= vetRespLockExpiry v
            , "monitoring_end_time" .= vetRespMonitoringEndTime v
            , "info" .= vetRespInfo v
            , "created_at" .= vetRespCreatedAt v
            , "updated_at" .= vetRespUpdatedAt v
            ]

-- ============================================================================
-- Server Config Response Types
-- ============================================================================

data ServerConfigEntry = ServerConfigEntry
    { sceKey :: Text
    , sceValue :: Text
    , sceType :: Text
    , sceDefault :: Text
    , sceDescription :: Text
    , sceProduct :: Maybe Text
    , sceEnabled :: Bool
    , sceId :: Int
    }
    deriving (Show, Generic)

instance ToJSON ServerConfigEntry where
    toJSON e =
        object
            [ "key" .= sceKey e
            , "value" .= sceValue e
            , "type" .= sceType e
            , "default" .= sceDefault e
            , "description" .= sceDescription e
            , "product" .= sceProduct e
            , "enabled" .= sceEnabled e
            , "id" .= sceId e
            ]

data ServerConfigGroup = ServerConfigGroup
    { scgName :: Text
    , scgConfigs :: [ServerConfigEntry]
    }
    deriving (Show, Generic)

instance ToJSON ServerConfigGroup where
    toJSON g =
        object
            [ "name" .= scgName g
            , "configs" .= scgConfigs g
            ]

data ServerConfigFlatItem = ServerConfigFlatItem
    { scfId :: Int
    , scfType :: Text
    , scfName :: Text
    , scfValue :: Text
    , scfEnabled :: Int
    , scfProduct :: Maybe Text
    }
    deriving (Show, Generic)

instance ToJSON ServerConfigFlatItem where
    toJSON i =
        object
            [ "id" .= scfId i
            , "type" .= scfType i
            , "name" .= scfName i
            , "value" .= scfValue i
            , "enabled" .= scfEnabled i
            , "product" .= scfProduct i
            ]

data ServerConfigResponse = ServerConfigResponse
    { scrGroups :: [ServerConfigGroup]
    , scrConfigs :: [ServerConfigFlatItem]
    }
    deriving (Show, Generic)

instance ToJSON ServerConfigResponse where
    toJSON r =
        object
            [ "groups" .= scrGroups r
            , "configs" .= scrConfigs r
            ]

-- ============================================================================
-- ConfigMap Tracker Response Type
-- ============================================================================

data ConfigMapResponse = ConfigMapResponse
    { cmrId :: Text
    , cmrService :: Text
    , cmrAppGroup :: Text
    , cmrName :: Maybe Text
    , cmrStatus :: Text
    , cmrDescription :: Text
    , cmrEnv :: Text
    , cmrCluster :: Text
    , cmrDateCreated :: Maybe UTCTime
    , cmrLastUpdated :: Maybe UTCTime
    , cmrStartTime :: Maybe UTCTime
    , cmrEndTime :: Maybe UTCTime
    , cmrReleaseManager :: Text
    , cmrIsApproved :: Int
    , cmrIsInfraApproved :: Int
    , cmrEvents :: [Value]
    , cmrReleaseTag :: Maybe Text
    , cmrConfig :: Maybe Text
    , cmrFile :: Maybe Text
    , cmrCommit :: Maybe Text
    , cmrChangeLog :: Text
    , cmrPriority :: Int32
    , cmrScheduleTime :: Maybe UTCTime
    , cmrSlackThreadId :: Text
    }
    deriving (Show, Generic)

instance ToJSON ConfigMapResponse where
    toJSON r =
        object
            [ "id" .= cmrId r
            , "service" .= cmrService r
            , "appGroup" .= cmrAppGroup r
            , "product" .= cmrAppGroup r  -- backward compat
            , "name" .= cmrName r
            , "status" .= cmrStatus r
            , "description" .= cmrDescription r
            , "env" .= cmrEnv r
            , "cluster" .= cmrCluster r
            , "date_created" .= cmrDateCreated r
            , "last_updated" .= cmrLastUpdated r
            , "start_time" .= cmrStartTime r
            , "end_time" .= cmrEndTime r
            , "release_manager" .= cmrReleaseManager r
            , "is_approved" .= cmrIsApproved r
            , "is_infra_approved" .= cmrIsInfraApproved r
            , "events" .= cmrEvents r
            , "release_tag" .= cmrReleaseTag r
            , "config" .= cmrConfig r
            , "file" .= cmrFile r
            , "commit" .= cmrCommit r
            , "change_log" .= cmrChangeLog r
            , "priority" .= cmrPriority r
            , "schedule_time" .= cmrScheduleTime r
            , "slack_thread_id" .= cmrSlackThreadId r
            ]

data ConfigMapListResponse = ConfigMapListResponse
    { cmlList :: [ConfigMapResponse]
    }
    deriving (Show, Generic)

instance ToJSON ConfigMapListResponse where
    toJSON r = object ["list" .= cmlList r]

-- ============================================================================
-- ConfigMap K8s Lookup Response
-- ============================================================================

data ConfigMapK8sResponse = ConfigMapK8sResponse
    { cmkConfigMap :: Value
    }
    deriving (Show, Generic)

instance ToJSON ConfigMapK8sResponse where
    toJSON r = object ["configMap" .= cmkConfigMap r]

instance FromJSON ConfigMapK8sResponse where
    parseJSON = withObject "ConfigMapK8sResponse" $ \v ->
        ConfigMapK8sResponse <$> v .: "configMap"

-- ============================================================================
-- Release Event Response Type
-- ============================================================================

data ReleaseEventResponse = ReleaseEventResponse
    { reCategory :: Text
    , reLabel :: Text
    , reData :: Value
    , reTimestamp :: UTCTime
    }
    deriving (Show, Generic)

instance ToJSON ReleaseEventResponse where
    toJSON e =
        object
            [ "category" .= reCategory e
            , "label" .= reLabel e
            , "data" .= reData e
            , "timestamp" .= reTimestamp e
            ]

-- ============================================================================
-- Error Response Type (for typed 404s etc.)
-- ============================================================================

data ErrorResponse = ErrorResponse
    { errError :: Text
    , errMessage :: Maybe Text
    }
    deriving (Show, Generic)

instance ToJSON ErrorResponse where
    toJSON (ErrorResponse e m) =
        object $ ["error" .= e] <> maybe [] (\msg -> ["message" .= msg]) m

-- ============================================================================
-- VS Lock Error Response
-- ============================================================================

data VsLockErrorResponse = VsLockErrorResponse
    { vleError :: Text
    , vleLockedBy :: Maybe Text
    , vleLockExpiry :: Maybe UTCTime
    }
    deriving (Show, Generic)

instance ToJSON VsLockErrorResponse where
    toJSON v =
        object
            [ "error" .= vleError v
            , "locked_by" .= vleLockedBy v
            , "lock_expiry" .= vleLockExpiry v
            ]

-- ============================================================================
-- Upsert Server Config Request Type
-- ============================================================================

data UpsertServerConfigReq = UpsertServerConfigReq
    { uscName :: Text
    , uscValue :: Maybe Text
    , uscEnabled :: Maybe Text
    }
    deriving (Show, Generic)

instance FromJSON UpsertServerConfigReq where
    parseJSON = withObject "UpsertServerConfigReq" $ \v ->
        UpsertServerConfigReq
            <$> (v .: "name")
            <*> v .:? "value"
            <*> (do
                    mVal <- v .:? "enabled"
                    case mVal of
                        Nothing -> pure Nothing
                        Just (String s) -> pure (Just s)
                        Just (Number n) -> pure (Just (pack (show (round n :: Int))))
                        Just (Bool b) -> pure (Just (if b then "1" else "0"))
                        _ -> pure Nothing
                )

instance ToJSON UpsertServerConfigReq where
    toJSON r =
        object
            [ "name" .= uscName r
            , "value" .= uscValue r
            , "enabled" .= uscEnabled r
            ]
