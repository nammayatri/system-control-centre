-- 0027-staged-rollout.sql
-- Promote-to-review + staged-rollout state, tracked per release on release_tracker.
-- See docs/superpowers/plans/2026-06-09-promote-review-and-staged-rollout.md (Phase 1).
--
-- NOTE vs the plan: the plan called this "0026" (repo was at 0025 when it was written),
-- but 0026 was taken by 0026-debug-env.sql since — so this is 0027. And the plan's
-- `rollout_history` is named `store_rollout_history` here, because a `rollout_history`
-- column already exists on release_tracker (the backend K8s staggered-rollout history,
-- a different shape). store_rollout_history holds the mobile [RolloutStage] JSON.

ALTER TABLE release_tracker
  ADD COLUMN IF NOT EXISTS review_status         TEXT,             -- in_review | approved | rejected (iOS); submitted | live (Android)
  ADD COLUMN IF NOT EXISTS review_submitted_at   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS review_decided_at     TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS review_reject_reason  TEXT,
  ADD COLUMN IF NOT EXISTS rollout_status        TEXT,             -- rolling_out | halted | completed
  ADD COLUMN IF NOT EXISTS rollout_percent       DOUBLE PRECISION, -- current live % (0.0000001–100)
  ADD COLUMN IF NOT EXISTS store_rollout_history TEXT,             -- JSON [{percent, startedAt, endedAt, notes, actor}]
  ADD COLUMN IF NOT EXISTS asc_version_id        TEXT,             -- iOS: App Store version id (cached)
  ADD COLUMN IF NOT EXISTS asc_phased_id         TEXT;             -- iOS: phased-release id (pause/resume)

CREATE INDEX IF NOT EXISTS idx_rt_review_status  ON release_tracker(review_status)  WHERE review_status  IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_rt_rollout_status ON release_tracker(rollout_status) WHERE rollout_status IS NOT NULL;
