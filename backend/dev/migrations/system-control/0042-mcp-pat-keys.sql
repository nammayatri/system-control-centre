CREATE TABLE IF NOT EXISTS mcp_pat_keys (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    person_id UUID NOT NULL REFERENCES sc_person(id) ON DELETE CASCADE,
    label TEXT NOT NULL,
    token_prefix TEXT NOT NULL,
    token_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    last_used_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ,
    UNIQUE (token_hash)
);

CREATE INDEX IF NOT EXISTS idx_mcp_pat_keys_person ON mcp_pat_keys(person_id);

ANALYZE;
