-- Seed default server_config entries.
-- Idempotent: WHERE NOT EXISTS prevents re-insert; identity column auto-assigns id.
--
-- ─── How this file is used ─────────────────────────────────────────────
-- Every entry below maps 1:1 to a getter in
-- `src/Products/Autopilot/RuntimeConfig.hs`. The Haskell side reads each
-- value at runtime via `getConfig{Bool,Int,Double,Text}ForProduct`. If a
-- key is missing the getter falls back to a hard-coded default; this seed
-- exists to make those defaults visible/editable in the DB.
--
-- Comments below describe WHERE the value is consumed in the Haskell code
-- and what production effect changing it has. Match the comment in
-- RuntimeConfig.hs for each getter.
-- ────────────────────────────────────────────────────────────────────────

-- Maximum kubectl retry attempts on transient errors. Used by
-- `executeWithRetry` in K8s/Execute.hs around every kubectl shell call.
-- Default 3. Increase only if your cluster has very flaky API server.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'max_k8s_retries', '3', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'max_k8s_retries');

-- When true, multiple in-flight releases per (app_group, env) are allowed
-- as long as they target DIFFERENT services. When false, only ONE release
-- per app_group can run at a time. Same-service concurrency is ALWAYS
-- blocked. Read by `pickJobs` / `isEligibleToRun` in Runner.hs.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'BOOL', 'multi_release_per_product', 'true', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'multi_release_per_product');

-- Reserved buffer added to HPA maxReplicas during clone/patch. Currently
-- read by `getHpaMaxReplicasBuffer` but not actively branched on; left
-- here for parity with Julia's `hpa_max_replicas_buffer`.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'hpa_max_replicas_buffer', '1', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'hpa_max_replicas_buffer');

-- Pod readiness poll cap: maximum poll attempts before `waitForPodsReady`
-- gives up and aborts the rollout with a "pods never ready" error. Default
-- 30 attempts × `pod_readiness_poll_seconds` (10s) = 5 min total cap.
-- Bump for slow-startup JVM services. Read by waitForPodsReady in
-- BackendServiceWorkflow.hs.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'pod_readiness_max_attempts', '30', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'pod_readiness_max_attempts');

-- Pod readiness poll interval (seconds). Tied to pod_readiness_max_attempts
-- for the total wait cap. Default 10s.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'pod_readiness_poll_seconds', '10', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'pod_readiness_poll_seconds');

-- Pod restart-count threshold for fast-fail. Used by checkPodHealthDetailed
-- to abort a release if any pod's container restartCount exceeds this
-- value (signal of CrashLoopBackOff). Default 3.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'pod_restart_count_threshold', '3', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'pod_restart_count_threshold');

-- Default minReplicas for HPA created from template (branch 3 of
-- prepareK8sResources). Used as the floor when neither old nor new HPA
-- exist AND `rolloutStrategy[0].pods` is unavailable. Default 1.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'hpa_default_min_pods_config', '1', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'hpa_default_min_pods_config');

-- Decision engine: when HTTP errors occur (5xx, timeout, unreachable),
-- treat as Abort (fail-closed = true, Julia parity) or Continue
-- (fail-open = false, lenient). Read by `failOrContinue` in
-- DecisionEngine.hs. Default true (conservative).
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'BOOL', 'decision_engine_fail_closed', 'true', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'decision_engine_fail_closed');

-- Decision engine: `allowedTimeDiffInMins` sent in the HS GET body. Tells
-- the engine to ignore metric data older than this many minutes (i.e.
-- only score on fresh data from the rollout window). Julia default 60.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'ab_hs_allowed_time_diff_mins', '60', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ab_hs_allowed_time_diff_mins');

-- Decision engine: per-(app_group, service) AB/HS gating for in-flight
-- rollout decisions. Empty map = no service has decision-engine reads on.
-- Shape: {"APP_GROUP_NAME": ["ALL"] | ["service-a","service-b"]}.
-- Used by isABHSDecisionEnabledForAppGroupService in RuntimeConfig.hs to
-- decide whether to call getHSDecision during cooloff polls.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'JSON', 'ab_hs_decision_enabled_app_groups', '{}', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ab_hs_decision_enabled_app_groups');

-- Decision engine: per-(app_group, service) gating for POST-monitoring
-- (after rollout reaches 100%). Same shape as above. Post-monitoring is
-- alert-only — Abort here does NOT auto-rollback (intentional divergence
-- from Julia, see notifyDecisionThreadMessage call in postMonitorLoop).
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'JSON', 'ab_hs_post_monitoring_decision_enabled_app_groups', '{}', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ab_hs_post_monitoring_decision_enabled_app_groups');

-- Decision engine: API key sent as `x-api-key` header on every AB initiate
-- POST and HS GET request. Empty by default — operator must set this
-- before flipping decision_engine on or all calls will 401.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'STRING', 'ab_hs_api_key', '', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ab_hs_api_key');

-- Master gate for Prometheus query checks during rollout cooloffs. When
-- true, the workflow runs `prometheusCheck` on every cooloff iteration in
-- AUTO mode and aborts on threshold breach. Read by isPromQueryCheckEnabled.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'DECISION', 'prom_checks_enabled', 'false', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'prom_checks_enabled');

-- Master gate for AB initiate. When true, prepareK8sResources fires
-- initiateABDecisionForRelease ONCE per release (Julia parity). Off by
-- default. Requires AB_ENGINE_URL env var set to a reachable host.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'DECISION', 'ab_decision_enabled', 'false', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ab_decision_enabled');

-- Master gate for HS GET decision reads during rollout cooloffs. When
-- true, getHSDecision is called every cooloff iteration. Off by default.
-- Requires AB_HS_URL env var set + ab_hs_api_key configured.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'DECISION', 'ab_hs_enabled', 'false', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ab_hs_enabled');

-- Master gate for POST-monitoring HS reads (after 100% reached). Off by
-- default. Even when on, post-monitor Abort is alert-only (no rollback).
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'DECISION', 'ab_hs_post_monitoring_enabled', 'false', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ab_hs_post_monitoring_enabled');

-- HPA scaling enable list: JSON array of app group names that get HPA
-- ops applied (clone/patch/create from template). Empty array means HPA
-- is OFF for everything. Read by isHpaEnabledForProduct, gates the
-- entire HPA section in prepareK8sResources. Format MUST be JSON array
-- of strings: '["TEST_AUTOPILOT","NY"]'. Falls back to comma-split if
-- JSON parse fails (legacy compatibility).
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'JSON', 'scaling_with_hpa_enabled', '[]', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'scaling_with_hpa_enabled');

-- Old-version pods scale-down delay (HOURS, fractional allowed). Used by the
-- runner's findCompletedTrackersForScaleDown gate (Julia parity:
-- pods_scale_down_delay_config). Default 0 = drain immediately on completion.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'DOUBLE', 'pods_scale_down_delay_config', '0', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'pods_scale_down_delay_config');

-- Pod-count ratchet multiplier used by scaleNewDeploymentForStage. Julia parity:
-- pods_calculation_factor (service.jl:17). The strategy formula is
--   strategyByFactor = ceil(factor × oldDesired / 100 × routePercent).
-- Default 1.0 means "match old version pods exactly". Setting > 1.0 adds
-- headroom over the old pod count for traffic-shift safety, but BEWARE: with
-- the HPA ratchet (max(live, computed)), each release inflates pods by
-- (factor − 1.0). e.g. factor=1.2 + identical 100% rollouts will grow the HPA
-- min by ~20% per release. In production this self-heals because the HPA
-- scales replicas down between releases under real CPU load; in test envs
-- with idle pods, leave at 1.0 to avoid runaway growth.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'DOUBLE', 'pods_calculation_factor', '1.0', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'pods_calculation_factor');

-- HPA min/max ratio used by scaleNewDeploymentForStage. Julia parity:
-- hpa_min_max_factor (service.jl:17). Defines the HPA max as
--   hpaMax = max(hpaMin, ceil(safeTarget × ratio)).
-- Default 1.0 = fixed-replica HPA (max == min). Operators should bump to 3.0+
-- for real autoscaling headroom. Kept at 1.0 by default to match the
-- conservative ratchet semantics.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'DOUBLE', 'hpa_min_max_ratio', '1.0', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'hpa_min_max_ratio');

-- Workflow loop sleep between cooloff polls (seconds). Julia parity:
-- collect_metrics_delay. Default 10s.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'collect_metrics_delay', '10', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'collect_metrics_delay');

-- Stale-DISCARDING tracker sweep threshold (minutes). Trackers stuck in
-- DISCARDING longer than this are flipped to DISCARDED on the next runner
-- poll. Julia parity: filterUsingScheduleTime! discards instantly. We use a
-- short grace period to absorb in-flight kubectl calls. Default 5 minutes.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'discarding_sweep_minutes', '5', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'discarding_sweep_minutes');

-- VS-edit lock auto-expiry (minutes). Julia parity: lock_expiry_delay_minutes.
-- Locks older than this are eligible for re-acquisition by tryAcquireVsLock.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'lock_expiry_delay_minutes', '30', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'lock_expiry_delay_minutes');

-- Decision-engine notification dedup window (minutes). Used by
-- notifyDecisionThreadMessage to suppress repeat Slack messages with the
-- same (decisionType, decision, reason) tuple. Julia parity:
-- repeat_interval in ABHSSlackSpamFilter (release/workflow/service.jl:793-824).
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'decision_notification_dedup_minutes', '15', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'decision_notification_dedup_minutes');

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
