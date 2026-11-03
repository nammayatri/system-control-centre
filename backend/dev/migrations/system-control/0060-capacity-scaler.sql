-- 0060: Capacity scaler — scheduled capacity for Memorystore for Valkey (cluster: shards, standalone:
-- replicas) and AlloyDB read pools (nodes), plus an editor for the autoscaler config that drives them.
--
-- Targets are registered from the console in two tables, redis_config and db_config (not in
-- deployment_config). Schedules, the apply ledger, events and guardrails are shared and carry
-- (target_kind, target_id). Mirrors the HPA scheduler (0055): everything is scoped by `cloud`, an apply is
-- claimed with a lease, and the unique indexes make a second in-flight apply for the same target, or a
-- second apply of the same schedule window, impossible. Loop leader election reuses hpa_loop_lease.

CREATE TABLE IF NOT EXISTS redis_config (
  id                  TEXT PRIMARY KEY,
  cloud               TEXT NOT NULL,
  name                TEXT NOT NULL,
  project             TEXT NOT NULL,
  location            TEXT NOT NULL,
  instance            TEXT NOT NULL,                  -- Memorystore for Valkey instance id
  autoscaler_job      TEXT,                           -- Cloud Scheduler job that feeds the autoscaler (optional)
  autoscaler_location TEXT,                           -- defaults to `location`
  created_by          TEXT NOT NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at          TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_redis_config_instance
  ON redis_config (cloud, project, location, instance) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS db_config (
  id                  TEXT PRIMARY KEY,
  cloud               TEXT NOT NULL,
  name                TEXT NOT NULL,
  project             TEXT NOT NULL,
  location            TEXT NOT NULL,
  cluster             TEXT NOT NULL,                  -- AlloyDB cluster id
  read_pool           TEXT NOT NULL,                  -- AlloyDB read-pool instance id
  autoscaler_job      TEXT,
  autoscaler_location TEXT,
  created_by          TEXT NOT NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at          TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_db_config_pool
  ON db_config (cloud, project, location, cluster, read_pool) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS scaler_schedule (
  id           TEXT PRIMARY KEY,
  cloud        TEXT NOT NULL,
  target_kind  TEXT NOT NULL,                         -- REDIS | DB
  target_id    TEXT NOT NULL,
  name         TEXT NOT NULL,
  status       TEXT NOT NULL DEFAULT 'ACTIVE',        -- ACTIVE | PAUSED | EXPIRED
  timing       JSONB NOT NULL,                        -- ScheduleKind (ONCE | WEEKLY), shared with the HPA scheduler
  change       JSONB NOT NULL,                        -- ScaleChange
  created_by   TEXT NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_eval_at TIMESTAMPTZ,
  deleted_at   TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_scaler_schedule_target
  ON scaler_schedule (cloud, target_kind, target_id) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS scaler_apply (
  id               TEXT PRIMARY KEY,
  cloud            TEXT NOT NULL,
  schedule_id      TEXT,                                -- NULL for a manual apply
  trigger_kind     TEXT NOT NULL,                       -- SCHEDULED | MANUAL
  target_kind      TEXT NOT NULL,
  target_id        TEXT NOT NULL,
  status           TEXT NOT NULL,
  step             TEXT,
  change           JSONB NOT NULL,
  before_spec      JSONB,                               -- ScaleSnapshot, written once before the first change
  before_raw       JSONB,                               -- the autoscaler job as it was, written once
  after_spec       JSONB,                               -- what we intended / wrote / the operation we started
  window_start     TIMESTAMPTZ,
  window_end       TIMESTAMPTZ,                         -- NULL = hold until restored by hand
  attempt          INT NOT NULL DEFAULT 0,
  defer_count      INT NOT NULL DEFAULT 0,
  claimed_by       TEXT,
  lease_expires_at TIMESTAMPTZ,
  next_run_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  observe_until    TIMESTAMPTZ,
  rollback_reason  TEXT,
  error            TEXT,
  created_by       TEXT NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at      TIMESTAMPTZ
);

-- One in-flight apply per target. Keep the status list in sync with Hpa.Types.blockingStatusTexts.
CREATE UNIQUE INDEX IF NOT EXISTS uq_scaler_apply_inflight
  ON scaler_apply (cloud, target_kind, target_id)
  WHERE status NOT IN ('RESTORED', 'ROLLED_BACK', 'FAILED', 'SKIPPED');

-- A scheduled window is applied to a target at most once, even after a rollback.
CREATE UNIQUE INDEX IF NOT EXISTS uq_scaler_apply_window
  ON scaler_apply (schedule_id, target_kind, target_id, window_start)
  WHERE schedule_id IS NOT NULL AND window_start IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_scaler_apply_work
  ON scaler_apply (cloud, next_run_at)
  WHERE status IN ('PENDING', 'APPLYING', 'OBSERVING', 'APPLIED', 'RESTORING', 'ROLLING_BACK');
CREATE INDEX IF NOT EXISTS idx_scaler_apply_target
  ON scaler_apply (cloud, target_kind, target_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_scaler_apply_schedule ON scaler_apply (schedule_id);

CREATE TABLE IF NOT EXISTS scaler_event (
  id          BIGSERIAL PRIMARY KEY,
  cloud       TEXT NOT NULL,
  apply_id    TEXT,
  schedule_id TEXT,
  target_kind TEXT NOT NULL,
  target_id   TEXT NOT NULL,
  ts          TIMESTAMPTZ NOT NULL DEFAULT now(),
  kind        TEXT NOT NULL,
  message     TEXT NOT NULL,
  data        JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_scaler_event_apply ON scaler_event (apply_id, id);
CREATE INDEX IF NOT EXISTS idx_scaler_event_target ON scaler_event (cloud, target_kind, target_id, ts DESC);

CREATE TABLE IF NOT EXISTS scaler_guardrail (
  cloud       TEXT NOT NULL,
  target_kind TEXT NOT NULL,
  target_id   TEXT NOT NULL,
  data        JSONB NOT NULL,
  updated_by  TEXT NOT NULL,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (cloud, target_kind, target_id)
);

-- Every change made to an autoscaler's config from the console, with both entries, so it can be
-- reviewed and put back.
CREATE TABLE IF NOT EXISTS scaler_autoscaler_history (
  id          BIGSERIAL PRIMARY KEY,
  cloud       TEXT NOT NULL,
  target_kind TEXT NOT NULL,
  target_id   TEXT NOT NULL,
  ts          TIMESTAMPTZ NOT NULL DEFAULT now(),
  actor       TEXT NOT NULL,
  action      TEXT NOT NULL,                            -- EDIT | REVERT | PAUSE | RESUME
  note        TEXT,
  before      JSONB,                                    -- the target's config entry before
  after       JSONB                                     -- ... and after
);
CREATE INDEX IF NOT EXISTS idx_scaler_autoscaler_history ON scaler_autoscaler_history (cloud, target_kind, target_id, id DESC);
