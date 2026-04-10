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

-- Max retry attempts for scaling down leaked NEW deployments. When a scale-down
-- fails (e.g., deployment not found in k8s), the runner retries up to this
-- limit before marking the cleanup as permanently FAILED. Each retry waits
-- for the next poll cycle (release_watch_delay). Default 5.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'max_cleanup_retries', '5', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'max_cleanup_retries');

-- Pod-count multiplier used by scaleNewDeploymentForStage. Julia parity:
-- pods_calculation_factor (service.jl:17). The strategy formula is
--   strategyByFactor = ceil(factor × oldDesired / 100 × routePercent).
-- Default 1.0 means "match old version pods exactly". Setting > 1.0 adds
-- headroom over the old pod count for traffic-shift safety. Safe to bump
-- (e.g. 1.2 for 20% headroom) because progressive rollout no longer
-- ratchets HPA bounds — it only scales the deployment directly, capped at
-- the live HPA's maxReplicas. Inflated values just size the transient
-- rollout bigger and settle back when the HPA reconciles.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'DOUBLE', 'pods_calculation_factor', '1.0', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'pods_calculation_factor');

-- HPA min/max ratio used ONLY when creating a new HPA from a template on a
-- first-ever release for a service (no prior HPA to clone from). Defines
--   hpaMax = max(hpaMin, ceil(hpaMin × ratio))
-- where hpaMin is the last rollout stage's podPct (the steady-state target).
-- Default 4.0 gives the template HPA real autoscaling headroom (max = 4× min).
-- On all subsequent releases the HPA is cloned verbatim from the prior version
-- — min/max/metrics/behavior are preserved from whatever the operator has
-- configured. Progressive rollout NEVER mutates HPA bounds; it only scales
-- the deployment and caps safeTarget at the live HPA's maxReplicas.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'DOUBLE', 'hpa_min_max_ratio', '4.0', 1, 'autopilot'
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
    "maxReplicas": 100,
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

-- AB/HS volume floor for the A side (control). Used by getHSDecision +
-- parseDecisionResponseWithVolume in DecisionEngine.hs to downgrade an
-- engine-reported Abort to Wait when total_a < this value (defensive
-- against rolling back on tiny samples). Julia parity:
-- DecisionThreshold.volume_thresholds[1] default 50.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'ab_hs_volume_min_a', '50', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ab_hs_volume_min_a');

-- AB/HS volume floor for the B side (variant). Same semantics as
-- ab_hs_volume_min_a. Julia default 100.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'ab_hs_volume_min_b', '100', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ab_hs_volume_min_b');

-- Auto-complete delay for VS-edit trackers stuck in APPLIED. Used by the
-- runner sweep step 7 (sweepAutoCompleteVsTrackers) to flip APPLIED →
-- COMPLETED after this many minutes. Julia parity:
-- release/watcher.jl:158-160 getAutoCompleteVSTrackerDelay. Default 60 min.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'auto_complete_vs_tracker_minutes', '60', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'auto_complete_vs_tracker_minutes');

-- BackendJob category poll cap (hours). Read by monitorJobStatus in
-- BackendJobWorkflow.hs to compute maxPolls = hours × 360 (10s poll interval).
-- Was hardcoded to 60 polls (10 min). Julia parity: max_job_completion_hours
-- in api/release/create.jl. Default 3 hours.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'max_job_completion_hours', '3', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'max_job_completion_hours');

-- ────────────────────────────────────────────────────────────────────────
-- Final batch: every config key that has a Haskell getter in
-- RuntimeConfig.hs but was missing from the seed before. Adding all of
-- them as idempotent inserts so a fresh DB init has the full surface
-- area visible/editable from the UI.
-- ────────────────────────────────────────────────────────────────────────

-- Maintenance mode flag. JSON object @{"owner":"someone","ap_under_maintenance":bool}@.
-- When true, /releases/create returns 400 "System is under maintenance" — used by
-- the runner check before accepting new releases. Read by isUnderMaintenance.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'JSON', 'ap_under_maintenance', '{"ap_under_maintenance":false}', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ap_under_maintenance');

-- When true, every newly-created release is auto-approved (is_approved set
-- at create time). For CI/CD pipelines without a human approver step.
-- Read by isApproveAllReleases. Default false.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'BOOL', 'approve_all_releases', 'false', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'approve_all_releases');

-- Julia's `ckh_cluster_name` global. Sent in the AB initiate placeholders
-- as the @cluster@ field — picks which ClickHouse cluster the engine
-- queries. Opaque string forwarded as-is.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'STRING', 'ckh_cluster_name', '', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ckh_cluster_name');

-- Post-monitoring AB initiate self-closing-time (seconds). Sent as
-- @self_closing_time@ in the post-monitoring AB initiate body so the
-- engine self-stops if SC crashes mid-monitoring. Julia parity. Default
-- 1800s = 30 min.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'de_post_monitoring_timeout', '1800', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'de_post_monitoring_timeout');

-- Master gate for posting events to the external GCLT (global changelog)
-- service. Off by default — the GCLT HTTP client is not yet implemented
-- in Haskell (CONTEXT.md "Conditional" list). Flipping this on without
-- the client is a no-op.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'BOOL', 'global_changelog_tracker_enabled', 'false', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'global_changelog_tracker_enabled');

-- Pods creation delay (seconds). Used between deployment apply and the
-- first pod-readiness poll to give the API server a moment to schedule
-- pods. Read by getPodsCreationDelay. Default 60.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'pods_creation_delay', '60', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'pods_creation_delay');

-- Newer name for the Prometheus query check master gate. Read first by
-- isPromQueryCheckEnabled with fallback to legacy `prom_checks_enabled`.
-- Default false.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'BOOL', 'prom_query_check_enabled', 'false', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'prom_query_check_enabled');

-- Delay (seconds) between runner picking a CREATED tracker and actually
-- starting the workflow. Used to absorb a brief race window where two
-- pollers might both pick the same tracker. Read by getReleaseStartDelay.
-- Default 2.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'release_start_delay', '2', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'release_start_delay');

-- Runner poll interval (seconds). Both runner.hs and SyncWatcher.hs poll
-- on this cadence. Lower = faster pickup but more DB load. Default 20.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'release_watch_delay', '20', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'release_watch_delay');

-- Revert cooloff (minutes). Minimum delay between an operator-initiated
-- revert and the next allowed forward release on the same service.
-- Prevents flapping. Read by getRevertCooloff. Default 1.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'revert_cooloff', '1', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'revert_cooloff');

-- When true, the runner schedules a scale-down of the OLD deployment
-- after a release reaches COMPLETED. False leaves the old deployment
-- running indefinitely (canary-style side-by-side). Read by
-- isScaleDownPodsOnCompletion. Default true.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'BOOL', 'scale_down_pods_on_completion', 'true', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'scale_down_pods_on_completion');

-- Master kill-switch for Slack notifications. When false, every notify*
-- helper short-circuits with no HTTP call. Set false in dev/test envs
-- without a Slack workspace. Default false.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'BOOL', 'slack_enabled', 'false', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'slack_enabled');

-- Cross-cloud sync master gate. When true, completed releases POST a sync
-- payload to the secondary cluster's @/releases/create@ endpoint via
-- Sync.hs. The receiver sets isFromSync=true to prevent loops. Off by
-- default. Read by isSyncClusterEnabled. Enable only in production
-- multi-cloud setups.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'BOOL', 'sync_cluster_enabled', 'false', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'sync_cluster_enabled');

-- Master kill-switch for the runner poll loop. When false, the runner
-- spawns but skips the iteration body so no new releases get picked.
-- Lets operators freeze new dispatches without restarting the backend.
-- Read by isWatcherEnabled. Default true.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'BOOL', 'watcher_enabled', 'true', 1, 'autopilot'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'watcher_enabled');


-- ────────────────────────────────────────────────────────────────────────
-- Production server_config seed (pulled from NammaAP cloud DB on 2026-04-08)
-- Source: kubectl exec autopilot-0 → MySQL → server_config table
-- 33 distinct keys, latest value per key (deduped on name)
-- Type column normalized: production uses 'CONFIG' for everything; we
-- map to typed values (BOOL/INT/JSON/STRING) so the Haskell
-- get*ForProduct getters parse correctly.
-- ────────────────────────────────────────────────────────────────────────

-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'JSON', 'admin_list', '["sidharth@nammayatri.in","piyush@nammayatri.in","ritika@nammayatri.in","ashish.saini@nammayatri.in","khuzema.khomosi@nammayatri.in","ratnadeep.b@nammayatri.in","chakradhar.k@nammayatri.in","soumyajit.behera@nammayatri.in","saimanohar.veeravajhula@nammayatri.in","rupak.korde@nammayatri.in","saurabh.s@nammayatri.in","akhilesh.bhadauriya@nammayatri.in","vijay.gupta@nammayatri.in","anuragini.paunikar@nammayatri.in","aayush.agarwal@nammayatri.in","aman.dwivedi@nammayatri.in","prashant.singh@nammayatri.in","rohit.dhaker@nammayatri.in","jaypal.m@nammayatri.in","yashika.kaushik@nammayatri.in","piyush.kumar@nammayatri.in","vinit.j@nammayatri.in","nikith@nammayatri.in","braj.mohan@nammayatri.in","arun.s@nammayatri.in","vignesh.s@nammayatri.in","banala.siva.ext@nammayatri.in","jatin.arora.ext@nammayatri.in","yashwanth.s@nammayatri.in"]', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'admin_list');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'JSON', 'ap_dev_list', '["nikith@nammayatri.in","sidharth@nammayatri.in","piyush@nammayatri.in","hemant.mangla@nammayatri.in", "rupak.korde@nammayatri.in","piyush.kumar@nammayatri.in","vijay.gupta@nammayatri.in","ratnadeep.b@nammayatri.in","yashwanth.s@nammayatri.in"]', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ap_dev_list');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'JSON', 'ap_under_maintenance', '{"owner":"shabeeb.m.ext","ap_under_maintenance":false}', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'ap_under_maintenance');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'BOOL', 'approve_all_releases', 'true', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'approve_all_releases');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'BOOL', 'AUTOSCALER_CONFIG_ENABLED', 'false', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'AUTOSCALER_CONFIG_ENABLED');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'STRING', 'beckn_uat_release_branch', 'sbx-release-20231109', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'beckn_uat_release_branch');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'INT', 'collect_metrics_delay', '60', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'collect_metrics_delay');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'JSON', 'custom_counter_info', '{"CUSTOM":{"max":2,"counter":2}}', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'custom_counter_info');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'JSON', 'custom_deployment_enabled', '{"BECKN_UAT":true}', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'custom_deployment_enabled');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'BOOL', 'decision_engine_enabled', 'false', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'decision_engine_enabled');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'BOOL', 'global_changelog_tracker_enabled', 'false', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'global_changelog_tracker_enabled');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'JSON', 'infra_admin_list', '["sidharth@nammayatri.in","piyush@nammayatri.in","ritika@nammayatri.in","ashish.saini@nammayatri.in","khuzema.khomosi@nammayatri.in","ratnadeep.b@nammayatri.in","chakradhar.k@nammayatri.in","soumyajit.behera@nammayatri.in","saimanohar.veeravajhula@nammayatri.in","rupak.korde@nammayatri.in","saurabh.s@nammayatri.in","akhilesh.bhadauriya@nammayatri.in","vijay.gupta@nammayatri.in","anuragini.paunikar@nammayatri.in","aayush.agarwal@nammayatri.in","aman.dwivedi@nammayatri.in","prashant.singh@nammayatri.in","rohit.dhaker@nammayatri.in","jaypal.m@nammayatri.in","vijay.gupta@nammayatri.in","piyush.kumar@nammayatri.in","vinit.j@nammayatri.in"."pranav.sathya@nammayatri.in","vignesh.s@nammayatri.in","banala.siva.ext@nammayatri.in","jatin.arora.ext@nammayatri.in","yashwanth.s@nammayatri.in"]', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'infra_admin_list');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'STRING', 'integ_cluster_release_branch', 'integ-release-20210616', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'integ_cluster_release_branch');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'BOOL', 'is_pomerium_sso', 'true', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'is_pomerium_sso');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'BOOL', 'is_rbac_enabled', 'true', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'is_rbac_enabled');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'BOOL', 'is_workflow_watcher_enabled', 'true', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'is_workflow_watcher_enabled');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'BOOL', 'k8s_enabled', 'true', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'k8s_enabled');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'BOOL', 'mailing_enabled', 'false', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'mailing_enabled');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'INT', 'mandatory_vs_edit_monitoring_minutes', '5', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'mandatory_vs_edit_monitoring_minutes');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'INT', 'pods_scale_down_delay_config', '0', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'pods_scale_down_delay_config');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'STRING', 'release_branch', 'integ-release-20200907', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'release_branch');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'STRING', 'release_jira_id', 'EUL-2534', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'release_jira_id');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'INT', 'release_schedule_delay', '0', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'release_schedule_delay');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'INT', 'release_start_delay', '0', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'release_start_delay');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'INT', 'release_watch_delay', '60', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'release_watch_delay');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'BOOL', 'scale_down_pods_on_completion', 'true', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'scale_down_pods_on_completion');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'JSON', 'scaling_with_hpa_enabled', '["BECKN","BECKN_DASHBOARD","BECKN_ADMIN_DASHBOARD"]', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'scaling_with_hpa_enabled');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'JSON', 'subscribed_event_categories', '[BUSINESS,NOTIFICATION]', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'subscribed_event_categories');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'JSON', 'subscribed_event_labels', '[STATUS_UPDATED,TRAFFIC_UPDATED]', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'subscribed_event_labels');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'BOOL', 'sync_cluster_enabled', 'true', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'sync_cluster_enabled');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'BOOL', 'sync_cluster_enabled_2', 'true', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'sync_cluster_enabled_2');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'JSON', 'sync_rollout_strategy_config', '{"EKS":{"percentage":50,"strategy":"SAME"},"TRINITY":{"percentage":50,"strategy":"DEFAULT"}}', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'sync_rollout_strategy_config');
-- INSERT INTO server_config (type, name, value, enabled, product) SELECT 'INT', 'worklfow_tracker_discard_interval_in_min', '60', 1, 'autopilot' WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'worklfow_tracker_discard_interval_in_min');
