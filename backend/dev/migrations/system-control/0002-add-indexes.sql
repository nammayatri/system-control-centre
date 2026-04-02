-- Performance indexes for all tables
-- Run: psql -d system_control -f dev/migrations/system-control/0005-add-indexes.sql

-- release_tracker
CREATE INDEX IF NOT EXISTS idx_rt_status ON release_tracker(status);
CREATE INDEX IF NOT EXISTS idx_rt_app_group_env ON release_tracker(app_group, env);
CREATE INDEX IF NOT EXISTS idx_rt_created_at ON release_tracker(date_created DESC);
CREATE INDEX IF NOT EXISTS idx_rt_is_approved ON release_tracker(is_approved);
CREATE INDEX IF NOT EXISTS idx_rt_global_id ON release_tracker(global_id) WHERE global_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_rt_updated_at ON release_tracker(last_updated DESC);

-- release_events
CREATE INDEX IF NOT EXISTS idx_re_release_id ON release_events(re_release_id);

-- deployment_config
CREATE INDEX IF NOT EXISTS idx_dc_app_group ON deployment_config(app_group);
CREATE INDEX IF NOT EXISTS idx_dc_app_group_service ON deployment_config(app_group, service);

-- server_config
CREATE INDEX IF NOT EXISTS idx_sc_name ON server_config(name);

-- RBAC
CREATE INDEX IF NOT EXISTS idx_person_email ON sc_person(email);
CREATE INDEX IF NOT EXISTS idx_role_product ON sc_role(product_slug);
CREATE INDEX IF NOT EXISTS idx_access_person ON sc_person_product_access(person_id);
CREATE INDEX IF NOT EXISTS idx_override_person ON sc_person_permission_override(person_id, product_slug);
CREATE INDEX IF NOT EXISTS idx_token_value ON sc_registration_token(token);

ANALYZE;
