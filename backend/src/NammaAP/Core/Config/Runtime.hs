{-# LANGUAGE OverloadedStrings #-}

-- | Runtime configuration read from server_config DB table.
-- Matches ny-autopilot's configs.jl pattern: DB value takes precedence,
-- then env var fallback, then hardcoded default.
module NammaAP.Core.Config.Runtime
  ( -- Feature flags
    isK8sEnabled
  , isWatcherEnabled
  , isAbEnabled
  , isAbHsEnabled
  , isAbortOnAbFailure
  , isApproveAllReleases
  , isScaleDownPodsOnCompletion
  , isSlackEnabled
  , isMailingEnabled
  , isGcltEnabled
  , isPromQueryCheckEnabled
  , isSyncClusterEnabled

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
  , getAbRequestTimeoutSeconds
  , getDefaultRecordingTime

    -- HPA
  , isHpaEnabledForProduct
  , getHpaTemplate

    -- String configs
  , getAbHost
  , getAbHsHost
  , getAbTrackerCreatePath
  , getAbDeciderPathPrefix
  , getAbHsDecisionPathPrefix

    -- Product-level
  , isAbHsDecisionEnabledForProduct
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Text.Read (readMaybe)
import NammaAP.Shared.Queries.ServerConfig (getEnabledServerConfigValue)
import NammaAP.Core.Config (Config (..))
import NammaAP.Core.Environment (DBEnv)

-- ── Helpers ────────────────────────────────────────────────────────

getConfigBool :: DBEnv -> Text -> Bool -> IO Bool
getConfigBool db name fallback = do
  v <- getEnabledServerConfigValue db name
  pure $ case v of
    Just t  -> T.toLower (T.strip t) `elem` ["true", "1", "yes"]
    Nothing -> fallback

getConfigInt :: DBEnv -> Text -> Int -> IO Int
getConfigInt db name fallback = do
  v <- getEnabledServerConfigValue db name
  pure $ case v of
    Just t  -> fromMaybe fallback (readMaybe (T.unpack (T.strip t)))
    Nothing -> fallback

getConfigDouble :: DBEnv -> Text -> Double -> IO Double
getConfigDouble db name fallback = do
  v <- getEnabledServerConfigValue db name
  pure $ case v of
    Just t  -> fromMaybe fallback (readMaybe (T.unpack (T.strip t)))
    Nothing -> fallback

getConfigText :: DBEnv -> Text -> Text -> IO Text
getConfigText db name fallback = do
  v <- getEnabledServerConfigValue db name
  pure $ fromMaybe fallback v

getConfigTextMaybe :: DBEnv -> Text -> IO (Maybe Text)
getConfigTextMaybe db name = getEnabledServerConfigValue db name

-- ── Feature flags ──────────────────────────────────────────────────

isK8sEnabled :: DBEnv -> Config -> IO Bool
isK8sEnabled db _cfg = getConfigBool db "k8s_enabled" True

isWatcherEnabled :: DBEnv -> Config -> IO Bool
isWatcherEnabled db _cfg = getConfigBool db "watcher_enabled" True

isAbEnabled :: DBEnv -> Config -> IO Bool
isAbEnabled db cfg = getConfigBool db "ab_enabled" (abDecisionEnabled cfg)

isAbHsEnabled :: DBEnv -> Config -> IO Bool
isAbHsEnabled db cfg = getConfigBool db "ab_hs_enabled" (abHsDecisionEnabled cfg)

isAbortOnAbFailure :: DBEnv -> Config -> IO Bool
isAbortOnAbFailure db cfg = getConfigBool db "abort_on_ab_failure" (abAbortOnFailure cfg)

isApproveAllReleases :: DBEnv -> IO Bool
isApproveAllReleases db = getConfigBool db "approve_all_releases" False

isScaleDownPodsOnCompletion :: DBEnv -> IO Bool
isScaleDownPodsOnCompletion db = getConfigBool db "scale_down_pods_on_completion" True

isSlackEnabled :: DBEnv -> IO Bool
isSlackEnabled db = getConfigBool db "slack_enabled" False

isMailingEnabled :: DBEnv -> IO Bool
isMailingEnabled db = getConfigBool db "mailing_enabled" False

isGcltEnabled :: DBEnv -> IO Bool
isGcltEnabled db = getConfigBool db "global_changelog_tracker_enabled" False

isPromQueryCheckEnabled :: DBEnv -> IO Bool
isPromQueryCheckEnabled db = getConfigBool db "prom_query_check_enabled" False

isSyncClusterEnabled :: DBEnv -> IO Bool
isSyncClusterEnabled db = getConfigBool db "sync_cluster_enabled" False

-- ── Delays / numeric configs ───────────────────────────────────────

getReleaseWatchDelay :: DBEnv -> Config -> IO Int
getReleaseWatchDelay db cfg = getConfigInt db "release_watch_delay" (runnerPollSeconds cfg)

getReleaseStartDelay :: DBEnv -> IO Int
getReleaseStartDelay db = getConfigInt db "release_start_delay" 2

getCollectMetricsDelay :: DBEnv -> Config -> IO Int
getCollectMetricsDelay db cfg = getConfigInt db "collect_metrics_delay" (abCollectMetricsDelaySeconds cfg)

getPodsCreationDelay :: DBEnv -> IO Int
getPodsCreationDelay db = getConfigInt db "pods_creation_delay" 60

getPodsScaleDownDelayFromConfig :: DBEnv -> Config -> IO Double
getPodsScaleDownDelayFromConfig db cfg =
  getConfigDouble db "pods_scale_down_delay_config" (fromIntegral (oldDeploymentCleanupDelaySeconds cfg) / 60.0)

getPodsCalculationFactor :: DBEnv -> IO Double
getPodsCalculationFactor db = getConfigDouble db "pods_calculation_factor" 1.2

getHpaMinMaxFactor :: DBEnv -> Config -> IO Double
getHpaMinMaxFactor db cfg = getConfigDouble db "hpa_min_max_ratio" (fromIntegral (hpaMaxReplicasBuffer cfg))

getMaxJobCompletionHours :: DBEnv -> IO Int
getMaxJobCompletionHours db = getConfigInt db "max_job_completion_hours" 3

getRevertCooloff :: DBEnv -> IO Int
getRevertCooloff db = getConfigInt db "revert_cooloff" 1

getLockExpiryDelayMinutes :: DBEnv -> IO Int
getLockExpiryDelayMinutes db = getConfigInt db "lock_expiry_delay_minutes" 15

getAbRequestTimeoutSeconds :: DBEnv -> Config -> IO Int
getAbRequestTimeoutSeconds db cfg = getConfigInt db "ab_request_timeout" (abRequestTimeoutSeconds cfg)

getDefaultRecordingTime :: DBEnv -> IO Double
getDefaultRecordingTime db = getConfigDouble db "default_recording_time" 20.0

-- ── HPA configs ────────────────────────────────────────────────────

-- | Check if HPA scaling is enabled for a product.
-- Reads server_config 'scaling_with_hpa_enabled' (JSON array or CSV),
-- then falls back to NammaAP_SCALING_WITH_HPA_ENABLED env var.
isHpaEnabledForProduct :: DBEnv -> Config -> Text -> IO Bool
isHpaEnabledForProduct db cfg productName = do
  dbConfig <- getEnabledServerConfigValue db "scaling_with_hpa_enabled"
  let dbProducts = case dbConfig of
        Just val -> map T.strip (T.splitOn "," (T.filter (\c -> c /= '[' && c /= ']' && c /= '"') val))
        Nothing -> []
      envProducts = hpaEnabledProducts cfg
      allProducts = dbProducts <> envProducts
  pure $ T.toUpper productName `elem` map T.toUpper (filter (not . T.null) allProducts)

getHpaTemplate :: DBEnv -> IO (Maybe Text)
getHpaTemplate db = getEnabledServerConfigValue db "hpa_template"

-- ── AB / Decision engine string configs ────────────────────────────

getAbHost :: DBEnv -> Config -> IO (Maybe String)
getAbHost db cfg = do
  v <- getConfigTextMaybe db "ab_host"
  pure $ case v of
    Just t | not (T.null t) -> Just (T.unpack t)
    _ -> abHost cfg

getAbHsHost :: DBEnv -> Config -> IO (Maybe String)
getAbHsHost db cfg = do
  v <- getConfigTextMaybe db "ab_hs_host"
  pure $ case v of
    Just t | not (T.null t) -> Just (T.unpack t)
    _ -> abHsHost cfg

getAbTrackerCreatePath :: DBEnv -> Config -> IO String
getAbTrackerCreatePath db cfg = do
  v <- getConfigText db "ab_tracker_create_path" (T.pack (abTrackerCreatePath cfg))
  pure (T.unpack v)

getAbDeciderPathPrefix :: DBEnv -> Config -> IO String
getAbDeciderPathPrefix db cfg = do
  v <- getConfigText db "ab_decider_path_prefix" (T.pack (abDeciderPathPrefix cfg))
  pure (T.unpack v)

getAbHsDecisionPathPrefix :: DBEnv -> Config -> IO String
getAbHsDecisionPathPrefix db cfg = do
  v <- getConfigText db "ab_hs_decision_path_prefix" (T.pack (abHsDecisionPathPrefix cfg))
  pure (T.unpack v)

-- ── Product-level configs ──────────────────────────────────────────

-- | Check if AB HS decision is enabled for a specific product+service.
-- Reads from server_config 'ab_hs_decision_enabled_products' (JSON).
isAbHsDecisionEnabledForProduct :: DBEnv -> Config -> Text -> Text -> IO Bool
isAbHsDecisionEnabledForProduct db cfg productName _serviceName = do
  if not (abHsDecisionEnabled cfg)
    then pure False
    else do
      v <- getEnabledServerConfigValue db "ab_hs_decision_enabled_products"
      case v of
        Nothing -> pure False
        Just val ->
          let products = map T.strip (T.splitOn "," (T.filter (\c -> c /= '[' && c /= ']' && c /= '"') val))
          in pure $ T.toUpper productName `elem` map T.toUpper (filter (not . T.null) products)
