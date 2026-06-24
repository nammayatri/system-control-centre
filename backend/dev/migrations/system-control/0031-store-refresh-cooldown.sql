-- 0031-store-refresh-cooldown.sql
-- Store sync moved from a background poller to on-demand refresh. Drop the now-dead
-- poller flags and seed the single on-demand knob.
--
--   • store_sync_enabled / store_sync_interval_minutes — drove the background loop,
--     which no longer exists. Nothing reads them.
--   • store_refresh_cooldown_seconds — seconds the on-demand refresh serves cache
--     before re-polling an app (the Play edit-quota guard) AND the threshold the UI
--     uses to auto-refresh on open + warn that data is stale. Keep above ~180s.

DELETE FROM server_config
WHERE name IN ('store_sync_enabled', 'store_sync_interval_minutes')
  AND product = 'autopilot';

INSERT INTO server_config (name, type, value, enabled, product)
VALUES ('store_refresh_cooldown_seconds', 'int', '300', 1, 'autopilot')
ON CONFLICT DO NOTHING;
