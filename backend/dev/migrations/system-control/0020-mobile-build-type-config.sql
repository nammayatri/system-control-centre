-- 0020-mobile-build-type-config.sql
-- Build type for this deployment env. One value per environment:
--   master  → 'debug'   (Firebase / TestFlight)
--   prod    → 'release' (Google Play / App Store)
-- Stamped onto each release at creation time (mbcBuildType in the
-- MobileBuildContext). Default 'release' in code; local dev runs as debug.

INSERT INTO server_config (name, type, value, enabled, product)
VALUES ('mobile_build_type', 'STRING', 'debug', 1, 'autopilot')
ON CONFLICT DO NOTHING;
