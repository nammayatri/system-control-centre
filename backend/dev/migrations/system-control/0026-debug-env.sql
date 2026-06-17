-- 0026-debug-env.sql
--
-- DEBUG / INTEG environment config, consolidated into ONE file (the env/debug/00..03
-- overrides folded together). Sets:
--   • mobile_build_type = debug
--   • store_sync_enabled / version_preview_enabled = false
--   • every seeded app → its DEBUG workflow
--   • provider (driver) apps → their `.debug` applicationIds / bundle ids
-- Runs in the common pass, AFTER the 0011/0025 seeds, so its UPDATEs win.
--
-- ⚠️ PROD WARNING — this lives in the common pass, which runs for EVERY environment.
-- It applies DEBUG values everywhere. That's correct for a debug/INTEG deployment.
-- For a PRODUCTION deployment you MUST override these with release values
-- (mobile_build_type=release, prod fastlane workflows, base package ids) by running
-- the env/prod/* migrations after this — otherwise prod would build debug APKs on
-- debug workflows with `.debug` package ids. If you ship to prod, do NOT rely on this
-- file alone.

-- ── mobile build type = debug (Firebase + TestFlight) ───────────────────────────
UPDATE server_config SET value = 'debug', enabled = 1 WHERE name = 'mobile_build_type';
INSERT INTO server_config (name, type, value, enabled, product)
SELECT 'mobile_build_type', 'STRING', 'debug', 1, 'autopilot'
WHERE NOT EXISTS (
    SELECT 1 FROM server_config WHERE name = 'mobile_build_type' AND product = 'autopilot'
);

-- ── store sync / version preview OFF (no Play / App Store presence) ──────────────
UPDATE server_config SET value = 'false'
WHERE name IN ('store_sync_enabled', 'version_preview_enabled') AND product = 'autopilot';

-- ── point every seeded app at its DEBUG workflow ────────────────────────────────
UPDATE app_catalog
SET workflow_path = CASE platform
    WHEN 'android' THEN '.github/workflows/fastlane-android-debug.yaml'
    WHEN 'ios'     THEN '.github/workflows/fastlane-ios-debug.yaml'
    ELSE workflow_path
END
WHERE github_repo = 'nammayatri/ny-react-native' AND surface = 'customer';

UPDATE app_catalog
SET workflow_path = CASE platform
    WHEN 'android' THEN '.github/workflows/provider-debug-apk-gen.yaml'
    WHEN 'ios'     THEN '.github/workflows/provider-debug-ios-gen.yaml'
    ELSE workflow_path
END
WHERE github_repo = 'nammayatri/ny-react-native' AND surface = 'driver';

-- ── provider (driver) debug applicationIds / bundle ids ─────────────────────────
-- Android = <prod id>.debug (build.gradle `master` mode applicationIdSuffix).
-- iOS: .debug where the Xcode target defines a Debug bundle (Bridge/NammaYatri/
-- OdishaYatri/YatriSathi); base id for KeralaSavaari & Lynx (no Debug config);
-- ManaYatri/Yatri/MarutiSuzuki/BharatTaxi have no iOS row (no iOS app).
UPDATE app_catalog SET package_name = 'in.juspay.nammayatripartner.debug'    WHERE surface = 'driver' AND name = 'NammaYatriPartner';
UPDATE app_catalog SET package_name = 'in.mobility.odishayatripartner.debug' WHERE surface = 'driver' AND name = 'OdishaYatriPartner';
UPDATE app_catalog SET package_name = 'in.juspay.jatrisaathidriver.debug'    WHERE surface = 'driver' AND name = 'YatriSathiDriver';
UPDATE app_catalog SET package_name = 'com.mobility.movingtechdriver.debug'  WHERE surface = 'driver' AND name = 'BridgeDriver';
UPDATE app_catalog SET package_name = 'in.mobility.manayatripartner.debug'   WHERE surface = 'driver' AND name = 'ManaYatriPartner';
UPDATE app_catalog SET package_name = 'net.openkochi.yatripartner.debug'     WHERE surface = 'driver' AND name = 'YatriPartner';
UPDATE app_catalog SET package_name = 'in.mobility.bharattaxidriver.debug'   WHERE surface = 'driver' AND name = 'BharatTaxiPartner';
UPDATE app_catalog SET package_name = 'com.maruti.smartride.debug'           WHERE surface = 'driver' AND name = 'MarutiSuzuki';

UPDATE app_catalog SET package_name = CASE platform
    WHEN 'android' THEN 'in.mobility.keralasavaari.debug'
    WHEN 'ios'     THEN 'in.mobility.keralasavaari'
  END
WHERE surface = 'driver' AND name = 'KeralaSavaariPartner' AND platform IN ('android', 'ios');

UPDATE app_catalog SET package_name = CASE platform
    WHEN 'android' THEN 'in.mobility.lynxdriver.debug'
    WHEN 'ios'     THEN 'in.mobility.lynxdriver'
  END
WHERE surface = 'driver' AND name = 'LynxDriver' AND platform IN ('android', 'ios');
