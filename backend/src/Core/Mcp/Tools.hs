{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Core.Mcp.Tools
  ( McpTool (..),
    mcpProduct,
    mcpTools,
  )
where

import Control.Monad.Catch (throwM)
import Core.Admin.Queries (writeAuditLog)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson (..))
import Core.Environment (Flow)
import Data.Aeson (FromJSON, Result (..), Value (..), fromJSON, object, toJSON, (.=))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Data.Text qualified as T
import Products.Autopilot.Actions.ConfigMap qualified as ConfigMap
import Products.Autopilot.Actions.Release qualified as Release
import Products.Autopilot.Types.API
import Products.Autopilot.Types.Permission (AutopilotPermission (..))

data McpTool = McpTool
  { mtName :: Text,
    mtDescription :: Text,
    mtInputSchema :: Value,
    mtPermission :: AutopilotPermission,
    mtRun :: AuthedPerson -> Value -> Flow Value
  }

mcpProduct :: Text
mcpProduct = "autopilot"

asObject :: Value -> KM.KeyMap Value
asObject (Object o) = o
asObject _ = KM.empty

textArg :: Text -> Value -> Maybe Text
textArg k v = case KM.lookup (K.fromText k) (asObject v) of
  Just (String t) | not (T.null t) -> Just t
  _ -> Nothing

requireTextArg :: Text -> Value -> Flow Text
requireTextArg k v = case textArg k v of
  Just t -> pure t
  Nothing -> throwM $ BadRequest ("Missing required argument: " <> k)

decodeArg :: (FromJSON a) => Value -> Flow a
decodeArg v = case fromJSON v of
  Success a -> pure a
  Error e -> throwM $ BadRequest (T.pack e)

auditMcp :: AuthedPerson -> Text -> Text -> Maybe Text -> Flow ()
auditMcp ap toolName entityType entityId =
  writeAuditLog (apPersonId ap) ("MCP_" <> T.toUpper toolName) (Just entityType) entityId (Just (object ["source" .= ("mcp" :: Text), "tool" .= toolName]))

objSchema :: [(Text, Value)] -> [Text] -> Value
objSchema props required =
  object
    [ "type" .= ("object" :: Text),
      "properties" .= object (map (\(k, v) -> K.fromText k .= v) props),
      "required" .= required,
      "additionalProperties" .= True
    ]

strP :: Text -> Value
strP desc = object ["type" .= ("string" :: Text), "description" .= desc]

boolP :: Text -> Value
boolP desc = object ["type" .= ("boolean" :: Text), "description" .= desc]

intP :: Text -> Value
intP desc = object ["type" .= ("integer" :: Text), "description" .= desc]

rid :: Value
rid = strP "The releaseId of the tracker to act on"

releaseListTool :: McpTool
releaseListTool =
  McpTool
    { mtName = "release_list",
      mtDescription = "List release trackers, optionally filtered by date range and category.",
      mtInputSchema =
        objSchema
          [ ("from", strP "Start date (ISO8601), optional"),
            ("to", strP "End date (ISO8601), optional"),
            ("category", strP "Release category filter, optional")
          ]
          [],
      mtPermission = AP_RELEASE_VIEW,
      mtRun = \ap args ->
        toJSON <$> Release.listReleasesH ap (textArg "from" args) (textArg "to" args) (textArg "category" args)
    }

releaseGetTool :: McpTool
releaseGetTool =
  McpTool
    { mtName = "release_get",
      mtDescription = "Get a single release tracker by releaseId.",
      mtInputSchema = objSchema [("releaseId", rid)] ["releaseId"],
      mtPermission = AP_RELEASE_VIEW,
      mtRun = \ap args -> do
        r <- requireTextArg "releaseId" args
        toJSON <$> Release.getReleaseH ap r
    }

releaseCreateTool :: McpTool
releaseCreateTool =
  McpTool
    { mtName = "release_create",
      mtDescription = "Create a new release for a service (appGroup/product + service + version bump). Triggers the release workflow.",
      mtInputSchema =
        objSchema
          [ ("appGroup", strP "App group / product slug (alias: product)"),
            ("service", strP "Service name"),
            ("env", strP "Environment, e.g. UAT/PROD (defaults to UAT)"),
            ("trackerType", strP "Release category, e.g. BackendService"),
            ("oldVersion", strP "Current version"),
            ("newVersion", strP "Target version"),
            ("releaseTag", strP "Optional release tag"),
            ("description", strP "Optional description"),
            ("priority", intP "Optional priority")
          ]
          ["appGroup", "service"],
      mtPermission = AP_RELEASE_CREATE,
      mtRun = \ap args -> do
        req <- decodeArg args :: Flow K8sCreateReleaseReq
        result <- Release.createReleaseH ap Nothing Nothing req
        auditMcp ap "release_create" "release" Nothing
        pure (toJSON result)
    }

releaseApproveTool :: McpTool
releaseApproveTool =
  McpTool
    { mtName = "release_approve",
      mtDescription = "Approve a release for deployment.",
      mtInputSchema =
        objSchema
          [ ("releaseId", rid),
            ("approvedBy", strP "Approver identity (defaults to the caller's email)"),
            ("isInfraApproved", boolP "Whether infra approval is also granted")
          ]
          ["releaseId"],
      mtPermission = AP_RELEASE_APPROVE,
      mtRun = \ap args -> do
        r <- requireTextArg "releaseId" args
        req <- decodeArg (withDefaultApprovedBy ap args) :: Flow ApproveReleaseReq
        result <- Release.approveReleaseH ap r req
        auditMcp ap "release_approve" "release" (Just r)
        pure (toJSON result)
    }
  where
    withDefaultApprovedBy ap (Object o)
      | not (KM.member (K.fromText "approvedBy") o) =
          Object (KM.insert (K.fromText "approvedBy") (String (apEmail ap)) o)
    withDefaultApprovedBy _ v = v

releaseTriggerTool :: McpTool
releaseTriggerTool =
  McpTool
    { mtName = "release_trigger",
      mtDescription = "Trigger (kick off) an approved release.",
      mtInputSchema = objSchema [("releaseId", rid), ("reason", strP "Optional reason")] ["releaseId"],
      mtPermission = AP_RELEASE_CREATE,
      mtRun = \ap args -> do
        r <- requireTextArg "releaseId" args
        req <- decodeArg args :: Flow TriggerReleaseReq
        result <- Release.triggerReleaseH ap r req
        auditMcp ap "release_trigger" "release" (Just r)
        pure (toJSON result)
    }

releaseRollbackTool :: McpTool
releaseRollbackTool =
  McpTool
    { mtName = "release_rollback",
      mtDescription = "Roll back a release.",
      mtInputSchema = objSchema [("releaseId", rid), ("reason", strP "Optional reason")] ["releaseId"],
      mtPermission = AP_RELEASE_REVERT,
      mtRun = \ap args -> do
        r <- requireTextArg "releaseId" args
        req <- decodeArg args :: Flow TriggerReleaseReq
        result <- Release.rollbackReleaseH ap r req
        auditMcp ap "release_rollback" "release" (Just r)
        pure (toJSON result)
    }

releaseRevertTool :: McpTool
releaseRevertTool =
  McpTool
    { mtName = "release_revert",
      mtDescription = "Revert a completed release to its previous version.",
      mtInputSchema =
        objSchema
          [ ("releaseId", rid),
            ("requestedBy", strP "Requester identity (defaults to the caller's email)"),
            ("info", strP "Optional info/reason"),
            ("immediate", boolP "Whether to revert immediately")
          ]
          ["releaseId"],
      mtPermission = AP_RELEASE_REVERT,
      mtRun = \ap args -> do
        r <- requireTextArg "releaseId" args
        req <- decodeArg (withDefaultRequestedBy ap args) :: Flow RevertReleaseReq
        result <- Release.revertReleaseH ap r req
        auditMcp ap "release_revert" "release" (Just r)
        pure (toJSON result)
    }

releaseDiscardTool :: McpTool
releaseDiscardTool =
  McpTool
    { mtName = "release_discard",
      mtDescription = "Discard a release that hasn't been triggered yet.",
      mtInputSchema = objSchema [("releaseId", rid), ("reason", strP "Optional reason")] ["releaseId"],
      mtPermission = AP_RELEASE_DISCARD,
      mtRun = \ap args -> do
        r <- requireTextArg "releaseId" args
        req <- decodeArg args :: Flow DiscardReleaseReq
        result <- Release.discardReleaseH ap r req
        auditMcp ap "release_discard" "release" (Just r)
        pure (toJSON result)
    }

releaseUpdateStatusTool :: McpTool
releaseUpdateStatusTool =
  McpTool
    { mtName = "release_update_status",
      mtDescription = "Update a release tracker — this is how you pause, resume, or abort an in-progress release: pass status=\"PAUSED\" to pause, \"INPROGRESS\" to resume, \"ABORTING\" to abort, or \"RESTARTING\" to restart. Other tracker fields (priority, description, ...) can be updated the same way.",
      mtInputSchema =
        objSchema
          [ ("releaseId", rid),
            ("status", strP "One of PAUSED | INPROGRESS | ABORTING | RESTARTING"),
            ("priority", intP "Optional new priority"),
            ("description", strP "Optional new description")
          ]
          ["releaseId"],
      mtPermission = AP_RELEASE_UPDATE,
      mtRun = \ap args -> do
        r <- requireTextArg "releaseId" args
        req <- decodeArg args :: Flow K8sUpdateTrackerReq
        result <- Release.updateTrackerH ap r req
        auditMcp ap "release_update_status" "release" (Just r)
        pure (toJSON result)
    }

releaseDeleteTool :: McpTool
releaseDeleteTool =
  McpTool
    { mtName = "release_delete",
      mtDescription = "Delete a release tracker.",
      mtInputSchema = objSchema [("releaseId", rid)] ["releaseId"],
      mtPermission = AP_RELEASE_DELETE,
      mtRun = \ap args -> do
        r <- requireTextArg "releaseId" args
        result <- Release.deleteReleaseH ap r
        auditMcp ap "release_delete" "release" (Just r)
        pure (toJSON result)
    }

releaseImmediateRevertTool :: McpTool
releaseImmediateRevertTool =
  McpTool
    { mtName = "release_immediate_revert",
      mtDescription = "Immediately revert a release (skips the staged revert flow).",
      mtInputSchema =
        objSchema
          [ ("releaseId", rid),
            ("requestedBy", strP "Requester identity (defaults to the caller's email)"),
            ("info", strP "Optional info/reason")
          ]
          ["releaseId"],
      mtPermission = AP_RELEASE_REVERT,
      mtRun = \ap args -> do
        r <- requireTextArg "releaseId" args
        req <- decodeArg (withDefaultRequestedBy ap args) :: Flow ImmediateRevertReq
        result <- Release.immediateRevertH ap r req
        auditMcp ap "release_immediate_revert" "release" (Just r)
        pure (toJSON result)
    }

releaseRestartTool :: McpTool
releaseRestartTool =
  McpTool
    { mtName = "release_restart",
      mtDescription = "Restart a release's rollout from the beginning.",
      mtInputSchema =
        objSchema
          [ ("releaseId", rid),
            ("requestedBy", strP "Requester identity (defaults to the caller's email)"),
            ("reason", strP "Optional reason")
          ]
          ["releaseId"],
      mtPermission = AP_RELEASE_CREATE,
      mtRun = \ap args -> do
        r <- requireTextArg "releaseId" args
        req <- decodeArg (withDefaultRequestedBy ap args) :: Flow RestartReleaseReq
        result <- Release.restartReleaseH ap r req
        auditMcp ap "release_restart" "release" (Just r)
        pure (toJSON result)
    }

releaseRolloutRestartDeploymentTool :: McpTool
releaseRolloutRestartDeploymentTool =
  McpTool
    { mtName = "release_rollout_restart_deployment",
      mtDescription = "Rollout-restart the k8s deployment backing a release (pod recycle without a version change).",
      mtInputSchema =
        objSchema
          [ ("releaseId", rid),
            ("requestedBy", strP "Requester identity (defaults to the caller's email)"),
            ("reason", strP "Optional reason")
          ]
          ["releaseId"],
      mtPermission = AP_RELEASE_UPDATE,
      mtRun = \ap args -> do
        r <- requireTextArg "releaseId" args
        req <- decodeArg (withDefaultRequestedBy ap args) :: Flow RestartReleaseReq
        result <- Release.rolloutRestartDeploymentH ap r req
        auditMcp ap "release_rollout_restart_deployment" "release" (Just r)
        pure (toJSON result)
    }

releaseFastForwardTool :: McpTool
releaseFastForwardTool =
  McpTool
    { mtName = "release_fast_forward",
      mtDescription = "Fast-forward a staged/staggered rollout to completion.",
      mtInputSchema =
        objSchema
          [ ("releaseId", rid),
            ("requestedBy", strP "Requester identity (defaults to the caller's email)"),
            ("reason", strP "Optional reason")
          ]
          ["releaseId"],
      mtPermission = AP_RELEASE_UPDATE,
      mtRun = \ap args -> do
        r <- requireTextArg "releaseId" args
        req <- decodeArg (withDefaultRequestedBy ap args) :: Flow FastForwardReq
        result <- Release.fastForwardH ap r req
        auditMcp ap "release_fast_forward" "release" (Just r)
        pure (toJSON result)
    }

withDefaultRequestedBy :: AuthedPerson -> Value -> Value
withDefaultRequestedBy ap (Object o)
  | not (KM.member (K.fromText "requestedBy") o) =
      Object (KM.insert (K.fromText "requestedBy") (String (apEmail ap)) o)
withDefaultRequestedBy _ v = v

configMapListTool :: McpTool
configMapListTool =
  McpTool
    { mtName = "configmap_list",
      mtDescription = "List ConfigMap/VS-edit release trackers, optionally filtered by date range.",
      mtInputSchema = objSchema [("from", strP "Start date (ISO8601), optional"), ("to", strP "End date (ISO8601), optional")] [],
      mtPermission = AP_RELEASE_VIEW,
      mtRun = \ap args ->
        toJSON <$> ConfigMap.listConfigMapsH ap (textArg "from" args) (textArg "to" args)
    }

configMapGetTool :: McpTool
configMapGetTool =
  McpTool
    { mtName = "configmap_get",
      mtDescription = "Get a single ConfigMap tracker by id.",
      mtInputSchema = objSchema [("id", strP "ConfigMap tracker id")] ["id"],
      mtPermission = AP_RELEASE_VIEW,
      mtRun = \ap args -> do
        i <- requireTextArg "id" args
        ConfigMap.getConfigMapH ap i
    }

configMapCreateTool :: McpTool
configMapCreateTool =
  McpTool
    { mtName = "configmap_create",
      mtDescription = "Create a new ConfigMap edit release. Body shape matches the dashboard's ConfigMap create form.",
      mtInputSchema = objSchema [] [],
      mtPermission = AP_RELEASE_CREATE,
      mtRun = \ap args -> do
        result <- ConfigMap.createConfigMapH ap args
        auditMcp ap "configmap_create" "configmap" Nothing
        pure (toJSON result)
    }

configMapUpdateTool :: McpTool
configMapUpdateTool =
  McpTool
    { mtName = "configmap_update",
      mtDescription = "Update a ConfigMap tracker — this is how you pause, resume, abort, or discard a ConfigMap release: pass status=\"PAUSED\"/\"RESUMED\"/\"ABORTED\"/\"DISCARDED\".",
      mtInputSchema = objSchema [("id", strP "ConfigMap tracker id"), ("status", strP "One of PAUSED | RESUMED | ABORTED | DISCARDED")] ["id"],
      mtPermission = AP_RELEASE_UPDATE,
      mtRun = \ap args -> do
        i <- requireTextArg "id" args
        result <- ConfigMap.updateConfigMapH ap i args
        auditMcp ap "configmap_update" "configmap" (Just i)
        pure (toJSON result)
    }

configMapFetchFromK8sTool :: McpTool
configMapFetchFromK8sTool =
  McpTool
    { mtName = "configmap_fetch_from_k8s",
      mtDescription = "Fetch the live ConfigMap contents directly from the cluster for a product/service.",
      mtInputSchema = objSchema [("product", strP "App group / product slug"), ("name", strP "ConfigMap name")] [],
      mtPermission = AP_CONFIG_EDIT,
      mtRun = \ap args ->
        ConfigMap.fetchConfigMapFromK8sH ap (textArg "product" args) (textArg "name" args)
    }

configMapFetchSecondaryTool :: McpTool
configMapFetchSecondaryTool =
  McpTool
    { mtName = "configmap_fetch_secondary",
      mtDescription = "Fetch the live secondary-cluster ConfigMap contents for a product/service.",
      mtInputSchema = objSchema [("product", strP "App group / product slug"), ("name", strP "ConfigMap name")] [],
      mtPermission = AP_CONFIG_EDIT,
      mtRun = \ap args ->
        ConfigMap.fetchSecondaryConfigMapH ap (textArg "product" args) (textArg "name" args)
    }

mcpTools :: [McpTool]
mcpTools =
  [ releaseListTool,
    releaseGetTool,
    releaseCreateTool,
    releaseApproveTool,
    releaseTriggerTool,
    releaseRollbackTool,
    releaseRevertTool,
    releaseDiscardTool,
    releaseUpdateStatusTool,
    releaseDeleteTool,
    releaseImmediateRevertTool,
    releaseRestartTool,
    releaseRolloutRestartDeploymentTool,
    releaseFastForwardTool,
    configMapListTool,
    configMapGetTool,
    configMapCreateTool,
    configMapUpdateTool,
    configMapFetchFromK8sTool,
    configMapFetchSecondaryTool
  ]
