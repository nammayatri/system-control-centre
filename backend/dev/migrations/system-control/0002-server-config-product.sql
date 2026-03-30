ALTER TABLE server_config ADD COLUMN IF NOT EXISTS product TEXT;
-- NULL = global config, 'autopilot' = product-specific

-- Update existing configs to be autopilot-specific
UPDATE server_config SET product = 'autopilot' WHERE name IN (
  'k8s_enabled', 'approve_all_releases', 'sync_cluster_enabled',
  'sync_rollout_strategy_config', 'release_start_delay',
  'release_watch_delay', 'collect_metrics_delay',
  'scale_down_pods_on_completion', 'pods_scale_down_delay_config',
  'scaling_with_hpa_enabled', 'decision_engine_enabled',
  'AUTOSCALER_CONFIG_ENABLED', 'ap_under_maintenance',
  'global_changelog_tracker_enabled'
);

-- These are global
UPDATE server_config SET product = NULL WHERE name IN ('mailing_enabled');
