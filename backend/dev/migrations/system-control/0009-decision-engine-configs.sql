-- Decision engine server_config entries (all disabled by default).
-- Idempotent: WHERE NOT EXISTS prevents re-insert; identity column auto-assigns id.

INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'DECISION', 'prom_checks_enabled', 'false', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'prom_checks_enabled');

INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'DECISION', 'ab_decision_enabled', 'false', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ab_decision_enabled');

INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'DECISION', 'ab_hs_enabled', 'false', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ab_hs_enabled');

INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'DECISION', 'ab_hs_post_monitoring_enabled', 'false', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ab_hs_post_monitoring_enabled');
