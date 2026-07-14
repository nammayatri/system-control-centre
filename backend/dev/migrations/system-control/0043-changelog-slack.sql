-- 0043: changelog_slack_sent_at — durable per-GROUP claim marker so a release's
-- changelog is posted to Slack ONCE per release_group_id, not once per app.
-- Claimed by one atomic conditional UPDATE (the compare-and-swap):
--   UPDATE release_tracker SET changelog_slack_sent_at = now()
--   WHERE release_group_id = :gid AND changelog_slack_sent_at IS NULL
-- posting only if affected rows > 0. Under READ COMMITTED the row write-lock +
-- predicate recheck make exactly one caller flip the group NULL->timestamp; the
-- rest see the committed marker and skip. Durable, so it also holds across a
-- runner restart. Deliberately NOT in the beam ReleaseTrackerT schema, so no
-- workflow persist can clobber it. No new index: release_group_id is already
-- covered by migration 0042; the IS NULL is a residual predicate.

ALTER TABLE release_tracker ADD COLUMN IF NOT EXISTS changelog_slack_sent_at TIMESTAMPTZ;


-- make the group changelog-Slack outcome a proper
-- tri-state (pending / sent / failed) instead of a single claim timestamp.
--
-- Until now the ONLY durable signal was 0043's changelog_slack_sent_at, stamped
-- at CLAIM time (before the POST) and never rolled back. A failed Slack POST
-- therefore looked identical to a success and permanently blocked any retry
-- (the account_inactive incident: group 771f900b claimed at 08:23:58, POST
-- returned ok=false, marker stayed stamped, nothing ever posted).
--
-- New model — state is derived from (opted_in, sent_at, error):
--   sent_at IS NOT NULL, error IS NULL  -> sent      (claim held + POST ok)
--   sent_at IS NULL,     error NOT NULL -> failed     (claim released on failure)
--   both NULL                           -> pending / not-yet
-- The send path now RELEASES the claim (sent_at -> NULL) and records the Slack
-- error on failure, so the next build-settle OR the manual "Resend to Slack"
-- button can re-win the CAS and re-post.
--
-- Writer discipline: like sent_at, this column is raw-SQL only — deliberately
-- NOT in the beam ReleaseTrackerT schema, so no workflow persist can clobber it.
-- No new index: release_group_id is already covered by 0042.

ALTER TABLE release_tracker ADD COLUMN IF NOT EXISTS changelog_slack_error TEXT;