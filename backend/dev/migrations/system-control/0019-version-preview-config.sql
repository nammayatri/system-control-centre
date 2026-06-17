-- 0019-version-preview-config.sql
-- Config flag for the version preview endpoint (Play Console / ASC lookups).
-- Default TRUE in code; set to 'false' in master (debug) environments.

INSERT INTO server_config (name, type, value, enabled, product)
VALUES ('version_preview_enabled', 'bool', 'false', 1, 'autopilot')
ON CONFLICT DO NOTHING;
