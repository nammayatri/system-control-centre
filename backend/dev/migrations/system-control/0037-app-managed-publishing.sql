-- 0037-app-managed-publishing.sql
-- Per-app "Play Managed Publishing" flag.
--
-- There is NO Google Play Developer API to query whether Managed Publishing is on
-- for an app/account (it's a Console-only setting, orthogonal to
-- changesNotSentForReview), so SCC can't detect it — we record it explicitly here.
--
-- It gates the release-summary "Publish in Play Console" panel: with Managed
-- Publishing ON a promoted Android build sits STAGED on production until the
-- operator clicks Publish (so a rollout % wouldn't apply yet → show the publish
-- gate); with it OFF a rollout % applies immediately → show the rollout controls
-- directly. Default true matches this account's setting; provider (driver) apps
-- run with Managed Publishing OFF, so flip those to false.

ALTER TABLE app_catalog
    ADD COLUMN IF NOT EXISTS managed_publishing BOOLEAN NOT NULL DEFAULT true;

-- Provider (driver) apps publish without the Managed-Publishing hold.
UPDATE app_catalog SET managed_publishing = false WHERE surface = 'driver';
