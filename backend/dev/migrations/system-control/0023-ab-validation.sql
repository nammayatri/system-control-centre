-- 0023-ab-validation.sql
-- AB Validation tracking on release_tracker.
--
-- After a release reaches a terminal state (COMPLETED / ABORTED / REVERTED),
-- an analyst can classify the AB test outcome:
--
--   UNASSIGNED  — not yet validated (default)
--   VERIFIED    — AB test correctly identified the outcome
--   MISSED_ABORT— should have aborted but did not (false negative)
--   FALSE_ABORT — aborted but shouldn't have (false positive)
--   TRUE_ABORT  — correctly aborted by the AB engine
--   INVALID     — release not applicable to AB validation
--
-- ab_validation stores the full JSON object:
--   { status, is_approved, rca_description, history: [...] }

ALTER TABLE release_tracker
  ADD COLUMN IF NOT EXISTS ab_validation_status VARCHAR DEFAULT 'UNASSIGNED',
  ADD COLUMN IF NOT EXISTS ab_validation        JSONB;

CREATE INDEX IF NOT EXISTS idx_rt_ab_validation_status
  ON release_tracker (ab_validation_status);
