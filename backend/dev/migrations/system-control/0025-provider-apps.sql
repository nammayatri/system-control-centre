-- 0025-provider-apps.sql
-- Seed the provider (driver) mobile apps into app_catalog.
--
-- IMPORTANT: `name` must be the PROVIDER catalyst key (…Partner / …Driver), NOT
-- the customer name. SCC sends `name` verbatim as the workflow's `selected_apps`
-- input, and the provider workflow does `catalyst -extract <platform>_debug
-- --apps "$SELECTED_APPS"` — matched against provider/catalyst-supported-merchants.txt
-- (NammaYatriPartner, ManaYatriPartner, YatriPartner, OdishaYatriPartner,
-- YatriSathiDriver, KeralaSavaariPartner, BridgeDriver, BharatTaxiPartner,
-- MarutiSuzuki, LynxDriver). A non-matching name yields an empty matrix and the
-- build fails ("Unexpected value '' for strategy").
--
-- Packages are the driver applicationIds from
-- nammayatri/ny-react-native → provider/android/app/build.gradle (productFlavors).
-- These are the PROD (base) ids; debug builds append `.debug` (Android `master`
-- mode `applicationIdSuffix`). The per-env package values are set authoritatively
-- in env/{prod,debug}/03-provider-app-packages.sql.
-- iOS: only Bridge, KeralaSavaari, Lynx, NammaYatri, OdishaYatri, YatriSathi have an
-- iOS target (bundle id == the Android base id); ManaYatri/Yatri/MarutiSuzuki/
-- BharatTaxi have NO iOS app yet, so those iOS rows are disabled placeholders.
-- Workflows are the provider ones. ON CONFLICT is idempotent.

-- Rename any earlier rows seeded with the customer-style names (idempotent — a
-- no-op once the names are the catalyst keys, or on a fresh DB).
UPDATE app_catalog SET name = 'NammaYatriPartner'    WHERE surface = 'driver' AND name = 'NammaYatri';
UPDATE app_catalog SET name = 'ManaYatriPartner'     WHERE surface = 'driver' AND name = 'ManaYatri';
UPDATE app_catalog SET name = 'YatriPartner'         WHERE surface = 'driver' AND name = 'Yatri';
UPDATE app_catalog SET name = 'OdishaYatriPartner'   WHERE surface = 'driver' AND name = 'OdishaYatri';
UPDATE app_catalog SET name = 'YatriSathiDriver'     WHERE surface = 'driver' AND name = 'YatriSathi';
UPDATE app_catalog SET name = 'KeralaSavaariPartner' WHERE surface = 'driver' AND name = 'KeralaSavaari';
UPDATE app_catalog SET name = 'BridgeDriver'         WHERE surface = 'driver' AND name = 'Bridge';
UPDATE app_catalog SET name = 'BharatTaxiPartner'    WHERE surface = 'driver' AND name = 'BharatTaxi';
UPDATE app_catalog SET name = 'LynxDriver'           WHERE surface = 'driver' AND name = 'Lynx';
-- MarutiSuzuki already matches the catalyst key.

-- ─── Driver Android (enabled=true so usable immediately for debug builds) ────
INSERT INTO app_catalog (name, surface, platform, github_repo, workflow_path, package_name, display_label, enabled)
VALUES
  ('OdishaYatriPartner',   'driver', 'android', 'nammayatri/ny-react-native', '.github/workflows/provider-debug-apk-gen.yaml', 'in.mobility.odishayatripartner', 'Odisha Yatri (Driver Android)',  true),
  ('KeralaSavaariPartner', 'driver', 'android', 'nammayatri/ny-react-native', '.github/workflows/provider-debug-apk-gen.yaml', 'in.mobility.keralasavaari',      'Kerala Savaari (Driver Android)', true),
  ('NammaYatriPartner',    'driver', 'android', 'nammayatri/ny-react-native', '.github/workflows/provider-debug-apk-gen.yaml', 'in.juspay.nammayatripartner',    'Namma Yatri (Driver Android)',   true),
  ('ManaYatriPartner',     'driver', 'android', 'nammayatri/ny-react-native', '.github/workflows/provider-debug-apk-gen.yaml', 'in.mobility.manayatripartner',   'Mana Yatri (Driver Android)',    true),
  ('BridgeDriver',         'driver', 'android', 'nammayatri/ny-react-native', '.github/workflows/provider-debug-apk-gen.yaml', 'com.mobility.movingtechdriver',  'Bridge (Driver Android)',        true),
  ('LynxDriver',           'driver', 'android', 'nammayatri/ny-react-native', '.github/workflows/provider-debug-apk-gen.yaml', 'in.mobility.lynxdriver',         'Lynx (Driver Android)',          true),
  ('YatriSathiDriver',     'driver', 'android', 'nammayatri/ny-react-native', '.github/workflows/provider-debug-apk-gen.yaml', 'in.juspay.jatrisaathidriver',    'Yatri Sathi (Driver Android)',   true),
  -- YatriPartner has NO android_debug entry in provider/catalyst.yaml (prod only),
  -- so a debug build would yield an empty matrix → disabled for debug.
  -- ('YatriPartner',         'driver', 'android', 'nammayatri/ny-react-native', '.github/workflows/provider-debug-apk-gen.yaml', 'net.openkochi.yatripartner',     'Yatri (Driver Android)',         true),
  ('MarutiSuzuki',         'driver', 'android', 'nammayatri/ny-react-native', '.github/workflows/provider-debug-apk-gen.yaml', 'com.maruti.smartride',           'Maruti Suzuki (Driver Android)', true),
  ('BharatTaxiPartner',    'driver', 'android', 'nammayatri/ny-react-native', '.github/workflows/provider-debug-apk-gen.yaml', 'in.mobility.bharattaxidriver',   'Bharat Taxi (Driver Android)',   true)
ON CONFLICT (name, surface, platform) DO NOTHING;

-- ─── Driver iOS — ONLY the apps with a real iOS target (bundle id from
-- provider/ios/provider.xcodeproj). ManaYatri, Yatri, MarutiSuzuki and BharatTaxi
-- have NO iOS app, so they are intentionally omitted (no bundle id → no row).
-- Bundle id == the Android base id; disabled by default. ────
INSERT INTO app_catalog (name, surface, platform, github_repo, workflow_path, package_name, display_label, enabled)
VALUES
  ('OdishaYatriPartner',   'driver', 'ios', 'nammayatri/ny-react-native', '.github/workflows/provider-debug-ios-gen.yaml', 'in.mobility.odishayatripartner', 'Odisha Yatri (Driver iOS)',  true),
  ('KeralaSavaariPartner', 'driver', 'ios', 'nammayatri/ny-react-native', '.github/workflows/provider-debug-ios-gen.yaml', 'in.mobility.keralasavaari',      'Kerala Savaari (Driver iOS)', true),
  ('NammaYatriPartner',    'driver', 'ios', 'nammayatri/ny-react-native', '.github/workflows/provider-debug-ios-gen.yaml', 'in.juspay.nammayatripartner',    'Namma Yatri (Driver iOS)',   true),
  ('BridgeDriver',         'driver', 'ios', 'nammayatri/ny-react-native', '.github/workflows/provider-debug-ios-gen.yaml', 'com.mobility.movingtechdriver',  'Bridge (Driver iOS)',        true),
  ('LynxDriver',           'driver', 'ios', 'nammayatri/ny-react-native', '.github/workflows/provider-debug-ios-gen.yaml', 'in.mobility.lynxdriver',         'Lynx (Driver iOS)',          true),
  ('YatriSathiDriver',     'driver', 'ios', 'nammayatri/ny-react-native', '.github/workflows/provider-debug-ios-gen.yaml', 'in.juspay.jatrisaathidriver',    'Yatri Sathi (Driver iOS)',   true)
ON CONFLICT (name, surface, platform) DO NOTHING;
