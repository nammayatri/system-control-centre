-- 0052: qa_automation_config.internal_base_url — the dashboard is fronted
-- externally by Pomerium (identity-aware proxy, expects a browser/SSO
-- session), so a server-to-server call from this backend using
-- X-QA-Webhook-Token would either be intercepted by Pomerium or rejected
-- before ever reaching the dashboard's own token check. When SCC and the
-- dashboard run in the same cluster, the trigger POST and the status-refresh
-- GET should go straight to the in-cluster Service DNS instead.
--
-- test_dashboard_url stays what it always was — the external, human-facing
-- URL used to build the "?qaRunId=" link shown on the release page. NULL
-- here (the common case when the two coincide, e.g. local dev) falls back
-- to test_dashboard_url for the outbound calls.

ALTER TABLE qa_automation_config ADD COLUMN IF NOT EXISTS internal_base_url TEXT;

ANALYZE;
