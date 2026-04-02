-- Add missing server_config entries (previously only in env vars)

INSERT INTO server_config (id, type, name, value, enabled)
SELECT COALESCE(MAX(id), 0) + 1, 'INT', 'max_k8s_retries', '3', 1
FROM server_config
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'max_k8s_retries');

INSERT INTO server_config (id, type, name, value, enabled)
SELECT COALESCE(MAX(id), 0) + 1, 'BOOL', 'multi_release_per_product', 'false', 1
FROM server_config
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'multi_release_per_product');

INSERT INTO server_config (id, type, name, value, enabled)
SELECT COALESCE(MAX(id), 0) + 1, 'INT', 'hpa_max_replicas_buffer', '1', 1
FROM server_config
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'hpa_max_replicas_buffer');
