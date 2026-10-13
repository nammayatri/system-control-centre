-- 0053: Xyne release bot — one row per "@system-control-center-bot release X till <commit>"
-- request. The row is the durable state machine: webhook retries dedupe on
-- xyne_message_id, the worker resumes from `state` after a restart, and the
-- public read-only diff page renders from `data`.
--
-- Hot columns are real columns (indexed / CAS-updated); everything else lives in
-- `data` (JSONB) so the flow can evolve without a migration. Partial updates use
-- `data = data || patch` so the worker and the approval handler never clobber
-- each other's fields.

CREATE TABLE IF NOT EXISTS release_request (
  id TEXT PRIMARY KEY,
  state TEXT NOT NULL,
  xyne_message_id TEXT,
  xyne_channel TEXT,
  requester_email TEXT,
  expires_at TIMESTAMPTZ,
  data JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Xyne retries webhooks; a repeated message id must not create a second request.
CREATE UNIQUE INDEX IF NOT EXISTS uq_release_request_msg
  ON release_request (xyne_message_id) WHERE xyne_message_id IS NOT NULL;

-- The worker scans non-terminal rows.
CREATE INDEX IF NOT EXISTS idx_release_request_active
  ON release_request (state)
  WHERE state NOT IN ('COMPLETED', 'REJECTED', 'EXPIRED', 'FAILED', 'DENIED', 'INFO_ONLY');
