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
    isABHSDecisionEnabledForAppGroupService,
    isABHSPostMonitoringDecisionEnabledForAppGroupService,
    getDecisionEngineFailClosed,
    getABHSApiKey,
    getABHSAllowedTimeDiffMins,
    isSyncClusterEnabled,
    isMultiReleasePerProduct,
    isStoreSyncEnabled,
    getStoreSyncIntervalMinutes,
    isVersionPreviewEnabled,
    getMobileBuildType,
    isUnderMaintenance,
    -- Delays / numeric (MonadFlow versions)
    getReleaseWatchDelay,
    getReleaseStartDelay,
    getCollectMetricsDelay,
    getPodsCreationDelay,
    getPodsScaleDownDelayFromConfig,
    getPodsCalculationFactor,
    getHpaMinMaxFactor,
    getHpaDefaultMinPods,
    getMaxJobCompletionHours,
    getRevertCooloff,
    getLockExpiryDelayMinutes,
    getDiscardingSweepMinutes,
    getABHSVolumeMinA,
    getABHSVolumeMinB,
    getAutoCompleteVsTrackerMinutes,
    getDecisionNotificationDedupMinutes,
    getMaxK8sRetries,
    getMaxCleanupRetries,
    getMaxVsLockWaitRetries,
    getVsLockWaitDelaySeconds,
    getCkhClusterName,
    getDEPostMonitoringTimeout,
    getPodReadinessMaxAttempts,
    getPodReadinessPollSeconds,
    getPodRestartCountThreshold,
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
    getConfigTextForProduct,
 )
import Shared.Queries.ServerConfig (getEnabledServerConfigValueForProduct_io)

-- ── Notifications ──────────────────────────────────────────────────

{- | Master kill-switch for Slack notifications. When False, every notify*
helper in Notifications.hs short-circuits with no HTTP call. Set False
in dev/test envs that don't have a Slack workspace configured. Read by
'whenSlackEnabled' wrapper at every notification entry point.
-}
isSlackEnabled :: (MonadFlow m) => m Bool
isSlackEnabled = getConfigBoolForProduct "slack_enabled" (Just "autopilot") False

{- | Master kill-switch for kubectl operations. When False, the workflow
skips deployment cloning, HPA ops, VS edits, scale calls, and pod
readiness polls (it walks the state machine but never touches k8s).
Used for unit-test runs and DB-only smoke checks. Default True.
-}
isK8sEnabled :: (MonadFlow m) => m Bool
isK8sEnabled = getConfigBoolForProduct "k8s_enabled" (Just "autopilot") True

{- | Master kill-switch for the runner poll loop. When False, the runner
still spawns but skips the iteration body, so no releases get picked.
Lets operators freeze new dispatches without restarting the backend
(e.g. while debugging a stuck workflow). Default True.
-}
isWatcherEnabled :: (MonadFlow m) => m Bool
isWatcherEnabled = getConfigBoolForProduct "watcher_enabled" (Just "autopilot") True

{- | When True, every newly-created release is auto-approved (is_approved
forced to True at create time). Used for automation scenarios where
releases come from CI/CD without a human approver. Default False
(operators must explicitly approve via /releases/:id/approve).
-}
isApproveAllReleases :: (MonadFlow m) => m Bool
isApproveAllReleases = getConfigBoolForProduct "approve_all_releases" (Just "autopilot") False

{- | When True, the runner schedules a scale-down of the OLD deployment
after a release reaches COMPLETED. False leaves the old deployment
running indefinitely (useful for canary-style releases where old and
new run side-by-side for an extended period). Default True.
-}
isScaleDownPodsOnCompletion :: (MonadFlow m) => m Bool
isScaleDownPodsOnCompletion = getConfigBoolForProduct "scale_down_pods_on_completion" (Just "autopilot") True

{- | When True, the workflow POSTs every release lifecycle event to the
external GCLT (global changelog) service. Off by default — the GCLT
HTTP client is not yet implemented in Haskell (CONTEXT.md "Conditional"
list). Flipping this on without the client is a no-op.
-}
isGcltEnabled :: (MonadFlow m) => m Bool
isGcltEnabled = getConfigBoolForProduct "global_changelog_tracker_enabled" (Just "autopilot") False

{- | Prometheus query check master gate. Reads Julia's
@prom_query_check_enabled@ key first; falls back to the older
@prom_checks_enabled@ key for backward compatibility with existing
deployments.
-}
isPromQueryCheckEnabled :: (MonadFlow m) => m Bool
isPromQueryCheckEnabled = do
    new <- getConfigBoolForProduct "prom_query_check_enabled" (Just "autopilot") False
    if new
        then pure True
        else getConfigBoolForProduct "prom_checks_enabled" (Just "autopilot") False

{- | Per-(app-group, service) gating for AB/HS decision consumption.
Reads @ab_hs_decision_enabled_app_groups@, expecting JSON shape:
@{"EULER": ["ALL"], "EULER_SCHEDULER": ["payment-svc","auth-svc"]}@.
Returns True iff @appGroupName@ is a key AND the array contains
either @"ALL"@ or @serviceName@. Case-sensitive.

Julia's equivalent is @isABHSDecisionEnabledForProduct@ in @configs.jl@,
where Julia's "product" is what we now call "app_group" (renamed in
migration 0007). The JSON wire format is identical.
-}
isABHSDecisionEnabledForAppGroupService :: (MonadFlow m) => Text -> Text -> m Bool
isABHSDecisionEnabledForAppGroupService =
    isAppGroupServiceEnabledFromKey "ab_hs_decision_enabled_app_groups"

{- | Per-(app-group, service) gating for post-monitoring AB/HS consumption.
Same shape as 'isABHSDecisionEnabledForAppGroupService', different key:
@ab_hs_post_monitoring_decision_enabled_app_groups@.
-}
isABHSPostMonitoringDecisionEnabledForAppGroupService :: (MonadFlow m) => Text -> Text -> m Bool
isABHSPostMonitoringDecisionEnabledForAppGroupService =
    isAppGroupServiceEnabledFromKey "ab_hs_post_monitoring_decision_enabled_app_groups"

isAppGroupServiceEnabledFromKey :: (MonadFlow m) => Text -> Text -> Text -> m Bool
isAppGroupServiceEnabledFromKey key appGroupName serviceName = withDb $ \db -> do
    mVal <- getEnabledServerConfigValueForProduct_io db key (Just "autopilot")
    pure $ case mVal of
        Nothing -> False
        Just raw ->
            case eitherDecode (LBS.fromStrict (TE.encodeUtf8 raw)) :: Either String Value of
                Right (Object obj) ->
                    case KM.lookup (K.fromText appGroupName) obj of
                        Just (Array arr) ->
                            let svcs =
                                    [ s | String s <- toListV arr
                                    ]
                             in "ALL" `elem` svcs || serviceName `elem` svcs
                        _ -> False
                _ -> False
  where
    toListV = foldr (:) []

-- | Treat decision-engine HTTP errors as ABORT (fail-closed) or CONTINUE. Default fail-closed.
getDecisionEngineFailClosed :: (MonadFlow m) => m Bool
getDecisionEngineFailClosed =
    getConfigBoolForProduct "decision_engine_fail_closed" (Just "autopilot") True

-- | API key sent as @x-api-key@ to the AB/HS engine. Empty string if unset.
getABHSApiKey :: (MonadFlow m) => m Text
getABHSApiKey = withDb $ \db -> do
    v <- getEnabledServerConfigValueForProduct_io db "ab_hs_api_key" (Just "autopilot")
    pure $ case v of
        Just t -> t
        Nothing -> ""

-- | Allowed time-diff (minutes) sent in HS decision request body. Default 60.
getABHSAllowedTimeDiffMins :: (MonadFlow m) => m Int
getABHSAllowedTimeDiffMins =
    getConfigIntForProduct "ab_hs_allowed_time_diff_mins" (Just "autopilot") 60

{- | Master gate for cross-cloud sync. When True, completed releases POST
to the secondary cluster's @/releases/create@ with @isFromSync=true@ to
prevent loops. Off unless running multi-cloud.
-}
isSyncClusterEnabled :: (MonadFlow m) => m Bool
isSyncClusterEnabled = getConfigBoolForProduct "sync_cluster_enabled" (Just "autopilot") False

{- | When True, allow multiple in-flight releases per (app_group, env)
provided they target DIFFERENT services. Same-service concurrency is
always blocked regardless.
-}
isMultiReleasePerProduct :: (MonadFlow m) => m Bool
isMultiReleasePerProduct = getConfigBoolForProduct "multi_release_per_product" (Just "autopilot") False

isStoreSyncEnabled :: (MonadFlow m) => m Bool
isStoreSyncEnabled = getConfigBoolForProduct "store_sync_enabled" (Just "autopilot") False

getStoreSyncIntervalMinutes :: (MonadFlow m) => m Int
getStoreSyncIntervalMinutes = getConfigIntForProduct "store_sync_interval_minutes" (Just "autopilot") 30

isVersionPreviewEnabled :: (MonadFlow m) => m Bool
isVersionPreviewEnabled = getConfigBoolForProduct "version_preview_enabled" (Just "autopilot") True

{- | Build type for this deployment: "debug" (master env → Firebase/TestFlight)
or "release" (production env → Google Play/App Store). One value per
environment; stamped onto each release at creation time.
-}
getMobileBuildType :: (MonadFlow m) => m Text
getMobileBuildType = getConfigTextForProduct "mobile_build_type" (Just "autopilot") "release"

-- | Reads @ap_under_maintenance@ from server_config ({"ap_under_maintenance":bool}).
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

{- | Max retry attempts for scaling down leaked NEW deployments. When a scale-down
fails (e.g., deployment not found in k8s), the runner retries up to this limit
before marking the cleanup as permanently FAILED. Default 5.
-}
getMaxCleanupRetries :: (MonadFlow m) => m Int
getMaxCleanupRetries = getConfigIntForProduct "max_cleanup_retries" (Just "autopilot") 5

getMaxVsLockWaitRetries :: (MonadFlow m) => m Int
getMaxVsLockWaitRetries = getConfigIntForProduct "max_vs_lock_wait_retries" (Just "autopilot") 30

getVsLockWaitDelaySeconds :: (MonadFlow m) => m Int
getVsLockWaitDelaySeconds = getConfigIntForProduct "vs_lock_wait_delay_seconds" (Just "autopilot") 10

{- | Default 1.0 = match old-version pod count exactly. Bumping above 1.0
combined with the per-stage HPA ratchet (max(live, computed)) causes
per-release pod inflation when the HPA never scales down (idle envs).
-}
getPodsCalculationFactor :: (MonadFlow m) => m Double
getPodsCalculationFactor = getConfigDoubleForProduct "pods_calculation_factor" (Just "autopilot") 1.0

getHpaMinMaxFactor :: (MonadFlow m) => m Double
getHpaMinMaxFactor = getConfigDoubleForProduct "hpa_min_max_ratio" (Just "autopilot") 1.0

getHpaDefaultMinPods :: (MonadFlow m) => m Int
getHpaDefaultMinPods = getConfigIntForProduct "hpa_default_min_pods_config" (Just "autopilot") 1

getMaxJobCompletionHours :: (MonadFlow m) => m Int
getMaxJobCompletionHours = getConfigIntForProduct "max_job_completion_hours" (Just "autopilot") 3

getRevertCooloff :: (MonadFlow m) => m Int
getRevertCooloff = getConfigIntForProduct "revert_cooloff" (Just "autopilot") 1

-- | Opaque ClickHouse cluster name forwarded to the AB engine initiate body.
getCkhClusterName :: (MonadFlow m) => m T.Text
getCkhClusterName = getConfigTextForProduct "ckh_cluster_name" (Just "autopilot") ""

{- | Sent as @self_closing_time@ in the post-monitoring AB initiate body
so the engine self-stops if SC crashes mid-monitoring. Default 1800s.
-}
getDEPostMonitoringTimeout :: (MonadFlow m) => m Int
getDEPostMonitoringTimeout = getConfigIntForProduct "de_post_monitoring_timeout" (Just "autopilot") 1800

getLockExpiryDelayMinutes :: (MonadFlow m) => m Int
getLockExpiryDelayMinutes = getConfigIntForProduct "lock_expiry_delay_minutes" (Just "autopilot") 15

{- | Stale-DISCARDING sweep grace period (minutes). Short window absorbs
in-flight kubectl calls before trackers are force-flipped to DISCARDED.
-}
getDiscardingSweepMinutes :: (MonadFlow m) => m Int
getDiscardingSweepMinutes = getConfigIntForProduct "discarding_sweep_minutes" (Just "autopilot") 5

{- | Sample-size floor for the A side. Abort verdicts are downgraded to
Wait when @total_a < this@ so we don't roll back on tiny samples.
-}
getABHSVolumeMinA :: (MonadFlow m) => m Int
getABHSVolumeMinA = getConfigIntForProduct "ab_hs_volume_min_a" (Just "autopilot") 50

-- | Same as 'getABHSVolumeMinA' but for the B (variant) side.
getABHSVolumeMinB :: (MonadFlow m) => m Int
getABHSVolumeMinB = getConfigIntForProduct "ab_hs_volume_min_b" (Just "autopilot") 100

{- | Minutes after which VS-edit trackers stuck in APPLIED are auto-flipped
to COMPLETED by the runner sweep.
-}
getAutoCompleteVsTrackerMinutes :: (MonadFlow m) => m Int
getAutoCompleteVsTrackerMinutes =
    getConfigIntForProduct "auto_complete_vs_tracker_minutes" (Just "autopilot") 60

{- | Dedup window (minutes) for decision-engine Slack notifications; a
repeat within the window is suppressed even if the tuple differs.
-}
getDecisionNotificationDedupMinutes :: (MonadFlow m) => m Int
getDecisionNotificationDedupMinutes =
    getConfigIntForProduct "decision_notification_dedup_minutes" (Just "autopilot") 15

getMaxK8sRetries :: (MonadFlow m) => m Int
getMaxK8sRetries = getConfigIntForProduct "max_k8s_retries" (Just "autopilot") 3

getPodReadinessMaxAttempts :: (MonadFlow m) => m Int
getPodReadinessMaxAttempts = getConfigIntForProduct "pod_readiness_max_attempts" (Just "autopilot") 30

getPodReadinessPollSeconds :: (MonadFlow m) => m Int
getPodReadinessPollSeconds = getConfigIntForProduct "pod_readiness_poll_seconds" (Just "autopilot") 10

getPodRestartCountThreshold :: (MonadFlow m) => m Int
getPodRestartCountThreshold = getConfigIntForProduct "pod_restart_count_threshold" (Just "autopilot") 3

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
    , rcsHpaDefaultMinPods :: Int
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
        <*> getHpaDefaultMinPods
        <*> getMaxJobCompletionHours
        <*> getRevertCooloff
        <*> getLockExpiryDelayMinutes
        <*> getMaxK8sRetries
        <*> getHpaTemplate
