-- Migration: Merge all tracker tables into release_tracker
-- Date: 2026-03-30
--
-- This migration:
-- 1. Adds a 'category' column to release_tracker
-- 2. Adds 'release_wf_status' column if missing
-- 3. Migrates data from configmap_tracker, db_tracker, app_bundle_release,
--    workflow_tracker, global_tracker into release_tracker
-- 4. Drops the old tables

BEGIN;

-- ============================================================
-- Step 0: Add primary key if missing
-- ============================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'release_tracker'::regclass
      AND contype = 'p'
  ) THEN
    -- Check for duplicate IDs before adding PK
    IF (SELECT count(*) - count(DISTINCT id) FROM release_tracker) = 0 THEN
      ALTER TABLE release_tracker ADD PRIMARY KEY (id);
    ELSE
      RAISE NOTICE 'Duplicate IDs found in release_tracker, skipping PK constraint';
    END IF;
  END IF;
END $$;

-- ============================================================
-- Step 1: Add new columns to release_tracker
-- ============================================================
ALTER TABLE release_tracker ADD COLUMN IF NOT EXISTS category TEXT DEFAULT 'BackendService';
ALTER TABLE release_tracker ADD COLUMN IF NOT EXISTS release_wf_status TEXT DEFAULT 'Init';

-- ============================================================
-- Step 2: Migrate configmap_tracker -> release_tracker (category = 'BackendConfig')
-- ============================================================
INSERT INTO release_tracker (
  id, status, description, product, service, env, date_created, last_updated,
  start_time, end_time, release_manager, is_approved, is_infra_approved,
  events, release_tag, change_log, priority, schedule_time, category,
  release_context, new_version, old_version, release_wf_status
)
SELECT
  id, status, description, product, service, env, date_created, last_updated,
  start_time, end_time, release_manager, is_approved, is_infra_approved,
  events, COALESCE(release_tag, ''), change_log, COALESCE(priority, 0), schedule_time,
  'BackendConfig',
  json_build_object(
    'configName', name,
    'configFile', file,
    'configContent', config,
    'commit', commit,
    'cluster', cluster
  )::text,
  '', '', 'Init'
FROM configmap_tracker
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- Step 3: Migrate db_tracker -> release_tracker (category = 'DatabaseMigration')
-- ============================================================
INSERT INTO release_tracker (
  id, status, product, service, env, date_created, last_updated,
  release_manager, is_approved, events, release_tag, category,
  release_context, new_version, old_version, priority, release_wf_status
)
SELECT
  id, status, product, service, env, date_created, last_updated,
  release_manager, is_approved, events, COALESCE(release_tag, ''), 'DatabaseMigration',
  json_build_object(
    'scriptPath', script_path,
    'rollbackScriptPath', rollback_script_path
  )::text,
  '', '', 0, 'Init'
FROM db_tracker
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- Step 4: Migrate app_bundle_release -> release_tracker (category = 'MobileAppBundle')
-- ============================================================
INSERT INTO release_tracker (
  id, status, product, service, env, date_created, last_updated,
  release_manager, events, category, release_context,
  rollout_strategy, new_version, old_version, priority, release_tag, release_wf_status
)
SELECT
  id, status, app_name, app_name, platform, created_at, updated_at,
  release_manager, events, 'MobileAppBundle',
  json_build_object(
    'platform', platform,
    'buildId', build_id,
    'releaseContext', release_context
  )::text,
  rollout_strategy, '', '', 0, '', 'Init'
FROM app_bundle_release
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- Step 5: Migrate workflow_tracker -> release_tracker (category = 'Workflow')
-- ============================================================
INSERT INTO release_tracker (
  id, status, product, service, env, date_created, last_updated,
  release_manager, events, category, release_context,
  schedule_time, approved_by, new_version, old_version,
  priority, release_tag, release_wf_status
)
SELECT
  id, COALESCE(status, 'Created'), product, service, env, created_at, last_updated,
  release_manager, events, 'Workflow',
  json_build_object(
    'workflow', workflow,
    'trackerType', tracker_type,
    'trackerContext', tracker_context,
    'workflowContext', workflow_context,
    'cluster', cluster
  )::text,
  schedule_time, approved_by, '', '', 0, '', 'Init'
FROM workflow_tracker
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- Step 6: Migrate global_tracker -> release_tracker (category = 'GlobalRelease')
-- ============================================================
INSERT INTO release_tracker (
  id, status, is_approved, date_created, last_updated, category,
  release_context, product, service, env, release_manager,
  new_version, old_version, priority, release_tag, release_wf_status
)
SELECT
  id, status, is_approved, COALESCE(created_at, now()), COALESCE(updated_at, now()),
  'GlobalRelease',
  json_build_object(
    'tracker', tracker,
    'syncStrategy', sync_strategy
  )::text,
  '', '', '', '', '', '', 0, '', 'Init'
FROM global_tracker
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- Step 7: Drop old tables
-- ============================================================
DROP TABLE IF EXISTS configmap_tracker;
DROP TABLE IF EXISTS db_tracker;
DROP TABLE IF EXISTS app_bundle_release;
DROP TABLE IF EXISTS workflow_tracker;
DROP TABLE IF EXISTS global_tracker;

COMMIT;
