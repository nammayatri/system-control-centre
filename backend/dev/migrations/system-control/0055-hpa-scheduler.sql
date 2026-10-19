-- 0055: HPA scheduler — time-windowed HPA changes with snapshot, verify, auto-rollback.
--
-- Everything is scoped by `cloud` (the runner's cloud_provider): one DB serves several
-- clusters and each runner must only ever touch HPAs in its own.
--
-- hpa_apply is the durable ledger. Nothing lives in a thread: a worker claims a row with a
-- lease, heartbeats it, and writes `step` before/after each side effect, so if the worker (or
-- the whole pod) dies another one resumes from the row. `before_spec`/`before_raw` are written
-- once, before the first patch, and are what every restore/rollback is computed from.

CREATE TABLE IF NOT EXISTS hpa_schedule (
  id           TEXT PRIMARY KEY,
  cloud        TEXT NOT NULL,
  app_group    TEXT NOT NULL,
  service      TEXT NOT NULL,
  name         TEXT NOT NULL,
  status       TEXT NOT NULL DEFAULT 'ACTIVE',        -- ACTIVE | PAUSED | EXPIRED
  kind         JSONB NOT NULL,                         -- ScheduleKind (ONCE | WEEKLY)
  change       JSONB NOT NULL,                         -- HpaChange
  health_policy JSONB NOT NULL DEFAULT '{}'::jsonb,    -- HealthPolicy (missing keys = defaults)
  created_by   TEXT NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_eval_at TIMESTAMPTZ,
  deleted_at   TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_hpa_schedule_service
  ON hpa_schedule (cloud, app_group, service) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS hpa_apply (
  id               TEXT PRIMARY KEY,
  cloud            TEXT NOT NULL,
  schedule_id      TEXT,                                -- NULL for a manual apply
  trigger_kind     TEXT NOT NULL,                       -- SCHEDULED | MANUAL
  app_group        TEXT NOT NULL,
  service          TEXT NOT NULL,
  namespace        TEXT NOT NULL,
  hpa_name         TEXT NOT NULL,
  status           TEXT NOT NULL,
  step             TEXT,
  change           JSONB NOT NULL,
  health_policy    JSONB NOT NULL DEFAULT '{}'::jsonb,
  before_spec      JSONB,                               -- typed HpaSpec, written once
  before_raw       JSONB,                               -- full live object, written once
  after_spec       JSONB,
  window_start     TIMESTAMPTZ,
  window_end       TIMESTAMPTZ,                         -- NULL = hold until restored by hand
  attempt          INT NOT NULL DEFAULT 0,              -- claims that followed a dead worker
  defer_count      INT NOT NULL DEFAULT 0,              -- times postponed behind a release
  claimed_by       TEXT,
  lease_expires_at TIMESTAMPTZ,
  next_run_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  observe_until    TIMESTAMPTZ,
  unhealthy_since  TIMESTAMPTZ,
  rollback_reason  TEXT,
  error            TEXT,
  created_by       TEXT NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at      TIMESTAMPTZ
);

-- One in-flight apply per HPA. Keep the status list in sync with Hpa.Types.blockingStatusTexts.
CREATE UNIQUE INDEX IF NOT EXISTS uq_hpa_apply_inflight
  ON hpa_apply (cloud, namespace, hpa_name)
  WHERE status NOT IN ('RESTORED', 'ROLLED_BACK', 'FAILED', 'SKIPPED');

-- A scheduled window is applied to an HPA at most once, even after a rollback.
CREATE UNIQUE INDEX IF NOT EXISTS uq_hpa_apply_window
  ON hpa_apply (schedule_id, namespace, hpa_name, window_start)
  WHERE schedule_id IS NOT NULL AND window_start IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_hpa_apply_work
  ON hpa_apply (cloud, next_run_at)
  WHERE status IN ('PENDING', 'APPLYING', 'OBSERVING', 'APPLIED', 'RESTORING', 'ROLLING_BACK');
CREATE INDEX IF NOT EXISTS idx_hpa_apply_service
  ON hpa_apply (cloud, app_group, service, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_hpa_apply_schedule ON hpa_apply (schedule_id);

CREATE TABLE IF NOT EXISTS hpa_event (
  id          BIGSERIAL PRIMARY KEY,
  cloud       TEXT NOT NULL,
  apply_id    TEXT,
  schedule_id TEXT,
  app_group   TEXT NOT NULL,
  service     TEXT NOT NULL,
  ts          TIMESTAMPTZ NOT NULL DEFAULT now(),
  kind        TEXT NOT NULL,
  message     TEXT NOT NULL,
  data        JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_hpa_event_apply ON hpa_event (apply_id, id);
CREATE INDEX IF NOT EXISTS idx_hpa_event_service ON hpa_event (cloud, app_group, service, ts DESC);

-- Spec history. A row is written when an HPA's spec changes (by us or anyone else).
CREATE TABLE IF NOT EXISTS hpa_snapshot (
  id               BIGSERIAL PRIMARY KEY,
  cloud            TEXT NOT NULL,
  app_group        TEXT NOT NULL,
  service          TEXT NOT NULL,
  namespace        TEXT NOT NULL,
  hpa_name         TEXT NOT NULL,
  ts               TIMESTAMPTZ NOT NULL DEFAULT now(),
  spec             JSONB NOT NULL,
  spec_hash        TEXT NOT NULL,
  source           TEXT NOT NULL,                        -- OBSERVED | APPLY | RESTORE | ROLLBACK
  managed_by       TEXT,                                 -- schedule id annotation, if any
  apply_id         TEXT,
  resource_version TEXT
);
CREATE INDEX IF NOT EXISTS idx_hpa_snapshot_hpa ON hpa_snapshot (cloud, namespace, hpa_name, ts DESC);
CREATE INDEX IF NOT EXISTS idx_hpa_snapshot_service ON hpa_snapshot (cloud, app_group, service, ts DESC);

-- Replica / utilisation time series sampled by the observer (pruned after 7 days).
CREATE TABLE IF NOT EXISTS hpa_sample (
  cloud             TEXT NOT NULL,
  app_group         TEXT NOT NULL,
  service           TEXT NOT NULL,
  namespace         TEXT NOT NULL,
  hpa_name          TEXT NOT NULL,
  ts                TIMESTAMPTZ NOT NULL,
  min_replicas      INT NOT NULL,
  max_replicas      INT NOT NULL,
  current_replicas  INT NOT NULL,
  desired_replicas  INT NOT NULL,
  cpu_pct           DOUBLE PRECISION,
  memory_pct        DOUBLE PRECISION,
  metrics           JSONB,
  PRIMARY KEY (cloud, namespace, hpa_name, ts)
);
CREATE INDEX IF NOT EXISTS idx_hpa_sample_service ON hpa_sample (cloud, app_group, service, ts DESC);
CREATE INDEX IF NOT EXISTS idx_hpa_sample_ts ON hpa_sample (ts);

-- Kubernetes HPA events (SuccessfulRescale etc.), de-duplicated by event uid.
CREATE TABLE IF NOT EXISTS hpa_scale_event (
  uid        TEXT PRIMARY KEY,
  cloud      TEXT NOT NULL,
  app_group  TEXT NOT NULL,
  service    TEXT NOT NULL,
  namespace  TEXT NOT NULL,
  hpa_name   TEXT NOT NULL,
  type       TEXT,
  reason     TEXT NOT NULL,
  message    TEXT NOT NULL,
  new_size   INT,
  count      INT NOT NULL DEFAULT 1,
  first_ts   TIMESTAMPTZ NOT NULL,
  last_ts    TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_hpa_scale_event_service ON hpa_scale_event (cloud, app_group, service, last_ts DESC);

CREATE TABLE IF NOT EXISTS hpa_guardrail (
  cloud      TEXT NOT NULL,
  app_group  TEXT NOT NULL,
  service    TEXT NOT NULL,
  data       JSONB NOT NULL,
  updated_by TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (cloud, app_group, service)
);

-- Services the observer samples even when they have no schedule.
CREATE TABLE IF NOT EXISTS hpa_watch (
  cloud      TEXT NOT NULL,
  app_group  TEXT NOT NULL,
  service    TEXT NOT NULL,
  created_by TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (cloud, app_group, service)
);

-- Single-leader lease for the background loops (observer, schedule evaluator) so that
-- several pods do not all poll the cluster. A dead leader's lease simply expires.
CREATE TABLE IF NOT EXISTS hpa_loop_lease (
  name   TEXT NOT NULL,
  cloud  TEXT NOT NULL,
  holder TEXT NOT NULL,
  lease_until TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (name, cloud)
);
