-- Per-cloud deployment_config rows.
--
-- Each cloud owns its own row per (app_group, service). This makes cluster,
-- sync_cluster, service_state and the VS lock per-cloud, which is what the sync
-- flow needs: a shared service_state deadlocks it (the origin's create claims
-- MODIFYING, the synced create at the other cloud then cannot), and a shared
-- cluster can never match both sides at once.

ALTER TABLE deployment_config ADD COLUMN IF NOT EXISTS cloud_type TEXT;

DO $$
DECLARE resolved text := COALESCE(current_setting('scc.cloud_type', true), 'GCP');
BEGIN
    EXECUTE format('ALTER TABLE deployment_config ALTER COLUMN cloud_type SET DEFAULT %L', resolved);
    EXECUTE format('UPDATE deployment_config SET cloud_type = %L WHERE cloud_type IS NULL', resolved);
END
$$;

ALTER TABLE deployment_config ALTER COLUMN cloud_type SET NOT NULL;

DROP INDEX IF EXISTS uq_deployment_config;
CREATE UNIQUE INDEX IF NOT EXISTS uq_deployment_config
  ON deployment_config (app_group, COALESCE(service, ''), cloud_type);

CREATE INDEX IF NOT EXISTS idx_dc_cloud_type ON deployment_config(cloud_type);

ANALYZE;
