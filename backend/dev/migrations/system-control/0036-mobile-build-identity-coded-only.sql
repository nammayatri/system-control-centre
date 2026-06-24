-- 0036-mobile-build-identity-coded-only.sql
-- Make the version_code COLUMN mean "the STORE-identity code", and key the unique index
-- purely off it. A build owns a (version, code) identity only when it actually publishes
-- to a versioned app store (Google Play production / App Store) under that code.
--
-- Background: migration 0035 keyed every MobileBuild row on
--   (app_group, service, env, new_version, COALESCE(version_code, -1)).
-- That over-constrained builds whose code legitimately REPEATS and so own no identity:
--   * debug builds — ResolveVersion skips store resolution, so they have no code; and
--   * Firebase App Distribution builds (provider, destination='Firebase') — pushed to
--     Firebase, NOT Play, so Play's code isn't advanced and the NEXT build re-resolves the
--     SAME (name, code). Two such builds collided once the column became accurate.
--
-- The rule now lives in ONE place in Haskell: `claimsStoreIdentity` (Mobile/Types.hs),
-- which gates the version_code COLUMN write in toRow / mkMobileTrackerRow — so the column
-- carries a code ONLY for store-bound builds (the code still lives in the target_state
-- JSON for display either way). With the column gated, this index needs no JSON predicate:
-- it simply keys on a non-NULL column. (Allowlist in Haskell: non-debug AND destination in
-- {NULL, 'GooglePlay'} — a new internal destination defaults to NO identity.)
--
-- This migration brings EXISTING data in line with that gate, then rebuilds the index.

BEGIN;

-- 1) Backfill: NULL the column for any row that does NOT claim a store identity — i.e. the
--    negation of `claimsStoreIdentity` (debug, OR destination not in {NULL,'GooglePlay'}).
--    Their code stays in the JSON; only the identity column is cleared.
UPDATE release_tracker
SET version_code = NULL
WHERE category = 'MobileBuild'
  AND version_code IS NOT NULL
  AND NOT (
        COALESCE(release_context::jsonb #>> '{contents,mbContext,build_type}', 'release') <> 'debug'
        AND COALESCE(release_context::jsonb #>> '{contents,mbContext,destination}', '') IN ('', 'GooglePlay')
      );

-- 2) With the column gated at the write path, the unique index keys purely on a non-NULL
--    code. Store-published builds keep strict (name, code) uniqueness (the original "two
--    rows for one build" bug stays fixed); debug / Firebase / not-yet-resolved rows have a
--    NULL column and are unconstrained.
DROP INDEX IF EXISTS uq_release_tracker_mobile_build;

CREATE UNIQUE INDEX IF NOT EXISTS uq_release_tracker_mobile_build
  ON release_tracker (app_group, service, env, new_version, version_code)
  WHERE category = 'MobileBuild' AND version_code IS NOT NULL;

COMMIT;
