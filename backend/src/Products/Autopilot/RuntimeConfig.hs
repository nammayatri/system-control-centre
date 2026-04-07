{-# LANGUAGE OverloadedStrings #-}

-- | Autopilot-specific runtime configs read from server_config DB table.
module Products.Autopilot.RuntimeConfig (
    -- Feature flags
    isK8sEnabled,
    isWatcherEnabled,
    isApproveAllReleases,
    isScaleDownPodsOnCompletion,
    isGcltEnabled,
    isPromQueryCheckEnabled,
    isSyncClusterEnabled,
    isMultiReleasePerProduct,
    isUnderMaintenance,
    -- Delays / numeric
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
    -- HPA
    isHpaEnabledForProduct,
    getHpaTemplate,
    -- Notifications
    isSlackEnabled,
)
where

import Core.Environment (DBEnv)
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
import Shared.Queries.ServerConfig (getEnabledServerConfigValueForProduct)

-- ── Notifications ──────────────────────────────────────────────────

isSlackEnabled :: DBEnv -> IO Bool
isSlackEnabled db = getConfigBoolForProduct db "slack_enabled" (Just "autopilot") False

-- ── Feature flags ──────────────────────────────────────────────────

isK8sEnabled :: DBEnv -> IO Bool
isK8sEnabled db = getConfigBoolForProduct db "k8s_enabled" (Just "autopilot") True

isWatcherEnabled :: DBEnv -> IO Bool
isWatcherEnabled db = getConfigBoolForProduct db "watcher_enabled" (Just "autopilot") True

isApproveAllReleases :: DBEnv -> IO Bool
isApproveAllReleases db = getConfigBoolForProduct db "approve_all_releases" (Just "autopilot") False

isScaleDownPodsOnCompletion :: DBEnv -> IO Bool
isScaleDownPodsOnCompletion db = getConfigBoolForProduct db "scale_down_pods_on_completion" (Just "autopilot") True

isGcltEnabled :: DBEnv -> IO Bool
isGcltEnabled db = getConfigBoolForProduct db "global_changelog_tracker_enabled" (Just "autopilot") False

isPromQueryCheckEnabled :: DBEnv -> IO Bool
isPromQueryCheckEnabled db = getConfigBoolForProduct db "prom_query_check_enabled" (Just "autopilot") False

isSyncClusterEnabled :: DBEnv -> IO Bool
isSyncClusterEnabled db = getConfigBoolForProduct db "sync_cluster_enabled" (Just "autopilot") False

isMultiReleasePerProduct :: DBEnv -> IO Bool
isMultiReleasePerProduct db = getConfigBoolForProduct db "multi_release_per_product" (Just "autopilot") False

{- | Check if autopilot is under maintenance.
Reads "ap_under_maintenance" from server_config. The value is a JSON object
like {"owner":"someone","ap_under_maintenance":false}. Returns True if the
"ap_under_maintenance" field is true.
-}
isUnderMaintenance :: DBEnv -> IO Bool
isUnderMaintenance db = do
    v <- getEnabledServerConfigValueForProduct db "ap_under_maintenance" (Just "autopilot")
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

-- ── Delays / numeric configs ───────────────────────────────────────

getReleaseWatchDelay :: DBEnv -> IO Int
getReleaseWatchDelay db = getConfigIntForProduct db "release_watch_delay" (Just "autopilot") 20

getReleaseStartDelay :: DBEnv -> IO Int
getReleaseStartDelay db = getConfigIntForProduct db "release_start_delay" (Just "autopilot") 2

getCollectMetricsDelay :: DBEnv -> IO Int
getCollectMetricsDelay db = getConfigIntForProduct db "collect_metrics_delay" (Just "autopilot") 60

getPodsCreationDelay :: DBEnv -> IO Int
getPodsCreationDelay db = getConfigIntForProduct db "pods_creation_delay" (Just "autopilot") 60

getPodsScaleDownDelayFromConfig :: DBEnv -> IO Double
getPodsScaleDownDelayFromConfig db = getConfigDoubleForProduct db "pods_scale_down_delay_config" (Just "autopilot") 0.0

getPodsCalculationFactor :: DBEnv -> IO Double
getPodsCalculationFactor db = getConfigDoubleForProduct db "pods_calculation_factor" (Just "autopilot") 1.2

getHpaMinMaxFactor :: DBEnv -> IO Double
getHpaMinMaxFactor db = getConfigDoubleForProduct db "hpa_min_max_ratio" (Just "autopilot") 1.0

getMaxJobCompletionHours :: DBEnv -> IO Int
getMaxJobCompletionHours db = getConfigIntForProduct db "max_job_completion_hours" (Just "autopilot") 3

getRevertCooloff :: DBEnv -> IO Int
getRevertCooloff db = getConfigIntForProduct db "revert_cooloff" (Just "autopilot") 1

getLockExpiryDelayMinutes :: DBEnv -> IO Int
getLockExpiryDelayMinutes db = getConfigIntForProduct db "lock_expiry_delay_minutes" (Just "autopilot") 15

getMaxK8sRetries :: DBEnv -> IO Int
getMaxK8sRetries db = getConfigIntForProduct db "max_k8s_retries" (Just "autopilot") 3

-- ── HPA configs ────────────────────────────────────────────────────

isHpaEnabledForProduct :: DBEnv -> Text -> IO Bool
isHpaEnabledForProduct db productName = do
    dbConfig <- getEnabledServerConfigValueForProduct db "scaling_with_hpa_enabled" (Just "autopilot")
    let dbProducts = case dbConfig of
            Just val -> map T.strip (T.splitOn "," (T.filter (\c -> c /= '[' && c /= ']' && c /= '"') val))
            Nothing -> []
    pure $ T.toUpper productName `elem` map T.toUpper (filter (not . T.null) dbProducts)

getHpaTemplate :: DBEnv -> IO (Maybe Text)
getHpaTemplate db = getEnabledServerConfigValueForProduct db "hpa_template" (Just "autopilot")
