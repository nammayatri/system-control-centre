-- 0028-external-review-dedup.sql
-- Dedup guard for synthetic out-of-band review rows.
--
-- store sync surfaces an App Store version that's in review but was NOT submitted
-- from SCC as a synthetic INPROGRESS row (mode = 'EXTERNAL_REVIEW'). Two
-- concurrent sync passes — or two SCC replicas of the same env — could each
-- insert a row for the same app before either commits. A partial unique index
-- makes the second a no-op: the insert uses ON CONFLICT DO NOTHING (see
-- insertReleaseTrackerRowIfAbsent). Mirrors uq_release_tracker_store_sync.
--
-- There is at most one ACTIVE review-phase external row per (app, surface,
-- platform). Once an operator releases it (rollout_status is set) the row leaves
-- the index, so a later in-flight version can still get its own row.

-- Clear any pre-existing duplicates first (keep the most recent per identity) so
-- the unique index can be created. Synthetic rows are re-derivable from the store
-- on the next sync, so dropping older copies is safe.
DELETE FROM release_tracker rt
USING (
  SELECT id, ROW_NUMBER() OVER (
    PARTITION BY app_group, service, env
    ORDER BY date_created DESC
  ) AS rn
  FROM release_tracker
  WHERE mode = 'EXTERNAL_REVIEW' AND status = 'INPROGRESS' AND rollout_status IS NULL
) dup
WHERE rt.id = dup.id AND dup.rn > 1;

CREATE UNIQUE INDEX IF NOT EXISTS uq_release_tracker_external_review
  ON release_tracker (app_group, service, env)
  WHERE mode = 'EXTERNAL_REVIEW' AND status = 'INPROGRESS' AND rollout_status IS NULL;
