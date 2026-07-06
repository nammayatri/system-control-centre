-- 0032-fix-bridge-package.sql
-- Bridge (Customer) had the wrong store id. Source of truth nammayatri/ny-react-native:
--   consumer/android/app/build.gradle  → bridge flavor applicationId = com.mobility.movingtech
--   nammayatri-ios (consumer)           → PRODUCT_BUNDLE_IDENTIFIER     = com.mobility.movingtech
-- The seed had 'com.mobility.bridge', which exists on neither Play nor the App Store
-- (play_package_not_found / asc_app_not_found). Correct it for already-applied DBs;
-- fresh DBs get the right value from 0011 directly.

UPDATE app_catalog
SET package_name = 'com.mobility.movingtech'
WHERE name = 'Bridge' AND surface = 'customer' AND package_name = 'com.mobility.bridge';
