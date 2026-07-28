-- Version-first comparator for mobile slot convergence, shared by the
-- convergence SQL in Queries/Supersession.hs and the operator inspect script.
-- MUST match StoreSync.versionOlderThan exactly: split on '.', each segment
-- parses as a whole number or reads 0 (so '3.3.16-beta' = {3,3,0}, like the
-- Haskell readMaybe fallback). Postgres array comparison is elementwise with
-- shorter-is-less on equal prefixes, matching Haskell list Ord.
CREATE OR REPLACE FUNCTION mobile_version_key(v text) RETURNS bigint[]
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT COALESCE(
    array_agg(CASE WHEN t.s ~ '^[0-9]+$' THEN t.s::bigint ELSE 0 END ORDER BY t.ord),
    ARRAY[]::bigint[])
  FROM unnest(string_to_array(v, '.')) WITH ORDINALITY AS t(s, ord)
$$;















-- supersede-same-version-rebuilds.sql
--
-- One-off operator runbook: heal release_tracker rows stuck reading "Live"
-- because a REBUILD of the same version replaced them on the store (e.g.
-- KeralaSavaari iOS 3.3.107+3 still "Live" beside the real live 3.3.107+4).
--
-- Root cause (docs/MOBILE_SLOT_SUPERSESSION_AUDIT.md, same-version rebuild
-- gap): Rule A skips completed rows and store-sync's stale-retire compares
-- versions strictly, so a same-version different-code row is never retired.
-- The CODE fix (supersedeRebuiltSameVersion, wired into syncIos) prevents
-- recurrence for iOS from the next deploy; this script heals rows that got
-- stuck BEFORE that fix shipped.
--
-- ┌─ READ BEFORE RUNNING ───────────────────────────────────────────────────────┐
-- │ • This MUTATES the database. Confirm $DATABASE_URL points at the intended    │
-- │   env (the cloud/prod DB is normally treated as READ-ONLY — this is a        │
-- │   deliberate one-off).                                                       │
-- │ • TAKE THE BACKUP in §2 first — it is your only undo.                        │
-- │ • Run §1 (inspect) and eyeball the rows BEFORE the §3 transaction.           │
-- │ • Policy per (app, surface, platform, version): KEEP the highest             │
-- │   version_code (the store can only have one live build; the highest code is  │
-- │   the one Apple/Google actually serves), supersede the rest.                 │
-- │ • NULL-code rows are deliberately untouched (a legacy code-less row IS the   │
-- │   version's row).                                                            │
-- └──────────────────────────────────────────────────────────────────────────────┘

-- ════════════════════════════════════════════════════════════════════════════
-- §1. INSPECT — every same-version live-slot duplicate (run first, no writes)
-- ════════════════════════════════════════════════════════════════════════════

WITH live_slot AS (
  SELECT id, app_group, service, env, new_version, version_code,
         rollout_status, release_manager, created_at
  FROM release_tracker
  WHERE category = 'MobileBuild'
    AND store_track = 'production'
    AND rollout_status IN ('rolling_out', 'halted', 'completed')
    AND version_code IS NOT NULL
),
keepers AS (
  SELECT DISTINCT ON (app_group, service, env, new_version) id
  FROM live_slot
  ORDER BY app_group, service, env, new_version, version_code DESC
)
SELECT ls.*,
       CASE WHEN k.id IS NULL THEN '→ SUPERSEDE' ELSE 'keep (live build)' END AS action
FROM live_slot ls
LEFT JOIN keepers k ON k.id = ls.id
WHERE (ls.app_group, ls.service, ls.env, ls.new_version) IN (
  SELECT app_group, service, env, new_version
  FROM live_slot GROUP BY 1, 2, 3, 4 HAVING count(*) > 1
)
ORDER BY ls.app_group, ls.env, ls.new_version, ls.version_code DESC;

-- Expected for the observed case: KeralaSavaari / ios / 3.3.107 shows two rows —
-- version_code 4 "keep (live build)", version_code 3 "→ SUPERSEDE".

-- ════════════════════════════════════════════════════════════════════════════
-- §2. BACKUP — run in a shell BEFORE §3 (this is the undo)
-- ════════════════════════════════════════════════════════════════════════════
--   pg_dump "$DATABASE_URL" -t release_tracker \
--     --data-only --column-inserts > rebuild_supersede_backup_$(date +%F).sql

-- ════════════════════════════════════════════════════════════════════════════
-- §3. FIX — supersede every non-keeper duplicate (mirrors the Haskell rule:
--     status COMPLETED + rollout_status 'superseded'; percent left frozen)
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

WITH live_slot AS (
  SELECT id, app_group, service, env, new_version, version_code
  FROM release_tracker
  WHERE category = 'MobileBuild'
    AND store_track = 'production'
    AND rollout_status IN ('rolling_out', 'halted', 'completed')
    AND version_code IS NOT NULL
),
keepers AS (
  SELECT DISTINCT ON (app_group, service, env, new_version) id
  FROM live_slot
  ORDER BY app_group, service, env, new_version, version_code DESC
),
losers AS (
  SELECT ls.id
  FROM live_slot ls
  WHERE ls.id NOT IN (SELECT id FROM keepers)
)
UPDATE release_tracker rt
SET status = 'COMPLETED',
    rollout_status = 'superseded'
FROM losers l
WHERE rt.id = l.id;

-- Verify: the §1 inspect query re-run inside this txn should now show zero
-- '→ SUPERSEDE' rows. COMMIT only if the affected row count matches §1.
COMMIT;
