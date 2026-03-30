{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}

module NammaAP.Products.Autopilot.Types.Storage.Schema where

import Data.Aeson (Value)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Database.Beam
import GHC.Int (Int32)
import Database.Beam.Schema.Tables (fieldNamed, setEntityName)

data ProductConfigT f = ProductConfigT
  { productConfigId :: Columnar f Int32,
    productName :: Columnar f Text,
    productRepoName :: Columnar f Text,
    productType :: Columnar f Text,
    productAcronym :: Columnar f Text,
    productReleaseBranch :: Columnar f Text,
    productNeedInfraApproval :: Columnar f (Maybe Bool),
    productTargetConfig :: Columnar f (Maybe Text)
  }
  deriving (Generic, Beamable)

type ProductConfig = ProductConfigT Identity
deriving instance Show ProductConfig

instance Table ProductConfigT where
  data PrimaryKey ProductConfigT f = ProductConfigId (Columnar f Int32) deriving (Generic, Beamable)
  primaryKey = ProductConfigId . productConfigId

data ReleaseConfigT f = ReleaseConfigT
  { releaseConfigId :: Columnar f Int32,
    releaseConfigEmails :: Columnar f (Maybe Text),
    releaseConfigRolloutStrategy :: Columnar f (Maybe Text),
    releaseConfigDecisionConfig :: Columnar f (Maybe Text),
    serviceName :: Columnar f Text,
    serviceProduct :: Columnar f Text,
    releaseConfigFlags :: Columnar f (Maybe Text),
    releaseConfigSlackWebhookUrls :: Columnar f (Maybe Text),
    serviceAcronym :: Columnar f (Maybe Text),
    serviceType :: Columnar f Text,
    releaseConfigBitbucketPath :: Columnar f (Maybe Text),
    releaseConfigRevertStrategy :: Columnar f (Maybe Text),
    serviceTargetConfig :: Columnar f (Maybe Text)
  }
  deriving (Generic, Beamable)

type ReleaseConfig = ReleaseConfigT Identity
deriving instance Show ReleaseConfig

instance Table ReleaseConfigT where
  data PrimaryKey ReleaseConfigT f = ReleaseConfigIdKey (Columnar f Int32) deriving (Generic, Beamable)
  primaryKey = ReleaseConfigIdKey . releaseConfigId

data ReleaseTrackerT f = ReleaseTrackerT
  { rtId :: Columnar f Text,
    rtOldVersion :: Columnar f Text,
    rtNewVersion :: Columnar f Text,
    rtProduct :: Columnar f Text,
    rtService :: Columnar f Text,
    rtPriority :: Columnar f Int32,
    rtEnv :: Columnar f Text,
    rtCategory :: Columnar f Text,
    rtStatus :: Columnar f Text,
    rtReleaseWFStatus :: Columnar f Text,
    rtMode :: Columnar f (Maybe Text),
    rtCreatedBy :: Columnar f Text,
    rtApprovedBy :: Columnar f (Maybe Text),
    rtIsApproved :: Columnar f (Maybe Bool),
    rtIsInfraApproved :: Columnar f (Maybe Bool),
    rtReleaseTag :: Columnar f (Maybe Text),
    rtScheduleTime :: Columnar f (Maybe UTCTime),
    rtStartTime :: Columnar f (Maybe UTCTime),
    rtEndTime :: Columnar f (Maybe UTCTime),
    rtRolloutStrategy :: Columnar f (Maybe Text),
    rtRolloutHistory :: Columnar f (Maybe Text),
    rtTargetState :: Columnar f (Maybe Text),
    rtInfo :: Columnar f (Maybe Text),
    rtDescription :: Columnar f (Maybe Text),
    rtChangeLog :: Columnar f (Maybe Text),
    rtMetadata :: Columnar f (Maybe Text),
    rtGlobalId :: Columnar f (Maybe Text),
    rtUdf1 :: Columnar f (Maybe Text),
    rtUdf2 :: Columnar f (Maybe Text),
    rtUdf3 :: Columnar f (Maybe Text),
    rtCreatedAt :: Columnar f UTCTime,
    rtUpdatedAt :: Columnar f UTCTime
  }
  deriving (Generic, Beamable)

type ReleaseTrackerRow = ReleaseTrackerT Identity
deriving instance Show ReleaseTrackerRow

instance Table ReleaseTrackerT where
  data PrimaryKey ReleaseTrackerT f = ReleaseTrackerId (Columnar f Text) deriving (Generic, Beamable)
  primaryKey = ReleaseTrackerId . rtId

data ReleaseEventT f = ReleaseEventT
  { reId :: Columnar f Int32,
    reReleaseId :: Columnar f Text,
    reCategory :: Columnar f Text,
    reLabel :: Columnar f Text,
    rePayload :: Columnar f Value,
    reCreatedAt :: Columnar f UTCTime
  }
  deriving (Generic, Beamable)

type ReleaseEvent = ReleaseEventT Identity
deriving instance Show ReleaseEvent

instance Table ReleaseEventT where
  data PrimaryKey ReleaseEventT f = ReleaseEventId (Columnar f Int32) deriving (Generic, Beamable)
  primaryKey = ReleaseEventId . reId

data ServerConfigT f = ServerConfigT
  { scId :: Columnar f Int32,
    scType :: Columnar f Text,
    scName :: Columnar f Text,
    scValue :: Columnar f Text,
    scLastUpdated :: Columnar f UTCTime,
    scEnabled :: Columnar f Int32
  }
  deriving (Generic, Beamable)

type ServerConfig = ServerConfigT Identity
deriving instance Show ServerConfig

instance Table ServerConfigT where
  data PrimaryKey ServerConfigT f = ServerConfigId (Columnar f Int32) deriving (Generic, Beamable)
  primaryKey = ServerConfigId . scId

data ConfigMapTrackerT f = ConfigMapTrackerT
  { cmtId :: Columnar f Text,
    cmtService :: Columnar f Text,
    cmtStatus :: Columnar f Text,
    cmtDescription :: Columnar f (Maybe Text),
    cmtEnv :: Columnar f Text,
    cmtCluster :: Columnar f Text,
    cmtProduct :: Columnar f Text,
    cmtDateCreated :: Columnar f UTCTime,
    cmtLastUpdated :: Columnar f UTCTime,
    cmtStartTime :: Columnar f (Maybe UTCTime),
    cmtEndTime :: Columnar f (Maybe UTCTime),
    cmtReleaseManager :: Columnar f Text,
    cmtIsApproved :: Columnar f (Maybe Bool),
    cmtEvents :: Columnar f (Maybe Text),
    cmtReleaseTag :: Columnar f (Maybe Text),
    cmtIsInfraApproved :: Columnar f (Maybe Bool),
    cmtConfig :: Columnar f (Maybe Text),
    cmtCommit :: Columnar f (Maybe Text),
    cmtChangeLog :: Columnar f (Maybe Text),
    cmtPriority :: Columnar f (Maybe Int32),
    cmtScheduleTime :: Columnar f (Maybe UTCTime),
    cmtName :: Columnar f (Maybe Text),
    cmtFile :: Columnar f (Maybe Text)
  }
  deriving (Generic, Beamable)

type ConfigMapTrackerRow = ConfigMapTrackerT Identity
deriving instance Show ConfigMapTrackerRow

instance Table ConfigMapTrackerT where
  data PrimaryKey ConfigMapTrackerT f = ConfigMapTrackerId (Columnar f Text) deriving (Generic, Beamable)
  primaryKey = ConfigMapTrackerId . cmtId

data NammaAPDb f = NammaAPDb
  { productConfig :: f (TableEntity ProductConfigT),
    releaseConfig :: f (TableEntity ReleaseConfigT),
    releaseTrackers :: f (TableEntity ReleaseTrackerT),
    releaseEvents :: f (TableEntity ReleaseEventT),
    serverConfigs :: f (TableEntity ServerConfigT),
    configMapTrackers :: f (TableEntity ConfigMapTrackerT)
  }
  deriving (Generic, Database be)

nammaAPDb :: DatabaseSettings be NammaAPDb
nammaAPDb =
  defaultDbSettings
    `withDbModification`
      dbModification
        { productConfig =
            setEntityName "product_config"
              <> modifyTableFields
                tableModification
                { productConfigId = fieldNamed "id",
                  productName = fieldNamed "product",
                  productRepoName = fieldNamed "repo_name",
                  productType = fieldNamed "product_type",
                  productAcronym = fieldNamed "product_acronym",
                  productReleaseBranch = fieldNamed "release_branch",
                  productNeedInfraApproval = fieldNamed "need_infra_approval",
                  productTargetConfig = fieldNamed "target_config"
                },
          releaseConfig =
            setEntityName "release_config"
              <> modifyTableFields
                tableModification
                { releaseConfigId = fieldNamed "id",
                  releaseConfigEmails = fieldNamed "emails",
                  releaseConfigRolloutStrategy = fieldNamed "rollout_strategy",
                  releaseConfigDecisionConfig = fieldNamed "decision_config",
                  serviceName = fieldNamed "service",
                  serviceProduct = fieldNamed "product",
                  releaseConfigFlags = fieldNamed "flags",
                  releaseConfigSlackWebhookUrls = fieldNamed "slack_webhook_urls",
                  serviceAcronym = fieldNamed "service_acronym",
                  serviceType = fieldNamed "service_type",
                  releaseConfigBitbucketPath = fieldNamed "bitbucket_path",
                  releaseConfigRevertStrategy = fieldNamed "revert_strategy",
                  serviceTargetConfig = fieldNamed "target_config"
                },
          releaseTrackers =
            setEntityName "release_tracker"
              <> modifyTableFields
                tableModification
                { rtId = fieldNamed "id",
                  rtOldVersion = fieldNamed "old_version",
                  rtNewVersion = fieldNamed "new_version",
                  rtProduct = fieldNamed "product",
                  rtService = fieldNamed "service",
                  rtPriority = fieldNamed "priority",
                  rtEnv = fieldNamed "env",
                  rtCategory = fieldNamed "category",
                  rtStatus = fieldNamed "status",
                  rtReleaseWFStatus = fieldNamed "release_wf_status",
                  rtMode = fieldNamed "mode",
                  rtCreatedBy = fieldNamed "release_manager",
                  rtApprovedBy = fieldNamed "approved_by",
                  rtIsApproved = fieldNamed "is_approved",
                  rtIsInfraApproved = fieldNamed "is_infra_approved",
                  rtReleaseTag = fieldNamed "release_tag",
                  rtScheduleTime = fieldNamed "schedule_time",
                  rtStartTime = fieldNamed "start_time",
                  rtEndTime = fieldNamed "end_time",
                  rtRolloutStrategy = fieldNamed "rollout_strategy",
                  rtRolloutHistory = fieldNamed "rollout_history",
                  rtTargetState = fieldNamed "release_context",
                  rtInfo = fieldNamed "info",
                  rtDescription = fieldNamed "description",
                  rtChangeLog = fieldNamed "change_log",
                  rtMetadata = fieldNamed "metadata",
                  rtGlobalId = fieldNamed "global_id",
                  rtUdf1 = fieldNamed "udf1",
                  rtUdf2 = fieldNamed "udf2",
                  rtUdf3 = fieldNamed "udf3",
                  rtCreatedAt = fieldNamed "date_created",
                  rtUpdatedAt = fieldNamed "last_updated"
                },
          releaseEvents =
            setEntityName "release_events"
              <> modifyTableFields
                tableModification
                { reId = fieldNamed "re_id",
                  reReleaseId = fieldNamed "re_release_id",
                  reCategory = fieldNamed "re_category",
                  reLabel = fieldNamed "re_label",
                  rePayload = fieldNamed "re_payload",
                  reCreatedAt = fieldNamed "re_created_at"
                },
          serverConfigs =
            setEntityName "server_config"
              <> modifyTableFields
                tableModification
                { scId = fieldNamed "id",
                  scType = fieldNamed "type",
                  scName = fieldNamed "name",
                  scValue = fieldNamed "value",
                  scLastUpdated = fieldNamed "last_updated",
                  scEnabled = fieldNamed "enabled"
                },
          configMapTrackers =
            setEntityName "configmap_tracker"
              <> modifyTableFields
                tableModification
                { cmtId = fieldNamed "id",
                  cmtService = fieldNamed "service",
                  cmtStatus = fieldNamed "status",
                  cmtDescription = fieldNamed "description",
                  cmtEnv = fieldNamed "env",
                  cmtCluster = fieldNamed "cluster",
                  cmtProduct = fieldNamed "product",
                  cmtDateCreated = fieldNamed "date_created",
                  cmtLastUpdated = fieldNamed "last_updated",
                  cmtStartTime = fieldNamed "start_time",
                  cmtEndTime = fieldNamed "end_time",
                  cmtReleaseManager = fieldNamed "release_manager",
                  cmtIsApproved = fieldNamed "is_approved",
                  cmtEvents = fieldNamed "events",
                  cmtReleaseTag = fieldNamed "release_tag",
                  cmtIsInfraApproved = fieldNamed "is_infra_approved",
                  cmtConfig = fieldNamed "config",
                  cmtCommit = fieldNamed "commit",
                  cmtChangeLog = fieldNamed "change_log",
                  cmtPriority = fieldNamed "priority",
                  cmtScheduleTime = fieldNamed "schedule_time",
                  cmtName = fieldNamed "name",
                  cmtFile = fieldNamed "file"
                }
        }
