-- 0034-mobile-version-identity.sql
-- Permanent fix: ONE release_tracker row per (app_group, service, env, new_version)
-- for mobile builds, regardless of who created it (SCC or out-of-band) or which
-- "mode" it passed through (MANUAL / STORE_SYNC / EXTERNAL_REVIEW).
--
-- Before this, identity was effectively (version, mode): the per-mode partial unique
-- indexes (uq_release_tracker_store_sync WHERE mode='STORE_SYNC',
-- uq_release_tracker_external_review WHERE mode='EXTERNAL_REVIEW') had DISJOINT
-- predicates, so one version could hold a STORE_SYNC rollout-mirror row AND an
-- EXTERNAL_REVIEW in-review row at the same time — the "INREVIEW while rolling out"
-- bug class. The only thing preventing it was app-level dedup, which kept leaking.
--
-- This migration makes VERSION the identity:
--   1. adds a first-class `store_track` column (was buried in metadata JSON),
--   2. backfills it (production lifecycle states imply the production track),
--   3. collapses any existing same-version duplicates to a single row (keeping the
--      most-advanced, repointing release_events so audit history survives),
--   4. replaces the two per-mode indexes with one version-keyed index.
--
-- The index is strict (one row per version, any state): mobile stores never reuse a
-- version code, so a version legitimately appears exactly once — there is no revert /
-- re-release case that needs a second row for the same version.

BEGIN;

-- 1) First-class, monotonic track attribute (internal -> production).
ALTER TABLE release_tracker ADD COLUMN IF NOT EXISTS store_track text;

-- 2a) Backfill from the metadata JSON snapshot where present.
UPDATE release_tracker
SET store_track = metadata::jsonb ->> 'store_track'
WHERE category = 'MobileBuild'
  AND store_track IS NULL
  AND metadata IS NOT NULL
  AND (metadata::jsonb ? 'store_track');

-- 2b) Any production-lifecycle state (in review / approved / rejected / rolling /
--     halted / superseded) is on the production track by definition.
UPDATE release_tracker
SET store_track = 'production'
WHERE category = 'MobileBuild'
  AND store_track IS DISTINCT FROM 'production'
  AND (review_status IS NOT NULL OR rollout_status IS NOT NULL OR mode = 'EXTERNAL_REVIEW');

-- 3) Collapse same-version duplicates to one row.
--    Advancement rank (keeper = rn 1): a live/halted/superseded rollout outranks an
--    approved-held review, which outranks any in-review/rejected (INPROGRESS) row,
--    which outranks a plain COMPLETED snapshot. Tie-break: most recently updated.
--    Every key is NULL-safe (COALESCE / IS [NOT] NULL) — a bare boolean like
--    `review_status = 'approved'` is NULL when review_status is NULL, and NULLs sort
--    FIRST under DESC, which would wrongly rank a stateless snapshot above an active row.
CREATE TEMP TABLE _mb_collapse ON COMMIT DROP AS
WITH ranked AS (
  SELECT id, app_group, service, env, new_version,
    row_number() OVER (
      PARTITION BY app_group, service, env, new_version
      ORDER BY
        (rollout_status IS NOT NULL) DESC,                 -- rolling / halted / superseded
        COALESCE(review_status = 'approved', false) DESC,  -- approved-held
        (status <> 'COMPLETED') DESC,                      -- INPROGRESS (in_review / rejected)
        (review_status IS NOT NULL) DESC,                  -- any review state beats a bare snapshot
        last_updated DESC
    ) AS rn
  FROM release_tracker
  WHERE category = 'MobileBuild'
)
SELECT r.id AS lose_id, k.id AS keep_id
FROM ranked r
JOIN ranked k
  ON (r.app_group, r.service, r.env, r.new_version)
   = (k.app_group, k.service, k.env, k.new_version)
 AND k.rn = 1
WHERE r.rn > 1;

-- 3a) Repoint audit events from the dropped rows onto the keeper (no FK, safe).
UPDATE release_events e
SET re_release_id = c.keep_id
FROM _mb_collapse c
WHERE e.re_release_id = c.lose_id;

-- 3b) Drop the redundant duplicate rows.
DELETE FROM release_tracker t
USING _mb_collapse c
WHERE t.id = c.lose_id;

-- 4) One row per version for mobile builds, across all modes/origins. Replaces the
--    two disjoint per-mode indexes.
DROP INDEX IF EXISTS uq_release_tracker_store_sync;
DROP INDEX IF EXISTS uq_release_tracker_external_review;

CREATE UNIQUE INDEX IF NOT EXISTS uq_release_tracker_mobile_version
  ON release_tracker (app_group, service, env, new_version)
  WHERE category = 'MobileBuild';

COMMIT;
