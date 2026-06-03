-- 0022-drop-mobile-secret-rows.sql
--
-- Remove the mobile secrets from server_config. They are now read from the
-- process ENVIRONMENT (k8s Secret in prod; backend/dev/local-mobile-secrets.env
-- in dev) by Core.Secrets — never from the DB. Storing them in server_config
-- meant they were returned by GET /server-config and visible in the frontend;
-- moving them to env removes them from the DB, the config API, and the FE
-- entirely.
--
-- The Haskell loaders (loadGhCreds / loadPlayCreds / loadAscCreds) no longer
-- read these rows, so deleting them is pure cleanup — but ONLY run this once the
-- deployment has the SC_* env vars wired, otherwise mobile builds have no creds.

DELETE FROM server_config
WHERE product = 'autopilot'
  AND name IN (
    'github_app_id',
    'github_app_installation_id',
    'github_app_private_key',
    'play_console_service_account_json',
    'app_store_connect_issuer_id',
    'app_store_connect_key_id',
    'app_store_connect_private_key_p8'
  );

-- Also drop the dead `mobile_run_poll_seconds` row. It was seeded by the original
-- mobile commit but NEVER read by any backend code — the runner poll cadence comes
-- from `release_watch_delay` (RuntimeConfig.getReleaseWatchDelay), store sync from
-- `store_sync_interval_minutes`. Changing it did nothing. Safe to delete anytime
-- (unlike the secrets above, this has no env-wiring prerequisite).
DELETE FROM server_config
WHERE product = 'autopilot'
  AND name = 'mobile_run_poll_seconds';
