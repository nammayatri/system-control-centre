-- System Control Centre — Combined Schema + Seed
-- This file is the canonical source for local development.
-- It combines: autopilot schema, RBAC schema, and seed data.
-- Safe to run multiple times (IF NOT EXISTS / ON CONFLICT).

-- ============================================================
-- Extensions
-- ============================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- Autopilot tables — release orchestration
-- ============================================================

CREATE TABLE IF NOT EXISTS release_tracker (
  id TEXT NOT NULL PRIMARY KEY,
  status TEXT NOT NULL,
  description TEXT,
  new_version TEXT NOT NULL,
  old_version TEXT NOT NULL,
  product TEXT NOT NULL,
  service TEXT NOT NULL,
  mode TEXT,
  date_created TIMESTAMPTZ NOT NULL,
  last_updated TIMESTAMPTZ NOT NULL,
  start_time TIMESTAMPTZ,
  end_time TIMESTAMPTZ,
  release_manager TEXT NOT NULL,
  env TEXT NOT NULL,
  priority INTEGER NOT NULL,
  rollout_strategy TEXT,
  rollout_history TEXT,
  schedule_time TIMESTAMPTZ,
  release_tag TEXT NOT NULL,
  events TEXT,
  change_log TEXT,
  release_context TEXT,
  info TEXT,
  udf1 TEXT,
  udf2 TEXT,
  udf3 TEXT,
  is_approved BOOLEAN,
  is_infra_approved BOOLEAN,
  metadata TEXT,
  global_id TEXT,
  new_service BOOLEAN,
  is_art_recorder INTEGER,
  cronjob_suspend BOOLEAN,
  ab_hs_status TEXT,
  category TEXT DEFAULT 'BackendService',
  release_wf_status TEXT DEFAULT 'Init',
  workflow_status TEXT,
  approved_by TEXT
);

CREATE TABLE IF NOT EXISTS product_config (
  id BIGINT NOT NULL,
  product TEXT NOT NULL,
  cluster TEXT NOT NULL,
  namespace TEXT NOT NULL,
  vs_name TEXT NOT NULL,
  repo_name TEXT NOT NULL,
  product_type TEXT NOT NULL,
  product_acronym TEXT NOT NULL,
  release_branch TEXT NOT NULL,
  sync_cluster TEXT,
  need_infra_approval BOOLEAN,
  need_infra_approval1 BOOLEAN,
  vs_locked_by TEXT,
  vs_lock_timestamp TIMESTAMPTZ,
  kube_context TEXT
);

CREATE TABLE IF NOT EXISTS release_config (
  id BIGINT NOT NULL,
  emails TEXT,
  rollout_strategy TEXT,
  decision_config TEXT,
  service TEXT NOT NULL,
  product TEXT NOT NULL,
  flags TEXT,
  slack_webhook_urls TEXT,
  service_acronym TEXT,
  service_host TEXT,
  service_type TEXT,
  bitbucket_path TEXT,
  microservice_type TEXT,
  revert_strategy TEXT,
  jira_webhook_url TEXT
);

CREATE TABLE IF NOT EXISTS release_events (
  re_id BIGINT NOT NULL,
  re_release_id TEXT NOT NULL,
  re_category TEXT NOT NULL,
  re_label TEXT NOT NULL,
  re_payload JSONB NOT NULL,
  re_created_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS server_config (
  id INTEGER NOT NULL,
  type TEXT NOT NULL,
  name TEXT NOT NULL,
  value TEXT NOT NULL,
  last_updated TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  enabled INTEGER NOT NULL DEFAULT 0
);

-- Old tracker tables (configmap_tracker, workflow_tracker, app_bundle_release,
-- db_tracker, global_tracker) have been merged into release_tracker with
-- the 'category' column. See migration 0001-merge-trackers.sql.

-- ============================================================
-- RBAC tables
-- Products and permissions are derived from Haskell ADTs, NOT stored in DB.
-- Only user/role/access/override data is stored here.
-- ============================================================

CREATE TABLE IF NOT EXISTS sc_person (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email TEXT NOT NULL UNIQUE,
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT true,
    is_superadmin BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sc_role (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    product_slug TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    is_system_role BOOLEAN NOT NULL DEFAULT false,
    permissions TEXT[] DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (product_slug, name)
);

CREATE TABLE IF NOT EXISTS sc_person_product_access (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    person_id UUID NOT NULL REFERENCES sc_person(id) ON DELETE CASCADE,
    product_slug TEXT NOT NULL,
    role_id UUID NOT NULL REFERENCES sc_role(id),
    granted_by UUID REFERENCES sc_person(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (person_id, product_slug)
);

CREATE TABLE IF NOT EXISTS sc_person_permission_override (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    person_id UUID NOT NULL REFERENCES sc_person(id) ON DELETE CASCADE,
    product_slug TEXT NOT NULL,
    permission_action TEXT NOT NULL,
    override_type TEXT NOT NULL CHECK (override_type IN ('GRANT', 'DENY')),
    granted_by UUID REFERENCES sc_person(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (person_id, product_slug, permission_action)
);

CREATE TABLE IF NOT EXISTS sc_registration_token (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    person_id UUID NOT NULL REFERENCES sc_person(id) ON DELETE CASCADE,
    token TEXT NOT NULL UNIQUE,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS sc_audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    person_id UUID REFERENCES sc_person(id),
    action TEXT NOT NULL,
    entity_type TEXT,
    entity_id TEXT,
    details JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- Seed data
-- ============================================================

-- Superadmin user (password: admin123)
INSERT INTO sc_person (email, first_name, last_name, password_hash, is_superadmin)
VALUES ('admin@juspay.in', 'Admin', 'User', 'admin123', true)
ON CONFLICT (email) DO NOTHING;

-- System roles for Autopilot product
INSERT INTO sc_role (product_slug, name, description, is_system_role) VALUES
  ('autopilot', 'Admin', 'Full access to all Autopilot features', true),
  ('autopilot', 'Manager', 'Can create, approve, manage releases (no config edit)', true),
  ('autopilot', 'Viewer', 'Read-only access to Autopilot', true)
ON CONFLICT (product_slug, name) DO NOTHING;

-- System roles for Config Manager product
INSERT INTO sc_role (product_slug, name, description, is_system_role) VALUES
  ('config-manager', 'Admin', 'Full access to Config Manager', true),
  ('config-manager', 'Manager', 'Can create and apply configs', true),
  ('config-manager', 'Viewer', 'Read-only access to Config Manager', true)
ON CONFLICT (product_slug, name) DO NOTHING;

-- Assign superadmin to Admin role on both products
INSERT INTO sc_person_product_access (person_id, product_slug, role_id)
SELECT p.id, 'autopilot', r.id
FROM sc_person p, sc_role r
WHERE p.email = 'admin@juspay.in' AND r.product_slug = 'autopilot' AND r.name = 'Admin'
ON CONFLICT (person_id, product_slug) DO NOTHING;

INSERT INTO sc_person_product_access (person_id, product_slug, role_id)
SELECT p.id, 'config-manager', r.id
FROM sc_person p, sc_role r
WHERE p.email = 'admin@juspay.in' AND r.product_slug = 'config-manager' AND r.name = 'Admin'
ON CONFLICT (person_id, product_slug) DO NOTHING;
