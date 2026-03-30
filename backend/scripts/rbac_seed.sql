-- Seed data for RBAC system
-- Products
INSERT INTO sc_product (id, slug, name, description)
VALUES
  ('a0000000-0000-0000-0000-000000000001', 'backend-releases', 'Backend Releases', 'Release management for backend services'),
  ('a0000000-0000-0000-0000-000000000002', 'config-manager', 'Config Manager', 'Configuration management for services')
ON CONFLICT (slug) DO NOTHING;

-- Permissions for backend-releases
INSERT INTO sc_permission (id, product_id, action, description)
VALUES
  ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'RELEASE_VIEW', 'View releases'),
  ('b0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001', 'RELEASE_CREATE', 'Create releases'),
  ('b0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001', 'RELEASE_APPROVE', 'Approve releases'),
  ('b0000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000001', 'RELEASE_REVERT', 'Revert releases'),
  ('b0000000-0000-0000-0000-000000000005', 'a0000000-0000-0000-0000-000000000001', 'RELEASE_DISCARD', 'Discard releases'),
  ('b0000000-0000-0000-0000-000000000006', 'a0000000-0000-0000-0000-000000000001', 'RELEASE_PAUSE', 'Pause releases'),
  ('b0000000-0000-0000-0000-000000000007', 'a0000000-0000-0000-0000-000000000001', 'RELEASE_RESUME', 'Resume releases'),
  ('b0000000-0000-0000-0000-000000000008', 'a0000000-0000-0000-0000-000000000001', 'RELEASE_ABORT', 'Abort releases'),
  ('b0000000-0000-0000-0000-000000000009', 'a0000000-0000-0000-0000-000000000001', 'RELEASE_UPDATE', 'Update releases'),
  ('b0000000-0000-0000-0000-000000000010', 'a0000000-0000-0000-0000-000000000001', 'MANAGE_STAGGER', 'Manage stagger strategy'),
  ('b0000000-0000-0000-0000-000000000011', 'a0000000-0000-0000-0000-000000000001', 'PRODUCT_CONFIG_VIEW', 'View product configuration'),
  ('b0000000-0000-0000-0000-000000000012', 'a0000000-0000-0000-0000-000000000001', 'PRODUCT_CONFIG_EDIT', 'Edit product configuration'),
  ('b0000000-0000-0000-0000-000000000013', 'a0000000-0000-0000-0000-000000000001', 'SERVICE_CONFIG_VIEW', 'View service configuration'),
  ('b0000000-0000-0000-0000-000000000014', 'a0000000-0000-0000-0000-000000000001', 'SERVICE_CONFIG_EDIT', 'Edit service configuration')
ON CONFLICT (product_id, action) DO NOTHING;

-- Permissions for config-manager
INSERT INTO sc_permission (id, product_id, action, description)
VALUES
  ('c0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', 'CONFIG_VIEW', 'View configurations'),
  ('c0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000002', 'CONFIG_CREATE', 'Create configurations'),
  ('c0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000002', 'CONFIG_APPLY', 'Apply configurations'),
  ('c0000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000002', 'CONFIG_ROLLBACK', 'Rollback configurations'),
  ('c0000000-0000-0000-0000-000000000005', 'a0000000-0000-0000-0000-000000000002', 'CONFIG_UPDATE', 'Update configurations')
ON CONFLICT (product_id, action) DO NOTHING;

-- Roles for backend-releases
INSERT INTO sc_role (id, product_id, name, description, is_system_role)
VALUES
  ('d0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'Admin', 'Full access to backend releases', true),
  ('d0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001', 'Manager', 'Manage releases without editing configs', true),
  ('d0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001', 'Viewer', 'View-only access to releases', true)
ON CONFLICT (product_id, name) DO NOTHING;

-- Roles for config-manager
INSERT INTO sc_role (id, product_id, name, description, is_system_role)
VALUES
  ('d0000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000002', 'Admin', 'Full access to config manager', true),
  ('d0000000-0000-0000-0000-000000000005', 'a0000000-0000-0000-0000-000000000002', 'Manager', 'Manage configs without rollback', true),
  ('d0000000-0000-0000-0000-000000000006', 'a0000000-0000-0000-0000-000000000002', 'Viewer', 'View-only access to configs', true)
ON CONFLICT (product_id, name) DO NOTHING;

-- Role permissions for backend-releases Admin (all permissions)
INSERT INTO sc_role_permission (role_id, permission_id)
SELECT 'd0000000-0000-0000-0000-000000000001', id FROM sc_permission WHERE product_id = 'a0000000-0000-0000-0000-000000000001'
ON CONFLICT DO NOTHING;

-- Role permissions for backend-releases Manager (all except *_EDIT)
INSERT INTO sc_role_permission (role_id, permission_id)
SELECT 'd0000000-0000-0000-0000-000000000002', id FROM sc_permission
WHERE product_id = 'a0000000-0000-0000-0000-000000000001' AND action NOT LIKE '%_EDIT'
ON CONFLICT DO NOTHING;

-- Role permissions for backend-releases Viewer (only *_VIEW)
INSERT INTO sc_role_permission (role_id, permission_id)
SELECT 'd0000000-0000-0000-0000-000000000003', id FROM sc_permission
WHERE product_id = 'a0000000-0000-0000-0000-000000000001' AND action LIKE '%_VIEW'
ON CONFLICT DO NOTHING;

-- Role permissions for config-manager Admin (all permissions)
INSERT INTO sc_role_permission (role_id, permission_id)
SELECT 'd0000000-0000-0000-0000-000000000004', id FROM sc_permission WHERE product_id = 'a0000000-0000-0000-0000-000000000002'
ON CONFLICT DO NOTHING;

-- Role permissions for config-manager Manager (all except CONFIG_ROLLBACK)
INSERT INTO sc_role_permission (role_id, permission_id)
SELECT 'd0000000-0000-0000-0000-000000000005', id FROM sc_permission
WHERE product_id = 'a0000000-0000-0000-0000-000000000002' AND action NOT IN ('CONFIG_ROLLBACK')
ON CONFLICT DO NOTHING;

-- Role permissions for config-manager Viewer (only CONFIG_VIEW)
INSERT INTO sc_role_permission (role_id, permission_id)
SELECT 'd0000000-0000-0000-0000-000000000006', id FROM sc_permission
WHERE product_id = 'a0000000-0000-0000-0000-000000000002' AND action = 'CONFIG_VIEW'
ON CONFLICT DO NOTHING;

-- Default superadmin user (password: admin123)
-- bcrypt hash of 'admin123': $2b$10$8K1p/a0dL1LXMw7kDt6Z0eJGa0RFML0n3kGxJc5aOaHbqG8n9FJyC
INSERT INTO sc_person (id, email, first_name, last_name, password_hash, is_active, is_superadmin)
VALUES (
  'e0000000-0000-0000-0000-000000000001',
  'admin@juspay.in',
  'Admin',
  'User',
  '$2b$10$8K1p/a0dL1LXMw7kDt6Z0eJGa0RFML0n3kGxJc5aOaHbqG8n9FJyC',
  true,
  true
)
ON CONFLICT (email) DO NOTHING;

-- Give superadmin Admin role on both products
INSERT INTO sc_person_product_access (person_id, product_id, role_id, granted_by)
VALUES
  ('e0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000001', NULL),
  ('e0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', 'd0000000-0000-0000-0000-000000000004', NULL)
ON CONFLICT (person_id, product_id) DO NOTHING;
