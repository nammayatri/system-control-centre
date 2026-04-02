-- Migration: Merge product_config + release_config into deployment_config
-- Also: vs_edit_tracker operations now use release_tracker with category='VSEdit'
-- Date: 2026-03-31
--
-- This migration is idempotent and safe to run multiple times.
-- The deployment_config table is created by ensureSchema on app startup,
-- and data is auto-migrated from old tables. This file documents the schema
-- and provides a manual migration path if needed.

-- Step 1: Create deployment_config (if not exists)
CREATE TABLE IF NOT EXISTS deployment_config (
    id SERIAL PRIMARY KEY,
    product TEXT NOT NULL,
    service TEXT,
    -- Product-level fields (service IS NULL)
    cluster TEXT,
    namespace TEXT,
    vs_name TEXT,
    product_acronym TEXT,
    product_type TEXT,
    repo_name TEXT,
    release_branch TEXT,
    sync_cluster TEXT,
    need_infra_approval BOOLEAN,
    vs_locked_by TEXT,
    vs_lock_timestamp TIMESTAMPTZ,
    -- Service-level fields (service IS NOT NULL)
    service_host TEXT,
    service_type TEXT,
    service_acronym TEXT,
    rollout_strategy TEXT,
    revert_strategy TEXT,
    decision_config TEXT,
    bitbucket_path TEXT,
    slack_channel TEXT,
    emails TEXT
);

-- Unique constraint: one row per (product, service) pair
-- COALESCE handles NULL service for product-level rows
DO $$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_deployment_config') THEN
    CREATE UNIQUE INDEX IF NOT EXISTS uq_deployment_config ON deployment_config (product, COALESCE(service, ''));
END IF;
END $$;

-- Step 2: Migrate product_config -> deployment_config
-- DISTINCT ON handles duplicate product rows (e.g., BECKN with different clusters)
INSERT INTO deployment_config (product, product_type, product_acronym, repo_name, release_branch, need_infra_approval,
    cluster, namespace, vs_name, sync_cluster)
SELECT DISTINCT ON (p.product) p.product, p.product_type, p.product_acronym, p.repo_name, p.release_branch, p.need_infra_approval,
    COALESCE((p.target_config::json->>'cluster')::text, ''),
    COALESCE((p.target_config::json->>'namespace')::text, ''),
    COALESCE((p.target_config::json->>'vsName')::text, ''),
    (p.target_config::json->>'syncCluster')::text
FROM product_config p
WHERE NOT EXISTS (SELECT 1 FROM deployment_config d WHERE d.product = p.product AND d.service IS NULL)
ORDER BY p.product, p.id;

-- Step 3: Migrate release_config -> deployment_config
INSERT INTO deployment_config (product, service, service_type, emails, rollout_strategy, revert_strategy,
    decision_config, slack_channel, bitbucket_path, service_host, service_acronym)
SELECT r.product, r.service, r.service_type, r.emails, r.rollout_strategy, r.revert_strategy,
    r.decision_config, r.slack_webhook_urls, r.bitbucket_path,
    COALESCE((r.target_config::json->>'serviceHost')::text, ''),
    r.service_acronym
FROM release_config r
WHERE NOT EXISTS (SELECT 1 FROM deployment_config d WHERE d.product = r.product AND d.service = r.service);

-- Step 4: Migrate vs_edit_tracker -> release_tracker (category='VSEdit')
-- Only migrate rows that don't already exist
INSERT INTO release_tracker (id, old_version, new_version, product, service, priority, env,
    category, status, release_wf_status, release_manager, date_created, last_updated,
    start_time, end_time, release_tag, metadata, udf1, udf2, udf3)
SELECT
    v.id, '', '', v.product, v.service, 0, v.env,
    'VSEdit', v.status, 'Init', v.created_by, v.created_at, v.updated_at,
    v.locked_at, v.lock_expiry, v.id, v.vs_name, v.locked_by, v.old_vs_data, v.new_vs_data
FROM vs_edit_tracker v
WHERE NOT EXISTS (SELECT 1 FROM release_tracker r WHERE r.id = v.id);

-- Step 5: Drop old tables (UNCOMMENT after verifying data is migrated correctly)
-- DROP TABLE IF EXISTS product_config;
-- DROP TABLE IF EXISTS release_config;
-- DROP TABLE IF EXISTS vs_edit_tracker;
