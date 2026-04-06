{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}

-- | Autopilot storage schema.
--
-- Canonical location for all autopilot-owned Beam table definitions:
--
--   * 'DeploymentConfigT'  — unified product+service deployment config
--   * 'ReleaseTrackerT'    — release tracker rows
--   * 'ReleaseEventT'      — release event log rows
--   * 'AutopilotDb'        — Beam Database binding the three autopilot tables
--
-- Cross-product tables (e.g. @server_config@) do NOT live here — they belong
-- under "Shared.Types.Storage.*" so that other products can use them without
-- reaching into Autopilot. See "Shared.Types.Storage.ServerConfig".
--
-- History: this module used to live at @Shared.Types.Storage.Schema@ and was
-- moved inside the Autopilot product in task #22. Task #30 then extracted
-- 'ServerConfigT' into Shared and renamed @NammaAPDb@ → 'AutopilotDb'.
module Products.Autopilot.Types.Storage.Schema where

import Data.Aeson (Value)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Database.Beam
import Database.Beam.Schema.Tables (fieldNamed, setEntityName)
import GHC.Int (Int32)

-- | Unified deployment config: product-level (service IS NULL) or service-level (service IS NOT NULL)
data DeploymentConfigT f = DeploymentConfigT
  { dcId :: Columnar f Int32,
    dcAppGroup :: Columnar f Text,
    dcService :: Columnar f (Maybe Text),
    -- Product-level fields (service IS NULL)
    dcCluster :: Columnar f (Maybe Text),
    dcNamespace :: Columnar f (Maybe Text),
    dcVsName :: Columnar f (Maybe Text),
    dcAppGroupAcronym :: Columnar f (Maybe Text),
    dcAppGroupType :: Columnar f (Maybe Text),
    dcSyncCluster :: Columnar f (Maybe Text),
    dcNeedInfraApproval :: Columnar f (Maybe Bool),
    dcVsLockedBy :: Columnar f (Maybe Text),
    dcVsLockTimestamp :: Columnar f (Maybe UTCTime),
    -- Service-level fields (service IS NOT NULL)
    dcServiceHost :: Columnar f (Maybe Text),
    dcServiceType :: Columnar f (Maybe Text),
    dcRolloutStrategy :: Columnar f (Maybe Text),
    dcRevertStrategy :: Columnar f (Maybe Text),
    dcDecisionConfig :: Columnar f (Maybe Text),
    dcSlackChannel :: Columnar f (Maybe Text)
  }
  deriving (Generic, Beamable)

type DeploymentConfig = DeploymentConfigT Identity

deriving instance Show DeploymentConfig

instance Table DeploymentConfigT where
  data PrimaryKey DeploymentConfigT f = DeploymentConfigId (Columnar f Int32) deriving (Generic, Beamable)
  primaryKey = DeploymentConfigId . dcId

data ReleaseTrackerT f = ReleaseTrackerT
  { rtId :: Columnar f Text,
    rtOldVersion :: Columnar f Text,
    rtNewVersion :: Columnar f Text,
    rtAppGroup :: Columnar f Text,
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
    rtSyncEnabled :: Columnar f (Maybe Text),
    rtEnvOverrideData :: Columnar f (Maybe Text),
    rtSlackThreadTs :: Columnar f (Maybe Text),
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

data AutopilotDb f = AutopilotDb
  { deploymentConfig :: f (TableEntity DeploymentConfigT),
    releaseTrackers :: f (TableEntity ReleaseTrackerT),
    releaseEvents :: f (TableEntity ReleaseEventT)
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
                { dcId = fieldNamed "id",
                  dcAppGroup = fieldNamed "app_group",
                  dcService = fieldNamed "service",
                  dcCluster = fieldNamed "cluster",
                  dcNamespace = fieldNamed "namespace",
                  dcVsName = fieldNamed "vs_name",
                  dcAppGroupAcronym = fieldNamed "product_acronym",
                  dcAppGroupType = fieldNamed "product_type",
                  dcSyncCluster = fieldNamed "sync_cluster",
                  dcNeedInfraApproval = fieldNamed "need_infra_approval",
                  dcVsLockedBy = fieldNamed "vs_locked_by",
                  dcVsLockTimestamp = fieldNamed "vs_lock_timestamp",
                  dcServiceHost = fieldNamed "service_host",
                  dcServiceType = fieldNamed "service_type",
                  dcRolloutStrategy = fieldNamed "rollout_strategy",
                  dcRevertStrategy = fieldNamed "revert_strategy",
                  dcDecisionConfig = fieldNamed "decision_config",
                  dcSlackChannel = fieldNamed "slack_channel"
                },
        releaseTrackers =
          setEntityName "release_tracker"
            <> modifyTableFields
              tableModification
                { rtId = fieldNamed "id",
                  rtOldVersion = fieldNamed "old_version",
                  rtNewVersion = fieldNamed "new_version",
                  rtAppGroup = fieldNamed "app_group",
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
                  rtSyncEnabled = fieldNamed "sync_enabled",
                  rtEnvOverrideData = fieldNamed "env_override_data",
                  rtSlackThreadTs = fieldNamed "slack_thread_ts",
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
                }
      }
