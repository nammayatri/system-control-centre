-- Row-level security for cloud isolation (Phase 2 of the shared-DB migration).
--
-- NOT auto-applied. This is deliberately outside dev/migrations/ because it
-- needs CREATEROLE, sets up login credentials that must not live in the repo,
-- and is a cutover step rather than a schema change. Migration 0045 adds the
-- cloud_type column and the Haskell-side guards; this file makes the database
-- enforce them so the raw-SQL writers cannot bypass the filter.
--
-- Apply as a superuser on the shared (GCP-hosted) database, AFTER the data
-- merge and after both instances are running the cloud_type-aware build.
--
--     psql "$SC_DATABASE_URL" -v ON_ERROR_STOP=1 -f rls-cloud-isolation.sql
--
-- Then set passwords out of band and repoint each instance's SC_DATABASE_URL:
--     ALTER ROLE scc_gcp LOGIN PASSWORD '...';
--     ALTER ROLE scc_aws LOGIN PASSWORD '...';

-- ---------------------------------------------------------------------------
-- Roles. One per instance, so the cloud is carried by the connection identity
-- rather than a session variable — a pooled connection cannot leak the wrong
-- cloud into a later checkout.
-- ---------------------------------------------------------------------------

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'scc_gcp') THEN
        CREATE ROLE scc_gcp NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'scc_aws') THEN
        CREATE ROLE scc_aws NOLOGIN;
    END IF;
END
$$;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO scc_gcp, scc_aws;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO scc_gcp, scc_aws;

-- ---------------------------------------------------------------------------
-- Policies on release_tracker.
--
-- Read/mutate: own cloud, plus the not-cluster-bound rows (cloud_type IS NULL —
-- MobileBuild, whose identity is global). Mirrors visibleToCloud in
-- Products/Autopilot/Queries/ReleaseTracker.hs.
--
-- INSERT is permissive BY DESIGN. Creating the twin row for the other cloud is
-- the one legitimate cross-cloud write (it is what replaces the HTTP sync), and
-- the twin is validated by its own cloud's runner on pickup. The property being
-- enforced here is that an instance cannot ACT ON another cloud's release.
--
-- SELECT IS COVERED DELIBERATELY. `FOR ALL` includes SELECT, so an instance
-- cannot even read another cloud's releases.
--
-- The tempting alternative was to restrict only UPDATE/DELETE and leave SELECT
-- open, so one instance's UI could list both clouds. That was rejected after
-- auditing whether every kubectl path claims its row via a CAS UPDATE first —
-- it does not. scaleDownOldDeployment (Runner.hs) re-reads the tracker with
-- findReleaseTracker and checks its status, which is a read, not an atomic
-- claim, and then runs kubectl against the old deployment;
-- scaleDownLeakedNewDeployment has the same shape. With SELECT open, a query
-- that forgot its cloud guard would therefore drain a deployment in the WRONG
-- cluster rather than harmlessly failing a claim.
--
-- Consequence for Phase 4: a release list spanning both clouds does not come
-- free with the shared database. It needs a separate read-only role holding a
-- global SELECT policy, with its own connection pool, used exclusively by
-- list/detail endpoints and never by the runner.
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS rt_cloud_read_gcp ON release_tracker;
DROP POLICY IF EXISTS rt_cloud_read_aws ON release_tracker;
DROP POLICY IF EXISTS rt_cloud_insert ON release_tracker;

CREATE POLICY rt_cloud_read_gcp ON release_tracker
    FOR ALL TO scc_gcp
    USING (cloud_type = 'GCP' OR cloud_type IS NULL);

CREATE POLICY rt_cloud_read_aws ON release_tracker
    FOR ALL TO scc_aws
    USING (cloud_type = 'AWS' OR cloud_type IS NULL);

CREATE POLICY rt_cloud_insert ON release_tracker
    FOR INSERT TO scc_gcp, scc_aws
    WITH CHECK (true);

-- ---------------------------------------------------------------------------
-- Enable. FORCE so the table owner is subject to the policies too — without it
-- an instance connecting as the owner silently bypasses everything above.
--
-- Run this LAST, and only once both instances connect as scc_gcp / scc_aws.
-- Enabling it while an instance still connects as the owner is a no-op; enabling
-- it before the roles have credentials locks that instance out entirely.
-- ---------------------------------------------------------------------------

ALTER TABLE release_tracker ENABLE ROW LEVEL SECURITY;
ALTER TABLE release_tracker FORCE ROW LEVEL SECURITY;

-- Verification — each should return only its own cloud's rows plus NULLs:
--   SET ROLE scc_gcp; SELECT DISTINCT cloud_type FROM release_tracker; RESET ROLE;
--   SET ROLE scc_aws; SELECT DISTINCT cloud_type FROM release_tracker; RESET ROLE;
--
-- And a cross-cloud mutation must affect zero rows:
--   SET ROLE scc_gcp;
--   UPDATE release_tracker SET status = status WHERE cloud_type = 'AWS';  -- expect UPDATE 0
--   RESET ROLE;
