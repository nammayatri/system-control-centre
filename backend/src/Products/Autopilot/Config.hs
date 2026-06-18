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
        "max_cleanup_retries"
        (IntConfig 5)
        ScalingGroup
        "Max retry attempts for scaling down leaked NEW deployments before marking as SCALE_DOWN_FAILED"
        (Just "autopilot")
    , ConfigEntry
        "max_vs_lock_wait_retries"
        (IntConfig 30)
        DeploymentGroup
        "Max retries waiting for VS editor lock to release before aborting a release workflow"
        (Just "autopilot")
    , ConfigEntry
        "vs_lock_wait_delay_seconds"
        (IntConfig 10)
        DeploymentGroup
        "Delay in seconds between VS editor lock wait retries"
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
    , -- Pod-count ratchet & HPA ratio: 1.0/1.0 defaults avoid per-release
      -- HPA min inflation when CPU-driven scale-down is idle.
      ConfigEntry
        "pods_calculation_factor"
        (DoubleConfig 1.0)
        ScalingGroup
        "Pod-count ratchet multiplier. 1.0 = match old version pods exactly. >1.0 adds headroom but inflates HPA min on every release in idle envs."
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
        "Trackers stuck in DISCARDING longer than this are flipped to DISCARDED by the runner sweep."
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
        "Suppress repeat decision-engine Slack messages with the same (decisionType, decision, reason) tuple within this window."
        (Just "autopilot")
    , -- Decision engine sample-volume floors: parseDecisionResponseWithVolume
      -- downgrades Abort → Wait when the engine's sample sizes are below these.
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
        "VS-edit trackers stuck in APPLIED longer than this are auto-flipped to COMPLETED by the runner sweep."
        (Just "autopilot")
    , ConfigEntry
        "max_job_completion_hours"
        (IntConfig 3)
        DeploymentGroup
        "BackendJob category: max wall-clock hours to wait for a Kubernetes Job to complete before aborting the release. Read by monitorJobStatus (polls = hours × 360)."
        (Just "autopilot")
    , -- Mobile (React Native) release flags.
      -- Note: mobile_build_type is intentionally NOT registered here. It's a
      -- per-environment invariant (master = debug, prod = release) set once via
      -- migration; exposing it as an editable runtime toggle would let someone
      -- break the env-lock guarantee. It's hidden from the config UI too.
      ConfigEntry
        "version_preview_enabled"
        (BoolConfig True)
        MobileGroup
        "Fetch next-version suggestions from Play Console / App Store Connect on the create-release form. Disable in debug-only envs."
        (Just "autopilot")
    , ConfigEntry
        "store_refresh_cooldown_seconds"
        (IntConfig 300)
        MobileGroup
        "Seconds the on-demand store refresh serves cache before re-polling a given app — the Play edit-quota guard, and the threshold the UI uses to auto-refresh on open + warn that data is stale. Keep above ~180s."
        (Just "autopilot")
    , ConfigEntry
        "mobile_dispatch_enabled"
        (BoolConfig False)
        MobileGroup
        "Master kill-switch for dispatching mobile release workflows to GitHub Actions. When off, releases can be drafted but not dispatched."
        (Just "autopilot")
    , ConfigEntry
        "mobile_tag_confirm_timeout_minutes"
        (IntConfig 60)
        MobileGroup
        "Minutes the ConfirmTag stage waits for the build's Git tag before failing the release (tag_timeout → ABORTED). Release builds only."
        (Just "autopilot")
    , -- Staged store rollout + review polling. All gated behind
      -- mobile_staged_rollout_enabled; when off, release builds keep
      -- auto-completing at tag-push (legacy behavior, no review hold).
      ConfigEntry
        "mobile_staged_rollout_enabled"
        (BoolConfig False)
        MobileGroup
        "Master switch for staged store rollout. When on, release builds hold at tag-push for an explicit promote-to-review action instead of auto-completing. Off keeps the legacy auto-complete behavior."
        (Just "autopilot")
    , ConfigEntry
        "review_poll_interval_sec"
        (IntConfig 1200)
        MobileGroup
        "How often the review-poll stage checks App Store Connect for the iOS review decision (seconds). Default 1200 = 20 min."
        (Just "autopilot")
    , ConfigEntry
        "review_poll_timeout_days"
        (IntConfig 7)
        MobileGroup
        "Days the review-poll stage waits for a store review decision before emitting a soft nudge. Does not abort the release."
        (Just "autopilot")
    , ConfigEntry
        "android_review_rollout_fraction"
        (DoubleConfig 0.000001)
        MobileGroup
        "Effectively-zero Play rollout fraction used when promoting to production for review, so approval exposes ~0 users until the operator rolls out. Must stay strictly in (0,1)."
        (Just "autopilot")
    , -- AI (Grid / LiteLLM). The SC_AI_API_KEY secret is NOT here — it lives in env.
      ConfigEntry
        "ai_enabled"
        (BoolConfig False)
        MobileGroup
        "Master switch for AI features (release changelog summary, risk assessment, Q&A). Off by default."
        (Just "autopilot")
    , ConfigEntry
        "ai_base_url"
        (TextConfig "https://grid.ai.juspay.net")
        MobileGroup
        "Grid (LiteLLM) gateway base URL. No trailing slash."
        (Just "autopilot")
    , ConfigEntry
        "ai_model"
        (TextConfig "claude-sonnet-4-6")
        MobileGroup
        "Model id — a Grid alias from GET /v1/models (e.g. claude-sonnet-4-6)."
        (Just "autopilot")
    , ConfigEntry
        "ai_allowed_host_suffix"
        (TextConfig "grid.ai.juspay.net")
        MobileGroup
        "SSRF allowlist: ai_base_url's host must end with this suffix."
        (Just "autopilot")
    , ConfigEntry
        "ai_temperature"
        (DoubleConfig 0.2)
        MobileGroup
        "Sampling temperature (low = more deterministic summaries)."
        (Just "autopilot")
    , ConfigEntry
        "ai_cache_ttl_hours"
        (IntConfig 168)
        MobileGroup
        "How long generated summaries are cached, in hours."
        (Just "autopilot")
    ]
