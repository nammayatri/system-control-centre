INSERT INTO sc_role (product_slug, name, description, is_system_role, permissions) VALUES
  ('autopilot', 'config_pilot_releaser', 'Create and run staggered ConfigPilot config releases', false,
   ARRAY['RELEASE_VIEW', 'RELEASE_CREATE', 'RELEASE_APPROVE', 'RELEASE_PAUSE', 'RELEASE_RESUME', 'RELEASE_ABORT', 'CONFIG_PILOT_RELEASE'])
ON CONFLICT (product_slug, name) DO NOTHING;
