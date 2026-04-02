-- Decision engine server_config entries (all disabled by default)

INSERT INTO server_config (id, type, name, value, enabled)
SELECT COALESCE(MAX(id), 0) + 1, 'DECISION', 'prom_checks_enabled', 'false', 1
FROM server_config
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'prom_checks_enabled');

INSERT INTO server_config (id, type, name, value, enabled)
SELECT COALESCE(MAX(id), 0) + 1, 'DECISION', 'ab_decision_enabled', 'false', 1
FROM server_config
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ab_decision_enabled');

INSERT INTO server_config (id, type, name, value, enabled)
SELECT COALESCE(MAX(id), 0) + 1, 'DECISION', 'ab_hs_enabled', 'false', 1
FROM server_config
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ab_hs_enabled');

INSERT INTO server_config (id, type, name, value, enabled)
SELECT COALESCE(MAX(id), 0) + 1, 'DECISION', 'ab_hs_post_monitoring_enabled', 'false', 1
FROM server_config
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ab_hs_post_monitoring_enabled');
