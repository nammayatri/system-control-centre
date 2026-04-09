{-# LANGUAGE OverloadedStrings #-}

{- | Production-format event logging (matches Julia autopilot exactly).

Emits release events with the same category/label/payload structure as
the production Julia autopilot (/release/events.jl).

Three event types are supported:

* 'logTrafficUpdated'  — BUSINESS / TRAFFIC_UPDATED
* 'logDecisionResult'  — DECISION_ENGINE / DECISION_RESULT
* 'logStatusUpdated'   — NOTIFICATION / STATUS_UPDATED

The @rollout_history@ field in each payload is serialized as a JSON
STRING (not a nested object) to match Julia's @JSON2.write@ output.
-}
module Products.Autopilot.EventLog (
    logTrafficUpdated,
    logTrafficUpdatedWithMessage,
    logDecisionResult,
    logStatusUpdated,
    encodeProdRolloutHistory,

    -- * Event categories
    evCategoryBusiness,
    evCategoryDecisionEngine,
    evCategoryNotification,
    evCategorySnapshot,

    -- * Event labels
    evTrafficUpdated,
    evSyncRequest,
    evSyncResponse,
    evSyncFailedFinal,
    evSyncGateCheck,
    evSyncSkipped,
    evSyncTriggered,
    evRevertSyncGateCheck,
    evRevertSyncTriggered,
    evRevertSyncSkipped,
    evImmediateRevertSyncRequest,
    evRevertRestartFailed,
    evAbortHandled,
    evFailed,
    evKubectlFailed,
    evWorkflowAbortExit,
    evWorkflowAborted,
    evVersionMismatch,
    evConfigmapSyncRequest,
    evConfigmapSyncResponse,
    evConfigmapSyncFailed,
    evVsOld,
    evVsNew,
    evVsLockFailed,
    evDuplicateDiscarded,
    evTrackerCreated,
    evTrackerApproved,
    evTrackerTriggered,
    evTrackerUpdated,
    evRevertTrackerCreated,
    evRollbackRequested,
    evImmediateRevert,
    evRunnerPicked,
    evCompleted,
    evDecisionResult,
    evStatusUpdated,
    evDeploymentBefore,
    evDeploymentAfter,
    evConfigmapBefore,
    evConfigmapAfter,
    evVsBefore,
    evVsAfter,
)
where

import Core.Environment (MonadFlow)
import Data.Aeson (Value (..), object, toJSON, (.=))
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (UTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Products.Autopilot.Queries.ReleaseTracker (insertReleaseEvent, releaseStatusToText)
import Products.Autopilot.Types.Release (
    Decision (..),
    ReleaseTracker (..),
    RolloutHistory (..),
 )

-- ============================================================================
-- Production-format rollout_history serialization
-- ============================================================================

encodeProdRolloutHistory :: [RolloutHistory] -> Text
encodeProdRolloutHistory hs =
    let jsonArray = toJSON (map historyToProdJson hs)
     in TE.decodeUtf8 (LBS.toStrict (A.encode jsonArray))

historyToProdJson :: RolloutHistory -> Value
historyToProdJson h =
    object
        [ "rollout" .= historyRolloutPercent h
        , "cooloff" .= historyCooloffMinutes h
        , "pods" .= historyPodsCount h
        , "last_decision" .= fmap decisionToText (historyDecision h)
        , "decision_result" .= historyDecisionReason h
        , "started_at" .= formatProdTime (historyStartedAt h)
        , "completed_at" .= fmap formatProdTime (historyCompletedAt h)
        , "manual_override" .= historyManualOverride h
        , "last_decision_hs" .= fmap decisionToText (historyDecisionHs h)
        , "decision_hs_result" .= historyDecisionHsReason h
        ]

formatProdTime :: UTCTime -> Text
formatProdTime = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%3Q"

decisionToText :: Decision -> Text
decisionToText WaitForMoreIteration = "WaitForMoreIteration"
decisionToText Continue = "Continue"
decisionToText Wait = "Wait"
decisionToText Abort = "Abort"

-- ============================================================================
-- Event emitters (MonadFlow only — no _io versions)
-- ============================================================================

logTrafficUpdated :: (MonadFlow m) => ReleaseTracker -> Int -> m ()
logTrafficUpdated rt previousRollout = do
    let payload =
            object
                [ "status" .= statusText rt
                , "previous_rollout" .= previousRollout
                , "rollout_history" .= encodeProdRolloutHistory (rolloutHistory rt)
                ]
    insertReleaseEvent (releaseId rt) "BUSINESS" "TRAFFIC_UPDATED" payload

logTrafficUpdatedWithMessage :: (MonadFlow m) => ReleaseTracker -> Int -> Text -> m ()
logTrafficUpdatedWithMessage rt previousRollout message = do
    let payload =
            object
                [ "status" .= statusText rt
                , "previous_rollout" .= previousRollout
                , "rollout_history" .= encodeProdRolloutHistory (rolloutHistory rt)
                , "message" .= message
                ]
    insertReleaseEvent (releaseId rt) "BUSINESS" "TRAFFIC_UPDATED" payload

logDecisionResult ::
    (MonadFlow m) =>
    ReleaseTracker ->
    Decision ->
    Text ->
    [Text] ->
    m ()
logDecisionResult rt decision decisionResult reasons = do
    let payload =
            object
                [ "status" .= statusText rt
                , "rollout_history" .= encodeProdRolloutHistory (rolloutHistory rt)
                , "decision" .= decisionToText decision
                , "decision_result" .= decisionResult
                , "reason" .= reasons
                , "severity" .= object []
                ]
    insertReleaseEvent (releaseId rt) "DECISION_ENGINE" "DECISION_RESULT" payload

logStatusUpdated :: (MonadFlow m) => ReleaseTracker -> Text -> m ()
logStatusUpdated rt message = do
    let payload =
            object
                [ "status" .= statusText rt
                , "message" .= message
                , "rollout_history" .= encodeProdRolloutHistory (rolloutHistory rt)
                ]
    insertReleaseEvent (releaseId rt) "NOTIFICATION" "STATUS_UPDATED" payload

-- ============================================================================
-- Helpers
-- ============================================================================

statusText :: ReleaseTracker -> Text
statusText = releaseStatusToText . status

-- ============================================================================

-- * Event categories & labels — central registry

-- ============================================================================

{- | Typed constants for every release-event @(category, label)@ pair currently
emitted across @Products.Autopilot.*@.

This section is intentionally *additive only*. Existing call sites still pass
string literals directly to 'insertReleaseEvent'; they are **not** migrated in
this pass. Future work should gradually replace magic strings with these
constants to eliminate typo risk and provide a single source of truth.

Naming convention: category constants are prefixed @evCategory@; label
constants are prefixed @ev@ followed by the camelCase form of the underlying
@SNAKE_CASE@ label (e.g. @SYNC_REQUEST@ becomes 'evSyncRequest').
-}
evCategoryBusiness, evCategoryDecisionEngine, evCategoryNotification, evCategorySnapshot :: Text
evCategoryBusiness = "BUSINESS"
evCategoryDecisionEngine = "DECISION_ENGINE"
evCategoryNotification = "NOTIFICATION"
evCategorySnapshot = "SNAPSHOT"

-- | BUSINESS category labels.
evTrafficUpdated
    , evSyncRequest
    , evSyncResponse
    , evSyncFailedFinal
    , evSyncGateCheck
    , evSyncSkipped
    , evSyncTriggered
    , evRevertSyncGateCheck
    , evRevertSyncTriggered
    , evRevertSyncSkipped
    , evImmediateRevertSyncRequest
    , evRevertRestartFailed
    , evAbortHandled
    , evFailed
    , evKubectlFailed
    , evWorkflowAbortExit
    , evWorkflowAborted
    , evVersionMismatch
    , evConfigmapSyncRequest
    , evConfigmapSyncResponse
    , evConfigmapSyncFailed
    , evVsOld
    , evVsNew
    , evVsLockFailed
    , evDuplicateDiscarded
    , evTrackerCreated
    , evTrackerApproved
    , evTrackerTriggered
    , evTrackerUpdated
    , evRevertTrackerCreated
    , evRollbackRequested
    , evImmediateRevert
    , evRunnerPicked
    , evCompleted ::
        Text
evTrafficUpdated = "TRAFFIC_UPDATED"
evSyncRequest = "SYNC_REQUEST"
evSyncResponse = "SYNC_RESPONSE"
evSyncFailedFinal = "SYNC_FAILED_FINAL"
evSyncGateCheck = "SYNC_GATE_CHECK"
evSyncSkipped = "SYNC_SKIPPED"
evSyncTriggered = "SYNC_TRIGGERED"
evRevertSyncGateCheck = "REVERT_SYNC_GATE_CHECK"
evRevertSyncTriggered = "REVERT_SYNC_TRIGGERED"
evRevertSyncSkipped = "REVERT_SYNC_SKIPPED"
evImmediateRevertSyncRequest = "IMMEDIATE_REVERT_SYNC_REQUEST"
evRevertRestartFailed = "REVERT_RESTART_FAILED"
evAbortHandled = "ABORT_HANDLED"
evFailed = "FAILED"
evKubectlFailed = "KUBECTL_FAILED"
evWorkflowAbortExit = "WORKFLOW_ABORT_EXIT"
evWorkflowAborted = "WORKFLOW_ABORTED"
evVersionMismatch = "VERSION_MISMATCH"
evConfigmapSyncRequest = "CONFIGMAP_SYNC_REQUEST"
evConfigmapSyncResponse = "CONFIGMAP_SYNC_RESPONSE"
evConfigmapSyncFailed = "CONFIGMAP_SYNC_FAILED"
evVsOld = "VS_OLD"
evVsNew = "VS_NEW"
evVsLockFailed = "VS_LOCK_FAILED"
evDuplicateDiscarded = "DUPLICATE_DISCARDED"
evTrackerCreated = "TRACKER_CREATED"
evTrackerApproved = "TRACKER_APPROVED"
evTrackerTriggered = "TRACKER_TRIGGERED"
evTrackerUpdated = "TRACKER_UPDATED"
evRevertTrackerCreated = "REVERT_TRACKER_CREATED"
evRollbackRequested = "ROLLBACK_REQUESTED"
evImmediateRevert = "IMMEDIATE_REVERT"
evRunnerPicked = "RUNNER_PICKED"
evCompleted = "COMPLETED"

-- | DECISION_ENGINE category labels.
evDecisionResult :: Text
evDecisionResult = "DECISION_RESULT"

-- | NOTIFICATION category labels.
evStatusUpdated :: Text
evStatusUpdated = "STATUS_UPDATED"

-- | SNAPSHOT category labels.
evDeploymentBefore, evDeploymentAfter, evConfigmapBefore, evConfigmapAfter, evVsBefore, evVsAfter :: Text
evDeploymentBefore = "DEPLOYMENT_BEFORE"
evDeploymentAfter = "DEPLOYMENT_AFTER"
evConfigmapBefore = "CONFIGMAP_BEFORE"
evConfigmapAfter = "CONFIGMAP_AFTER"
evVsBefore = "VS_BEFORE"
evVsAfter = "VS_AFTER"
