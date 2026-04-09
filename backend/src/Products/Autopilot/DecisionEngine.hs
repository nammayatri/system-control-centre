{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Decision engine. Three gated decision sources:

1. Prometheus query checks (decision_config in deployment_config).
2. AB Decision Engine — external Continue/Wait/Abort service.
3. Health Score — external service, pre- and post-monitoring variants.

All sources fail OPEN on HTTP/parse/config errors so monitoring outages
never block releases — except where @decision_engine_fail_closed@ is set.
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

{- | Run Prometheus checks per the service's decision_config. Returns
PromOK when gated off / no config / no URL / parse failure (fail open),
PromAbort on any abort_threshold breach, PromWarn on warn_threshold.
-}
checkPromQueries :: (MonadFlow m) => Config -> ReleaseTracker -> Maybe Text -> m PromCheckResult
checkPromQueries cfg tracker mDecisionConfig = do
    enabled <- isPromQueryCheckEnabled
    if not enabled
        then pure PromOK
        else case mDecisionConfig of
            Nothing -> pure PromOK
            Just configJson -> do
                let promUrl = prometheusUrl cfg
                if null promUrl
                    then pure PromOK
                    else liftIO $ executePromChecks promUrl configJson tracker

executePromChecks :: String -> Text -> ReleaseTracker -> IO PromCheckResult
executePromChecks promUrl configJson tracker =
    case A.decodeStrict' (TE.encodeUtf8 configJson) of
        Nothing -> do
            logWarningG "[DECISION] Failed to parse decision_config JSON, skipping prom checks"
            pure PromOK
        Just configs -> checkAllConfigs promUrl configs tracker

-- | Worst-result fold across configs: Abort > Warn > OK.
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

{- | Check a single config entry against Prometheus. Expected shape:
@{cluster, config: {experiments: [{queries: [{query, name}], thresholds: {abort, warn}}]}}@.
HTTP errors return PromOK (fail open).
-}
checkSingleConfig :: String -> Value -> ReleaseTracker -> IO PromCheckResult
checkSingleConfig url config _rt = do
    result <- try (checkConfigQueries url config) :: IO (Either SomeException PromCheckResult)
    case result of
        Right r -> pure r
        Left e -> do
            logErrorG $ "[DECISION] Prometheus check failed: " <> T.pack (show e)
            pure PromOK

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

checkExperiment :: String -> Value -> IO PromCheckResult
checkExperiment promUrl (Object expObj) = do
    let queries = case KM.lookup (K.fromText "queries") expObj of
            Just (Array qs) -> toList qs
            _ -> []
        abortThreshold = extractThreshold "abort" expObj
        warnThreshold = extractThreshold "warn" expObj
    checkQueryList promUrl queries abortThreshold warnThreshold
checkExperiment _ _ = pure PromOK

extractThreshold :: Text -> KM.KeyMap Value -> Maybe Double
extractThreshold key expObj =
    case KM.lookup (K.fromText "thresholds") expObj of
        Just (Object thresholds) ->
            case KM.lookup (K.fromText key) thresholds of
                Just (Number n) -> Just (realToFrac n)
                _ -> Nothing
        _ -> Nothing

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

-- | Query Prometheus for a single metric and apply threshold + safety rails.
checkSingleQuery :: String -> Value -> Maybe Double -> Maybe Double -> IO PromCheckResult
checkSingleQuery promUrl (Object qObj) abortTh warnTh = do
    let mQuery = case KM.lookup (K.fromText "query") qObj of
            Just (String q) -> Just q
            _ -> Nothing
        mName = case KM.lookup (K.fromText "name") qObj of
            Just (String n) -> n
            _ -> "unknown"
        readDouble k = case KM.lookup (K.fromText k) qObj of
            Just (Number n) -> Just (toRealFloat n :: Double)
            _ -> Nothing
        -- Layer A: 5xx error-spike force-abort when (sampleCount × val/100) ≥ 200.
        -- sampleCount must be supplied via the query config (sample_count/totalB).
        is5xxMetric =
            mName
                `elem` [ "resp_500_rate"
                       , "resp_501_rate"
                       , "resp_503_rate"
                       , "resp_5xx_rate"
                       , "5xx_rate"
                       ]
        sampleCount = readDouble "sample_count" <|> readDouble "totalB"
        -- Layer B: abort on A/B split drift outside target ± buffer (default 5%).
        targetSplit = readDouble "target_split" <|> readDouble "release_percentage"
        actualSplit = readDouble "actual_split" <|> readDouble "current_split"
        splitBuffer = readDouble "split_buffer" <|> readDouble "release_buffer"
    case mQuery of
        Nothing -> pure PromOK
        Just query -> do
            mValue <- queryPrometheus promUrl query
            case mValue of
                Nothing -> pure PromOK
                Just val -> do
                    logDebugG $ "[DECISION] Prom query '" <> mName <> "' = " <> T.pack (show val)
                    -- Layer A wins over generic thresholds; layer B wins over A engine verdict.
                    let spike5xx = case (is5xxMetric, sampleCount) of
                            (True, Just sc) -> (sc * val / 100.0 :: Double) >= 200.0
                            _ -> False
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

-- | GET {promUrl}/api/v1/query — extracts scalar value. Nothing on any failure.
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

-- | Parse @{data: {result: [{value: [ts, "n"]}]}}@ into a scalar.
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

{- | Spawn the AB decision pod ONCE per release via POST
@{AB_ENGINE_URL}initiate/ab@. Called from the workflow prepare phase, not
the rollout loop (per-step calls would re-spawn every iteration).
Gated by @ab_decision_enabled@ AND per-service
@ab_hs_decision_enabled_app_groups@. HTTP errors return Abort if
@decision_engine_fail_closed@ is set (default), else Continue. The
verdict is read later via 'getHSDecision' polling the same run_id.
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

fromMaybeT :: Maybe Text -> Text
fromMaybeT = maybe "" id

{- | Spawn the post-monitoring AB run (run_id suffix @-post@) once the new
version hits 100% and pods are ready, before the post-monitor HS loop.
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

{- | Best-effort POST @{abUrl}stop/ab/{run_id}@ to terminate the decision
pod on abort/complete. Logs failures; never throws.
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

{- | Per-rollout-step AB read — structurally a no-op (always Continue). The
AB pod's verdict arrives via 'getHSDecision'. Kept as a separate function
so the workflow's two-call shape stays readable.
-}
getABDecision :: (MonadFlow m) => Config -> ReleaseTracker -> m DecisionResult
getABDecision _cfg _tracker = pure (DecisionResult Continue Nothing "AB_ENGINE")

-- | POST @{abUrl}initiate/ab@; success returns Continue (verdict via HS poll).
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

-- | JSON body for @initiate/ab@. end_time is start+24h.
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

{- | Post-monitoring variant of 'mkInitiateAbBody'. Differences: service
suffixed @_POST@, interval 5, start_time=now, global_time=now-24h,
run_id suffixed @-post@, plus top-level @self_closing_time@.
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

-- | "YYYY-mm-ddTHH:MM:SS" for the AB engine.
formatStdTime :: UTCTime -> Text
formatStdTime = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S"

extractCluster :: ReleaseTracker -> Text
extractCluster tracker = case releaseContext tracker of
    Just (Object o) -> case KM.lookup (K.fromText "cluster") o of
        Just (String c) -> c
        _ -> ""
    _ -> ""

{- | GET @{AB_HS_URL}get/ab/decision/{runId}@ (body allowed on GET) with
int-encoded response (0 Continue, 1 Abort, 2 Wait). Post-monitoring uses
@{runId}-post@. Gated by @ab_hs_enabled@; HTTP errors honour
@decision_engine_fail_closed@.
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
                    -- Per-env volume floors via server_config.
                    minA <- getABHSVolumeMinA
                    minB <- getABHSVolumeMinB
                    let runId =
                            if isPostMonitoring
                                then releaseId tracker <> "-post"
                                else releaseId tracker
                    liftIO $ pollHSDecision hsUrl apiKey diffMins runId failClosed minA minB

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

failOrContinue :: Bool -> Text -> Text -> DecisionResult
failOrContinue True src reason = DecisionResult Abort (Just reason) src
failOrContinue False src reason = DecisionResult Continue (Just reason) src

ensureSlash :: Text -> Text
ensureSlash u
    | T.null u = u
    | T.last u == '/' = u
    | otherwise = u <> "/"

-- | Combine AB + HS by priority: Abort > Wait > WaitForMoreIteration > Continue.
getCombinedDecision :: DecisionResult -> DecisionResult -> Decision
getCombinedDecision ab hs =
    let a = drDecision ab
        b = drDecision hs
     in if decisionPriority a <= decisionPriority b then a else b

{- | Parse an engine response with four defensive layers (any omitted field
= no-op):

  1. Volume floor — downgrade Abort→Wait if totalA\<minA or totalB\<minB.
  2. Rate-of-growth — downgrade Abort→Wait if totals aren't growing.
  3. 5xx spike — force Abort if (totalB × rate/100) ≥ 200 for a
     @resp_5xx@-family metric regardless of engine verdict.
  4. A/B split breach — force Abort if actual drifted outside
     target ± buffer (default 5%).

The primary @decision@ field is int-encoded (0 Continue, 1 Abort, 2 Wait,
3 WaitForMoreIteration); a string fallback recognises the same names.
Missing field is treated as Continue (fail-open parse error).
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

        belowVolume = case (totalA, totalB) of
            (Just a, _) | a < minA -> True
            (_, Just b) | b < minB -> True
            _ -> False

        belowRate = case (totalA, prevTotalA, totalB, prevTotalB) of
            (Just a, Just pa, Just b, Just pb) | (a - pa) <= 0 && (b - pb) <= 0 -> True
            _ -> False

        is5xxMetric = case metricName of
            Just m -> m `elem` ["resp_500_rate", "resp_501_rate", "resp_503_rate", "resp_5xx_rate"]
            Nothing -> False
        spike5xxForceAbort = case (is5xxMetric, totalB, errorRate) of
            (True, Just tb, Just rate) -> (fromIntegral tb * rate / 100.0 :: Double) >= 200.0
            _ -> False

        splitBreach = case (actualSplit, targetSplit) of
            (Just actual, Just target) ->
                let buf = maybe 5.0 id splitBuffer
                 in actual < (target - buf) || actual > (target + buf)
            _ -> False

        -- Priority: 5xx force-abort > split breach > engine Abort (volume-gated) > raw.
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
