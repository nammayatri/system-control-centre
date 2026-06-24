-- 0035-mobile-build-code-identity.sql
-- Revise the mobile-release identity from VERSION NAME to (VERSION NAME + BUILD NUMBER).
--
-- Migration 0034 keyed a mobile release on (app_group, service, env, new_version) alone.
-- That is too strict for the real workflow: multiple INTERNAL builds can share a version
-- name but differ by build number (3.3.16+134, 3.3.16+135, ...), and an operator later
-- promotes ONE of them to prod. The name-only unique index blocked creating a second build
-- of the same name (raw 23505 -> INTERNAL_ERROR, e.g. KeralaSavaari customer android 3.3.16).
--
-- The build number (Android versionCode / iOS build number) is part of the TRUE identity —
-- it's what the stores use to uniquely identify a build, and every build always has one.
-- So the identity becomes (app_group, service, env, new_version, version_code).
--
-- This (a) lets multiple builds of one version name coexist, while (b) still blocking the
-- original "two rows for one build" bug (same name AND code, different modes — BharatTaxi
-- INREVIEW-while-rolling-out), because those rows share the same (name, code).

BEGIN;

-- 1) First-class build-number column (mobile-only; NULL for backend rows).
ALTER TABLE release_tracker ADD COLUMN IF NOT EXISTS version_code integer;

-- 2a) Backfill from the persisted target_state JSON (column release_context). The
--     MobileBuildState ToJSON wraps the context under contents.mbContext.
UPDATE release_tracker
SET version_code = (release_context::jsonb #>> '{contents,mbContext,version_code}')::int
WHERE category = 'MobileBuild'
  AND version_code IS NULL
  AND release_context IS NOT NULL
  AND (release_context::jsonb #>> '{contents,mbContext,version_code}') IS NOT NULL;

-- 2b) Backfill any remaining store-sync snapshot rows from metadata.tracks.<store_track>.code.
UPDATE release_tracker
SET version_code = (metadata::jsonb -> 'tracks' -> store_track ->> 'code')::int
WHERE category = 'MobileBuild'
  AND version_code IS NULL
  AND store_track IS NOT NULL
  AND metadata IS NOT NULL
  AND (metadata::jsonb -> 'tracks' -> store_track ->> 'code') IS NOT NULL;

-- 2c) A NULL-code row sitting next to a REAL coded build of the same version is a bogus
--     reflection (the iOS rollout-reflection seeded a row without a build number, and
--     NULL-distinct let it repeat every sync). Repoint its events to the coded row and drop it.
CREATE TEMP TABLE _mb_bogus_null ON COMMIT DROP AS
SELECT l.id AS lose_id,
       (SELECT k.id FROM release_tracker k
          WHERE k.category = 'MobileBuild' AND k.version_code IS NOT NULL
            AND k.app_group = l.app_group AND k.service = l.service
            AND k.env = l.env AND k.new_version = l.new_version
          ORDER BY k.last_updated DESC LIMIT 1) AS keep_id
FROM release_tracker l
WHERE l.category = 'MobileBuild' AND l.version_code IS NULL
  AND EXISTS (SELECT 1 FROM release_tracker k
                WHERE k.category = 'MobileBuild' AND k.version_code IS NOT NULL
                  AND k.app_group = l.app_group AND k.service = l.service
                  AND k.env = l.env AND k.new_version = l.new_version);

UPDATE release_events e SET re_release_id = b.keep_id FROM _mb_bogus_null b WHERE e.re_release_id = b.lose_id;
DELETE FROM release_tracker t USING _mb_bogus_null b WHERE t.id = b.lose_id;

-- 2d) Collapse any remaining rows that still collide under COALESCE(version_code, -1)
--     (e.g. several NULL-code rows of a version with no coded sibling). Keep the most-advanced.
CREATE TEMP TABLE _mb_code_collapse ON COMMIT DROP AS
WITH ranked AS (
  SELECT id,
    row_number() OVER w AS rn,
    first_value(id) OVER w AS keep_id
  FROM release_tracker
  WHERE category = 'MobileBuild'
  WINDOW w AS (
    PARTITION BY app_group, service, env, new_version, COALESCE(version_code, -1)
    ORDER BY (rollout_status IS NOT NULL) DESC, (status <> 'COMPLETED') DESC, last_updated DESC
  )
)
SELECT id AS lose_id, keep_id FROM ranked WHERE rn > 1;

UPDATE release_events e SET re_release_id = c.keep_id FROM _mb_code_collapse c WHERE e.re_release_id = c.lose_id;
DELETE FROM release_tracker t USING _mb_code_collapse c WHERE t.id = c.lose_id;

-- 3) Replace the name-only index with the (name, build-number) index. The new key is
--    strictly LOOSER than 0034's (every row that passed name-only also passes name+code),
--    so no de-dup pass is needed. Same (name, code) is still unique → the original bug
--    stays fixed.
--    COALESCE(version_code, -1): Postgres treats NULLs as DISTINCT in a unique index, so two
--    rows with a NULL code (e.g. an iOS rollout reflection that has no build number) would
--    NOT dedup and would multiply every sync. Folding NULL -> -1 makes all code-less rows of
--    the same version collapse to one, while real distinct codes stay distinct.
DROP INDEX IF EXISTS uq_release_tracker_mobile_version;

CREATE UNIQUE INDEX IF NOT EXISTS uq_release_tracker_mobile_build
  ON release_tracker (app_group, service, env, new_version, COALESCE(version_code, -1))
  WHERE category = 'MobileBuild';

COMMIT;
