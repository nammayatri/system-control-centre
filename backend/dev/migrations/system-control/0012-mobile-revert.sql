-- 0012-mobile-revert.sql
-- Mobile revert support:
--   * commit_sha          — captured per release once the GH run resolves
--                           (head_sha of the dispatched ref). Lets reverts
--                           verify the previous good release's commit.
--   * source_ref          — the git ref the workflow was dispatched on.
--                           NULL means "main" (existing behaviour). Revert
--                           releases set this to "refs/tags/<prev-good-tag>"
--                           so checkout lands on the previous good commit.
--   * reverts_release_id  — for revert releases, the ID of the release row
--                           being reverted. Drives the audit chain and the
--                           "↩ Reverts release X" / "⤴ Reverted by Y"
--                           banners.
-- All three columns are nullable. Existing rows leave them NULL and behave
-- exactly as before.

ALTER TABLE release_tracker
  ADD COLUMN IF NOT EXISTS commit_sha         TEXT,
  ADD COLUMN IF NOT EXISTS source_ref         TEXT,
  ADD COLUMN IF NOT EXISTS reverts_release_id TEXT;

CREATE INDEX IF NOT EXISTS idx_rt_commit_sha
  ON release_tracker(commit_sha);

CREATE INDEX IF NOT EXISTS idx_rt_reverts_release_id
  ON release_tracker(reverts_release_id);

-- At most one ACTIVE (non-terminal) revert per bad release.
--
-- Two operators (or a double-submitted form) could otherwise create two
-- revert rows pointing at the same `reverts_release_id`, producing duplicate
-- rollbacks. This partial unique index makes the second insert fail loudly
-- instead. Mirrors the uq_release_tracker_service_inflight pattern
-- (0002-add-indexes.sql): the predicate uses the same in-flight status set,
-- so once a revert reaches a terminal state (COMPLETED / FAILED / DISCARDED /
-- ABORTED) a fresh revert is permitted again — consistent with allowing
-- revert-of-a-revert and retry-after-failure. Scoped to rows that ARE reverts
-- (reverts_release_id IS NOT NULL); normal releases are unaffected.
CREATE UNIQUE INDEX IF NOT EXISTS uq_release_tracker_revert_inflight
  ON release_tracker (reverts_release_id)
  WHERE reverts_release_id IS NOT NULL
    AND status IN ('CREATED','INPROGRESS','PAUSED','ABORTING','REVERTING','RESTARTING','PREPARING');
