{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}

{- | Autopilot-owned Beam tables: 'DeploymentConfigT', 'ReleaseTrackerT',
'ReleaseEventT', bound together by 'AutopilotDb'. Cross-product tables
(e.g. @server_config@) belong under @Shared.Types.Storage.*@.
-}
module Products.Autopilot.Types.Storage.Schema where

import Data.Aeson (Value)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Database.Beam
import GHC.Int (Int32)
import Products.Autopilot.Mobile.Types.Storage (AppCatalogT, StoreStatusT, appCatalog, storeStatus)

-- | Product-level row when @dcService@ IS NULL; service-level otherwise.
data DeploymentConfigT f = DeploymentConfigT
    { dcId :: Columnar f Int32
    , dcAppGroup :: Columnar f Text
    , dcService :: Columnar f (Maybe Text)
    , -- Product-level fields (service IS NULL)
      dcCluster :: Columnar f (Maybe Text)
    , dcNamespace :: Columnar f (Maybe Text)
    , dcVsName :: Columnar f (Maybe Text)
    , dcAppGroupAcronym :: Columnar f (Maybe Text)
    , dcRepoName :: Columnar f (Maybe Text)
    , dcAppGroupType :: Columnar f (Maybe Text)
    , dcSyncCluster :: Columnar f (Maybe Text)
    , dcNeedInfraApproval :: Columnar f (Maybe Bool)
    , dcVsLockedBy :: Columnar f (Maybe Text)
    , dcVsLockTimestamp :: Columnar f (Maybe UTCTime)
    , -- Service-level fields (service IS NOT NULL)
      dcServiceHost :: Columnar f (Maybe Text)
    , dcServiceType :: Columnar f (Maybe Text)
    , dcRolloutStrategy :: Columnar f (Maybe Text)
    , dcRevertStrategy :: Columnar f (Maybe Text)
    , dcDecisionConfig :: Columnar f (Maybe Text)
    , dcSlackChannel :: Columnar f (Maybe Text)
    , dcServiceState :: Columnar f (Maybe Text)
    , dcHpaMinReplicas :: Columnar f (Maybe Int32)
    , dcHpaMaxReplicas :: Columnar f (Maybe Int32)
    , dcCloudType :: Columnar f Text
    }
    deriving (Generic, Beamable)

type DeploymentConfig = DeploymentConfigT Identity

deriving instance Show DeploymentConfig

instance Table DeploymentConfigT where
    data PrimaryKey DeploymentConfigT f = DeploymentConfigId (Columnar f Int32) deriving (Generic, Beamable)
    primaryKey = DeploymentConfigId . dcId

data ReleaseTrackerT f = ReleaseTrackerT
    { rtId :: Columnar f Text
    , rtOldVersion :: Columnar f Text
    , rtNewVersion :: Columnar f Text
    , rtAppGroup :: Columnar f Text
    , rtService :: Columnar f Text
    , rtPriority :: Columnar f Int32
    , rtEnv :: Columnar f Text
    , rtCategory :: Columnar f Text
    , rtStatus :: Columnar f Text
    , rtReleaseWFStatus :: Columnar f Text
    , rtMode :: Columnar f (Maybe Text)
    , rtCreatedBy :: Columnar f Text
    , rtApprovedBy :: Columnar f (Maybe Text)
    , rtIsApproved :: Columnar f (Maybe Bool)
    , rtIsInfraApproved :: Columnar f (Maybe Bool)
    , rtReleaseTag :: Columnar f (Maybe Text)
    , rtScheduleTime :: Columnar f (Maybe UTCTime)
    , rtStartTime :: Columnar f (Maybe UTCTime)
    , rtEndTime :: Columnar f (Maybe UTCTime)
    , rtRolloutStrategy :: Columnar f (Maybe Text)
    , rtRolloutHistory :: Columnar f (Maybe Text)
    , rtTargetState :: Columnar f (Maybe Text)
    , rtInfo :: Columnar f (Maybe Text)
    , rtDescription :: Columnar f (Maybe Text)
    , rtChangeLog :: Columnar f (Maybe Text)
    , rtMetadata :: Columnar f (Maybe Text)
    , rtGlobalId :: Columnar f (Maybe Text)
    , rtSyncEnabled :: Columnar f (Maybe Text)
    , rtEnvOverrideData :: Columnar f (Maybe Text)
    , rtSlackThreadTs :: Columnar f (Maybe Text)
    , rtDispatchId :: Columnar f (Maybe Text)
    , rtExternalRunId :: Columnar f (Maybe Text)
    , rtCommitSha :: Columnar f (Maybe Text)
    , rtSourceRef :: Columnar f (Maybe Text)
    , rtRevertsReleaseId :: Columnar f (Maybe Text)
    , rtAbValidationStatus :: Columnar f (Maybe Text)
    , rtAbValidation :: Columnar f (Maybe Text)
    , -- Store review + staged rollout (migration 0027). Mobile-only; defaulted to
      -- Nothing for backend / configmap / VSEdit rows.
      rtReviewStatus :: Columnar f (Maybe Text)
    , rtReviewSubmittedAt :: Columnar f (Maybe UTCTime)
    , rtReviewDecidedAt :: Columnar f (Maybe UTCTime)
    , rtReviewRejectReason :: Columnar f (Maybe Text)
    , rtRolloutStatus :: Columnar f (Maybe Text)
    , rtRolloutPercent :: Columnar f (Maybe Double)
    , rtStoreRolloutHistory :: Columnar f (Maybe Text)
    , rtAscVersionId :: Columnar f (Maybe Text)
    , rtAscPhasedId :: Columnar f (Maybe Text)
    , rtStoreTrack :: Columnar f (Maybe Text)
    , rtVersionCode :: Columnar f (Maybe Int32)
    , rtTerminalStatus :: Columnar f (Maybe Text)
    , rtReleaseGroupId :: Columnar f (Maybe Text)
    , rtReleaseGroupLabel :: Columnar f (Maybe Text)
    , rtCloudType :: Columnar f (Maybe Text)
    , rtCreatedAt :: Columnar f UTCTime
    , rtUpdatedAt :: Columnar f UTCTime
    }
    deriving (Generic, Beamable)

type ReleaseTrackerRow = ReleaseTrackerT Identity

deriving instance Show ReleaseTrackerRow

instance Table ReleaseTrackerT where
    data PrimaryKey ReleaseTrackerT f = ReleaseTrackerId (Columnar f Text) deriving (Generic, Beamable)
    primaryKey = ReleaseTrackerId . rtId

data ReleaseEventT f = ReleaseEventT
    { reId :: Columnar f Int32
    , reReleaseId :: Columnar f Text
    , reCategory :: Columnar f Text
    , reLabel :: Columnar f Text
    , rePayload :: Columnar f Value
    , reCreatedAt :: Columnar f UTCTime
    }
    deriving (Generic, Beamable)

type ReleaseEvent = ReleaseEventT Identity

deriving instance Show ReleaseEvent

instance Table ReleaseEventT where
    data PrimaryKey ReleaseEventT f = ReleaseEventId (Columnar f Int32) deriving (Generic, Beamable)
    primaryKey = ReleaseEventId . reId

data AutopilotDb f = AutopilotDb
    { deploymentConfig :: f (TableEntity DeploymentConfigT)
    , releaseTrackers :: f (TableEntity ReleaseTrackerT)
    , releaseEvents :: f (TableEntity ReleaseEventT)
    , appCatalogs :: f (TableEntity AppCatalogT)
    , storeStatuses :: f (TableEntity StoreStatusT)
    }
    deriving (Generic, Database be)

autopilotDb :: DatabaseSettings be AutopilotDb
autopilotDb =
    defaultDbSettings
        `withDbModification` dbModification
            { deploymentConfig =
                setEntityName "deployment_config"
                    <> modifyTableFields
                        tableModification
                            { dcId = fieldNamed "id"
                            , dcAppGroup = fieldNamed "app_group"
                            , dcService = fieldNamed "service"
                            , dcCluster = fieldNamed "cluster"
                            , dcNamespace = fieldNamed "namespace"
                            , dcVsName = fieldNamed "vs_name"
                            , dcAppGroupAcronym = fieldNamed "product_acronym"
                            , dcRepoName = fieldNamed "repo_name"
                            , dcAppGroupType = fieldNamed "product_type"
                            , dcSyncCluster = fieldNamed "sync_cluster"
                            , dcNeedInfraApproval = fieldNamed "need_infra_approval"
                            , dcVsLockedBy = fieldNamed "vs_locked_by"
                            , dcVsLockTimestamp = fieldNamed "vs_lock_timestamp"
                            , dcServiceHost = fieldNamed "service_host"
                            , dcServiceType = fieldNamed "service_type"
                            , dcRolloutStrategy = fieldNamed "rollout_strategy"
                            , dcRevertStrategy = fieldNamed "revert_strategy"
                            , dcDecisionConfig = fieldNamed "decision_config"
                            , dcSlackChannel = fieldNamed "slack_channel"
                            , dcServiceState = fieldNamed "service_state"
                            , dcCloudType = fieldNamed "cloud_type"
                            }
            , releaseTrackers =
                setEntityName "release_tracker"
                    <> modifyTableFields
                        tableModification
                            { rtId = fieldNamed "id"
                            , rtOldVersion = fieldNamed "old_version"
                            , rtNewVersion = fieldNamed "new_version"
                            , rtAppGroup = fieldNamed "app_group"
                            , rtService = fieldNamed "service"
                            , rtPriority = fieldNamed "priority"
                            , rtEnv = fieldNamed "env"
                            , rtCategory = fieldNamed "category"
                            , rtStatus = fieldNamed "status"
                            , rtReleaseWFStatus = fieldNamed "release_wf_status"
                            , rtMode = fieldNamed "mode"
                            , rtCreatedBy = fieldNamed "release_manager"
                            , rtApprovedBy = fieldNamed "approved_by"
                            , rtIsApproved = fieldNamed "is_approved"
                            , rtIsInfraApproved = fieldNamed "is_infra_approved"
                            , rtReleaseTag = fieldNamed "release_tag"
                            , rtScheduleTime = fieldNamed "schedule_time"
                            , rtStartTime = fieldNamed "start_time"
                            , rtEndTime = fieldNamed "end_time"
                            , rtRolloutStrategy = fieldNamed "rollout_strategy"
                            , rtRolloutHistory = fieldNamed "rollout_history"
                            , rtTargetState = fieldNamed "release_context"
                            , rtInfo = fieldNamed "info"
                            , rtDescription = fieldNamed "description"
                            , rtChangeLog = fieldNamed "change_log"
                            , rtMetadata = fieldNamed "metadata"
                            , rtGlobalId = fieldNamed "global_id"
                            , rtSyncEnabled = fieldNamed "sync_enabled"
                            , rtEnvOverrideData = fieldNamed "env_override_data"
                            , rtSlackThreadTs = fieldNamed "slack_thread_ts"
                            , rtDispatchId = fieldNamed "dispatch_id"
                            , rtExternalRunId = fieldNamed "external_run_id"
                            , rtCommitSha = fieldNamed "commit_sha"
                            , rtSourceRef = fieldNamed "source_ref"
                            , rtRevertsReleaseId = fieldNamed "reverts_release_id"
                            , rtAbValidationStatus = fieldNamed "ab_validation_status"
                            , rtAbValidation = fieldNamed "ab_validation"
                            , rtReviewStatus = fieldNamed "review_status"
                            , rtReviewSubmittedAt = fieldNamed "review_submitted_at"
                            , rtReviewDecidedAt = fieldNamed "review_decided_at"
                            , rtReviewRejectReason = fieldNamed "review_reject_reason"
                            , rtRolloutStatus = fieldNamed "rollout_status"
                            , rtRolloutPercent = fieldNamed "rollout_percent"
                            , rtStoreRolloutHistory = fieldNamed "store_rollout_history"
                            , rtAscVersionId = fieldNamed "asc_version_id"
                            , rtAscPhasedId = fieldNamed "asc_phased_id"
                            , rtStoreTrack = fieldNamed "store_track"
                            , rtVersionCode = fieldNamed "version_code"
                            , rtTerminalStatus = fieldNamed "terminal_status"
                            , rtReleaseGroupId = fieldNamed "release_group_id"
                            , rtReleaseGroupLabel = fieldNamed "release_group_label"
                            , rtCloudType = fieldNamed "cloud_type"
                            , rtCreatedAt = fieldNamed "date_created"
                            , rtUpdatedAt = fieldNamed "last_updated"
                            }
            , releaseEvents =
                setEntityName "release_events"
                    <> modifyTableFields
                        tableModification
                            { reId = fieldNamed "re_id"
                            , reReleaseId = fieldNamed "re_release_id"
                            , reCategory = fieldNamed "re_category"
                            , reLabel = fieldNamed "re_label"
                            , rePayload = fieldNamed "re_payload"
                            , reCreatedAt = fieldNamed "re_created_at"
                            }
            , appCatalogs = appCatalog
            , storeStatuses = storeStatus
            }
