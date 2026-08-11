-- 0050: outbound release webhooks — fire a caller-defined HTTP request to an
-- external party whenever a release reaches a terminal state (COMPLETED, or
-- any of the ABORTED family).
--
-- Scoped like deployment_config, the table that holds the cool-off / rollout
-- strategy for the same deployment: keyed on (app_group, cloud_type). Which
-- services within the group a hook covers is a SET, held in `services` as a
-- JSON array of service names; NULL or [] means every service in the group.
--
-- Kept as its own table rather than columns on deployment_config because a
-- group can have N webhooks, each with its own method/headers/body.
--
-- services / headers / query_params are all TEXT-holding-JSON, matching how
-- rollout_strategy / decision_config / ab_validation are stored on their tables.
--
-- Any of url / headers / query_params / body may embed placeholder tokens
-- ({{NEW_VERSION}}, {{OLD_VERSION}}); they are substituted at fire time.

CREATE TABLE IF NOT EXISTS release_webhook (
  id SERIAL PRIMARY KEY,
  app_group TEXT NOT NULL,
  services TEXT,
  cloud_type TEXT NOT NULL DEFAULT 'GCP',
  name TEXT NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  on_success BOOLEAN NOT NULL DEFAULT TRUE,
  on_failure BOOLEAN NOT NULL DEFAULT TRUE,
  method TEXT NOT NULL DEFAULT 'POST',
  url TEXT NOT NULL,
  headers TEXT,
  query_params TEXT,
  body TEXT,
  timeout_seconds INTEGER,
  retries INTEGER,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One webhook name per app group. Scope is a set held in `services`, not part
-- of the key, so changing the covered services never collides.
CREATE UNIQUE INDEX IF NOT EXISTS uq_release_webhook
  ON release_webhook (app_group, cloud_type, name);

-- The dispatch-time lookup: every enabled hook for an app group on this cloud.
-- Service matching happens in Haskell — the set is a JSON blob, and a group has
-- only a handful of hooks.
CREATE INDEX IF NOT EXISTS idx_release_webhook_lookup
  ON release_webhook (app_group, cloud_type)
  WHERE enabled;

-- Exactly-once dispatch guard. Two writers can terminalize the same release
-- (a runner tick and a user-facing handler), so the dispatcher claims its turn
-- by inserting this marker and treats a unique violation as "someone else got
-- it". Partial: every other release_events label repeats freely per release.
CREATE UNIQUE INDEX IF NOT EXISTS uq_release_event_webhook_dispatch
  ON release_events (re_release_id, re_label)
  WHERE re_label IN ('WEBHOOK_DISPATCH_SUCCESS', 'WEBHOOK_DISPATCH_FAILURE');

ANALYZE;
