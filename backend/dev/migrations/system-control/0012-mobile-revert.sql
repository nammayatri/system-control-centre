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
