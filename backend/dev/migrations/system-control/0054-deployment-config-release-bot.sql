-- 0054: per-row release-bot rules on deployment_config.
--
-- JSON text, same style as rollout_strategy / decision_config.
--   * product-level row (service IS NULL): env, branches, channels, jenkins, secretFiles,
--     configMaps (which changed file -> which configmap key), ignoreConfigMaps
--   * service-level row: aliases, dhallFiles, envVar (which changed file -> which env var),
--     defaultRollout
-- NULL / empty = the release bot does nothing for that row. See RELEASE_BOT.md.
ALTER TABLE deployment_config ADD COLUMN IF NOT EXISTS release_bot_config TEXT;
