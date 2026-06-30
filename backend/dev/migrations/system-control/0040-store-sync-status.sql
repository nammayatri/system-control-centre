-- 0040-store-sync-status.sql
-- Per-app last store-refresh outcome, so the monitor can surface a clear status
-- (fresh / errored + reason) for EVERY enabled app — not just silently-stale cells.
-- One row per app_catalog entry (app_catalog_id is 1:1 with platform).

CREATE TABLE IF NOT EXISTS store_sync_status (
  app_catalog_id  INT PRIMARY KEY REFERENCES app_catalog(id) ON DELETE CASCADE,
  last_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),  -- when the sweep last tried
  last_ok_at      TIMESTAMPTZ,                          -- last successful read (= cell freshness)
  last_error      TEXT,                                 -- message when the last attempt failed
  error_code      TEXT                                  -- machine code: no_creds | not_found | rate_limited | asc_unauthorized | api_error
);
