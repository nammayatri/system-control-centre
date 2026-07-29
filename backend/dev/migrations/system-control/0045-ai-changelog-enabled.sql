-- Per-app-group default for the "AI Changelog to Slack" toggle on create-release.
-- NULL/false = toggle starts off; true = starts on. Per-release overrides live in
-- release_context.changelogSlackOptIn and never write back here.
ALTER TABLE deployment_config ADD COLUMN IF NOT EXISTS ai_changelog_enabled BOOLEAN;
