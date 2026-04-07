-- Performance indexes + unique constraints for all tables.
-- Idempotent (CREATE INDEX IF NOT EXISTS).

-- release_tracker
CREATE INDEX IF NOT EXISTS idx_rt_status ON release_tracker(status);
CREATE INDEX IF NOT EXISTS idx_rt_app_group_env ON release_tracker(app_group, env);
CREATE INDEX IF NOT EXISTS idx_rt_created_at ON release_tracker(date_created DESC);
CREATE INDEX IF NOT EXISTS idx_rt_is_approved ON release_tracker(is_approved);
CREATE INDEX IF NOT EXISTS idx_rt_updated_at ON release_tracker(last_updated DESC);

-- Unique partial index on global_id: prevents duplicate cross-cloud sync trackers
-- when the Haskell-level idempotency check loses a race. Partial because
-- global_id is NULL for human-originated releases (the common case).
CREATE UNIQUE INDEX IF NOT EXISTS uq_release_tracker_global_id
    ON release_tracker (global_id) WHERE global_id IS NOT NULL;

-- Same-service concurrency guard. The Haskell-level findInFlightSameService
-- check is TOCTOU under parallel create — multiple POST /releases/create
-- on the same (app_group, service) can all see zero in-flight rows and
-- all insert. This partial unique index lets only ONE row exist for a
-- (app_group, service) pair while it is still in a non-terminal state;
-- subsequent inserts during the window fail with sqlState 23505 which
-- the handler translates to the same user-friendly error.
--
-- IMPORTANT: filter by category='BackendService' so the index ONLY
-- constrains rolling-deployment releases. ConfigMap and VS edit trackers
-- share the same release_tracker table but use different category values
-- ('BackendConfig' / no category) and have their own concurrency rules.
-- Without the category filter, creating any configmap or VS-edit while a
-- service has an in-flight release (or vice versa) hits the unique
-- violation incorrectly.
CREATE UNIQUE INDEX IF NOT EXISTS uq_release_tracker_service_inflight
    ON release_tracker (app_group, service)
    WHERE status IN ('CREATED','INPROGRESS','PAUSED','ABORTING','REVERTING','RESTARTING','PREPARING')
      AND category IN ('BackendService','BackendScheduler','BackendCronJob','BackendJob');

-- release_events
CREATE INDEX IF NOT EXISTS idx_re_release_id ON release_events(re_release_id);

-- deployment_config
CREATE INDEX IF NOT EXISTS idx_dc_app_group ON deployment_config(app_group);
CREATE INDEX IF NOT EXISTS idx_dc_app_group_service ON deployment_config(app_group, service);

-- server_config
CREATE INDEX IF NOT EXISTS idx_sc_name ON server_config(name);

-- Unique expression index matching the upsert in Shared/Queries/ServerConfig.hs:
--   ON CONFLICT (name, COALESCE(product, '')) DO UPDATE ...
-- Without this every server_config update fails with SQLSTATE 42P10.
-- COALESCE collapses NULL product to '' so global and product-scoped rows
-- with the same name remain distinguishable.
CREATE UNIQUE INDEX IF NOT EXISTS uq_server_config_name_product
    ON server_config (name, COALESCE(product, ''));

-- RBAC
CREATE INDEX IF NOT EXISTS idx_person_email ON sc_person(email);
CREATE INDEX IF NOT EXISTS idx_role_product ON sc_role(product_slug);
CREATE INDEX IF NOT EXISTS idx_access_person ON sc_person_product_access(person_id);
CREATE INDEX IF NOT EXISTS idx_override_person ON sc_person_permission_override(person_id, product_slug);
CREATE INDEX IF NOT EXISTS idx_token_value ON sc_registration_token(token);

ANALYZE;
