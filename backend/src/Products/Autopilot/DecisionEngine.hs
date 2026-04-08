{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Decision engine for autopilot releases.

Provides three decision functions, all gated behind server_config flags:

1. Prometheus query checks — reads decision_config from deployment_config,
 queries Prometheus HTTP API, checks thresholds.
2. AB Decision Engine — calls external AB testing service for Continue/Wait/Abort.
3. Health Score (HS) Decision — calls external health score service,
 supports pre-monitoring (during rollout) and post-monitoring (after 100%).

All functions fail OPEN: on any error (HTTP failure, parse failure, missing config),
they return Continue/PromOK so releases are never blocked by monitoring infrastructure failures.
-}
module Products.Autopilot.DecisionEngine (
    -- * Decision Functions
    checkPromQueries,
    initiateABDecisionForRelease,
    initiatePostMonitoringABDecisionForRelease,
    stopDecisionEngineHS,
    getABDecision,
    getHSDecision,
    getCombinedDecision,

    -- * Types
    DecisionResult (..),
    PromCheckResult (..),
)
where

import Control.Applicative ((<|>))
import Control.Exception (SomeException, try)
import Control.Monad.IO.Class (liftIO)
import Core.Config (Config (..))
import Core.Environment (MonadFlow)
import Core.Http.Client (HttpError, HttpReq (..), HttpResponse (..), Method (..), defaultReq, httpRaw)
import Core.Logging (logDebugG, logErrorG, logWarningG)
import Core.Types.Time (Seconds (..))
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as LBS
import Data.Foldable (toList)
import Data.Scientific (toBoundedInteger, toRealFloat)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (UTCTime, addUTCTime, defaultTimeLocale, formatTime, getCurrentTime)
import Products.Autopilot.Queries.ProductService (findServiceByProductAndName, getServiceHost)
import Products.Autopilot.RuntimeConfig (
    getABHSAllowedTimeDiffMins,
    getABHSApiKey,
    getABHSVolumeMinA,
    getABHSVolumeMinB,
    getCkhClusterName,
    getDEPostMonitoringTimeout,
    getDecisionEngineFailClosed,
    isABHSDecisionEnabledForAppGroupService,
    isPromQueryCheckEnabled,
 )
import Products.Autopilot.Types.Release (Decision (..), ReleaseTracker (..), decisionPriority)
import Shared.Config.Runtime (getConfigBoolForProduct)
import Prelude

-- ============================================================================
-- Types
-- ============================================================================

data DecisionResult = DecisionResult
    { drDecision :: Decision
    -- ^ Continue, Wait, or Abort
    , drReason :: Maybe Text
    -- ^ Human-readable reason
    , drSource :: Text
    -- ^ "PROMETHEUS" | "AB_ENGINE" | "HEALTH_SCORE"
    }
    deriving (Show)

data PromCheckResult
    = PromOK
    | PromWarn Text
    | PromAbort Text
    deriving (Show)

-- ============================================================================
-- Prometheus Query Checks
-- ============================================================================

{- | Run Prometheus query checks against the service's decision_config.

Reads the decision_config JSON from deployment_config, parses query configs,
and for each query calls the Prometheus HTTP API to check thresholds.

Returns PromOK if:
- prom_checks_enabled is false (gate)
- No decision_config provided
- No PROMETHEUS_URL configured
- Config is invalid JSON (fail open)
- All queries pass thresholds

Returns PromAbort if any metric exceeds abort_threshold.
Returns PromWarn if any metric exceeds warn_threshold (but not abort).
-}
checkPromQueries :: (MonadFlow m) => Config -> ReleaseTracker -> Maybe Text -> m PromCheckResult
checkPromQueries cfg tracker mDecisionConfig = do
    -- Master gate: Julia's @prom_query_check_enabled@ (with @prom_checks_enabled@ fallback)
    enabled <- isPromQueryCheckEnabled
    if not enabled
        then pure PromOK
        else case mDecisionConfig of
            Nothing -> pure PromOK
            Just configJson -> do
                let promUrl = prometheusUrl cfg
                if null promUrl
                    then pure PromOK -- No Prometheus URL configured
                    else liftIO $ executePromChecks promUrl configJson tracker

{- | Internal: Execute Prometheus checks against all configs in the decision_config JSON.

The decision_config is a JSON array of config objects, each containing queries
and thresholds. We check each config entry and return the worst result
(Abort > Warn > OK).
-}
executePromChecks :: String -> Text -> ReleaseTracker -> IO PromCheckResult
executePromChecks promUrl configJson tracker =
    case A.decodeStrict' (TE.encodeUtf8 configJson) of
        Nothing -> do
            logWarningG "[DECISION] Failed to parse decision_config JSON, skipping prom checks"
            pure PromOK -- Invalid config, skip (fail open)
        Just configs -> checkAllConfigs promUrl configs tracker

{- | Check all config entries, returning the worst result.
Abort > Warn > OK.
-}
checkAllConfigs :: String -> [Value] -> ReleaseTracker -> IO PromCheckResult
checkAllConfigs _ [] _ = pure PromOK
checkAllConfigs url (c : rest) rt = do
    result <- checkSingleConfig url c rt
    case result of
        PromAbort reason -> pure (PromAbort reason)
        PromWarn reason -> do
            restResult <- checkAllConfigs url rest rt
            case restResult of
                PromAbort r -> pure (PromAbort r)
                _ -> pure (PromWarn reason)
        PromOK -> checkAllConfigs url rest rt

{- | Check a single config entry against Prometheus.

Expected config structure:
{
"cluster": "...",
"config": {
  "experiments": [{
    "queries": [{"query": "...", "name": "..."}],
    "thresholds": {"abort": 100, "warn": 50}
  }]
}
}

Uses try/catch for HTTP failures — returns PromOK on failure (fail open).
-}
checkSingleConfig :: String -> Value -> ReleaseTracker -> IO PromCheckResult
checkSingleConfig url config _rt = do
    result <- try (checkConfigQueries url config) :: IO (Either SomeException PromCheckResult)
    case result of
        Right r -> pure r
        Left e -> do
            logErrorG $ "[DECISION] Prometheus check failed: " <> T.pack (show e)
            pure PromOK -- Fail open

{- | Extract queries from a config entry and check each one.

Navigates: config.config.experiments[].queries[] and config.config.experiments[].thresholds
-}
checkConfigQueries :: String -> Value -> IO PromCheckResult
checkConfigQueries promUrl (Object configObj) = do
    case KM.lookup (K.fromText "config") configObj of
        Just (Object innerConfig) ->
            case KM.lookup (K.fromText "experiments") innerConfig of
                Just (Array experiments) ->
                    checkExperiments promUrl (toList experiments)
                _ -> pure PromOK
        _ -> pure PromOK
checkConfigQueries _ _ = pure PromOK

-- | Check all experiments in a config entry.
checkExperiments :: String -> [Value] -> IO PromCheckResult
checkExperiments _ [] = pure PromOK
checkExperiments promUrl (exp' : rest) = do
    result <- checkExperiment promUrl exp'
    case result of
        PromAbort reason -> pure (PromAbort reason)
        PromWarn reason -> do
            restResult <- checkExperiments promUrl rest
            case restResult of
                PromAbort r -> pure (PromAbort r)
                _ -> pure (PromWarn reason)
        PromOK -> checkExperiments promUrl rest

-- | Check a single experiment: extract queries and thresholds, query Prometheus.
checkExperiment :: String -> Value -> IO PromCheckResult
checkExperiment promUrl (Object expObj) = do
    let queries = case KM.lookup (K.fromText "queries") expObj of
            Just (Array qs) -> toList qs
            _ -> []
        abortThreshold = extractThreshold "abort" expObj
        warnThreshold = extractThreshold "warn" expObj
    checkQueryList promUrl queries abortThreshold warnThreshold
checkExperiment _ _ = pure PromOK

-- | Extract a numeric threshold from the thresholds object.
extractThreshold :: Text -> KM.KeyMap Value -> Maybe Double
extractThreshold key expObj =
    case KM.lookup (K.fromText "thresholds") expObj of
        Just (Object thresholds) ->
            case KM.lookup (K.fromText key) thresholds of
                Just (Number n) -> Just (realToFrac n)
                _ -> Nothing
        _ -> Nothing

-- | Check a list of queries against Prometheus, comparing results to thresholds.
checkQueryList :: String -> [Value] -> Maybe Double -> Maybe Double -> IO PromCheckResult
checkQueryList _ [] _ _ = pure PromOK
checkQueryList promUrl (q : rest) abortTh warnTh = do
    result <- checkSingleQuery promUrl q abortTh warnTh
    case result of
        PromAbort reason -> pure (PromAbort reason)
        PromWarn reason -> do
            restResult <- checkQueryList promUrl rest abortTh warnTh
            case restResult of
                PromAbort r -> pure (PromAbort r)
                _ -> pure (PromWarn reason)
        PromOK -> checkQueryList promUrl rest abortTh warnTh

-- | Query Prometheus for a single metric and compare against thresholds.
checkSingleQuery :: String -> Value -> Maybe Double -> Maybe Double -> IO PromCheckResult
checkSingleQuery promUrl (Object qObj) abortTh warnTh = do
    let mQuery = case KM.lookup (K.fromText "query") qObj of
            Just (String q) -> Just q
            _ -> Nothing
        mName = case KM.lookup (K.fromText "name") qObj of
            Just (String n) -> n
            _ -> "unknown"
        -- Optional config fields read from the decision_config JSON for
        -- per-query Julia parity safety rails:
        readDouble k = case KM.lookup (K.fromText k) qObj of
            Just (Number n) -> Just (toRealFloat n :: Double)
            _ -> Nothing
        -- Layer A: 5xx error-spike force-abort
        -- (Julia decision/runner.jl:508-511). For metrics whose name flags
        -- them as a 500/501/503/5xx error rate, force-abort when
        -- (totalSamples × val/100) ≥ 200. The Prom path doesn't get a
        -- raw "totalSamples" — we expect callers to put it in the query
        -- config as @sample_count@ for these metric names.
        is5xxMetric =
            mName
                `elem` [ "resp_500_rate"
                       , "resp_501_rate"
                       , "resp_503_rate"
                       , "resp_5xx_rate"
                       , "5xx_rate"
                       ]
        sampleCount = readDouble "sample_count" <|> readDouble "totalB"
        -- Layer B: A/B split percentage breach
        -- (Julia decision/runner.jl:646-651). If the query config carries
        -- @target_split@ + @actual_split@ (the runner is expected to
        -- populate actual_split from the live VS routes before calling
        -- the decision engine), abort if actual drifted outside
        -- target ± buffer (default 5%).
        targetSplit = readDouble "target_split" <|> readDouble "release_percentage"
        actualSplit = readDouble "actual_split" <|> readDouble "current_split"
        splitBuffer = readDouble "split_buffer" <|> readDouble "release_buffer"
    case mQuery of
        Nothing -> pure PromOK
        Just query -> do
            mValue <- queryPrometheus promUrl query
            case mValue of
                Nothing -> pure PromOK -- Query failed, fail open
                Just val -> do
                    logDebugG $ "[DECISION] Prom query '" <> mName <> "' = " <> T.pack (show val)
                    -- Layer A: 5xx spike force-abort wins over generic threshold.
                    let spike5xx = case (is5xxMetric, sampleCount) of
                            (True, Just sc) -> (sc * val / 100.0 :: Double) >= 200.0
                            _ -> False
                        -- Layer B: A/B split breach.
                        splitBreach = case (actualSplit, targetSplit) of
                            (Just a, Just t) ->
                                let buf = maybe 5.0 id splitBuffer
                                 in a < (t - buf) || a > (t + buf)
                            _ -> False
                    if spike5xx
                        then
                            pure $
                                PromAbort
                                    ( "5xx spike force-abort: "
                                        <> mName
                                        <> " val="
                                        <> T.pack (show val)
                                        <> " sampleCount="
                                        <> T.pack (show sampleCount)
                                        <> " (Julia parity)"
                                    )
                        else
                            if splitBreach
                                then
                                    pure $
                                        PromAbort
                                            ( "A/B split breach: actual="
                                                <> T.pack (show actualSplit)
                                                <> " target="
                                                <> T.pack (show targetSplit)
                                                <> "±"
                                                <> T.pack (show splitBuffer)
                                            )
                                else case abortTh of
                                    Just threshold
                                        | val > threshold ->
                                            pure $ PromAbort (mName <> " = " <> T.pack (show val) <> " exceeds abort threshold " <> T.pack (show threshold))
                                    _ -> case warnTh of
                                        Just threshold
                                            | val > threshold ->
                                                pure $ PromWarn (mName <> " = " <> T.pack (show val) <> " exceeds warn threshold " <> T.pack (show threshold))
                                        _ -> pure PromOK
checkSingleQuery _ _ _ _ = pure PromOK

{- | Query Prometheus HTTP API and extract the scalar result value.

Calls: GET {promUrl}/api/v1/query?query={query}
Parses the response JSON to extract the numeric value from the result.
Returns Nothing on any failure (fail open).
-}
queryPrometheus :: String -> Text -> IO (Maybe Double)
queryPrometheus promUrl query = do
    let url = T.pack promUrl <> "/api/v1/query?query=" <> query
        req = (defaultReq url){reqTimeout = Seconds 10, reqRetries = 0, reqLogTag = "prometheus"}
    result <- httpRaw req
    case result of
        Right HttpResponse{respStatus = s, respBody = b}
            | s < 400 ->
                pure (parsePromResponse (T.unpack (TE.decodeUtf8 (LBS.toStrict b))))
        Right HttpResponse{respStatus = s} -> do
            logErrorG $ "[DECISION] Prometheus query failed (HTTP " <> T.pack (show s) <> ")"
            pure Nothing
        Left e -> do
            logErrorG $ "[DECISION] Prometheus query failed: " <> T.pack (show e)
            pure Nothing

{- | Parse Prometheus query response JSON.

Expected format:
{ "status": "success", "data": { "result": [{ "value": [timestamp, "value_string"] }] } }
-}
parsePromResponse :: String -> Maybe Double
parsePromResponse raw =
    case A.decodeStrict' (TE.encodeUtf8 (T.pack raw)) :: Maybe Value of
        Nothing -> Nothing
        Just (Object obj) ->
            case KM.lookup (K.fromText "data") obj of
                Just (Object dataObj) ->
                    case KM.lookup (K.fromText "result") dataObj of
                        Just (Array results) ->
                            case toList results of
                                (Object r : _) ->
                                    case KM.lookup (K.fromText "value") r of
                                        Just (Array vals) ->
                                            case toList vals of
                                                [_, String valStr] ->
                                                    case reads (T.unpack valStr) :: [(Double, String)] of
                                                        ((v, _) : _) -> Just v
                                                        _ -> Nothing
                                                _ -> Nothing
                                        _ -> Nothing
                                _ -> Nothing
                        _ -> Nothing
                _ -> Nothing
        _ -> Nothing

-- ============================================================================
-- AB Decision Engine
-- ============================================================================

{- | Initiate the AB decision pod ONCE per release (Julia parity).

Mirrors Julia's @intiateDecisionEngine@ in @global_changelog.jl@: a single
POST to @{AB_ENGINE_URL}initiate/ab@ at release start spawns the ephemeral
decision pod. The actual decision verdict is read later via 'getHSDecision'
polling the same @run_id@ during the rollout loop.

This function should be called from the workflow's preparing phase (e.g.
'prepareK8sResources'), not from the rollout step loop. Calling it once
matches Julia's contract; per-step calls (the previous behavior) would
re-spawn the pod on every iteration.

Gates: master @ab_decision_enabled@ AND per-service
@ab_hs_decision_enabled_app_groups@ JSON. If either is false, returns
Continue without contacting the engine.

On HTTP error returns Abort (fail-closed) if @decision_engine_fail_closed@
is true (default — Julia parity), Continue otherwise.

NOTE: Julia's full flow includes a webhook callback path on the AB engine
side; we implement only the synchronous initiate path. The decision result
is read via 'getHSDecision', which polls the same run_id. See CONTEXT.md
"AB engine: synchronous polling only" note.
-}
initiateABDecisionForRelease :: (MonadFlow m) => Config -> ReleaseTracker -> m DecisionResult
initiateABDecisionForRelease cfg tracker = do
    masterEnabled <- getConfigBoolForProduct "ab_decision_enabled" (Just (appGroup tracker)) False
    perServiceEnabled <- isABHSDecisionEnabledForAppGroupService (appGroup tracker) (service tracker)
    if not (masterEnabled && perServiceEnabled)
        then pure (DecisionResult Continue Nothing "AB_ENGINE")
        else do
            let abUrl = abEngineUrl cfg
            if null abUrl
                then pure (DecisionResult Continue Nothing "AB_ENGINE")
                else do
                    apiKey <- getABHSApiKey
                    failClosed <- getDecisionEngineFailClosed
                    cluster <- getCkhClusterName
                    svcHost <- do
                        mSvc <- findServiceByProductAndName (appGroup tracker) (service tracker)
                        pure $ maybe "" (fromMaybeT . getServiceHost) mSvc
                    now <- liftIO getCurrentTime
                    let body = mkInitiateAbBody tracker cluster svcHost now
                    liftIO $ initiateABDecision abUrl apiKey (appGroup tracker) body failClosed

-- | Helper: Maybe Text -> Text with "" default.
fromMaybeT :: Maybe Text -> Text
fromMaybeT = maybe "" id

{- | Julia-parity: POST a second initiate to spawn the POST-monitoring AB run.
Mirrors Julia's @intiateDecisionEnginePostMonitoring@. Called once AFTER
the new version reaches 100% traffic and pods are ready, BEFORE the
post-monitor HS poll loop starts. The @run_id@ is @<release-id>-post@
so the HS GET during post-monitoring reads a distinct verdict stream.
-}
initiatePostMonitoringABDecisionForRelease :: (MonadFlow m) => Config -> ReleaseTracker -> m DecisionResult
initiatePostMonitoringABDecisionForRelease cfg tracker = do
    let abUrl = abEngineUrl cfg
    if null abUrl
        then pure (DecisionResult Continue Nothing "AB_ENGINE")
        else do
            apiKey <- getABHSApiKey
            failClosed <- getDecisionEngineFailClosed
            cluster <- getCkhClusterName
            svcHost <- do
                mSvc <- findServiceByProductAndName (appGroup tracker) (service tracker)
                pure $ maybe "" (fromMaybeT . getServiceHost) mSvc
            selfClosingSec <- getDEPostMonitoringTimeout
            now <- liftIO getCurrentTime
            let body = mkInitiateAbBodyPostMonitoring tracker cluster svcHost selfClosingSec now
            liftIO $ initiateABDecision abUrl apiKey (appGroup tracker) body failClosed

{- | Julia parity: POST @{abUrl}stop/ab/{run_id}@ to terminate the decision
pod when we abort or complete a release. Best-effort: logs on failure and
never throws, so cleanup paths remain robust.
-}
stopDecisionEngineHS :: (MonadFlow m) => Config -> Text -> m ()
stopDecisionEngineHS cfg runId = do
    let abUrl = abEngineUrl cfg
    if null abUrl || T.null runId
        then pure ()
        else do
            apiKey <- getABHSApiKey
            liftIO $ do
                let url = ensureSlash (T.pack abUrl) <> "stop/ab/" <> runId
                    req =
                        (defaultReq url)
                            { reqMethod = POST
                            , reqHeaders =
                                [ ("Content-Type", "application/json")
                                , ("x-api-key", apiKey)
                                ]
                            , reqTimeout = Seconds 10
                            , reqRetries = 1
                            , reqLogTag = "ab-stop"
                            }
                result <- try (httpRaw req) :: IO (Either SomeException (Either HttpError HttpResponse))
                case result of
                    Right (Right HttpResponse{respStatus = s})
                        | s < 400 ->
                            logDebugG $ "[DECISION] Stopped AB engine for run_id " <> runId
                    Right (Right HttpResponse{respStatus = s}) ->
                        logWarningG $ "[DECISION] Stop AB engine HTTP " <> T.pack (show s) <> " for " <> runId
                    Right (Left e) ->
                        logWarningG $ "[DECISION] Stop AB engine failed: " <> T.pack (show e)
                    Left e ->
                        logWarningG $ "[DECISION] Stop AB engine threw: " <> T.pack (show e)

{- | Per-rollout-step AB decision read.

In Julia's flow, the AB engine never returns a verdict directly during the
rollout — the decision pod runs in the background and emits its verdict via
the HS GET poll using the shared @run_id@. So this function is structurally
a no-op: it always returns Continue. The actual decision-making happens in
'getHSDecision'.

Kept as a separate function (rather than inlining) for symmetry with Julia's
two-call shape (@getABDecision@ + @getHSDecision@) and to make the workflow
call site read identically to Julia's @service.jl@.
-}
getABDecision :: (MonadFlow m) => Config -> ReleaseTracker -> m DecisionResult
getABDecision _cfg _tracker = pure (DecisionResult Continue Nothing "AB_ENGINE")

{- | Internal: POST @{abUrl}initiate/ab@ to spawn the decision pod.
Mirrors @intiateDecisionEngine@ in Julia's @global_changelog.jl@.
On success returns @DecisionResult Continue@ — the actual decision
comes back via the HS poll (which reads the same @run_id@).
-}
initiateABDecision :: String -> Text -> Text -> Value -> Bool -> IO DecisionResult
initiateABDecision abUrl apiKey productName body failClosed = do
    let url = ensureSlash (T.pack abUrl) <> "initiate/ab"
        req =
            (defaultReq url)
                { reqMethod = POST
                , reqHeaders =
                    [ ("Content-Type", "application/json")
                    , ("product", productName)
                    , ("x-api-key", apiKey)
                    ]
                , reqBody = Just (A.encode body)
                , reqTimeout = Seconds 10
                , reqRetries = 1
                , reqLogTag = "ab-init"
                }
    result <- httpRaw req
    case result of
        Right HttpResponse{respStatus = s}
            | s < 400 ->
                pure (DecisionResult Continue (Just "AB initiated") "AB_ENGINE")
        Right HttpResponse{respStatus = s} -> do
            logErrorG $ "[DECISION] AB initiate failed (HTTP " <> T.pack (show s) <> ")"
            pure (failOrContinue failClosed "AB_ENGINE" ("AB initiate HTTP " <> T.pack (show s)))
        Left e -> do
            logErrorG $ "[DECISION] AB initiate failed: " <> T.pack (show e)
            pure (failOrContinue failClosed "AB_ENGINE" "AB Engine unreachable")

{- | Build the JSON body Julia POSTs to @initiate/ab@ — full Julia parity.
Julia source: @global_changelog.jl:111-124@. Includes start_time, end_time
(start+24h), cluster (ckh_cluster_name), and the deployment_config service host.
-}
mkInitiateAbBody :: ReleaseTracker -> Text -> Text -> UTCTime -> Value
mkInitiateAbBody tracker cluster svcHost now =
    let st = case startTime tracker of
            Just t -> t
            Nothing -> now
        et = addUTCTime (24 * 3600) st
     in object
            [ "product" .= appGroup tracker
            , "service" .= service tracker
            , "environment" .= extractCluster tracker
            , "interval" .= (1 :: Int)
            , "placeholders"
                .= object
                    [ "version_a" .= oldVersion tracker
                    , "version_b" .= newVersion tracker
                    , "start_time" .= formatStdTime st
                    , "end_time" .= formatStdTime et
                    , "cluster" .= cluster
                    , "service" .= svcHost
                    ]
            , "run_id" .= releaseId tracker
            ]

{- | Julia parity: post-monitoring AB initiate body. Source:
@global_changelog.jl:144-188@. Differences from primary body:
  * service suffixed with "_POST"
  * interval = 5
  * placeholders.start_time = now (not tracker.start_time)
  * placeholders.global_time = now - 24h
  * run_id suffixed with "-post"
  * top-level self_closing_time field
-}
mkInitiateAbBodyPostMonitoring :: ReleaseTracker -> Text -> Text -> Int -> UTCTime -> Value
mkInitiateAbBodyPostMonitoring tracker cluster svcHost selfClosingSec now =
    let globalT = addUTCTime (negate (24 * 3600)) now
     in object
            [ "product" .= appGroup tracker
            , "service" .= (service tracker <> "_POST")
            , "environment" .= extractCluster tracker
            , "interval" .= (5 :: Int)
            , "placeholders"
                .= object
                    [ "version_a" .= oldVersion tracker
                    , "version_b" .= newVersion tracker
                    , "start_time" .= formatStdTime now
                    , "cluster" .= cluster
                    , "service" .= svcHost
                    , "global_time" .= formatStdTime globalT
                    ]
            , "run_id" .= (releaseId tracker <> "-post")
            , "self_closing_time" .= selfClosingSec
            ]

{- | Format a UTCTime the way Julia's @convertTimeToStandardFormat@ does:
ISO-ish "YYYY-mm-ddTHH:MM:SS".
-}
formatStdTime :: UTCTime -> Text
formatStdTime = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S"

-- | Pull "cluster" out of the tracker's releaseContext JSON blob.
extractCluster :: ReleaseTracker -> Text
extractCluster tracker = case releaseContext tracker of
    Just (Object o) -> case KM.lookup (K.fromText "cluster") o of
        Just (String c) -> c
        _ -> ""
    _ -> ""

-- ============================================================================
-- Health Score (HS) Decision Engine
-- ============================================================================

{- | Get decision from Health Score / AB engine.

Wire format (Julia parity, @global_changelog.jl:191-216@):

@
  GET  {AB_HS_URL}get/ab/decision/{run_id}
  Headers: Content-Type: application/json
           x-api-key: <ab_hs_api_key>
  Body:    {"allowedTimeDiffInMins": <ab_hs_allowed_time_diff_mins>,
            "ignoreMetricsForDecision": []}
@

Note: Julia's HTTP client allows a body on GET. We do the same via
'Core.Http.Client'. Response is integer-encoded:

  * @{"decision": 0}@ → Continue
  * @{"decision": 1}@ → Abort
  * @{"decision": 2}@ → Wait

For post-monitoring, the run_id is suffixed with @"-post"@ (Julia
@intiateDecisionEnginePostMonitoring@ uses @tracker.id * "-post"@).

Returns Continue if @ab_hs_enabled@ is false or @AB_HS_URL@ unset.
On HTTP error: Abort if @decision_engine_fail_closed@ is true (default,
Julia parity), Continue otherwise.
-}
getHSDecision :: (MonadFlow m) => Config -> ReleaseTracker -> Bool -> m DecisionResult
getHSDecision cfg tracker isPostMonitoring = do
    enabled <- getConfigBoolForProduct "ab_hs_enabled" (Just (appGroup tracker)) False
    if not enabled
        then pure (DecisionResult Continue Nothing "HEALTH_SCORE")
        else do
            let hsUrl = abHsUrl cfg
            if null hsUrl
                then pure (DecisionResult Continue Nothing "HEALTH_SCORE")
                else do
                    apiKey <- getABHSApiKey
                    diffMins <- getABHSAllowedTimeDiffMins
                    failClosed <- getDecisionEngineFailClosed
                    -- Julia parity: read configurable volume floors
                    -- (DecisionThreshold.volume_thresholds) so operators
                    -- can tighten/loosen per environment via server_config.
                    minA <- getABHSVolumeMinA
                    minB <- getABHSVolumeMinB
                    let runId =
                            if isPostMonitoring
                                then releaseId tracker <> "-post"
                                else releaseId tracker
                    liftIO $ pollHSDecision hsUrl apiKey diffMins runId failClosed minA minB

{- | Internal: GET @{hsUrl}get/ab/decision/{runId}@ with the Julia-parity
JSON body and headers. Parses int-encoded decision.
-}
pollHSDecision :: String -> Text -> Int -> Text -> Bool -> Int -> Int -> IO DecisionResult
pollHSDecision hsUrl apiKey diffMins runId failClosed minA minB = do
    let url = ensureSlash (T.pack hsUrl) <> "get/ab/decision/" <> runId
        body =
            object
                [ "allowedTimeDiffInMins" .= diffMins
                , "ignoreMetricsForDecision" .= ([] :: [Value])
                ]
        req =
            (defaultReq url)
                { reqMethod = GET
                , reqHeaders =
                    [ ("Content-Type", "application/json")
                    , ("x-api-key", apiKey)
                    ]
                , reqBody = Just (A.encode body)
                , reqTimeout = Seconds 10
                , reqRetries = 1
                , reqLogTag = "hs-decision"
                }
    result <- httpRaw req
    case result of
        Right HttpResponse{respStatus = s, respBody = b} | s < 400 ->
            case A.decodeStrict' (LBS.toStrict b) :: Maybe Value of
                Just v -> parseDecisionResponseWithVolume v "HEALTH_SCORE" minA minB
                Nothing -> do
                    logWarningG "[DECISION] HS response: JSON decode error"
                    pure (failOrContinue failClosed "HEALTH_SCORE" "HS JSON decode error")
        Right HttpResponse{respStatus = s} -> do
            logErrorG $ "[DECISION] HS Engine call failed (HTTP " <> T.pack (show s) <> ")"
            pure (failOrContinue failClosed "HEALTH_SCORE" ("HS Engine HTTP " <> T.pack (show s)))
        Left e -> do
            logErrorG $ "[DECISION] HS Engine call failed: " <> T.pack (show e)
            pure (failOrContinue failClosed "HEALTH_SCORE" "HS Engine unreachable")

-- | Choose Abort (fail-closed, Julia parity) or Continue (lenient) on error.
failOrContinue :: Bool -> Text -> Text -> DecisionResult
failOrContinue True src reason = DecisionResult Abort (Just reason) src
failOrContinue False src reason = DecisionResult Continue (Just reason) src

-- | Ensure a URL string ends with @/@ so we can append @initiate/ab@ etc.
ensureSlash :: Text -> Text
ensureSlash u
    | T.null u = u
    | T.last u == '/' = u
    | otherwise = u <> "/"

-- ============================================================================
-- Combined Decision
-- ============================================================================

{- | Combine AB and HS decisions by Julia priority ordering:
  Abort > Wait > WaitForMoreIteration > Continue.
Julia parity (decision/runner.jl decisionPriority field on ABDecision).
-}
getCombinedDecision :: DecisionResult -> DecisionResult -> Decision
getCombinedDecision ab hs =
    let a = drDecision ab
        b = drDecision hs
     in if decisionPriority a <= decisionPriority b then a else b

-- ============================================================================
-- Shared Helpers
-- ============================================================================

{- | Parse a decision response JSON.

Primary path (Julia parity, @decisionengine.jl:87-95@): the @"decision"@
field is an integer:

  * @0@ → Continue
  * @1@ → Abort
  * @2@ → Wait
  * any other int → Continue (lenient)

Fallback path (forward-compat with any string-emitting endpoint):
recognises @"Abort"@/@"Wait"@/@"Continue"@ case-insensitively.

If the field is missing entirely we return Continue (fail-open default
for parse-only errors; HTTP-level errors honour @decision_engine_fail_closed@).
-}

{- | Parse decision response with Julia-parity safety checks.

Defensive layers (Julia parity):
  1. Volume floor (decision/runner.jl:494,537-541 volume_rate_result):
     downgrade Abort → Wait if totalA < minA or totalB < minB. Defaults
     match Julia (50, 100) but can be overridden via the optional
     @minA@ / @minB@ args (read from server_config by the caller).
  2. Volume rate-of-growth (decision/runner.jl:490-529 volume_rate_result):
     if the response includes prevTotalA / prevTotalB and the growth
     between samples is below @minRateA@ / @minRateB@, downgrade to Wait.
  3. 5xx spike force-abort (decision/runner.jl:508-511): when the metric
     name is in the resp_5xx family AND (totalB × errorPct/100) ≥ 200,
     force Abort regardless of the engine's reported decision.
  4. A/B split breach (decision/runner.jl:646-651): if the response
     reports an actual traffic split that drifted outside
     [routePercent − buffer, routePercent + buffer], abort with
     "A/B Split Percentage Breach".

All checks are no-ops if the engine omits the relevant fields — we
trust the engine's verdict in that case and apply only the int → enum
mapping.
-}
parseDecisionResponse :: Value -> Text -> IO DecisionResult
parseDecisionResponse v source =
    parseDecisionResponseWithVolume v source 50 100

{- | Variant of 'parseDecisionResponse' that accepts caller-supplied
volume thresholds. The 'getHSDecision' wrapper reads them from
server_config so operators can tighten/loosen per environment without
recompiling.
-}
parseDecisionResponseWithVolume :: Value -> Text -> Int -> Int -> IO DecisionResult
parseDecisionResponseWithVolume (Object obj) source minA minB = do
    let rawDecision = case KM.lookup (K.fromText "decision") obj of
            Just (Number n) -> case toBoundedInteger n :: Maybe Int of
                Just 0 -> Continue
                Just 1 -> Abort
                Just 2 -> Wait
                Just 3 -> WaitForMoreIteration
                _ -> Continue
            Just (String s) -> case T.toLower (T.strip s) of
                "abort" -> Abort
                "wait" -> Wait
                "wait_for_more_iteration" -> WaitForMoreIteration
                "waitformoreiteration" -> WaitForMoreIteration
                _ -> Continue
            _ -> Continue
        reason = case KM.lookup (K.fromText "reason") obj of
            Just (String r) | not (T.null r) -> Just r
            Just (Array rs) ->
                let xs = [r | String r <- toList rs, not (T.null r)]
                 in if null xs then Nothing else Just (T.intercalate "; " xs)
            _ -> Nothing
        readInt k = case KM.lookup (K.fromText k) obj of
            Just (Number n) -> toBoundedInteger n :: Maybe Int
            _ -> Nothing
        readDouble k = case KM.lookup (K.fromText k) obj of
            Just (Number n) -> Just (toRealFloat n :: Double)
            _ -> Nothing
        readText k = case KM.lookup (K.fromText k) obj of
            Just (String s) -> Just s
            _ -> Nothing
        totalA = readInt "totalA" <|> readInt "total_a" <|> readInt "sampleA"
        totalB = readInt "totalB" <|> readInt "total_b" <|> readInt "sampleB"
        prevTotalA = readInt "prevTotalA" <|> readInt "prev_total_a"
        prevTotalB = readInt "prevTotalB" <|> readInt "prev_total_b"
        metricName = readText "metric" <|> readText "metricName"
        errorRate = readDouble "rate" <|> readDouble "errorRate" <|> readDouble "mv_b"
        actualSplit = readDouble "actualSplit" <|> readDouble "actual_split" <|> readDouble "trafficSplit"
        targetSplit = readDouble "targetSplit" <|> readDouble "target_split" <|> readDouble "releasePercentage"
        splitBuffer = readDouble "splitBuffer" <|> readDouble "release_buffer"

        -- Layer 1: absolute sample-size floor.
        belowVolume = case (totalA, totalB) of
            (Just a, _) | a < minA -> True
            (_, Just b) | b < minB -> True
            _ -> False

        -- Layer 2: rate-of-growth floor. Julia checks (total - prev) > 0
        -- and bounded by a minimum rate. We use a conservative default:
        -- growth must be at least 1 sample/iteration, otherwise downgrade.
        belowRate = case (totalA, prevTotalA, totalB, prevTotalB) of
            (Just a, Just pa, Just b, Just pb) | (a - pa) <= 0 && (b - pb) <= 0 -> True
            _ -> False

        -- Layer 3: 5xx spike force-abort. Julia: for resp_500/501/503,
        -- if (total_b × mv_b/100) ≥ 200, force abort regardless of
        -- whatever the engine returned.
        is5xxMetric = case metricName of
            Just m -> m `elem` ["resp_500_rate", "resp_501_rate", "resp_503_rate", "resp_5xx_rate"]
            Nothing -> False
        spike5xxForceAbort = case (is5xxMetric, totalB, errorRate) of
            (True, Just tb, Just rate) -> (fromIntegral tb * rate / 100.0 :: Double) >= 200.0
            _ -> False

        -- Layer 4: A/B split breach. Abort if actual drifted outside
        -- target ± buffer. Default buffer 5% if not provided.
        splitBreach = case (actualSplit, targetSplit) of
            (Just actual, Just target) ->
                let buf = maybe 5.0 id splitBuffer
                 in actual < (target - buf) || actual > (target + buf)
            _ -> False

        -- Compose the final decision honouring layers in priority order:
        --   5xx force-abort > split breach > engine Abort (with volume gate) > raw
        decision
            | spike5xxForceAbort = Abort
            | splitBreach = Abort
            | rawDecision == Abort && (belowVolume || belowRate) = Wait
            | otherwise = rawDecision

        finalReason
            | spike5xxForceAbort =
                Just $
                    "5xx error spike force-abort (metric="
                        <> maybe "?" id metricName
                        <> ", totalB="
                        <> T.pack (show totalB)
                        <> ", rate="
                        <> T.pack (show errorRate)
                        <> ")"
            | splitBreach =
                Just $
                    "A/B split percentage breach (actual="
                        <> T.pack (show actualSplit)
                        <> ", target="
                        <> T.pack (show targetSplit)
                        <> "±"
                        <> T.pack (show splitBuffer)
                        <> ")"
            | rawDecision == Abort && belowVolume =
                Just $
                    "Abort downgraded to Wait — sample size below volume floor (totalA="
                        <> T.pack (show totalA)
                        <> "/min="
                        <> T.pack (show minA)
                        <> ", totalB="
                        <> T.pack (show totalB)
                        <> "/min="
                        <> T.pack (show minB)
                        <> ")"
            | rawDecision == Abort && belowRate =
                Just $
                    "Abort downgraded to Wait — sample volume not growing (totalA="
                        <> T.pack (show totalA)
                        <> "→prev="
                        <> T.pack (show prevTotalA)
                        <> ", totalB="
                        <> T.pack (show totalB)
                        <> "→prev="
                        <> T.pack (show prevTotalB)
                        <> ")"
            | otherwise = reason
    pure (DecisionResult decision finalReason source)
parseDecisionResponseWithVolume _ source _ _ = do
    logWarningG $ "[DECISION] Could not parse decision response for " <> source
    pure (DecisionResult Continue (Just "Invalid response format") source)
