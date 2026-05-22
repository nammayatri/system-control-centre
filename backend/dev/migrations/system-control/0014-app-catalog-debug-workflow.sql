-- Add debug_workflow_path to app_catalog.
-- When a release targets a debug destination (Firebase / TestFlight),
-- the dispatch stage uses this path instead of workflow_path.
ALTER TABLE app_catalog
  ADD COLUMN IF NOT EXISTS debug_workflow_path TEXT;

-- Seed debug workflow paths for existing rows.
UPDATE app_catalog
  SET debug_workflow_path = '.github/workflows/fastlane-android-debug.yaml'
  WHERE platform = 'android' AND debug_workflow_path IS NULL;

UPDATE app_catalog
  SET debug_workflow_path = '.github/workflows/fastlane-ios-debug.yaml'
  WHERE platform = 'ios' AND debug_workflow_path IS NULL;
