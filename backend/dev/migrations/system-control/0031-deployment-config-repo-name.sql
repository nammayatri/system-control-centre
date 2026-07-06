-- Add repo_name to deployment_config so each app-group's product-level row
-- (service IS NULL) can record its GitHub repository as "owner/repo".
-- Used to prefill release-tracker changelogs with a GitHub compare link
-- (github.com/owner/repo/compare/<old>...<new>) so reviewers can jump
-- straight to the diff instead of authoring a throwaway changelog.
ALTER TABLE deployment_config ADD COLUMN IF NOT EXISTS repo_name TEXT;
