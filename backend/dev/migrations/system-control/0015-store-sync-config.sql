-- 0015-store-sync-config.sql
-- Config flags for the periodic store-sync background job.

INSERT INTO server_config (name, type, value, enabled, product)
VALUES ('store_sync_enabled', 'bool', 'true', 1, 'autopilot')
ON CONFLICT DO NOTHING;

INSERT INTO server_config (name, type, value, enabled, product)
VALUES ('store_sync_interval_minutes', 'int', '5', 1, 'autopilot')
ON CONFLICT DO NOTHING;
