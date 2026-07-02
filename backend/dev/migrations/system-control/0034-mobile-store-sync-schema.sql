-- Mobile store-sync schema (§16 SSOT): the columns + unique indexes behind the
-- (version, code)-keyed mobile build identity. STRUCTURE ONLY — no data fixes:
-- a fresh database has nothing to fix, and store sync repopulates every mobile
-- row/cell on the first refresh. (One-time data remediation for environments
-- deployed BEFORE this schema ships separately, uncommitted:
-- scripts/prod-upgrade-store-sync-ssot.sql.)

-- release_tracker — the build's durable identity + lifecycle columns.
--   version_code    — store build number; with new_version it IS the identity.
--   store_track     — internal | testflight | production (bound-or-live track).
--   terminal_status — write-once outcome (RELEASED | SUPERSEDED | ABORTED),
--                     stamped by setPhase on the first terminal transition.
ALTER TABLE release_tracker ADD COLUMN IF NOT EXISTS version_code INTEGER;
ALTER TABLE release_tracker ADD COLUMN IF NOT EXISTS store_track TEXT;
ALTER TABLE release_tracker ADD COLUMN IF NOT EXISTS terminal_status TEXT;

-- store_status is pure store truth — a review verdict is a decision about a
-- build and lives on its release_tracker row (0030 predates this split).
ALTER TABLE store_status DROP COLUMN IF EXISTS review_status;

-- One STORE_SYNC snapshot per (app, service, env, version, code). Replaces the
-- version-only index from 0021; PG14 has no NULLS NOT DISTINCT, so COALESCE
-- collapses code-less rows to one per version while keeping real codes distinct.
DROP INDEX IF EXISTS uq_release_tracker_store_sync;
CREATE UNIQUE INDEX IF NOT EXISTS uq_release_tracker_store_sync
  ON release_tracker (app_group, service, env, new_version, COALESCE(version_code, -1))
  WHERE mode = 'STORE_SYNC';

-- Cross-mode build identity: at most ONE MobileBuild row per
-- (app_group, service, env, version name, version code), regardless of origin
-- (MANUAL / STORE_SYNC / EXTERNAL_REVIEW). Partial on version_code IS NOT NULL:
-- a MANUAL build before ConfirmTag stamps its code doesn't collide.
CREATE UNIQUE INDEX IF NOT EXISTS uq_release_tracker_mobile_build
  ON release_tracker (app_group, service, env, new_version, version_code)
  WHERE category = 'MobileBuild' AND version_code IS NOT NULL;

-- One live external-review row per app + version (the row store sync reconciles
-- in place each pass). Partial on INPROGRESS so completed review history never
-- blocks a later re-detection of the same version.
CREATE UNIQUE INDEX IF NOT EXISTS uq_release_tracker_external_review
  ON release_tracker (app_group, service, env, new_version)
  WHERE mode = 'EXTERNAL_REVIEW' AND status = 'INPROGRESS';
