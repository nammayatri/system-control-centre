-- Performance indexes for all tables
-- Run: psql -d system_control -f dev/migrations/system-control/0005-add-indexes.sql

-- release_tracker (most queried)
CREATE INDEX IF NOT EXISTS idx_rt_status ON release_tracker(status);
CREATE INDEX IF NOT EXISTS idx_rt_product_env ON release_tracker(product, env);
CREATE INDEX IF NOT EXISTS idx_rt_created_at ON release_tracker(date_created DESC);
CREATE INDEX IF NOT EXISTS idx_rt_is_approved ON release_tracker(is_approved);
CREATE INDEX IF NOT EXISTS idx_rt_global_id ON release_tracker(global_id) WHERE global_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_rt_updated_at ON release_tracker(last_updated DESC);

-- release_events
CREATE INDEX IF NOT EXISTS idx_re_release_id ON release_events(re_release_id);

-- RBAC
CREATE INDEX IF NOT EXISTS idx_person_email ON sc_person(email);
CREATE INDEX IF NOT EXISTS idx_role_product ON sc_role(product_slug);
CREATE INDEX IF NOT EXISTS idx_access_person ON sc_person_product_access(person_id);
CREATE INDEX IF NOT EXISTS idx_override_person ON sc_person_permission_override(person_id, product_slug);
CREATE INDEX IF NOT EXISTS idx_token_value ON sc_registration_token(token);

-- Config
CREATE INDEX IF NOT EXISTS idx_pc_product ON product_config(product);
CREATE INDEX IF NOT EXISTS idx_rc_product_service ON release_config(product, service);
CREATE INDEX IF NOT EXISTS idx_sc_name ON server_config(name);
CREATE INDEX IF NOT EXISTS idx_vet_product_vs ON vs_edit_tracker(product, vs_name, env);

-- Drop unused column
ALTER TABLE product_config DROP COLUMN IF EXISTS need_infra_approval1;

ANALYZE;
