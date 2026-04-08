{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.Config (autopilotConfigs) where

import Shared.Config.Types

autopilotConfigs :: [ConfigEntry]
autopilotConfigs =
    [ ConfigEntry
        "k8s_enabled"
        (BoolConfig True)
        DeploymentGroup
        "Enable Kubernetes operations"
        (Just "autopilot")
    , ConfigEntry
        "approve_all_releases"
        (BoolConfig False)
        DeploymentGroup
        "Auto-approve all new releases"
        (Just "autopilot")
    , ConfigEntry
        "ap_under_maintenance"
        (JsonConfig "{}")
        DeploymentGroup
        "Maintenance mode (JSON with owner and flag)"
        (Just "autopilot")
    , ConfigEntry
        "release_start_delay"
        (IntConfig 0)
        DeploymentGroup
        "Delay before starting release (seconds)"
        (Just "autopilot")
    , ConfigEntry
        "sync_cluster_enabled"
        (BoolConfig False)
        SyncGroup
        "Enable multi-cloud sync to secondary cluster"
        (Just "autopilot")
    , ConfigEntry
        "sync_rollout_strategy_config"
        (JsonConfig "{}")
        SyncGroup
        "Rollout strategy for sync cluster (JSON)"
        (Just "autopilot")
    , ConfigEntry
        "release_watch_delay"
        (IntConfig 20)
        MonitoringGroup
        "Runner poll interval in seconds"
        (Just "autopilot")
    , ConfigEntry
        "collect_metrics_delay"
        (IntConfig 60)
        MonitoringGroup
        "Metrics collection interval in seconds"
        (Just "autopilot")
    , ConfigEntry
        "decision_engine_enabled"
        (BoolConfig False)
        ABTestingGroup
        "Enable A/B testing decision engine"
        (Just "autopilot")
    , ConfigEntry
        "global_changelog_tracker_enabled"
        (BoolConfig False)
        MonitoringGroup
        "Enable global changelog tracking"
        (Just "autopilot")
    , ConfigEntry
        "scale_down_pods_on_completion"
        (BoolConfig True)
        ScalingGroup
        "Scale down old pods after release completes"
        (Just "autopilot")
    , ConfigEntry
        "pods_scale_down_delay_config"
        (DoubleConfig 0)
        ScalingGroup
        "Delay before scaling down old pods (hours)"
        (Just "autopilot")
    , ConfigEntry
        "scaling_with_hpa_enabled"
        (JsonConfig "[]")
        ScalingGroup
        "Products with HPA scaling enabled (JSON array)"
        (Just "autopilot")
    , ConfigEntry
        "hpa_max_replicas_buffer"
        (IntConfig 1)
        ScalingGroup
        "Buffer added to HPA max replicas calculation"
        (Just "autopilot")
    , ConfigEntry
        "hpa_template"
        (JsonConfig "{}")
        ScalingGroup
        "HPA template JSON for auto-creating HPAs on first release. Placeholders: {{DEPLOYMENT-NAME}}, {{NAMESPACE}}, literal \"minReplicas\": 1 / \"maxReplicas\": 1"
        (Just "autopilot")
    , ConfigEntry
        "max_k8s_retries"
        (IntConfig 3)
        DeploymentGroup
        "Maximum K8s command retry attempts"
        (Just "autopilot")
    , ConfigEntry
        "multi_release_per_product"
        (BoolConfig False)
        DeploymentGroup
        "Allow multiple concurrent releases per product"
        (Just "autopilot")
    , ConfigEntry
        "slack_enabled"
        (BoolConfig False)
        NotificationGroup
        "Enable Slack notifications for release events"
        (Just "autopilot")
    , -- Decision engine / AB / HS (grouped under ABTestingGroup)
      ConfigEntry
        "ab_decision_enabled"
        (BoolConfig False)
        ABTestingGroup
        "Enable AB decision engine for release gating"
        (Just "autopilot")
    , ConfigEntry
        "ab_hs_enabled"
        (BoolConfig False)
        ABTestingGroup
        "Enable Health Score (HS) decision engine"
        (Just "autopilot")
    , ConfigEntry
        "ab_hs_post_monitoring_enabled"
        (BoolConfig False)
        ABTestingGroup
        "Enable post-monitoring HS decision after 100% rollout"
        (Just "autopilot")
    , ConfigEntry
        "prom_checks_enabled"
        (BoolConfig False)
        ABTestingGroup
        "Enable Prometheus metric checks during rollout"
        (Just "autopilot")
    , ConfigEntry
        "decision_engine_fail_closed"
        (BoolConfig True)
        ABTestingGroup
        "Decision engine HTTP errors → Abort (fail closed) vs Continue (lenient)"
        (Just "autopilot")
    , ConfigEntry
        "ab_hs_allowed_time_diff_mins"
        (IntConfig 60)
        ABTestingGroup
        "allowedTimeDiffInMins value sent in HS GET body"
        (Just "autopilot")
    , ConfigEntry
        "ab_hs_api_key"
        (TextConfig "")
        ABTestingGroup
        "x-api-key header value sent to Julia HS engine"
        (Just "autopilot")
    , ConfigEntry
        "ab_hs_decision_enabled_app_groups"
        (JsonConfig "{}")
        ABTestingGroup
        "Per-(app_group, service) gating for HS decision (JSON map)"
        (Just "autopilot")
    , ConfigEntry
        "ab_hs_post_monitoring_decision_enabled_app_groups"
        (JsonConfig "{}")
        ABTestingGroup
        "Per-(app_group, service) gating for post-monitoring HS decision (JSON map)"
        (Just "autopilot")
    , -- Pod readiness (grouped under DeploymentGroup)
      ConfigEntry
        "pod_readiness_max_attempts"
        (IntConfig 30)
        DeploymentGroup
        "Pod readiness poll: max attempts before timeout"
        (Just "autopilot")
    , ConfigEntry
        "pod_readiness_poll_seconds"
        (IntConfig 10)
        DeploymentGroup
        "Pod readiness poll: seconds between attempts"
        (Just "autopilot")
    , ConfigEntry
        "pod_restart_count_threshold"
        (IntConfig 3)
        DeploymentGroup
        "Pod readiness: max container restart count before failing release"
        (Just "autopilot")
    , -- HPA default (grouped under ScalingGroup)
      ConfigEntry
        "hpa_default_min_pods_config"
        (IntConfig 1)
        ScalingGroup
        "HPA minReplicas default for first-release create-from-template branch"
        (Just "autopilot")
    , -- Pod-count ratchet & HPA min/max ratio (Julia parity tunables; both
      -- changed from historic 1.2 / 1.0 to safer 1.0 / 1.0 defaults to stop
      -- the per-release HPA min inflation when CPU-driven scale-down is idle).
      ConfigEntry
        "pods_calculation_factor"
        (DoubleConfig 1.0)
        ScalingGroup
        "Pod-count ratchet multiplier (Julia parity). 1.0 = match old version pods exactly. >1.0 adds headroom but inflates HPA min on every release in idle envs."
        (Just "autopilot")
    , ConfigEntry
        "hpa_min_max_ratio"
        (DoubleConfig 1.0)
        ScalingGroup
        "HPA max as ratio of computed safe target. 1.0 = fixed-replica HPA. Bump to 3.0+ for real autoscaling headroom."
        (Just "autopilot")
    , -- Stale-state sweep grace periods
      ConfigEntry
        "discarding_sweep_minutes"
        (IntConfig 5)
        DeploymentGroup
        "Trackers stuck in DISCARDING longer than this are flipped to DISCARDED by the runner sweep (Julia filterUsingScheduleTime! parity)."
        (Just "autopilot")
    , ConfigEntry
        "lock_expiry_delay_minutes"
        (IntConfig 30)
        DeploymentGroup
        "VS-edit lock auto-expiry: locks older than this are eligible for re-acquisition by tryAcquireVsLock."
        (Just "autopilot")
    , -- Decision-engine notification dedup
      ConfigEntry
        "decision_notification_dedup_minutes"
        (IntConfig 15)
        ABTestingGroup
        "Suppress repeat decision-engine Slack messages with the same (decisionType, decision, reason) tuple within this window. Julia ABHSSlackSpamFilter parity."
        (Just "autopilot")
    , -- Decision engine volume floors (Julia DecisionThreshold.volume_thresholds parity).
      -- Used by parseDecisionResponseWithVolume to downgrade Abort → Wait when
      -- the engine's reported sample sizes are below these floors.
      ConfigEntry
        "ab_hs_volume_min_a"
        (IntConfig 50)
        ABTestingGroup
        "Minimum samples on the A side (control) before honoring an engine Abort. Below this, downgrade to Wait."
        (Just "autopilot")
    , ConfigEntry
        "ab_hs_volume_min_b"
        (IntConfig 100)
        ABTestingGroup
        "Minimum samples on the B side (variant) before honoring an engine Abort. Below this, downgrade to Wait."
        (Just "autopilot")
    , -- Auto-complete VS tracker sweep
      ConfigEntry
        "auto_complete_vs_tracker_minutes"
        (IntConfig 60)
        DeploymentGroup
        "VS-edit trackers stuck in APPLIED longer than this are auto-flipped to COMPLETED by the runner sweep. Julia release/watcher.jl:158-160 parity."
        (Just "autopilot")
    ]
