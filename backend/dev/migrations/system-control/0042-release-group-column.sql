-- 0042: release_group_id as a real, indexed column (+ optional label).
--
-- Until now the group id lived ONLY inside the release_context TEXT JSON of
-- each row (MobileBuildContext.release_group_id), so "all releases of group X"
-- had no SQL access path — the FE aggregated a 24h window client-side. This
-- column is the Phase-1 foundation of the fleet-release design
-- (docs/MOBILE_FLEET_RELEASE_DESIGN.md §4).
--
-- Writer discipline: the column is stamped ONLY at row creation
-- (mkMobileTrackerRow / insertMobileRevertTracker / insertSyntheticRelease).
-- It is deliberately absent from insertReleaseTracker's upsert SET list and
-- casUpdateWorkflowCols, so workflow persists can never clobber it — same
-- protection as the setPhase-owned lifecycle columns.

ALTER TABLE release_tracker ADD COLUMN IF NOT EXISTS release_group_id TEXT;
ALTER TABLE release_tracker ADD COLUMN IF NOT EXISTS release_group_label TEXT;

CREATE INDEX IF NOT EXISTS idx_rt_release_group_id
    ON release_tracker (release_group_id)
    WHERE release_group_id IS NOT NULL;


