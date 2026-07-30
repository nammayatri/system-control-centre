-- 0048: realign uq_release_tracker_mobile_build to its canonical definition.
--
-- Early deployments created this index with COALESCE(version_code, -1) in the
-- key and NO predicate, which also enforces uniqueness over VERSION-LESS rows
-- (new_version = '', version_code NULL). Debug/master builds are inherently
-- version-less at create (the debug workflow hard-codes versionName "99.0.0"
-- at build time and stamps nothing back), so the second debug draft for an app
-- fails with 23505 on (app, service, env, '', -1).
--
-- The canonical shape (0034, current) is partial on version_code IS NOT NULL:
-- identity is enforced only once a build has a real (version, code) pair.
-- CREATE INDEX IF NOT EXISTS never repairs an existing wrong-shaped index —
-- drop and recreate. Idempotent.
DROP INDEX IF EXISTS uq_release_tracker_mobile_build;
CREATE UNIQUE INDEX IF NOT EXISTS uq_release_tracker_mobile_build
  ON release_tracker (app_group, service, env, new_version, version_code)
  WHERE category = 'MobileBuild' AND version_code IS NOT NULL;
