-- 0039-mobile-failed-build-release-identity.sql
-- A failed/aborted mobile build never shipped, so it must release its version-code
-- identity slot (design doc §3d) — otherwise a rebuild with the same version + code
-- hits the unique index (the 23505-on-retry-after-abort bug). Going forward `toRow`
-- NULLs the column on MBAborted / MBFailed; this backfills the existing stuck rows.
--
-- Aborted = USER_ABORTED (MBAborted); Failed = ABORTED with an MBFailed wf-status.
-- REJECTED (also ABORTED, but MBReviewRejected) KEEPS its slot — it reached the store.

UPDATE release_tracker
SET version_code = NULL
WHERE category = 'MobileBuild'
  AND version_code IS NOT NULL
  AND ( status = 'USER_ABORTED'
        OR ( status = 'ABORTED' AND release_context::text LIKE '%"tag":"MBFailed"%' ) );
