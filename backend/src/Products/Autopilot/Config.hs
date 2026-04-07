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
    ]
