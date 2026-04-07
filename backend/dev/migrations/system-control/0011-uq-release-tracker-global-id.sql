-- Add unique partial index on release_tracker.global_id so concurrent
-- cross-cloud sync POSTs cannot create duplicate trackers when the
-- Haskell-level idempotency check loses the race.
-- Partial: only enforces when global_id IS NOT NULL (the common case
-- for human-originated releases is NULL and stays unconstrained).

CREATE UNIQUE INDEX IF NOT EXISTS uq_release_tracker_global_id
  ON release_tracker (global_id) WHERE global_id IS NOT NULL;
