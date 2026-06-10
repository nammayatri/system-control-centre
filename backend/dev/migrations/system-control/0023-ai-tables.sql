-- 0023-ai-tables.sql
-- AI integration (Grid / LiteLLM): summary cache + audit log, plus the
-- server_config knobs (product 'autopilot') so they appear in the Config tab.
-- AI is OFF by default (ai_enabled = false). Idempotent.

-- Memoise expensive AI calls. Keyed by content (subject_type, subject_id, task,
-- model, prompt_hash) on a PLAIN unique index — TTL is enforced at query time
-- (cache_valid_until > now()) and the upsert refreshes the row. We do NOT use a
-- partial index on now() (index predicates must be IMMUTABLE).
CREATE TABLE IF NOT EXISTS ai_summary_cache (
  id                SERIAL PRIMARY KEY,
  subject_type      TEXT NOT NULL,
  subject_id        TEXT NOT NULL,
  task              TEXT NOT NULL,
  model             TEXT NOT NULL,
  prompt_hash       TEXT NOT NULL,
  summary           TEXT NOT NULL,
  input_tokens      INTEGER NOT NULL DEFAULT 0,
  output_tokens     INTEGER NOT NULL DEFAULT 0,
  cache_valid_until TIMESTAMPTZ NOT NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_ai_cache_key
  ON ai_summary_cache (subject_type, subject_id, task, model, prompt_hash);
CREATE INDEX IF NOT EXISTS idx_ai_cache_expiry ON ai_summary_cache (cache_valid_until);

-- Append-only audit of every AI call (hit / ok / error) for cost + incident review.
CREATE TABLE IF NOT EXISTS ai_audit_log (
  id            SERIAL PRIMARY KEY,
  subject_type  TEXT NOT NULL,
  subject_id    TEXT NOT NULL,
  task          TEXT NOT NULL,
  model         TEXT NOT NULL,
  prompt_hash   TEXT NOT NULL,
  input_tokens  INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  latency_ms    INTEGER NOT NULL DEFAULT 0,
  status        TEXT NOT NULL,
  error         TEXT,
  created_by    TEXT NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ai_audit_subject ON ai_audit_log (subject_type, subject_id);
CREATE INDEX IF NOT EXISTS idx_ai_audit_created_at ON ai_audit_log (created_at DESC);

-- Config knobs (editable in the Config tab). Secret (SC_AI_API_KEY) stays in env.
INSERT INTO server_config (name, type, value, enabled, product)
VALUES ('ai_enabled', 'BOOL', 'false', 1, 'autopilot')
ON CONFLICT DO NOTHING;

INSERT INTO server_config (name, type, value, enabled, product)
VALUES ('ai_base_url', 'STRING', 'https://grid.ai.juspay.net', 1, 'autopilot')
ON CONFLICT DO NOTHING;

INSERT INTO server_config (name, type, value, enabled, product)
VALUES ('ai_model', 'STRING', 'glm-flash-experimental', 1, 'autopilot')
ON CONFLICT DO NOTHING;

INSERT INTO server_config (name, type, value, enabled, product)
VALUES ('ai_allowed_host_suffix', 'STRING', 'grid.ai.juspay.net', 1, 'autopilot')
ON CONFLICT DO NOTHING;

INSERT INTO server_config (name, type, value, enabled, product)
VALUES ('ai_temperature', 'DOUBLE', '0.2', 1, 'autopilot')
ON CONFLICT DO NOTHING;

INSERT INTO server_config (name, type, value, enabled, product)
VALUES ('ai_cache_ttl_hours', 'INT', '168', 1, 'autopilot')
ON CONFLICT DO NOTHING;
