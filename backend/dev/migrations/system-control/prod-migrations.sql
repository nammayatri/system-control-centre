-- -- env: PROD  (Google Play + App Store; store sync + version preview active)
-- -- Applied automatically by db-init when SC_ENV = prod, and runs AFTER the common
-- -- migrations, so it is authoritative. See ../README.md.
-- UPDATE server_config SET value = 'release', enabled = 1 WHERE name = 'mobile_build_type';

-- INSERT INTO server_config (name, type, value, enabled, product)
-- SELECT 'mobile_build_type', 'STRING', 'release', 1, 'autopilot'
-- WHERE NOT EXISTS (
--     SELECT 1 FROM server_config WHERE name = 'mobile_build_type' AND product = 'autopilot'
-- );


-- -- env: PROD
-- -- Release builds publish to Google Play / App Store, so store sync (compare live
-- -- store versions) and version preview are active — turn them ON. Authoritative
-- -- override of the common 0015 / 0019 defaults.
-- UPDATE server_config SET value = 'true'
-- WHERE name IN ('store_sync_enabled', 'version_preview_enabled') AND product = 'autopilot';


-- -- env: PROD
-- -- Point every seeded app at its PRODUCTION fastlane workflow (Google Play / App Store):
-- --   android -> fastlane-android.yaml
-- --   ios     -> fastlane.yaml   (NOT fastlane-ios.yaml — verified against the
-- --                               nammayatri/ny-react-native workflow tree)
-- -- These are the release workflows that tag deterministically as
-- -- {normalize(app)}/prod/{platform}/v{version}+{code}.
-- -- Scoped by surface so provider (driver) apps get the provider prod workflows.
-- -- Customer:
-- UPDATE app_catalog
-- SET workflow_path = CASE platform
--     WHEN 'android' THEN '.github/workflows/fastlane-android.yaml'
--     WHEN 'ios'     THEN '.github/workflows/fastlane.yaml'
--     ELSE workflow_path
-- END
-- WHERE github_repo = 'nammayatri/ny-react-native' AND surface = 'customer';

-- -- Provider / driver:
-- UPDATE app_catalog
-- SET workflow_path = CASE platform
--     WHEN 'android' THEN '.github/workflows/provider-prod-apk-gen.yaml'
--     WHEN 'ios'     THEN '.github/workflows/provider-prod-ios-gen.yaml'
--     ELSE workflow_path
-- END
-- WHERE github_repo = 'nammayatri/ny-react-native' AND surface = 'driver';


-- -- env: PROD — production applicationIds / bundle ids for provider (driver) apps.
-- --
-- -- Source of truth: nammayatri/ny-react-native
-- --   Android: provider/android/app/build.gradle  (productFlavors, `prod` mode → no suffix)
-- --   iOS:     provider/ios/provider.xcodeproj     (Release PRODUCT_BUNDLE_IDENTIFIER)
-- -- For every app that has an iOS target the iOS bundle id == the Android base id, so a
-- -- single per-app value covers both platforms here.
-- --
-- -- Authoritative: runs in the env pass AFTER the common 0025 seed, so it overrides
-- -- package_name. Pairs with env/debug/03-provider-app-packages.sql (same filename).
-- -- Idempotent (plain UPDATE to a literal).

-- UPDATE app_catalog SET package_name = 'in.juspay.nammayatripartner'    WHERE surface = 'driver' AND name = 'NammaYatriPartner';
-- UPDATE app_catalog SET package_name = 'in.mobility.manayatripartner'   WHERE surface = 'driver' AND name = 'ManaYatriPartner';
-- UPDATE app_catalog SET package_name = 'net.openkochi.yatripartner'     WHERE surface = 'driver' AND name = 'YatriPartner';
-- UPDATE app_catalog SET package_name = 'in.mobility.odishayatripartner' WHERE surface = 'driver' AND name = 'OdishaYatriPartner';
-- UPDATE app_catalog SET package_name = 'in.juspay.jatrisaathidriver'    WHERE surface = 'driver' AND name = 'YatriSathiDriver';
-- UPDATE app_catalog SET package_name = 'in.mobility.keralasavaari'      WHERE surface = 'driver' AND name = 'KeralaSavaariPartner';
-- UPDATE app_catalog SET package_name = 'com.mobility.movingtechdriver'  WHERE surface = 'driver' AND name = 'BridgeDriver';
-- UPDATE app_catalog SET package_name = 'in.mobility.bharattaxidriver'   WHERE surface = 'driver' AND name = 'BharatTaxiPartner';
-- UPDATE app_catalog SET package_name = 'in.mobility.lynxdriver'         WHERE surface = 'driver' AND name = 'LynxDriver';
-- UPDATE app_catalog SET package_name = 'com.maruti.smartride'           WHERE surface = 'driver' AND name = 'MarutiSuzuki';


-- -- 0027-staged-rollout.sql
-- -- Promote-to-review + staged-rollout state, tracked per release on release_tracker.
-- -- See docs/superpowers/plans/2026-06-09-promote-review-and-staged-rollout.md (Phase 1).
-- --
-- -- NOTE vs the plan: the plan called this "0026" (repo was at 0025 when it was written),
-- -- but 0026 was taken by 0026-debug-env.sql since — so this is 0027. And the plan's
-- -- `rollout_history` is named `store_rollout_history` here, because a `rollout_history`
-- -- column already exists on release_tracker (the backend K8s staggered-rollout history,
-- -- a different shape). store_rollout_history holds the mobile [RolloutStage] JSON.

-- ALTER TABLE release_tracker
--   ADD COLUMN IF NOT EXISTS review_status         TEXT,             -- in_review | approved | rejected (iOS); submitted | live (Android)
--   ADD COLUMN IF NOT EXISTS review_submitted_at   TIMESTAMPTZ,
--   ADD COLUMN IF NOT EXISTS review_decided_at     TIMESTAMPTZ,
--   ADD COLUMN IF NOT EXISTS review_reject_reason  TEXT,
--   ADD COLUMN IF NOT EXISTS rollout_status        TEXT,             -- rolling_out | halted | completed
--   ADD COLUMN IF NOT EXISTS rollout_percent       DOUBLE PRECISION, -- current live % (0.0000001–100)
--   ADD COLUMN IF NOT EXISTS store_rollout_history TEXT,             -- JSON [{percent, startedAt, endedAt, notes, actor}]
--   ADD COLUMN IF NOT EXISTS asc_version_id        TEXT,             -- iOS: App Store version id (cached)
--   ADD COLUMN IF NOT EXISTS asc_phased_id         TEXT;             -- iOS: phased-release id (pause/resume)

-- CREATE INDEX IF NOT EXISTS idx_rt_review_status  ON release_tracker(review_status)  WHERE review_status  IS NOT NULL;
-- CREATE INDEX IF NOT EXISTS idx_rt_rollout_status ON release_tracker(rollout_status) WHERE rollout_status IS NOT NULL;


-- -- 0028-external-review-dedup.sql
-- -- Dedup guard for synthetic out-of-band review rows.
-- --
-- -- store sync surfaces an App Store version that's in review but was NOT submitted
-- -- from SCC as a synthetic INPROGRESS row (mode = 'EXTERNAL_REVIEW'). Two
-- -- concurrent sync passes — or two SCC replicas of the same env — could each
-- -- insert a row for the same app before either commits. A partial unique index
-- -- makes the second a no-op: the insert uses ON CONFLICT DO NOTHING (see
-- -- insertReleaseTrackerRowIfAbsent). Mirrors uq_release_tracker_store_sync.
-- --
-- -- There is at most one ACTIVE review-phase external row per (app, surface,
-- -- platform). Once an operator releases it (rollout_status is set) the row leaves
-- -- the index, so a later in-flight version can still get its own row.

-- -- Clear any pre-existing duplicates first (keep the most recent per identity) so
-- -- the unique index can be created. Synthetic rows are re-derivable from the store
-- -- on the next sync, so dropping older copies is safe.
-- DELETE FROM release_tracker rt
-- USING (
--   SELECT id, ROW_NUMBER() OVER (
--     PARTITION BY app_group, service, env
--     ORDER BY date_created DESC
--   ) AS rn
--   FROM release_tracker
--   WHERE mode = 'EXTERNAL_REVIEW' AND status = 'INPROGRESS' AND rollout_status IS NULL
-- ) dup
-- WHERE rt.id = dup.id AND dup.rn > 1;

-- CREATE UNIQUE INDEX IF NOT EXISTS uq_release_tracker_external_review
--   ON release_tracker (app_group, service, env)
--   WHERE mode = 'EXTERNAL_REVIEW' AND status = 'INPROGRESS' AND rollout_status IS NULL;



-- DELETE FROM release_tracker rt
-- USING (
--   SELECT id, ROW_NUMBER() OVER (
--     PARTITION BY app_group, service, env, new_version
--     ORDER BY date_created DESC
--   ) AS rn
--   FROM release_tracker
--   WHERE mode = 'EXTERNAL_REVIEW' AND status = 'INPROGRESS'
-- ) dup
-- WHERE rt.id = dup.id AND dup.rn > 1;

-- DROP INDEX IF EXISTS uq_release_tracker_external_review;

-- CREATE UNIQUE INDEX IF NOT EXISTS uq_release_tracker_external_review
--   ON release_tracker (app_group, service, env, new_version)
--   WHERE mode = 'EXTERNAL_REVIEW' AND status = 'INPROGRESS';



-- -- 0030-store-status.sql
-- -- App Release Monitoring: a per-track LIVE store-state cache.
-- --
-- -- The monitor dashboard is one DB read of this table. The StoreSync poller (and
-- -- the on-demand ↻ refresh) writes it: for every app in app_catalog — enabled OR
-- -- not, so the page shows EVERY app's live releases — it records each track's
-- -- current version / build code / status / staged-rollout % / review state /
-- -- "What's New" notes, plus expected_version (the last SCC-shipped version) so a
-- -- store version that SCC didn't ship can be flagged as out-of-band drift.
-- --
-- -- ~40 rows (apps × platforms × tracks). The PK covers every access path, so no
-- -- extra index. Rows cascade-delete with their app_catalog parent.
-- CREATE TABLE IF NOT EXISTS store_status (
--   app_catalog_id    INT  NOT NULL REFERENCES app_catalog(id) ON DELETE CASCADE,
--   platform          TEXT NOT NULL,            -- android | ios
--   track             TEXT NOT NULL,            -- production | internal | testflight
--   version_name      TEXT,
--   version_code      INT,
--   status            TEXT,                     -- live | completed | inProgress | halted | VALID | none | …
--   rollout_percent   DOUBLE PRECISION,         -- production staged-rollout % (0–100)
--   review_status     TEXT,                     -- in_review | approved | rejected (production)
--   release_notes     TEXT,                     -- "What's New" for this track's current version
--   expected_version  TEXT,                     -- last SCC-shipped version, for drift ⚠
--   synced_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
--   PRIMARY KEY (app_catalog_id, platform, track)
-- );
