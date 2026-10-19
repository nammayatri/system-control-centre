{-# LANGUAGE OverloadedStrings #-}

{- | Replica and CPU history for the performance chart, read ON DEMAND from the metrics
system (a Prometheus-compatible @query_range@ API: Prometheus, VictoriaMetrics, ...).

Nothing is stored by this application. Where no metrics endpoint is configured
(@PROMETHEUS_URL@ empty) the caller shows live numbers only.

Metric names follow the standard exporters:

* kube-state-metrics: @kube_horizontalpodautoscaler_status_current_replicas@,
  @..._status_desired_replicas@, @..._spec_min_replicas@, @..._spec_max_replicas@
  (label @horizontalpodautoscaler@; older versions use @hpa@, tried as a fallback);
* cAdvisor + kube-state-metrics for CPU: @container_cpu_usage_seconds_total@ over
  @kube_pod_container_resource_requests{resource="cpu"}@.
-}
module Products.Autopilot.Hpa.Metrics (
    SeriesPoint (..),
    fetchSeries,
    parsePromMatrix,
    mergeSeries,
    hpaQuery,
    cpuQuery,
)
where

import Control.Concurrent.Async (mapConcurrently)
import Core.Http.Client (HttpReq (..), HttpResponse (..), defaultReq, httpRaw)
import Core.Types.Time (Seconds (..))
import Data.Aeson (ToJSON (..), Value (..), (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Data.Vector qualified as V
import Network.HTTP.Types.URI (urlEncode)
import Products.Autopilot.Hpa.Health (safeK8sName)
import Text.Read (readMaybe)

data SeriesPoint = SeriesPoint
    { spTs :: UTCTime
    , spHpa :: Text
    , spMin :: Maybe Double
    , spMax :: Maybe Double
    , spCurrent :: Maybe Double
    , spDesired :: Maybe Double
    , spCpuPct :: Maybe Double
    }
    deriving (Eq, Show)

instance ToJSON SeriesPoint where
    toJSON p =
        A.object
            [ "ts" .= spTs p
            , "hpaName" .= spHpa p
            , "min" .= spMin p
            , "max" .= spMax p
            , "current" .= spCurrent p
            , "desired" .= spDesired p
            , "cpuPct" .= spCpuPct p
            , "memoryPct" .= (Nothing :: Maybe Double)
            ]

-- | A label value inside a PromQL regex. Names are validated first, so only @.@ needs care;
-- a character class avoids any backslash escaping.
rx :: Text -> Text
rx = T.replace "." "[.]"

-- | HPA gauge for the given HPAs in a namespace.
hpaQuery :: Text -> Text -> Text -> [Text] -> Text
hpaQuery labelName metric ns hpas =
    "kube_horizontalpodautoscaler_" <> metric <> "{namespace=\"" <> ns <> "\"," <> labelName <> "=~\"" <> T.intercalate "|" (map rx hpas) <> "\"}"

-- | CPU use as a percentage of the pods' requests for one Deployment's pods.
cpuQuery :: Text -> Text -> Text
cpuQuery ns dep =
    let pods = "pod=~\"" <> rx dep <> "-[a-z0-9]+-[a-z0-9]+\""
     in "100 * sum(rate(container_cpu_usage_seconds_total{namespace=\""
            <> ns
            <> "\","
            <> pods
            <> ",container!=\"\",container!=\"POD\"}[2m])) / sum(kube_pod_container_resource_requests{namespace=\""
            <> ns
            <> "\","
            <> pods
            <> ",resource=\"cpu\"})"

-- | @(labels, [(unixSeconds, value)])@ per series of a @query_range@ response.
parsePromMatrix :: Value -> Either Text [(Map.Map Text Text, [(Double, Double)])]
parsePromMatrix (Object o) = case KM.lookup "status" o of
    Just (String "error") -> Left "the metrics endpoint returned an error"
    _ -> case KM.lookup "data" o of
        Just (Object d) | Just (Array rs) <- KM.lookup "result" d -> Right (mapMaybe series (V.toList rs))
        _ -> Left "unexpected response from the metrics endpoint"
  where
    series (Object r) = do
        vals <- case KM.lookup "values" r of Just (Array vs) -> Just (mapMaybe pointOf (V.toList vs)); _ -> Nothing
        let labels = case KM.lookup "metric" r of
                Just (Object m) -> Map.fromList [(K.toText k, t) | (k, String t) <- KM.toList m]
                _ -> Map.empty
        pure (labels, vals)
    series _ = Nothing
    pointOf (Array p) | [Number t, String v] <- V.toList p, Just x <- readMaybe (T.unpack v), not (isNaN x), not (isInfinite x) = Just (realToFrac t, x)
    pointOf _ = Nothing
parsePromMatrix _ = Left "the metrics endpoint did not return JSON"

-- | Join per-field series (current, desired, min, max, cpu) into one point per HPA per timestamp.
mergeSeries :: [(Text, Text, [(Double, Double)])] -> [SeriesPoint]
mergeSeries fields =
    [ p
    | ((hpa, ts), vals) <- Map.toAscList grouped
    , let get f = lookup f vals
    , let p = SeriesPoint (posixSecondsToUTCTime (realToFrac ts)) hpa (get "min") (get "max") (get "current") (get "desired") (get "cpu")
    ]
  where
    grouped :: Map.Map (Text, Double) [(Text, Double)]
    grouped = Map.fromListWith (<>) [((hpa, ts), [(field, v)]) | (field, hpa, pts) <- fields, (ts, v) <- pts]

queryRange :: String -> Text -> UTCTime -> UTCTime -> Int -> IO (Either Text [(Map.Map Text Text, [(Double, Double)])])
queryRange base query from to step = do
    let secs t = T.pack (show (round (utcTimeToPOSIXSeconds t) :: Integer))
        url =
            T.pack base
                <> "/api/v1/query_range?query="
                <> TE.decodeUtf8 (urlEncode True (TE.encodeUtf8 query))
                <> "&start="
                <> secs from
                <> "&end="
                <> secs to
                <> "&step="
                <> T.pack (show step)
        req = (defaultReq url) {reqTimeout = Seconds 20, reqRetries = 0, reqLogTag = "hpa-metrics"}
    r <- httpRaw req
    pure $ case r of
        Left e -> Left ("metrics endpoint unreachable: " <> T.pack (take 120 (show e)))
        Right HttpResponse {respStatus = s, respBody = b}
            | s >= 400 -> Left ("metrics endpoint HTTP " <> T.pack (show s))
            | otherwise -> maybe (Left "metrics endpoint returned invalid JSON") parsePromMatrix (A.decode b)

{- | History for the given HPAs (name and the Deployment they scale), over @[from, to]@ at @step@ seconds.
Refuses names that are not plain Kubernetes names, so a crafted name cannot rewrite a query.
-}
fetchSeries :: String -> Text -> [(Text, Text)] -> UTCTime -> UTCTime -> Int -> IO (Either Text [SeriesPoint])
fetchSeries base ns hpas from to step
    | not (all safeK8sName (ns : concatMap (\(h, d) -> [h, d]) hpas)) = pure (Left "refusing to query metrics for an unusual resource name")
    | null hpas = pure (Right [])
    | otherwise = do
        r1 <- go "horizontalpodautoscaler"
        -- kube-state-metrics v1 labelled the HPA "hpa"
        r <- case r1 of
            Right [] -> go "hpa"
            other -> pure other
        pure (fmap mergeSeries r)
  where
    names = map fst hpas
    go label = do
        let gauges =
                [ (f, hpaQuery label m ns names)
                | (f, m) <- [("current", "status_current_replicas"), ("desired", "status_desired_replicas"), ("min", "spec_min_replicas"), ("max", "spec_max_replicas")]
                ]
        results <- mapConcurrently (\(f, q) -> (,) f <$> queryRange base q from to step) gauges
        cpu <- mapConcurrently (\(h, d) -> (,) h <$> queryRange base (cpuQuery ns d) from to step) hpas
        pure $ do
            gs <- fmap concat (traverse (gaugeSeries label) results)
            -- CPU is best-effort: a missing cAdvisor/requests metric must not hide the replica history.
            pure (gs <> [("cpu", h, pts) | (h, Right ss) <- cpu, (_, pts) <- take 1 ss])

    gaugeSeries :: Text -> (Text, Either Text [(Map.Map Text Text, [(Double, Double)])]) -> Either Text [(Text, Text, [(Double, Double)])]
    gaugeSeries _ (_, Left e) = Left e
    gaugeSeries label (f, Right ss) = Right [(f, Map.findWithDefault "" label l, pts) | (l, pts) <- ss]
