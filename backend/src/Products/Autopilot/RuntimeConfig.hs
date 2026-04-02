{-# LANGUAGE OverloadedStrings #-}

-- | Autopilot-specific runtime configs read from server_config DB table.
module Products.Autopilot.RuntimeConfig
    ( -- Feature flags
      isK8sEnabled
    , isWatcherEnabled
    , isApproveAllReleases
    , isScaleDownPodsOnCompletion
    , isGcltEnabled
    , isPromQueryCheckEnabled
    , isSyncClusterEnabled
    , isMultiReleasePerProduct
    , isUnderMaintenance
      -- Delays / numeric
    , getReleaseWatchDelay
    , getReleaseStartDelay
    , getCollectMetricsDelay
    , getPodsCreationDelay
    , getPodsScaleDownDelayFromConfig
    , getPodsCalculationFactor
    , getHpaMinMaxFactor
    , getMaxJobCompletionHours
    , getRevertCooloff
    , getLockExpiryDelayMinutes
    , getMaxK8sRetries
      -- HPA
    , isHpaEnabledForProduct
    , getHpaTemplate
      -- Re-export global flags for convenience
    , isSlackEnabled
    , isMailingEnabled
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
import Shared.Config.Runtime
    ( getConfigBool
    , getConfigDouble
    , getConfigInt
    , isMailingEnabled
    , isSlackEnabled
    )
import Shared.Queries.ServerConfig (getEnabledServerConfigValue)

-- ── Feature flags ──────────────────────────────────────────────────

isK8sEnabled :: DBEnv -> IO Bool
isK8sEnabled db = getConfigBool db "k8s_enabled" True

isWatcherEnabled :: DBEnv -> IO Bool
isWatcherEnabled db = getConfigBool db "watcher_enabled" True

isApproveAllReleases :: DBEnv -> IO Bool
isApproveAllReleases db = getConfigBool db "approve_all_releases" False

isScaleDownPodsOnCompletion :: DBEnv -> IO Bool
isScaleDownPodsOnCompletion db = getConfigBool db "scale_down_pods_on_completion" True

isGcltEnabled :: DBEnv -> IO Bool
isGcltEnabled db = getConfigBool db "global_changelog_tracker_enabled" False

isPromQueryCheckEnabled :: DBEnv -> IO Bool
isPromQueryCheckEnabled db = getConfigBool db "prom_query_check_enabled" False

isSyncClusterEnabled :: DBEnv -> IO Bool
isSyncClusterEnabled db = getConfigBool db "sync_cluster_enabled" False

isMultiReleasePerProduct :: DBEnv -> IO Bool
isMultiReleasePerProduct db = getConfigBool db "multi_release_per_product" False

-- | Check if autopilot is under maintenance.
-- Reads "ap_under_maintenance" from server_config. The value is a JSON object
-- like {"owner":"someone","ap_under_maintenance":false}. Returns True if the
-- "ap_under_maintenance" field is true.
isUnderMaintenance :: DBEnv -> IO Bool
isUnderMaintenance db = do
    v <- getEnabledServerConfigValue db "ap_under_maintenance"
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
getReleaseWatchDelay db = getConfigInt db "release_watch_delay" 20

getReleaseStartDelay :: DBEnv -> IO Int
getReleaseStartDelay db = getConfigInt db "release_start_delay" 2

getCollectMetricsDelay :: DBEnv -> IO Int
getCollectMetricsDelay db = getConfigInt db "collect_metrics_delay" 60

getPodsCreationDelay :: DBEnv -> IO Int
getPodsCreationDelay db = getConfigInt db "pods_creation_delay" 60

getPodsScaleDownDelayFromConfig :: DBEnv -> IO Double
getPodsScaleDownDelayFromConfig db = getConfigDouble db "pods_scale_down_delay_config" 0.0

getPodsCalculationFactor :: DBEnv -> IO Double
getPodsCalculationFactor db = getConfigDouble db "pods_calculation_factor" 1.2

getHpaMinMaxFactor :: DBEnv -> IO Double
getHpaMinMaxFactor db = getConfigDouble db "hpa_min_max_ratio" 1.0

getMaxJobCompletionHours :: DBEnv -> IO Int
getMaxJobCompletionHours db = getConfigInt db "max_job_completion_hours" 3

getRevertCooloff :: DBEnv -> IO Int
getRevertCooloff db = getConfigInt db "revert_cooloff" 1

getLockExpiryDelayMinutes :: DBEnv -> IO Int
getLockExpiryDelayMinutes db = getConfigInt db "lock_expiry_delay_minutes" 15


getMaxK8sRetries :: DBEnv -> IO Int
getMaxK8sRetries db = getConfigInt db "max_k8s_retries" 3

-- ── HPA configs ────────────────────────────────────────────────────

isHpaEnabledForProduct :: DBEnv -> Text -> IO Bool
isHpaEnabledForProduct db productName = do
    dbConfig <- getEnabledServerConfigValue db "scaling_with_hpa_enabled"
    let dbProducts = case dbConfig of
            Just val -> map T.strip (T.splitOn "," (T.filter (\c -> c /= '[' && c /= ']' && c /= '"') val))
            Nothing -> []
    pure $ T.toUpper productName `elem` map T.toUpper (filter (not . T.null) dbProducts)

getHpaTemplate :: DBEnv -> IO (Maybe Text)
getHpaTemplate db = getEnabledServerConfigValue db "hpa_template"
