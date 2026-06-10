-- Async, pre-computed release changelog summaries.
-- Generation runs in a background worker (forkFlow) keyed by content_key
-- (a hash of the commit range), so it is page-independent and survives the
-- request that triggered it. The status column doubles as a one-worker lock:
-- INSERT ... ON CONFLICT DO NOTHING RETURNING claims generation.
CREATE TABLE IF NOT EXISTS release_summary (
    id            SERIAL PRIMARY KEY,
    content_key   TEXT        NOT NULL,
    status        TEXT        NOT NULL DEFAULT 'pending',  -- 'pending' | 'ready' | 'failed'
    summary_long  TEXT,                                    -- AI prose, chunked + assembled
    summary_short TEXT,                                    -- AI 2-3 line synopsis
    model         TEXT,
    commit_count  INTEGER     NOT NULL DEFAULT 0,
    error         TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_release_summary_key ON release_summary (content_key);
