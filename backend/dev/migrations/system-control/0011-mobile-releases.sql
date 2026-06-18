-- 0011-mobile-releases.sql
-- Mobile release support: adds dispatch grouping + external run tracking
-- columns to release_tracker, and a new app_catalog auxiliary table.

-- Two nullable columns on release_tracker; backend rows leave them NULL.
ALTER TABLE release_tracker
  ADD COLUMN IF NOT EXISTS dispatch_id    TEXT,
  ADD COLUMN IF NOT EXISTS external_run_id TEXT;
CREATE INDEX IF NOT EXISTS idx_rt_dispatch_id     ON release_tracker(dispatch_id);
CREATE INDEX IF NOT EXISTS idx_rt_external_run_id ON release_tracker(external_run_id);

-- New auxiliary catalog of mobile apps releasable through SCC.
CREATE TABLE IF NOT EXISTS app_catalog (
  id              SERIAL PRIMARY KEY,
  name            TEXT NOT NULL,
  surface         TEXT NOT NULL,        -- 'customer' | 'driver'
  platform        TEXT NOT NULL,        -- 'android' | 'ios'
  github_repo     TEXT NOT NULL,
  workflow_path   TEXT NOT NULL,
  package_name    TEXT,
  display_label   TEXT,
  enabled         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT app_catalog_unique_app UNIQUE (name, surface, platform)
);

-- Seed the 10 customer Android apps. Lives here (not in the seed file) because
-- the seed runs before migrations and would otherwise reference app_catalog
-- before it exists. ON CONFLICT keeps this idempotent across re-runs.
INSERT INTO app_catalog (name, surface, platform, github_repo, workflow_path, package_name, display_label, enabled)
VALUES
  ('Cumta',         'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android-debug.yaml', 'in.mobility.cumta',                  'Cumta (Customer Android)',           true),
  ('NammaYatri',    'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android-debug.yaml', 'in.juspay.nammayatri',               'Namma Yatri (Customer Android)',     true),
  ('ManaYatri',     'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android-debug.yaml', 'in.mobility.manayatri',              'Mana Yatri (Customer Android)',      true),
  ('Yatri',         'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android-debug.yaml', 'net.openkochi.yatri',                'Yatri (Customer Android)',           true),
  ('OdishaYatri',   'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android-debug.yaml', 'in.mobility.odishayatri',            'Odisha Yatri (Customer Android)',    true),
  ('YatriSathi',    'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android-debug.yaml', 'in.juspay.jatrisaathi',              'Yatri Sathi (Customer Android)',     true),
  ('KeralaSavaari', 'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android-debug.yaml', 'in.mobility.keralasavaariconsumer',  'Kerala Savaari (Customer Android)',  true),
  ('Bridge',        'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android-debug.yaml', 'com.mobility.movingtech',            'Bridge (Customer Android)',          true),
  ('BharatTaxi',    'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android-debug.yaml', 'in.mobility.bharatTaxi',             'Bharat Taxi (Customer Android)',     true),
  ('Lynx',          'customer', 'android', 'nammayatri/ny-react-native', '.github/workflows/fastlane-android-debug.yaml', 'in.mobility.international',          'Lynx (Customer Android)',            true)
ON CONFLICT (name, surface, platform) DO NOTHING;

-- ─── iOS extension (added 2026-05-14) ───────────────────────────────
-- Same 10 apps with platform='ios'. Workflow file is fastlane.yaml (NOT
-- fastlane-ios.yaml — verified against nammayatri/ny-react-native's actual
-- workflow tree). package_name holds the iOS bundle id for these rows.
-- The ASC numeric app id is resolved at runtime via
--   GET /v1/apps?filter[bundleId]=<bundle_id>
-- so no extra column is needed. Disabled by default; admins enable per app.
-- ON CONFLICT keeps this idempotent on re-run.
INSERT INTO app_catalog (name, surface, platform, github_repo, workflow_path, package_name, display_label, enabled)
VALUES
  ('Cumta',         'customer', 'ios', 'nammayatri/ny-react-native', '.github/workflows/fastlane-ios-debug.yaml', 'in.mobility.cumta',                  'Cumta (Customer iOS)',           true),
  ('NammaYatri',    'customer', 'ios', 'nammayatri/ny-react-native', '.github/workflows/fastlane-ios-debug.yaml', 'in.juspay.nammayatri',               'Namma Yatri (Customer iOS)',     true),
  ('ManaYatri',     'customer', 'ios', 'nammayatri/ny-react-native', '.github/workflows/fastlane-ios-debug.yaml', 'in.mobility.manayatri',              'Mana Yatri (Customer iOS)',      true),
  ('Yatri',         'customer', 'ios', 'nammayatri/ny-react-native', '.github/workflows/fastlane-ios-debug.yaml', 'net.openkochi.yatri',                'Yatri (Customer iOS)',           true),
  ('OdishaYatri',   'customer', 'ios', 'nammayatri/ny-react-native', '.github/workflows/fastlane-ios-debug.yaml', 'in.mobility.odishayatri',            'Odisha Yatri (Customer iOS)',    true),
  ('YatriSathi',    'customer', 'ios', 'nammayatri/ny-react-native', '.github/workflows/fastlane-ios-debug.yaml', 'in.juspay.yatrisathi',              'Yatri Sathi (Customer iOS)',     true),
  ('KeralaSavaari', 'customer', 'ios', 'nammayatri/ny-react-native', '.github/workflows/fastlane-ios-debug.yaml', 'in.mobility.keralasavaariconsumer',  'Kerala Savaari (Customer iOS)',  true),
  ('Bridge',        'customer', 'ios', 'nammayatri/ny-react-native', '.github/workflows/fastlane-ios-debug.yaml', 'com.mobility.movingtech',            'Bridge (Customer iOS)',          true),
  ('BharatTaxi',    'customer', 'ios', 'nammayatri/ny-react-native', '.github/workflows/fastlane-ios-debug.yaml', 'in.mobility.bharatTaxi',             'Bharat Taxi (Customer iOS)',     true),
  ('Lynx',          'customer', 'ios', 'nammayatri/ny-react-native', '.github/workflows/fastlane-ios-debug.yaml', 'in.mobility.international',          'Lynx (Customer iOS)',            true)
ON CONFLICT (name, surface, platform) DO NOTHING;
