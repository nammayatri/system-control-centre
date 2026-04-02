-- Migration 0007: Major cleanup — rename product -> app_group, drop events + is_art_recorder
-- Applied: 2026-03-31

-- ========================================================================
-- 1. Drop obsolete columns from release_tracker
-- ========================================================================
ALTER TABLE release_tracker DROP COLUMN IF EXISTS events;
ALTER TABLE release_tracker DROP COLUMN IF EXISTS is_art_recorder;

-- ========================================================================
-- 2. Rename product -> app_group in deployment_config
-- ========================================================================
DO $$ BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'deployment_config' AND column_name = 'product'
    ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'deployment_config' AND column_name = 'app_group'
    ) THEN
        ALTER TABLE deployment_config RENAME COLUMN product TO app_group;
    END IF;
END $$;

-- ========================================================================
-- 3. Rename product -> app_group in release_tracker
-- ========================================================================
DO $$ BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'release_tracker' AND column_name = 'product'
    ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'release_tracker' AND column_name = 'app_group'
    ) THEN
        ALTER TABLE release_tracker RENAME COLUMN product TO app_group;
    END IF;
END $$;

-- ========================================================================
-- 4. Recreate indexes with new column name
-- ========================================================================
DROP INDEX IF EXISTS idx_rt_product_env;
CREATE INDEX IF NOT EXISTS idx_rt_app_group_env ON release_tracker(app_group, env);

-- Recreate unique constraint on deployment_config
DROP INDEX IF EXISTS uq_deployment_config;
CREATE UNIQUE INDEX uq_deployment_config ON deployment_config (app_group, COALESCE(service, ''));
