-- 0057: release bundles + grouped release runs.
--
-- A bundle is a reusable, ordered recipe: stages run one after another, and a
-- stage's steps (appGroup/service) run in PARALLEL or SEQUENTIAL. `definition`
-- is the JSON list of stages, so reshaping a bundle never needs a migration.
--
-- A run is one execution of a bundle. Every step gets a normal release_tracker
-- row up front (CREATED, unapproved). One group approval records the approver;
-- the coordinator then approves each step's tracker only when its stage is up,
-- so the existing runner executes them with no changes. Step outcome is read
-- live from the tracker status — only the WAITING/STARTED/SKIPPED bookkeeping
-- is stored here.

CREATE TABLE IF NOT EXISTS release_bundle (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  description TEXT NOT NULL DEFAULT '',
  definition TEXT NOT NULL,
  archived BOOLEAN NOT NULL DEFAULT FALSE,
  created_by TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS release_group_run (
  id TEXT PRIMARY KEY,
  bundle_id TEXT NOT NULL,
  bundle_name TEXT NOT NULL,
  env TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL,
  halt_reason TEXT NOT NULL DEFAULT '',
  created_by TEXT NOT NULL,
  approved_by TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_release_group_run_active
  ON release_group_run (state)
  WHERE state IN ('PENDING_APPROVAL', 'RUNNING', 'HALTED');

CREATE TABLE IF NOT EXISTS release_group_step (
  run_id TEXT NOT NULL REFERENCES release_group_run (id) ON DELETE CASCADE,
  stage_idx INT NOT NULL,
  step_idx INT NOT NULL,
  stage_name TEXT NOT NULL,
  stage_mode TEXT NOT NULL,
  app_group TEXT NOT NULL,
  service TEXT NOT NULL,
  release_id TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'WAITING',
  PRIMARY KEY (run_id, stage_idx, step_idx)
);

CREATE INDEX IF NOT EXISTS idx_release_group_step_release
  ON release_group_step (release_id);
