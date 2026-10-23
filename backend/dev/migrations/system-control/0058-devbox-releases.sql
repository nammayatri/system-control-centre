-- 0055: Devbox Releases — feature branches (backend + control-center, and
-- optionally the apps) built and run on a fleet dev-box for testing. SCC
-- creates a row, dispatches nammayatri's .github/workflows/devbox.yaml, and
-- follows the run: each DEVBOX_STAGE line becomes an event, DEVBOX_RESULT
-- fills in where it runs and its URLs.
--
-- Rules the database enforces itself:
--   * one active release per backend branch (stop the old one first);
--   * one active release per workspace name (its URL path and /tmp folder).
-- The per-person limit and the lifetime are server_config values below,
-- checked when a release is created and by the expiry sweep.

CREATE TABLE IF NOT EXISTS devbox_release (
  id              TEXT PRIMARY KEY,                       -- uuid
  workspace       TEXT NOT NULL,                          -- 'fare-fix' → /tmp/fare-fix, :8888/fare-fix
  status          TEXT NOT NULL DEFAULT 'QUEUED'
                  CHECK (status IN ('QUEUED','RUNNING','READY','FAILED','STOPPING','STOPPED')),
  stage           TEXT NOT NULL DEFAULT 'preparing'
                  CHECK (stage IN ('preparing','sync','build','start','data','cc','ready')),
  current_action  TEXT NOT NULL DEFAULT 'spawn'
                  CHECK (current_action IN ('spawn','stop')),

  -- What is being tested; commits are pinned when the release is created.
  backend_branch  TEXT NOT NULL,
  backend_sha     TEXT NOT NULL,
  cc_branch       TEXT,                                   -- NULL = no control centre
  cc_sha          TEXT,
  frontend_branch TEXT,                                   -- NULL = no app builds
  frontend_sha    TEXT,
  build_android   BOOLEAN NOT NULL DEFAULT false,
  build_ios       BOOLEAN NOT NULL DEFAULT false,

  -- Data loaded into the workspace.
  data_source     TEXT NOT NULL
                  CHECK (data_source IN ('master','prod','prod_international')),
  data_version    TEXT,                                   -- 'v14'; NULL = latest safe, filled once known

  -- Where it runs and how to reach it (from DEVBOX_RESULT).
  devbox_name     TEXT,                                   -- 'soya-chaap-MS-7E07'
  devbox_host     TEXT,                                   -- '192.168.10.107'
  devbox_user     TEXT,                                   -- SSH user; the stop run needs it
  backend_url     TEXT,                                   -- 'http://…:8888/fare-fix'
  cc_url          TEXT,                                   -- 'http://…:5301'

  -- GitHub run of the current action (the "View GitHub logs" button).
  gh_run_id       BIGINT,
  gh_run_url      TEXT,
  error           TEXT,                                   -- last failure, shown on the page

  -- Who and when.
  created_by      TEXT NOT NULL,                          -- SCC user email
  stopped_by      TEXT,                                   -- email, or 'system'
  stop_reason     TEXT CHECK (stop_reason IN ('user','expired','failed')),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  ready_at        TIMESTAMPTZ,
  expires_at      TIMESTAMPTZ NOT NULL,                   -- created_at + devbox_lifetime_days
  stopped_at      TIMESTAMPTZ
);

-- One active release per workspace name.
CREATE UNIQUE INDEX IF NOT EXISTS uq_devbox_release_active_workspace
  ON devbox_release (workspace)
  WHERE status IN ('QUEUED','RUNNING','READY','STOPPING');

-- One active release per backend branch: a second create is refused and the
-- page points at the running one.
CREATE UNIQUE INDEX IF NOT EXISTS uq_devbox_release_active_branch
  ON devbox_release (backend_branch)
  WHERE status IN ('QUEUED','RUNNING','READY','STOPPING');

-- Per-person limit check and "my releases".
CREATE INDEX IF NOT EXISTS idx_devbox_release_owner_active
  ON devbox_release (created_by)
  WHERE status IN ('QUEUED','RUNNING','READY','STOPPING');

-- The list's status filter, the poller and the expiry sweep.
CREATE INDEX IF NOT EXISTS idx_devbox_release_status
  ON devbox_release (status, expires_at);

CREATE INDEX IF NOT EXISTS idx_devbox_release_created
  ON devbox_release (created_at DESC);

-- Stage history: one row per DEVBOX_STAGE line (and per stop / expiry).
CREATE TABLE IF NOT EXISTS devbox_release_event (
  id          BIGSERIAL PRIMARY KEY,
  release_id  TEXT NOT NULL REFERENCES devbox_release(id) ON DELETE CASCADE,
  stage       TEXT NOT NULL,                              -- 'sync', 'build', 'stop', 'expiry', …
  label       TEXT NOT NULL
              CHECK (label IN ('started','done','skipped','failed','info')),
  payload     JSONB NOT NULL DEFAULT '{}'::jsonb,         -- ms, error, data version, actor
  gh_step_url TEXT,                                       -- link to that step's log
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_devbox_release_event_release
  ON devbox_release_event (release_id, created_at);

-- App builds (Android / iOS) started after the release is READY, only when a
-- frontend branch was picked. Each is its own ny-react-native workflow run.
CREATE TABLE IF NOT EXISTS devbox_release_build (
  id            BIGSERIAL PRIMARY KEY,
  release_id    TEXT NOT NULL REFERENCES devbox_release(id) ON DELETE CASCADE,
  platform      TEXT NOT NULL CHECK (platform IN ('android','ios')),
  status        TEXT NOT NULL DEFAULT 'QUEUED'
                CHECK (status IN ('QUEUED','RUNNING','DONE','FAILED','CANCELLED')),
  gh_run_id     BIGINT,
  gh_run_url    TEXT,
  download_url  TEXT,                                     -- Firebase link (android) / TestFlight link (ios)
  build_number  TEXT,
  error         TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (release_id, platform)
);

-- System roles (permission sets come from the DevboxPermission ADT in code):
-- Viewer sees, Manager creates and stops anyone's, Admin everything.
INSERT INTO sc_role (product_slug, name, description, is_system_role) VALUES
  ('devbox', 'Admin',   'Full access to Devbox Releases', true),
  ('devbox', 'Manager', 'Create devbox releases and stop any of them', true),
  ('devbox', 'Viewer',  'Read-only access to Devbox Releases', true)
ON CONFLICT (product_slug, name) DO NOTHING;

-- Superadmins get Admin on the new product.
INSERT INTO sc_person_product_access (person_id, product_slug, role_id)
SELECT p.id, 'devbox', r.id
FROM sc_person p, sc_role r
WHERE p.is_superadmin AND r.product_slug = 'devbox' AND r.name = 'Admin'
ON CONFLICT DO NOTHING;

-- Limits, editable without a deploy.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'devbox_max_active_per_user', '2', 1, 'devbox'
WHERE NOT EXISTS (SELECT 1 FROM server_config
                  WHERE name = 'devbox_max_active_per_user' AND product = 'devbox');

INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'INT', 'devbox_lifetime_days', '3', 1, 'devbox'
WHERE NOT EXISTS (SELECT 1 FROM server_config
                  WHERE name = 'devbox_lifetime_days' AND product = 'devbox');

ANALYZE;
