-- Seed default server_config entries.
-- Idempotent: WHERE NOT EXISTS prevents re-insert; identity column auto-assigns id.

INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'max_k8s_retries', '3', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'max_k8s_retries');

INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'BOOL', 'multi_release_per_product', 'false', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'multi_release_per_product');

INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'hpa_max_replicas_buffer', '1', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'hpa_max_replicas_buffer');
