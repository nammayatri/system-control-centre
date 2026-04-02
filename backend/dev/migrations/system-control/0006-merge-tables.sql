-- Migration: Merge product_config + release_config → deployment_config
-- Also: vs_edit_tracker → release_tracker with category='VSEdit'
-- Date: 2026-04-02
--
-- TERMINOLOGY:
--   deployment_config.product = deployment group (BECKN, NANDI, BECKN_DASHBOARD)
--     These are K8s deployment groups — each has its own namespace, VS, cluster.
--     One group has many services (BECKN_APP_BACKEND, BECKN_DRIVER_OFFER_BPP, etc.)
--
--   server_config.product = system-control module (autopilot, frontpilot)
--     These are the product modules in the System Control Centre app.
--     Each module has its own runtime configs (k8s_enabled, approve_all, etc.)
--
--   release_tracker.product = deployment group (same as deployment_config.product)
--     Links releases to their deployment group config.
--
-- This migration is idempotent and safe to run multiple times.

-- ============================================================================
-- Step 1: Create deployment_config table
-- ============================================================================
-- Replaces: product_config (product-level) + release_config (service-level)
-- Product rows: service IS NULL — one per deployment group (BECKN, NANDI)
-- Service rows: service IS NOT NULL — one per microservice (BECKN_APP_BACKEND_MASTER)

CREATE TABLE IF NOT EXISTS deployment_config (
    id SERIAL PRIMARY KEY,
    product TEXT NOT NULL,           -- deployment group name (BECKN, NANDI, etc.)
    service TEXT,                    -- NULL = product-level config, NOT NULL = service-level

    -- Product-level fields (when service IS NULL)
    cluster TEXT,                    -- K8s cluster name (BECKN_UAT, BECKN_PROD)
    namespace TEXT,                  -- K8s namespace (atlas, nandi)
    vs_name TEXT,                    -- VirtualService name (atlas-vs)
    product_acronym TEXT,            -- short name for release tags (BKN)
    product_type TEXT,               -- SERVICE, SCHEDULER
    repo_name TEXT,                  -- git repo name (for future Bitbucket integration)
    release_branch TEXT,             -- default release branch
    sync_cluster TEXT,               -- secondary cluster for multi-cloud sync
    need_infra_approval BOOLEAN,     -- require infra team approval for releases
    vs_locked_by TEXT,               -- who holds the VS edit lock (NULL = unlocked)
    vs_lock_timestamp TIMESTAMPTZ,   -- when the VS lock was acquired

    -- Service-level fields (when service IS NOT NULL)
    service_host TEXT,               -- K8s deployment/service name (beckn-app-backend-master)
    service_type TEXT,               -- SERVICE, SCHEDULER, CUSTOM
    service_acronym TEXT,            -- short name
    rollout_strategy TEXT,           -- default rollout stages JSON
    revert_strategy TEXT,            -- revert rollout stages JSON
    decision_config TEXT,            -- AB testing config JSON (Phase 3)
    bitbucket_path TEXT,             -- repo path (for future Bitbucket integration)
    slack_channel TEXT,              -- Slack channel ID for notifications
    emails TEXT                      -- notification email addresses
);

-- One row per (product, service) pair
DO $$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'uq_deployment_config') THEN
    CREATE UNIQUE INDEX uq_deployment_config ON deployment_config (product, COALESCE(service, ''));
END IF;
END $$;

-- ============================================================================
-- Step 2: Migrate product_config → deployment_config (product-level rows)
-- ============================================================================
INSERT INTO deployment_config (
    product, product_type, product_acronym, repo_name, release_branch,
    need_infra_approval, cluster, namespace, vs_name, sync_cluster
)
SELECT DISTINCT ON (p.product)
    p.product, p.product_type, p.product_acronym, p.repo_name, p.release_branch,
    p.need_infra_approval,
    COALESCE((p.target_config::json->>'cluster')::text, ''),
    COALESCE((p.target_config::json->>'namespace')::text, ''),
    COALESCE((p.target_config::json->>'vsName')::text, ''),
    (p.target_config::json->>'syncCluster')::text
FROM product_config p
WHERE NOT EXISTS (
    SELECT 1 FROM deployment_config d WHERE d.product = p.product AND d.service IS NULL
)
ORDER BY p.product, p.id;

-- ============================================================================
-- Step 3: Migrate release_config → deployment_config (service-level rows)
-- ============================================================================
INSERT INTO deployment_config (
    product, service, service_type, emails, rollout_strategy, revert_strategy,
    decision_config, slack_channel, bitbucket_path, service_host, service_acronym
)
SELECT
    r.product, r.service, r.service_type, r.emails, r.rollout_strategy,
    r.revert_strategy, r.decision_config, r.slack_webhook_urls, r.bitbucket_path,
    COALESCE((r.target_config::json->>'serviceHost')::text, ''),
    r.service_acronym
FROM release_config r
WHERE NOT EXISTS (
    SELECT 1 FROM deployment_config d WHERE d.product = r.product AND d.service = r.service
);

-- ============================================================================
-- Step 4: Migrate vs_edit_tracker → release_tracker (category='VSEdit')
-- ============================================================================
-- VS edit operations now tracked as releases with category='VSEdit'
-- Old VS data → udf2, new VS data → udf3, VS name → metadata, locked_by → udf1
INSERT INTO release_tracker (
    id, old_version, new_version, product, service, priority, env,
    category, status, release_wf_status, release_manager,
    date_created, last_updated, start_time, end_time,
    release_tag, metadata, udf1, udf2, udf3
)
SELECT
    v.id, '', '', v.product, v.service, 0, v.env,
    'VSEdit', v.status, 'Init', v.created_by,
    v.created_at, v.updated_at, v.locked_at, v.lock_expiry,
    'VSEDIT_' || v.product || '_' || v.id,
    v.vs_name, v.locked_by, v.old_vs_data, v.new_vs_data
FROM vs_edit_tracker v
WHERE NOT EXISTS (SELECT 1 FROM release_tracker r WHERE r.id = v.id);

-- ============================================================================
-- Step 5: Verify migration
-- ============================================================================
-- Run these to verify:
--   SELECT count(*) FROM deployment_config WHERE service IS NULL;  -- should match product_config count
--   SELECT count(*) FROM deployment_config WHERE service IS NOT NULL;  -- should match release_config count
--   SELECT count(*) FROM release_tracker WHERE category = 'VSEdit';  -- should match vs_edit_tracker count

-- ============================================================================
-- Step 6: Drop old tables (UNCOMMENT after verifying data migrated correctly)
-- ============================================================================
-- WARNING: Only run after verifying Step 5 counts match!
-- DROP TABLE IF EXISTS product_config;
-- DROP TABLE IF EXISTS release_config;
-- DROP TABLE IF EXISTS vs_edit_tracker;
