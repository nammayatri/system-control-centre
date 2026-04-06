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

import Core.Environment (DBEnv)
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

{- | Serialize rollout history as a JSON string matching Julia's field names.

Julia writes it with @JSON2.write(tracker.rollout_history)@ which produces
a JSON string like:

> "[{\"rollout\":100,\"cooloff\":1,\"pods\":6,\"last_decision\":\"Continue\",
>   \"decision_result\":\"[...]\",\"started_at\":\"2026-04-02T18:42:11.726\",
>   \"completed_at\":\"2026-04-02T18:43:13.043\",\"manual_override\":false,
>   \"last_decision_hs\":\"Continue\",\"decision_hs_result\":\"Not applicable\"}]"

Note: this returns the JSON array encoded as a *Text string*, so it will
appear as a quoted string value in the enclosing event payload.
-}
encodeProdRolloutHistory :: [RolloutHistory] -> Text
encodeProdRolloutHistory hs =
    let jsonArray = toJSON (map historyToProdJson hs)
     in TE.decodeUtf8 (LBS.toStrict (A.encode jsonArray))

-- | Convert one RolloutHistory entry to the production JSON shape.
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

-- | Format a UTCTime to Julia's @yyyy-mm-ddTHH:MM:SS.sss@ style.
formatProdTime :: UTCTime -> Text
formatProdTime = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%3Q"

decisionToText :: Decision -> Text
decisionToText Continue = "Continue"
decisionToText Wait = "Wait"
decisionToText Abort = "Abort"

-- ============================================================================
-- Event emitters
-- ============================================================================

{- | BUSINESS / TRAFFIC_UPDATED — emitted when rollout traffic % changes.

Production reference: @release/events.jl@ @rolloutEvent!@ (line 209-248).

Payload:

> { "status": "...",
>   "previous_rollout": <Int>,
>   "rollout_history": "<JSON-encoded history array as string>" }
-}
logTrafficUpdated :: DBEnv -> ReleaseTracker -> Int -> IO ()
logTrafficUpdated db rt previousRollout = do
    let payload =
            object
                [ "status" .= statusText rt
                , "previous_rollout" .= previousRollout
                , "rollout_history" .= encodeProdRolloutHistory (rolloutHistory rt)
                ]
    insertReleaseEvent db (releaseId rt) "BUSINESS" "TRAFFIC_UPDATED" payload

{- | BUSINESS / TRAFFIC_UPDATED with a @message@ field — emitted on rollback.

Production reference: @release/events.jl@ @rollbackEvent!@ (line 251-286).
Same shape as 'logTrafficUpdated' but with an extra @"message"@ key.
-}
logTrafficUpdatedWithMessage :: DBEnv -> ReleaseTracker -> Int -> Text -> IO ()
logTrafficUpdatedWithMessage db rt previousRollout message = do
    let payload =
            object
                [ "status" .= statusText rt
                , "previous_rollout" .= previousRollout
                , "rollout_history" .= encodeProdRolloutHistory (rolloutHistory rt)
                , "message" .= message
                ]
    insertReleaseEvent db (releaseId rt) "BUSINESS" "TRAFFIC_UPDATED" payload

{- | DECISION_ENGINE / DECISION_RESULT — emitted after decision engine runs.

Production reference: @release/events.jl@ @decisionEvent!@ (line 391-423).

Payload:

> { "status": "...",
>   "rollout_history": "<JSON-encoded history string>",
>   "decision": "Continue"|"Wait"|"Abort",
>   "decision_result": "<raw result text>",
>   "reason": [<list of reasons>],
>   "severity": <object, usually empty> }
-}
logDecisionResult ::
    DBEnv ->
    ReleaseTracker ->
    Decision ->
    -- | @decision_result@ — raw result string (e.g. the message from upstream)
    Text ->
    -- | @reason@ — list of reasons
    [Text] ->
    IO ()
logDecisionResult db rt decision decisionResult reasons = do
    let payload =
            object
                [ "status" .= statusText rt
                , "rollout_history" .= encodeProdRolloutHistory (rolloutHistory rt)
                , "decision" .= decisionToText decision
                , "decision_result" .= decisionResult
                , "reason" .= reasons
                , "severity" .= object []
                ]
    insertReleaseEvent db (releaseId rt) "DECISION_ENGINE" "DECISION_RESULT" payload

{- | NOTIFICATION / STATUS_UPDATED — emitted when release status transitions.

Production reference: @release/events.jl@ @updateStatusEvent!@ (line 149-180).

Payload:

> { "status": "...",
>   "message": "...",
>   "rollout_history": "<JSON-encoded history string>" }
-}
logStatusUpdated :: DBEnv -> ReleaseTracker -> Text -> IO ()
logStatusUpdated db rt message = do
    let payload =
            object
                [ "status" .= statusText rt
                , "message" .= message
                , "rollout_history" .= encodeProdRolloutHistory (rolloutHistory rt)
                ]
    insertReleaseEvent db (releaseId rt) "NOTIFICATION" "STATUS_UPDATED" payload

-- ============================================================================
-- Helpers
-- ============================================================================

statusText :: ReleaseTracker -> Text
statusText = releaseStatusToText . status
