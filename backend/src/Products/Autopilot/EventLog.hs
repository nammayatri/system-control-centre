{-# LANGUAGE OverloadedStrings #-}

{- | Release-event emitters with production payload format.

  * 'logTrafficUpdated'  — BUSINESS / TRAFFIC_UPDATED
  * 'logDecisionResult'  — DECISION_ENGINE / DECISION_RESULT
  * 'logStatusUpdated'   — NOTIFICATION / STATUS_UPDATED

@rollout_history@ is serialised as a JSON *string* (not a nested object)
for wire compatibility with the existing consumers.
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
    evDeploymentBeforePreview,
    evDeploymentAfterPreview,
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

statusText :: ReleaseTracker -> Text
statusText = releaseStatusToText . status

{- | Typed constants for every release-event @(category, label)@ pair.
Additive: existing call sites still use string literals; migrate over time.
-}
evCategoryBusiness, evCategoryDecisionEngine, evCategoryNotification, evCategorySnapshot :: Text
evCategoryBusiness = "BUSINESS"
evCategoryDecisionEngine = "DECISION_ENGINE"
evCategoryNotification = "NOTIFICATION"
evCategorySnapshot = "SNAPSHOT"

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

evDecisionResult :: Text
evDecisionResult = "DECISION_RESULT"

evStatusUpdated :: Text
evStatusUpdated = "STATUS_UPDATED"

{- | @DEPLOYMENT_BEFORE@/@_AFTER@ are ground-truth workflow snapshots.
@*_PREVIEW@ are captured at release-creation time by the API handlers so
the diff endpoint has something to show before the workflow runs; the
diff endpoint prefers the workflow labels and falls back to preview.
-}
evDeploymentBefore, evDeploymentAfter, evDeploymentBeforePreview, evDeploymentAfterPreview :: Text
evDeploymentBefore = "DEPLOYMENT_BEFORE"
evDeploymentAfter = "DEPLOYMENT_AFTER"
evDeploymentBeforePreview = "DEPLOYMENT_BEFORE_PREVIEW"
evDeploymentAfterPreview = "DEPLOYMENT_AFTER_PREVIEW"

evConfigmapBefore, evConfigmapAfter, evVsBefore, evVsAfter :: Text
evConfigmapBefore = "CONFIGMAP_BEFORE"
evConfigmapAfter = "CONFIGMAP_AFTER"
evVsBefore = "VS_BEFORE"
evVsAfter = "VS_AFTER"
