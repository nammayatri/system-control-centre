-- 0051: QA automation — trigger the private ny-qa-automation Postman/Newman
-- regression suites (NY/MSIL/YS) against a running test dashboard, either
-- automatically when a release reaches COMPLETED (mirrors how
-- release_webhook fires from the same point) or manually from a button on
-- the release page.
--
-- Two tables:
--   qa_automation_config — one row per (app_group, cloud_type): where to send
--     the trigger, which flows to run, and whether COMPLETED should fire it
--     automatically. `flows` is a JSON array of {directory} or
--     {directory, filename} — an entry with no filename means "run every
--     collection currently in that directory" (expanded on the dashboard
--     side, see qa_runner.py's _expand_collections).
--   qa_automation_run — one row per triggered run, keyed by the dashboard's
--     own run id. `detail` caches that dashboard's per-request failure
--     detail (JSON), refreshed on demand rather than on every poll.
--
-- Scoped and shaped like release_webhook (0050): TEXT-holding-JSON columns,
-- (app_group, cloud_type) as the config key.

CREATE TABLE IF NOT EXISTS qa_automation_config (
  id SERIAL PRIMARY KEY,
  app_group TEXT NOT NULL,
  cloud_type TEXT NOT NULL DEFAULT 'GCP',
  enabled BOOLEAN NOT NULL DEFAULT FALSE,
  on_success BOOLEAN NOT NULL DEFAULT TRUE,
  test_dashboard_url TEXT NOT NULL,
  webhook_token TEXT NOT NULL,
  flows TEXT NOT NULL,
  env_file TEXT NOT NULL DEFAULT 'Local.postman_environment.json',
  concurrency INTEGER NOT NULL DEFAULT 2,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One config per app group per cloud — the manual button and the
-- COMPLETED hook both look this up the same way.
CREATE UNIQUE INDEX IF NOT EXISTS uq_qa_automation_config
  ON qa_automation_config (app_group, cloud_type);

CREATE TABLE IF NOT EXISTS qa_automation_run (
  id SERIAL PRIMARY KEY,
  run_id TEXT NOT NULL,
  release_id TEXT NOT NULL,
  app_group TEXT NOT NULL,
  cloud_type TEXT NOT NULL DEFAULT 'GCP',
  release_version TEXT,
  status TEXT NOT NULL DEFAULT 'RUNNING',
  trigger_source TEXT NOT NULL,
  test_dashboard_url TEXT,
  passed INTEGER,
  failed INTEGER,
  detail TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The dashboard's run id is the join key for refreshing status/detail.
CREATE UNIQUE INDEX IF NOT EXISTS uq_qa_automation_run_run_id
  ON qa_automation_run (run_id);

-- The results tab's own lookup: every run for a release, newest first.
CREATE INDEX IF NOT EXISTS idx_qa_automation_run_release
  ON qa_automation_run (release_id, created_at DESC);

-- Exactly-once auto-dispatch guard, same pattern as
-- uq_release_event_webhook_dispatch (0050) — a release can be terminalized
-- from more than one place, and a duplicate QA run is wasted work, not a
-- harmless duplicate notification.
CREATE UNIQUE INDEX IF NOT EXISTS uq_release_event_qa_automation_dispatch
  ON release_events (re_release_id, re_label)
  WHERE re_label = 'QA_AUTOMATION_DISPATCHED';

ANALYZE;
