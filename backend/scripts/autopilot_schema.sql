-- Autopilot tables -- release orchestration
-- All tracker tables have been merged into release_tracker with a 'category' column.

CREATE TABLE IF NOT EXISTS release_tracker (
  id TEXT NOT NULL PRIMARY KEY,
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
  category TEXT DEFAULT 'BackendService',
  release_wf_status TEXT DEFAULT 'Init',
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
