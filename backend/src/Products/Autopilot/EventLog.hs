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
        , "pods" .= historyPodsPercent h
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
