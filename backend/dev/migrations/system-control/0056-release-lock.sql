-- 0056: release lock — stop new releases for a whole app group or one service.
--
-- service = '' means the lock covers the entire app group; otherwise it covers
-- that one service. A release is blocked when EITHER its group lock or its
-- service lock exists. Not cloud-scoped: a lock is an operator decision about
-- the service, not about one cloud's copy of it.
--
-- Only creating a NEW release is blocked. Releases already in flight keep
-- running, and revert/rollback stay available so a lock never traps a bad one.

CREATE TABLE IF NOT EXISTS release_lock (
  app_group TEXT NOT NULL,
  service TEXT NOT NULL DEFAULT '',
  reason TEXT NOT NULL DEFAULT '',
  locked_by TEXT NOT NULL,
  locked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (app_group, service)
);
