-- 0030-store-status.sql
-- App Release Monitoring: a per-track LIVE store-state cache.
--
-- The monitor dashboard is one DB read of this table. The StoreSync poller (and
-- the on-demand ↻ refresh) writes it: for every app in app_catalog — enabled OR
-- not, so the page shows EVERY app's live releases — it records each track's
-- current version / build code / status / staged-rollout % / review state /
-- "What's New" notes, plus expected_version (the last SCC-shipped version) so a
-- store version that SCC didn't ship can be flagged as out-of-band drift.
--
-- ~40 rows (apps × platforms × tracks). The PK covers every access path, so no
-- extra index. Rows cascade-delete with their app_catalog parent.
CREATE TABLE IF NOT EXISTS store_status (
  app_catalog_id    INT  NOT NULL REFERENCES app_catalog(id) ON DELETE CASCADE,
  platform          TEXT NOT NULL,            -- android | ios
  track             TEXT NOT NULL,            -- production | internal | testflight
  version_name      TEXT,
  version_code      INT,
  status            TEXT,                     -- live | completed | inProgress | halted | VALID | none | …
  rollout_percent   DOUBLE PRECISION,         -- production staged-rollout % (0–100)
  review_status     TEXT,                     -- in_review | approved | rejected (production)
  release_notes     TEXT,                     -- "What's New" for this track's current version
  expected_version  TEXT,                     -- last SCC-shipped version, for drift ⚠
  synced_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (app_catalog_id, platform, track)
);
