-- cloud_type — which cloud's cluster a release belongs to.
--
-- Phase 1 of the shared-DB migration: each cloud still runs its own database,
-- so every row here is tagged with this database's own cloud and every new
-- filter is a no-op. The column only starts doing work in Phase 2, when the
-- two datasets merge.
--
-- NULLABLE BY DESIGN. NULL means "not cluster-bound". MobileBuild rows drive
-- GitHub Actions and app stores, never kubectl, and their identity is global
-- (one App Store, not one per cloud) — so they stay NULL and remain visible to
-- every instance. Cluster-bound categories (BackendService, BackendScheduler,
-- BackendConfig, VSEdit) always carry a cloud.
--
-- PREREQUISITE ON THE AWS DATABASE — run BEFORE this migration:
--     ALTER DATABASE system_control SET scc.cloud_type = 'AWS';
-- Without it the backfill below silently defaults to GCP and every AWS release
-- is mis-tagged, which is exactly the wrong-cloud condition this column exists
-- to prevent. Verify after applying with the query at the bottom of this file.

-- The DEFAULT is kept, not dropped, and is the safety net for any writer that
-- does not name the column — an old binary mid-rolling-deploy, or hand-written
-- SQL. An untagged CLUSTER-BOUND row is dangerous (NULL means "visible to every
-- cloud", so both runners would drive it); an over-tagged mobile row is benign
-- (it just gets driven by one instance). The Haskell writers always set the
-- column explicitly — MobileBuild to NULL — and -Werror=missing-fields keeps
-- that true for any new row construction, so the default only ever applies to
-- writers outside the application.
ALTER TABLE release_tracker ADD COLUMN IF NOT EXISTS cloud_type TEXT;

-- Pin the default to a LITERAL resolved once, here. Writing the default as
-- `current_setting(...)` directly would re-evaluate it per INSERT in the
-- writing session's context — and a session that never inherited the setting
-- would silently fall back to 'GCP' on the AWS database, which is exactly the
-- mis-tag this column exists to prevent.
DO $$
DECLARE resolved text := COALESCE(current_setting('scc.cloud_type', true), 'GCP');
BEGIN
    EXECUTE format('ALTER TABLE release_tracker ALTER COLUMN cloud_type SET DEFAULT %L', resolved);
    -- Backfill cluster-bound rows. Idempotent, and also the repair path if a
    -- writer outside the application ever leaves one untagged.
    EXECUTE format(
        'UPDATE release_tracker SET cloud_type = %L
          WHERE cloud_type IS NULL AND category IS DISTINCT FROM ''MobileBuild''',
        resolved);
END
$$;

-- Mobile identity is global: these must stay NULL so every instance sees them.
-- Also the repair path for a mobile row written by a pre-0045 binary, which
-- would have picked up the column default.
UPDATE release_tracker
   SET cloud_type = NULL
 WHERE category = 'MobileBuild'
   AND cloud_type IS NOT NULL;

-- Twins legitimately share a global_id — that is the whole point of the pairing
-- key — so uniqueness moves to (global_id, cloud_type). Still partial: global_id
-- is NULL for human-originated releases, the common case.
DROP INDEX IF EXISTS uq_release_tracker_global_id;
CREATE UNIQUE INDEX IF NOT EXISTS uq_release_tracker_global_id
    ON release_tracker (global_id, cloud_type) WHERE global_id IS NOT NULL;

-- Same-service in-flight guard is per-cluster: an in-flight GCP release must not
-- block creating the AWS one for the same service. Category list unchanged from
-- 0002 (all cluster-bound, so cloud_type is never NULL for rows this covers).
DROP INDEX IF EXISTS uq_release_tracker_service_inflight;
CREATE UNIQUE INDEX IF NOT EXISTS uq_release_tracker_service_inflight
    ON release_tracker (app_group, service, cloud_type)
    WHERE status IN ('CREATED','INPROGRESS','PAUSED','ABORTING','REVERTING','RESTARTING','PREPARING')
      AND category IN ('BackendService','BackendScheduler','BackendCronJob','BackendJob');

-- The three mobile indexes (uq_release_tracker_store_sync,
-- uq_release_tracker_mobile_build, uq_release_tracker_external_review) are
-- deliberately NOT widened. They encode a global build identity; adding
-- cloud_type would relax them and permit duplicate store-sync rows.

-- Supports the poller filters, which are all (cloud_type, status) shaped.
CREATE INDEX IF NOT EXISTS idx_rt_cloud_status ON release_tracker(cloud_type, status);

-- Verification — expect mobile under NULL and everything else under one cloud:
--   SELECT cloud_type, category, count(*) FROM release_tracker
--    GROUP BY 1, 2 ORDER BY 1 NULLS FIRST, 2;

ANALYZE;
