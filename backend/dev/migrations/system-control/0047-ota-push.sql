-- 0047-ota-push.sql — OTA releases inside mobile releases
-- (docs/OTA_MOBILE_RELEASE_INTEGRATION.md §5.5)
--
-- app_catalog.airborne_app_ref joins an SCC app row to its airborne app:
-- the composite ref "<org>~<app>" (production namespace only — debug
-- namespaces are out of scope in v2; NULL = app has no OTA).
-- ota_push tracks one CI bundle build expectation per (app, platform) per
-- dispatch batch. ota_release_link records identity+intent for SCC-created
-- airborne releases; release STATUS is never stored (always read live).

ALTER TABLE app_catalog ADD COLUMN IF NOT EXISTS airborne_app_ref TEXT;

-- Seeds: consumer production namespaces from ny-react-native/catalyst.yaml.
-- The airborne org ("movingtech") is not in catalyst.yaml -- it is the
-- AIRBORNE_ORGANISATION the OTA CI workflow pushes under.
-- NOTE: SCC name "BharatTaxi" = catalyst key "bharatTaxi" (casing differs;
-- the code-level variant map in Handlers/Ota.hs owns that translation).
UPDATE app_catalog SET airborne_app_ref = seed.ref
FROM (VALUES
  ('NammaYatri',    'android', 'movingtech~nammayatriv2'),
  ('NammaYatri',    'ios',     'movingtech~nammayatriv2-ios'),
  ('Cumta',         'android', 'movingtech~chennaione'),
  ('Cumta',         'ios',     'movingtech~chennaione-ios'),
  ('ManaYatri',     'android', 'movingtech~manayatri'),
  ('ManaYatri',     'ios',     'movingtech~manayatri-ios'),
  ('Yatri',         'android', 'movingtech~yatri'),
  ('Yatri',         'ios',     'movingtech~yatri-ios'),
  ('OdishaYatri',   'android', 'movingtech~odishayatri'),
  ('OdishaYatri',   'ios',     'movingtech~odishayatri-ios'),
  ('YatriSathi',    'android', 'movingtech~yatrisathi'),
  ('YatriSathi',    'ios',     'movingtech~yatrisathi-ios'),
  ('KeralaSavaari', 'android', 'movingtech~keralasavaari'),
  ('KeralaSavaari', 'ios',     'movingtech~keralasavaari-ios'),
  ('Bridge',        'android', 'movingtech~bridge'),
  ('Bridge',        'ios',     'movingtech~bridge-ios'),
  ('BharatTaxi',    'android', 'movingtech~bharattaxiv2'),
  ('BharatTaxi',    'ios',     'movingtech~bharattaxi-iosv2'),
  ('Lynx',          'android', 'movingtech~lynxv2'),
  ('Lynx',          'ios',     'movingtech~lynxiosv2')
) AS seed(name, platform, ref)
WHERE app_catalog.name = seed.name
  AND app_catalog.platform = seed.platform
  AND app_catalog.surface = 'customer'
  AND app_catalog.airborne_app_ref IS NULL;

CREATE TABLE IF NOT EXISTS ota_push (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  mobile_release_group_id  TEXT NOT NULL,   -- release_tracker.release_group_id (no FK)
  app_name                 TEXT NOT NULL,
  platform                 TEXT NOT NULL,   -- android | ios
  airborne_app_ref         TEXT NOT NULL,   -- "<org>~<app>" at dispatch time
  env                      TEXT NOT NULL,   -- Production (v2: prod only)
  requested_bump           TEXT NOT NULL,   -- patch | minor | major
  status                   TEXT NOT NULL,   -- DISPATCHED | RUNNING | BUNDLE_PUSHED | FAILED
  source_ref               TEXT NOT NULL,
  dispatch_batch_id        UUID NOT NULL,
  external_run_id          BIGINT,
  commit_sha               TEXT,
  baseline_package_version INT,             -- pre-dispatch watermark (NULL = fallback disabled)
  package_version          INT,
  final_version            TEXT,            -- from the ota/<ns>/<ver> tag
  resolved_via             TEXT,            -- tag | baseline | manual
  error                    TEXT,
  dispatched_by            TEXT NOT NULL,
  dispatched_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ota_push_group
  ON ota_push (mobile_release_group_id, dispatched_at DESC);
-- Global dispatch-serialization guard (Decision D): any row here blocks a new dispatch.
CREATE INDEX IF NOT EXISTS idx_ota_push_active
  ON ota_push (status) WHERE status IN ('DISPATCHED','RUNNING');

CREATE TABLE IF NOT EXISTS ota_release_link (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- NULL = released straight from a package (proven-lineage flow), no push.
  ota_push_id              UUID REFERENCES ota_push(id) ON DELETE CASCADE,
  airborne_app_ref         TEXT NOT NULL,
  airborne_release_id      TEXT NOT NULL,  -- superposition experiment id
  package_version          INT NOT NULL,
  dimensions               JSONB,          -- targeting snapshot at create (intent, not state)
  created_by               TEXT NOT NULL,
  -- Provenance lives ON the link (not via the push join), so push-born and
  -- package-born releases read identically.
  mobile_release_group_id  TEXT,
  source_ref               TEXT,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (airborne_app_ref, airborne_release_id)  -- global provenance lookup
);

CREATE INDEX IF NOT EXISTS idx_ota_release_link_push  ON ota_release_link (ota_push_id);
CREATE INDEX IF NOT EXISTS idx_ota_release_link_ref   ON ota_release_link (airborne_app_ref);
CREATE INDEX IF NOT EXISTS idx_ota_release_link_group ON ota_release_link (mobile_release_group_id);

ANALYZE;
