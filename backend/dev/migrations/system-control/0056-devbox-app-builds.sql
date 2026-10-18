-- 0056: Devbox Releases — app builds per app AND platform.
--
-- A release can build up to four apps against its backend: rider / driver ×
-- android / ios (ny-react-native debug workflows with a base_url input). The
-- chosen ones are kept on the release as 'app:platform' strings; each build
-- run is one devbox_release_build row.

ALTER TABLE devbox_release
  ADD COLUMN IF NOT EXISTS app_builds TEXT[] NOT NULL DEFAULT '{}';   -- e.g. {rider:android,driver:ios}

ALTER TABLE devbox_release_build
  ADD COLUMN IF NOT EXISTS app TEXT NOT NULL DEFAULT 'rider';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'devbox_release_build_app_check') THEN
    ALTER TABLE devbox_release_build
      ADD CONSTRAINT devbox_release_build_app_check CHECK (app IN ('rider', 'driver'));
  END IF;
  -- One row per release + app + platform (was: per release + platform).
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'devbox_release_build_release_id_platform_key') THEN
    ALTER TABLE devbox_release_build DROP CONSTRAINT devbox_release_build_release_id_platform_key;
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_devbox_release_build_app_platform
  ON devbox_release_build (release_id, app, platform);

-- The poller's work list: builds with a GitHub run still going.
CREATE INDEX IF NOT EXISTS idx_devbox_release_build_open
  ON devbox_release_build (status)
  WHERE status IN ('QUEUED', 'RUNNING');

-- Which ny-react-native app each build uses (catalyst names), and the
-- version name the driver workflows require. Editable without a deploy.
INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'STRING', 'devbox_rider_app', 'NammaYatri', 1, 'devbox'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'devbox_rider_app' AND product = 'devbox');

INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'STRING', 'devbox_driver_app', 'NammaYatriPartner', 1, 'devbox'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'devbox_driver_app' AND product = 'devbox');

INSERT INTO server_config (type, name, value, enabled, product)
SELECT 'STRING', 'devbox_driver_version_name', '9.9.9', 1, 'devbox'
WHERE NOT EXISTS (SELECT 1 FROM server_config WHERE name = 'devbox_driver_version_name' AND product = 'devbox');

ANALYZE;
