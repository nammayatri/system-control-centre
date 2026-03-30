-- Autopilot tables — release orchestration
-- These are the existing tables from ny-autopilot-haskel

CREATE TABLE IF NOT EXISTS release_tracker (
  id TEXT NOT NULL,
  status TEXT NOT NULL,
  description TEXT,
  new_version TEXT NOT NULL,
  old_version TEXT NOT NULL,
  product TEXT NOT NULL,
  service TEXT NOT NULL,
  mode TEXT,
  date_created TIMESTAMPTZ NOT NULL,
  last_updated TIMESTAMPTZ NOT NULL,
  start_time TIMESTAMPTZ,
  end_time TIMESTAMPTZ,
  release_manager TEXT NOT NULL,
  env TEXT NOT NULL,
  priority INTEGER NOT NULL,
  rollout_strategy TEXT,
  rollout_history TEXT,
  schedule_time TIMESTAMPTZ,
  release_tag TEXT NOT NULL,
  events TEXT,
  change_log TEXT,
  release_context TEXT,
  info TEXT,
  udf1 TEXT,
  udf2 TEXT,
  udf3 TEXT,
  is_approved BOOLEAN,
  is_infra_approved BOOLEAN,
  metadata TEXT,
  global_id TEXT,
  new_service BOOLEAN,
  is_art_recorder INTEGER,
  cronjob_suspend BOOLEAN,
  ab_hs_status TEXT,
  tracker_type TEXT,
  workflow_status TEXT,
  approved_by TEXT
);

CREATE TABLE IF NOT EXISTS product_config (
  id BIGINT NOT NULL,
  product TEXT NOT NULL,
  cluster TEXT NOT NULL,
  namespace TEXT NOT NULL,
  vs_name TEXT NOT NULL,
  repo_name TEXT NOT NULL,
  product_type TEXT NOT NULL,
  product_acronym TEXT NOT NULL,
  release_branch TEXT NOT NULL,
  sync_cluster TEXT,
  need_infra_approval BOOLEAN,
  need_infra_approval1 BOOLEAN,
  vs_locked_by TEXT,
  vs_lock_timestamp TIMESTAMPTZ,
  kube_context TEXT
);

CREATE TABLE IF NOT EXISTS release_config (
  id BIGINT NOT NULL,
  emails TEXT,
  rollout_strategy TEXT,
  decision_config TEXT,
  service TEXT NOT NULL,
  product TEXT NOT NULL,
  flags TEXT,
  slack_webhook_urls TEXT,
  service_acronym TEXT,
  service_host TEXT,
  service_type TEXT,
  bitbucket_path TEXT,
  microservice_type TEXT,
  revert_strategy TEXT,
  jira_webhook_url TEXT
);

CREATE TABLE IF NOT EXISTS release_events (
  re_id BIGINT NOT NULL,
  re_release_id TEXT NOT NULL,
  re_category TEXT NOT NULL,
  re_label TEXT NOT NULL,
  re_payload JSONB NOT NULL,
  re_created_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS server_config (
  id INTEGER NOT NULL,
  type TEXT NOT NULL,
  name TEXT NOT NULL,
  value TEXT NOT NULL,
  last_updated TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  enabled INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS configmap_tracker (
  id TEXT NOT NULL,
  service TEXT NOT NULL,
  status TEXT NOT NULL,
  description TEXT,
  env TEXT NOT NULL,
  cluster TEXT NOT NULL,
  product TEXT NOT NULL,
  date_created TIMESTAMPTZ NOT NULL,
  last_updated TIMESTAMPTZ NOT NULL,
  start_time TIMESTAMPTZ,
  end_time TIMESTAMPTZ,
  release_manager TEXT NOT NULL,
  is_approved BOOLEAN,
  events TEXT,
  release_tag TEXT,
  is_infra_approved BOOLEAN,
  config TEXT,
  commit TEXT,
  change_log TEXT,
  priority INTEGER DEFAULT 0,
  schedule_time TIMESTAMPTZ,
  name TEXT,
  file TEXT
);

CREATE TABLE IF NOT EXISTS workflow_tracker (
  id TEXT NOT NULL,
  product TEXT NOT NULL,
  service TEXT NOT NULL,
  workflow TEXT,
  schedule_time TIMESTAMPTZ,
  release_manager TEXT NOT NULL,
  tracker_type TEXT,
  tracker_context TEXT,
  workflow_context TEXT,
  events TEXT,
  status TEXT,
  approved_by TEXT,
  cluster TEXT NOT NULL,
  env TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  last_updated TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS app_bundle_release (
  id TEXT NOT NULL,
  app_name TEXT NOT NULL,
  platform TEXT NOT NULL,
  build_id TEXT NOT NULL,
  release_manager TEXT NOT NULL,
  status TEXT NOT NULL,
  rollout_strategy TEXT,
  release_context TEXT,
  events TEXT,
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS db_tracker (
  id TEXT NOT NULL,
  product TEXT NOT NULL,
  service TEXT NOT NULL,
  env TEXT NOT NULL,
  release_manager TEXT NOT NULL,
  status TEXT NOT NULL,
  release_tag TEXT,
  script_path TEXT,
  rollback_script_path TEXT,
  events TEXT,
  date_created TIMESTAMPTZ NOT NULL,
  last_updated TIMESTAMPTZ NOT NULL,
  is_approved BOOLEAN
);

CREATE TABLE IF NOT EXISTS global_tracker (
  id TEXT NOT NULL,
  tracker TEXT,
  status TEXT NOT NULL,
  is_approved BOOLEAN,
  sync_strategy TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ
);
