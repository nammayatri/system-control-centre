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

INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'pod_readiness_max_attempts', '30', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'pod_readiness_max_attempts');

INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'pod_readiness_poll_seconds', '10', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'pod_readiness_poll_seconds');

INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'pod_restart_count_threshold', '3', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'pod_restart_count_threshold');

INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'hpa_default_min_pods_config', '1', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'hpa_default_min_pods_config');

-- Decision engine: Julia parity. Default fail-CLOSED (HTTP errors abort).
-- Operators can flip this to 'false' for the lenient (fail-open) behavior.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'BOOL', 'decision_engine_fail_closed', 'true', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'decision_engine_fail_closed');

-- Decision engine: allowedTimeDiffInMins value sent in HS GET body. Julia default 60.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'ab_hs_allowed_time_diff_mins', '60', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ab_hs_allowed_time_diff_mins');

-- Decision engine: per-(product, service) AB/HS gating. Empty map = nothing enabled.
-- Shape: {"PRODUCT_NAME": ["ALL"] | ["service-a","service-b"]}
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'JSON', 'ab_hs_decision_enabled_products', '{}', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ab_hs_decision_enabled_products');

INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'JSON', 'ab_hs_post_monitoring_decision_enabled_products', '{}', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ab_hs_post_monitoring_decision_enabled_products');

-- Decision engine: API key sent as x-api-key header. Empty by default; operator must set.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'STRING', 'ab_hs_api_key', '', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ab_hs_api_key');
