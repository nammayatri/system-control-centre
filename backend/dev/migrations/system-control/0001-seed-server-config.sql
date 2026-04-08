-- Seed default server_config entries.
-- Idempotent: WHERE NOT EXISTS prevents re-insert; identity column auto-assigns id.

INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'max_k8s_retries', '3', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'max_k8s_retries');

INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'BOOL', 'multi_release_per_product', 'true', 1, 'autopilot'
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

-- Decision engine: per-(app-group, service) AB/HS gating. Empty map = nothing enabled.
-- Shape: {"APP_GROUP_NAME": ["ALL"] | ["service-a","service-b"]}
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'JSON', 'ab_hs_decision_enabled_app_groups', '{}', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ab_hs_decision_enabled_app_groups');

INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'JSON', 'ab_hs_post_monitoring_decision_enabled_app_groups', '{}', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ab_hs_post_monitoring_decision_enabled_app_groups');

-- Decision engine: API key sent as x-api-key header. Empty by default; operator must set.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'STRING', 'ab_hs_api_key', '', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ab_hs_api_key');

-- Decision engine toggles (all disabled by default; operator opts in).
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

-- HPA scaling: list of app groups with autoscaler enabled. Empty array = nothing
-- enabled. Format MUST be a JSON array of strings (e.g. '["TEST_AUTOPILOT","NY"]').
-- isHpaEnabledForProduct parses with eitherDecode first, falls back to comma-split.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'JSON', 'scaling_with_hpa_enabled', '[]', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'scaling_with_hpa_enabled');

-- Old-version pods scale-down delay (HOURS, fractional allowed). Used by the
-- runner's findCompletedTrackersForScaleDown gate (Julia parity:
-- pods_scale_down_delay_config). Default 0 = drain immediately on completion.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'DOUBLE', 'pods_scale_down_delay_config', '0', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'pods_scale_down_delay_config');

-- HPA template used by prepareK8sResources branch 3 when neither the new nor
-- the old version has an existing HPA. Placeholders substituted by
-- buildCreateHpaFromTemplateCommand:
--   {{DEPLOYMENT-NAME}}  → <serviceHost>-<version>
--   {{NAMESPACE}}        → product namespace
--   "minReplicas": 1     → replaced with computed min
--   "maxReplicas": 1     → replaced with computed max
-- The literal "1" must be present in the template for the substitution to fire.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'JSON', 'hpa_template',
'{
  "apiVersion": "autoscaling/v2",
  "kind": "HorizontalPodAutoscaler",
  "metadata": {
    "name": "{{DEPLOYMENT-NAME}}-hpa",
    "namespace": "{{NAMESPACE}}"
  },
  "spec": {
    "scaleTargetRef": {
      "apiVersion": "apps/v1",
      "kind": "Deployment",
      "name": "{{DEPLOYMENT-NAME}}"
    },
    "minReplicas": 1,
    "maxReplicas": 1,
    "metrics": [
      {
        "type": "Resource",
        "resource": {
          "name": "cpu",
          "target": {
            "type": "Utilization",
            "averageUtilization": 70
          }
        }
      }
    ]
  }
}', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'hpa_template');
