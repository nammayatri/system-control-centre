-- System Control Centre — Seed Data
-- Only users and system roles. Products/permissions come from Haskell ADTs.

-- Superadmin user (password: admin123)
INSERT INTO sc_person (email, first_name, last_name, password_hash, is_superadmin)
VALUES ('admin@juspay.in', 'Admin', 'User', 'admin123', true)
ON CONFLICT (email) DO UPDATE SET is_superadmin = true;

-- System roles for Autopilot product
-- (permissions field is empty for system roles — they derive from code via defaultPermissions)
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
