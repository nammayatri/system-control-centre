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
import Products.Autopilot.Types.Release (ReleaseTracker (..))

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

numP :: Text -> Value
numP desc = object ["type" .= ("number" :: Text), "description" .= desc]

objP :: Text -> Value
objP desc = object ["type" .= ("object" :: Text), "description" .= desc]

enumP :: Text -> [Text] -> Value
enumP desc vals = object ["type" .= ("string" :: Text), "description" .= desc, "enum" .= vals]

releaseCategoryEnum :: [Text]
releaseCategoryEnum = ["BackendService", "BackendScheduler", "BackendConfig", "VSEdit", "MobileBuild"]

releaseStatusEnum :: [Text]
releaseStatusEnum =
  [ "CREATED",
    "INPROGRESS",
    "COMPLETED",
    "ABORTED",
    "USER_ABORTED",
    "DISCARDED",
    "DISCARDING",
    "PAUSED",
    "ABORTING",
    "REVERTING",
    "REVERTED",
    "RESTARTING",
    "GCLT_ABORTED",
    "LOCKED",
    "UNLOCKED",
    "APPLIED"
  ]

k8sCreateReleaseOptionalFields :: [(Text, Value)]
k8sCreateReleaseOptionalFields =
  [ ("metadata", objP "Optional metadata, e.g. {\"docker-image\": \"master-<sha>\"} to pin the exact image tag/reference to deploy. If omitted, the deployment falls back to splicing newVersion into the previous image tag, which breaks when newVersion is a \"vN\" suffix used only to distinguish redeploys of the same commit (no such registry tag exists) rather than a real build tag."),
    ("info", strP "Optional info/reason text"),
    ("approvedBy", strP "Optional: pre-approve the release as this identity"),
    ("is_approved", boolP "Optional: mark the release pre-approved"),
    ("is_infra_approved", boolP "Optional: mark the release pre-infra-approved"),
    ("requestedCluster", strP "Optional cluster override"),
    ("scheduleTime", strP "Optional ISO8601 time to schedule the release for"),
    ("deployFilePath", strP "Optional deployment manifest path override"),
    ("serviceFilePath", strP "Optional service manifest path override"),
    ("drFilePath", strP "Optional DR manifest path override"),
    ("vsFilePath", strP "Optional VirtualService manifest path override"),
    ("mode", strP "Optional release mode (e.g. AUTO/MANUAL)"),
    ("globalId", strP "Optional idempotency key for the release"),
    ("new_service", boolP "Optional: true if this is the first-ever release for a new service"),
    ("cronjob_suspend", boolP "Optional: suspend the cronjob instead of a normal rollout"),
    ("change_log", strP "Optional changelog text/URL"),
    ("syncEnabled", strP "Optional secondary-cluster sync flag"),
    ("envOverrideData", strP "Optional environment override data"),
    ("slackThreadTs", strP "Optional Slack thread timestamp to post updates to"),
    ("isReleaseSync", boolP "Optional: sync this release to the secondary cluster"),
    ("isSystemTriggered", boolP "Optional: mark the release as system-triggered rather than user-triggered"),
    ("syncClusterEnvOverrideData", strP "Optional environment override data for the secondary cluster"),
    ("syncClusterRolloutStrategy", objP "Optional rollout strategy override for the secondary cluster"),
    ("postChangelogSlack", boolP "Optional: post the changelog to Slack on completion")
  ]

rolloutStrategyP :: Text -> Value
rolloutStrategyP desc =
  object
    [ "type" .= ("array" :: Text),
      "description" .= desc,
      "items"
        .= object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "rolloutPercent" .= intP "Percentage of pods on the new version at this stage",
                  "cooloffMinutes" .= intP "Minutes to wait after this stage before proceeding to the next",
                  "podCount" .= intP "Number of pods to roll at this stage"
                ],
            "required" .= (["rolloutPercent", "cooloffMinutes", "podCount"] :: [Text])
          ]
    ]

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
          ( [ ("appGroup", strP "App group / product slug (alias: product)"),
              ("service", strP "Service name"),
              ("env", strP "Environment, e.g. UAT/PROD (defaults to UAT)"),
              ("trackerType", enumP "Release category" releaseCategoryEnum),
              ("oldVersion", strP "Current version"),
              ("newVersion", strP "Target version"),
              ("rolloutStrategy", rolloutStrategyP "Rollout stages (at least one required), e.g. [{\"rolloutPercent\":100,\"cooloffMinutes\":0,\"podCount\":1}]"),
              ("releaseTag", strP "Optional release tag"),
              ("description", strP "Optional description"),
              ("priority", intP "Optional priority")
            ]
              ++ k8sCreateReleaseOptionalFields
          )
          ["appGroup", "service", "rolloutStrategy"],
      mtPermission = AP_RELEASE_CREATE,
      mtRun = \ap args -> do
        req <- decodeArg args :: Flow K8sCreateReleaseReq
        result <- Release.createReleaseH ap Nothing Nothing req
        auditMcp ap "release_create" "release" Nothing
        pure (toJSON result)
    }

releaseCloneTool :: McpTool
releaseCloneTool =
  McpTool
    { mtName = "release_clone",
      mtDescription = "Clone an existing release tracker as the template for a new one — copies appGroup, service, env, category, rolloutStrategy, priority, mode, envOverrideData, and metadata (including the docker image reference) from the source release. Only releaseId and newVersion are required; oldVersion defaults to the source release's newVersion. Any field can be overridden by passing it explicitly. Mirrors the dashboard's \"Clone\" action.",
      mtInputSchema =
        objSchema
          ( [ ("releaseId", strP "releaseId of the release tracker to clone from"),
              ("newVersion", strP "Target version for the new release"),
              ("oldVersion", strP "Optional: defaults to the source release's newVersion"),
              ("env", strP "Optional environment override (defaults to the source release's env)"),
              ("priority", intP "Optional priority override"),
              ("description", strP "Optional description"),
              ("releaseTag", strP "Optional release tag")
            ]
              ++ k8sCreateReleaseOptionalFields
          )
          ["releaseId", "newVersion"],
      mtPermission = AP_RELEASE_CREATE,
      mtRun = \ap args -> do
        srcId <- requireTextArg "releaseId" args
        mSrc <- Release.getReleaseH ap srcId
        case mSrc of
          Nothing -> throwM (NotFound ("Release tracker not found: " <> srcId))
          Just ReleaseTracker {..} -> do
            let base =
                  object
                    [ "appGroup" .= appGroup,
                      "service" .= service,
                      "env" .= env,
                      "trackerType" .= category,
                      "oldVersion" .= newVersion,
                      "rolloutStrategy" .= rolloutStrategy,
                      "priority" .= priority,
                      "mode" .= mode,
                      "envOverrideData" .= envOverrideData,
                      "metadata" .= metadata
                    ]
                merged = Object (KM.union (asObject args) (asObject base))
            req <- decodeArg merged :: Flow K8sCreateReleaseReq
            result <- Release.createReleaseH ap Nothing Nothing req
            auditMcp ap "release_clone" "release" (Just srcId)
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
            ("immediate", boolP "Whether to revert immediately"),
            ("isRevertSync", boolP "Whether to also sync the revert to the secondary cluster")
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
      mtDescription = "Update a release tracker — this is how you pause, resume, or abort an in-progress release: pass status=\"PAUSED\" to pause, \"INPROGRESS\" to resume, \"ABORTING\" to abort, or \"RESTARTING\" to restart (actual transition legality is validated server-side against the tracker's current status). Also the only way to correct a bad dockerImage on an existing tracker. Other tracker fields (priority, description, ...) can be updated the same way.",
      mtInputSchema =
        objSchema
          [ ("releaseId", rid),
            ("status", enumP "New status to transition to (legality depends on current status)" releaseStatusEnum),
            ("priority", intP "Optional new priority"),
            ("description", strP "Optional new description"),
            ("rolloutStrategy", rolloutStrategyP "Optional: replace the rollout stages"),
            ("dockerImage", strP "Optional: correct/override the docker image tag/reference used for this tracker's deployment"),
            ("mode", strP "Optional release mode override"),
            ("releaseManager", strP "Optional release manager override"),
            ("scheduleTime", strP "Optional ISO8601 time to (re)schedule the release for"),
            ("info", strP "Optional info/reason"),
            ("changeLog", strP "Optional changelog text/URL"),
            ("isApproved", boolP "Optional approval flag override"),
            ("isInfraApproved", boolP "Optional infra-approval flag override"),
            ("syncEnabled", strP "Optional secondary-cluster sync flag"),
            ("envOverrideData", strP "Optional environment override data"),
            ("slackThreadTs", strP "Optional Slack thread timestamp to post updates to"),
            ("podsScaleDownDelay", numP "Optional delay (seconds) before scaling down old pods")
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
            ("info", strP "Optional info/reason"),
            ("isRevertSync", boolP "Whether to also sync the revert to the secondary cluster")
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
      mtInputSchema =
        objSchema
          [ ("appGroup", strP "App group / product slug (alias: product)"),
            ("service", strP "Service name"),
            ("env", strP "Environment, e.g. UAT/PROD (defaults to UAT)"),
            ("cluster", strP "Optional cluster override"),
            ("name", strP "ConfigMap name"),
            ("file", strP "The new ConfigMap contents (YAML/JSON) to deploy (alias: config)"),
            ("description", strP "Optional description"),
            ("change_log", strP "Optional changelog text/URL"),
            ("release_manager", strP "Optional release manager (defaults to caller)"),
            ("priority", intP "Optional priority"),
            ("isSync", boolP "Optional: also sync this ConfigMap to the secondary cluster"),
            ("secondary_file", strP "Optional secondary-cluster ConfigMap contents override"),
            ("is_approved", boolP "Optional: mark pre-approved")
          ]
          ["appGroup", "service", "name", "file"],
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
      mtDescription = "Update a ConfigMap tracker — this is how you pause, resume, abort, or discard a ConfigMap release: pass status=\"PAUSED\"/\"RESUMED\"/\"ABORTED\"/\"DISCARDED\", or status=\"revert\" to revert to the previous ConfigMap contents.",
      mtInputSchema =
        objSchema
          [ ("id", strP "ConfigMap tracker id"),
            ("status", strP "One of PAUSED | RESUMED | ABORTED | DISCARDED | revert"),
            ("description", strP "Optional new description"),
            ("change_log", strP "Optional changelog text/URL"),
            ("is_approved", boolP "Optional: mark approved"),
            ("is_infra_approved", boolP "Optional: mark infra-approved"),
            ("file", strP "Optional: replace the ConfigMap contents (alias: config)"),
            ("commit", strP "Optional commit reference"),
            ("current_cool_off", strP "Optional: set to \"0\" to fast-forward the cooloff")
          ]
          ["id"],
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
    releaseCloneTool,
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
