{-# LANGUAGE OverloadedStrings #-}

-- | Autopilot-specific runtime configs read from server_config DB table.
module Products.Autopilot.RuntimeConfig (
    -- Feature flags (MonadFlow versions)
    isK8sEnabled,
    isWatcherEnabled,
    isApproveAllReleases,
    isScaleDownPodsOnCompletion,
    isGcltEnabled,
    isPromQueryCheckEnabled,
    isSyncClusterEnabled,
    isMultiReleasePerProduct,
    isUnderMaintenance,
    -- Delays / numeric (MonadFlow versions)
    getReleaseWatchDelay,
    getReleaseStartDelay,
    getCollectMetricsDelay,
    getPodsCreationDelay,
    getPodsScaleDownDelayFromConfig,
    getPodsCalculationFactor,
    getHpaMinMaxFactor,
    getMaxJobCompletionHours,
    getRevertCooloff,
    getLockExpiryDelayMinutes,
    getMaxK8sRetries,
    -- HPA (MonadFlow versions)
    isHpaEnabledForProduct,
    getHpaTemplate,
    -- Notifications (MonadFlow versions)
    isSlackEnabled,
    -- Snapshot
    RuntimeConfigSnapshot (..),
    loadRuntimeConfigSnapshot,
)
where

import Core.Environment (MonadFlow, withDb)
import Data.Aeson (Value (..), eitherDecode)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Shared.Config.Runtime (
    getConfigBoolForProduct,
    getConfigDoubleForProduct,
    getConfigIntForProduct,
 )
import Shared.Queries.ServerConfig (getEnabledServerConfigValueForProduct_io)

-- ── Notifications ──────────────────────────────────────────────────

isSlackEnabled :: (MonadFlow m) => m Bool
isSlackEnabled = getConfigBoolForProduct "slack_enabled" (Just "autopilot") False

isK8sEnabled :: (MonadFlow m) => m Bool
isK8sEnabled = getConfigBoolForProduct "k8s_enabled" (Just "autopilot") True

isWatcherEnabled :: (MonadFlow m) => m Bool
isWatcherEnabled = getConfigBoolForProduct "watcher_enabled" (Just "autopilot") True

isApproveAllReleases :: (MonadFlow m) => m Bool
isApproveAllReleases = getConfigBoolForProduct "approve_all_releases" (Just "autopilot") False

isScaleDownPodsOnCompletion :: (MonadFlow m) => m Bool
isScaleDownPodsOnCompletion = getConfigBoolForProduct "scale_down_pods_on_completion" (Just "autopilot") True

isGcltEnabled :: (MonadFlow m) => m Bool
isGcltEnabled = getConfigBoolForProduct "global_changelog_tracker_enabled" (Just "autopilot") False

isPromQueryCheckEnabled :: (MonadFlow m) => m Bool
isPromQueryCheckEnabled = getConfigBoolForProduct "prom_query_check_enabled" (Just "autopilot") False

isSyncClusterEnabled :: (MonadFlow m) => m Bool
isSyncClusterEnabled = getConfigBoolForProduct "sync_cluster_enabled" (Just "autopilot") False

isMultiReleasePerProduct :: (MonadFlow m) => m Bool
isMultiReleasePerProduct = getConfigBoolForProduct "multi_release_per_product" (Just "autopilot") False

{- | Check if autopilot is under maintenance.
Reads "ap_under_maintenance" from server_config. The value is a JSON object
like {"owner":"someone","ap_under_maintenance":false}. Returns True if the
"ap_under_maintenance" field is true.
-}
isUnderMaintenance :: (MonadFlow m) => m Bool
isUnderMaintenance = withDb $ \db -> do
    v <- getEnabledServerConfigValueForProduct_io db "ap_under_maintenance" (Just "autopilot")
    pure $ case v of
        Nothing -> False
        Just raw ->
            case eitherDecode (LBS.fromStrict (TE.encodeUtf8 raw)) :: Either String Value of
                Right (Object obj) ->
                    case KM.lookup (K.fromText "ap_under_maintenance") obj of
                        Just (Bool b) -> b
                        _ -> False
                -- If it's not JSON, treat as a simple boolean string
                _ -> T.toLower (T.strip raw) `elem` ["true", "1", "yes"]

getReleaseWatchDelay :: (MonadFlow m) => m Int
getReleaseWatchDelay = getConfigIntForProduct "release_watch_delay" (Just "autopilot") 20

getReleaseStartDelay :: (MonadFlow m) => m Int
getReleaseStartDelay = getConfigIntForProduct "release_start_delay" (Just "autopilot") 2

getCollectMetricsDelay :: (MonadFlow m) => m Int
getCollectMetricsDelay = getConfigIntForProduct "collect_metrics_delay" (Just "autopilot") 60

getPodsCreationDelay :: (MonadFlow m) => m Int
getPodsCreationDelay = getConfigIntForProduct "pods_creation_delay" (Just "autopilot") 60

getPodsScaleDownDelayFromConfig :: (MonadFlow m) => m Double
getPodsScaleDownDelayFromConfig = getConfigDoubleForProduct "pods_scale_down_delay_config" (Just "autopilot") 0.0

getPodsCalculationFactor :: (MonadFlow m) => m Double
getPodsCalculationFactor = getConfigDoubleForProduct "pods_calculation_factor" (Just "autopilot") 1.2

getHpaMinMaxFactor :: (MonadFlow m) => m Double
getHpaMinMaxFactor = getConfigDoubleForProduct "hpa_min_max_ratio" (Just "autopilot") 1.0

getMaxJobCompletionHours :: (MonadFlow m) => m Int
getMaxJobCompletionHours = getConfigIntForProduct "max_job_completion_hours" (Just "autopilot") 3

getRevertCooloff :: (MonadFlow m) => m Int
getRevertCooloff = getConfigIntForProduct "revert_cooloff" (Just "autopilot") 1

getLockExpiryDelayMinutes :: (MonadFlow m) => m Int
getLockExpiryDelayMinutes = getConfigIntForProduct "lock_expiry_delay_minutes" (Just "autopilot") 15

getMaxK8sRetries :: (MonadFlow m) => m Int
getMaxK8sRetries = getConfigIntForProduct "max_k8s_retries" (Just "autopilot") 3

{- | Check whether HPA scaling is enabled for the given product.

Reads the "scaling_with_hpa_enabled" server_config value. The stored value
may be:
  * A JSON array string: @["FOO","BAR"]@
  * A comma-separated list: @FOO,BAR@

Tries JSON decode first; falls back to the comma-splitter on parse failure.
-}
isHpaEnabledForProduct :: (MonadFlow m) => Text -> m Bool
isHpaEnabledForProduct productName = withDb $ \db -> do
    dbConfig <- getEnabledServerConfigValueForProduct_io db "scaling_with_hpa_enabled" (Just "autopilot")
    let dbProducts = case dbConfig of
            Nothing -> []
            Just val -> parseProductList val
    pure $ T.toUpper productName `elem` map T.toUpper (filter (not . T.null) dbProducts)
  where
    parseProductList :: Text -> [Text]
    parseProductList val =
        case eitherDecode (LBS.fromStrict (TE.encodeUtf8 val)) :: Either String [Text] of
            Right xs -> map T.strip xs
            Left _ -> map T.strip (T.splitOn "," val)

getHpaTemplate :: (MonadFlow m) => m (Maybe Text)
getHpaTemplate = withDb $ \db -> getEnabledServerConfigValueForProduct_io db "hpa_template" (Just "autopilot")

-- ── Snapshot ───────────────────────────────────────────────────────

{- | Snapshot of all runtime config values, fetched in a single batch via
'loadRuntimeConfigSnapshot'. Purely additive: existing per-value functions
still hit the DB on every call. Callers that want to avoid repeated lookups
within a single workflow step can opt in to the snapshot.

Note: 'isHpaEnabledForProduct' is not included since it's parameterised on
the product name; call it directly. 'isUnderMaintenance' is also omitted
(it's checked at request entry rather than per workflow step).
-}
data RuntimeConfigSnapshot = RuntimeConfigSnapshot
    { rcsSlackEnabled :: Bool
    , rcsK8sEnabled :: Bool
    , rcsWatcherEnabled :: Bool
    , rcsApproveAllReleases :: Bool
    , rcsScaleDownPodsOnCompletion :: Bool
    , rcsGcltEnabled :: Bool
    , rcsPromQueryCheckEnabled :: Bool
    , rcsSyncClusterEnabled :: Bool
    , rcsMultiReleasePerProduct :: Bool
    , rcsReleaseWatchDelay :: Int
    , rcsReleaseStartDelay :: Int
    , rcsCollectMetricsDelay :: Int
    , rcsPodsCreationDelay :: Int
    , rcsPodsScaleDownDelayFromConfig :: Double
    , rcsPodsCalculationFactor :: Double
    , rcsHpaMinMaxFactor :: Double
    , rcsMaxJobCompletionHours :: Int
    , rcsRevertCooloff :: Int
    , rcsLockExpiryDelayMinutes :: Int
    , rcsMaxK8sRetries :: Int
    , rcsHpaTemplate :: Maybe Text
    }

loadRuntimeConfigSnapshot :: (MonadFlow m) => m RuntimeConfigSnapshot
loadRuntimeConfigSnapshot =
    RuntimeConfigSnapshot
        <$> isSlackEnabled
        <*> isK8sEnabled
        <*> isWatcherEnabled
        <*> isApproveAllReleases
        <*> isScaleDownPodsOnCompletion
        <*> isGcltEnabled
        <*> isPromQueryCheckEnabled
        <*> isSyncClusterEnabled
        <*> isMultiReleasePerProduct
        <*> getReleaseWatchDelay
        <*> getReleaseStartDelay
        <*> getCollectMetricsDelay
        <*> getPodsCreationDelay
        <*> getPodsScaleDownDelayFromConfig
        <*> getPodsCalculationFactor
        <*> getHpaMinMaxFactor
        <*> getMaxJobCompletionHours
        <*> getRevertCooloff
        <*> getLockExpiryDelayMinutes
        <*> getMaxK8sRetries
        <*> getHpaTemplate
