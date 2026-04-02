{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}

module Shared.Types.Storage.Schema where

import Data.Aeson (Value)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Database.Beam
import Database.Beam.Schema.Tables (fieldNamed, setEntityName)
import GHC.Int (Int32)

-- | Unified deployment config: product-level (service IS NULL) or service-level (service IS NOT NULL)
data DeploymentConfigT f = DeploymentConfigT
    { dcId :: Columnar f Int32
    , dcProduct :: Columnar f Text
    , dcService :: Columnar f (Maybe Text)
    -- Product-level fields (service IS NULL)
    , dcCluster :: Columnar f (Maybe Text)
    , dcNamespace :: Columnar f (Maybe Text)
    , dcVsName :: Columnar f (Maybe Text)
    , dcProductAcronym :: Columnar f (Maybe Text)
    , dcProductType :: Columnar f (Maybe Text)
    , dcRepoName :: Columnar f (Maybe Text)
    , dcReleaseBranch :: Columnar f (Maybe Text)
    , dcSyncCluster :: Columnar f (Maybe Text)
    , dcNeedInfraApproval :: Columnar f (Maybe Bool)
    , dcVsLockedBy :: Columnar f (Maybe Text)
    , dcVsLockTimestamp :: Columnar f (Maybe UTCTime)
    -- Service-level fields (service IS NOT NULL)
    , dcServiceHost :: Columnar f (Maybe Text)
    , dcServiceType :: Columnar f (Maybe Text)
    , dcServiceAcronym :: Columnar f (Maybe Text)
    , dcRolloutStrategy :: Columnar f (Maybe Text)
    , dcRevertStrategy :: Columnar f (Maybe Text)
    , dcDecisionConfig :: Columnar f (Maybe Text)
    , dcBitbucketPath :: Columnar f (Maybe Text)
    , dcSlackChannel :: Columnar f (Maybe Text)
    , dcEmails :: Columnar f (Maybe Text)
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
    , rtProduct :: Columnar f Text
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
    , rtUdf1 :: Columnar f (Maybe Text)
    , rtUdf2 :: Columnar f (Maybe Text)
    , rtUdf3 :: Columnar f (Maybe Text)
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

data ServerConfigT f = ServerConfigT
    { scId :: Columnar f Int32
    , scType :: Columnar f Text
    , scName :: Columnar f Text
    , scValue :: Columnar f Text
    , scLastUpdated :: Columnar f UTCTime
    , scEnabled :: Columnar f Int32
    , scProduct :: Columnar f (Maybe Text)
    }
    deriving (Generic, Beamable)

type ServerConfig = ServerConfigT Identity

deriving instance Show ServerConfig

instance Table ServerConfigT where
    data PrimaryKey ServerConfigT f = ServerConfigId (Columnar f Int32) deriving (Generic, Beamable)
    primaryKey = ServerConfigId . scId

data NammaAPDb f = NammaAPDb
    { deploymentConfig :: f (TableEntity DeploymentConfigT)
    , releaseTrackers :: f (TableEntity ReleaseTrackerT)
    , releaseEvents :: f (TableEntity ReleaseEventT)
    , serverConfigs :: f (TableEntity ServerConfigT)
    }
    deriving (Generic, Database be)

nammaAPDb :: DatabaseSettings be NammaAPDb
nammaAPDb =
    defaultDbSettings
        `withDbModification` dbModification
            { deploymentConfig =
                setEntityName "deployment_config"
                    <> modifyTableFields
                        tableModification
                            { dcId = fieldNamed "id"
                            , dcProduct = fieldNamed "product"
                            , dcService = fieldNamed "service"
                            , dcCluster = fieldNamed "cluster"
                            , dcNamespace = fieldNamed "namespace"
                            , dcVsName = fieldNamed "vs_name"
                            , dcProductAcronym = fieldNamed "product_acronym"
                            , dcProductType = fieldNamed "product_type"
                            , dcRepoName = fieldNamed "repo_name"
                            , dcReleaseBranch = fieldNamed "release_branch"
                            , dcSyncCluster = fieldNamed "sync_cluster"
                            , dcNeedInfraApproval = fieldNamed "need_infra_approval"
                            , dcVsLockedBy = fieldNamed "vs_locked_by"
                            , dcVsLockTimestamp = fieldNamed "vs_lock_timestamp"
                            , dcServiceHost = fieldNamed "service_host"
                            , dcServiceType = fieldNamed "service_type"
                            , dcServiceAcronym = fieldNamed "service_acronym"
                            , dcRolloutStrategy = fieldNamed "rollout_strategy"
                            , dcRevertStrategy = fieldNamed "revert_strategy"
                            , dcDecisionConfig = fieldNamed "decision_config"
                            , dcBitbucketPath = fieldNamed "bitbucket_path"
                            , dcSlackChannel = fieldNamed "slack_channel"
                            , dcEmails = fieldNamed "emails"
                            }
            , releaseTrackers =
                setEntityName "release_tracker"
                    <> modifyTableFields
                        tableModification
                            { rtId = fieldNamed "id"
                            , rtOldVersion = fieldNamed "old_version"
                            , rtNewVersion = fieldNamed "new_version"
                            , rtProduct = fieldNamed "product"
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
                            , rtUdf1 = fieldNamed "udf1"
                            , rtUdf2 = fieldNamed "udf2"
                            , rtUdf3 = fieldNamed "udf3"
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
            , serverConfigs =
                setEntityName "server_config"
                    <> modifyTableFields
                        tableModification
                            { scId = fieldNamed "id"
                            , scType = fieldNamed "type"
                            , scName = fieldNamed "name"
                            , scValue = fieldNamed "value"
                            , scLastUpdated = fieldNamed "last_updated"
                            , scEnabled = fieldNamed "enabled"
                            , scProduct = fieldNamed "product"
                            }
            }
