-- 0021-store-sync-dedup.sql
-- Dedup guard for synthetic store-sync release rows.
--
-- Store sync records the live store version as a COMPLETED release_tracker row
-- (mode = 'STORE_SYNC'). Two concurrent sync passes — or two SCC replicas of the
-- same env — could each insert a row for the same app + version. A partial
-- unique index makes the second a no-op: the insert uses ON CONFLICT DO NOTHING
-- (see insertReleaseTrackerRowIfAbsent). Mirrors the existing
-- uq_release_tracker_service_inflight / uq_release_tracker_global_id pattern.

-- Clear any pre-existing duplicates first so the unique index can be created.
-- Synthetic rows are re-derivable from the store on the next sync, so dropping
-- older copies (keeping the most recent per identity) is safe.
DELETE FROM release_tracker rt
USING (
  SELECT id, ROW_NUMBER() OVER (
    PARTITION BY app_group, service, env, new_version
    ORDER BY date_created DESC
  ) AS rn
  FROM release_tracker
  WHERE mode = 'STORE_SYNC'
) dup
WHERE rt.id = dup.id AND dup.rn > 1;

CREATE UNIQUE INDEX IF NOT EXISTS uq_release_tracker_store_sync
  ON release_tracker (app_group, service, env, new_version)
  WHERE mode = 'STORE_SYNC';
