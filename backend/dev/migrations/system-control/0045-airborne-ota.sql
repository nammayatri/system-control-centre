-- Airborne OTA product (docs/AIRBORNE_OTA_INTEGRATION.md §5.5):
-- proxied-mutation audit trail + system roles.
--
-- The product is driven LIVE off airborne's app list (GET /api/users); there is
-- no local scc<->airborne mapping table. App identity everywhere is the
-- composite ref "<org>~<app>" (the x-organisation/x-application pair): the URL
-- :app segment, the RBAC grant key (sc_person_deployment_access.app_group), and
-- the audit key below. Airborne application names are immutable (the only
-- application route is create -- no rename, no delete), so keying on the
-- airborne identity is safe.

CREATE TABLE IF NOT EXISTS airborne_events (
  id                  BIGSERIAL PRIMARY KEY,
  actor               TEXT NOT NULL,       -- SCC user email
  airborne_org        TEXT,                -- x-organisation (nullable: legacy rows)
  airborne_app        TEXT,                -- x-application
  action              TEXT NOT NULL,       -- RAMP | CONCLUDE | DISCARD
  endpoint            TEXT NOT NULL,       -- upstream path
  request             JSONB,
  upstream_status     INT,
  upstream_request_id TEXT,                -- airborne x-request-id, for log correlation
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_airborne_events_app
  ON airborne_events (airborne_org, airborne_app, created_at DESC);

-- System roles (mirrors the autopilot seed pattern; permission sets are
-- derived in code from the OtaPermission ADT, not stored here).
INSERT INTO sc_role (product_slug, name, description, is_system_role) VALUES
  ('airborne-ota', 'Admin',   'Full access to Airborne OTA', true),
  ('airborne-ota', 'Manager', 'Operate OTA releases (no discard)', true),
  ('airborne-ota', 'Viewer',  'Read-only access to Airborne OTA', true)
ON CONFLICT (product_slug, name) DO NOTHING;

-- Superadmins get Admin on the new product.
INSERT INTO sc_person_product_access (person_id, product_slug, role_id)
SELECT p.id, 'airborne-ota', r.id
FROM sc_person p, sc_role r
WHERE p.is_superadmin AND r.product_slug = 'airborne-ota' AND r.name = 'Admin'
ON CONFLICT DO NOTHING;

ANALYZE;
