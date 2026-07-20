#!/usr/bin/env bash
# ==============================================================================
# Verify cloud scoping (migration 0045).
#
# WHY THIS EXISTS: in Phase 1 each cloud still has its own database, so every
# cloud guard added to the queries matches every row and is a no-op. A green
# build and a green test suite therefore prove NOTHING about the scoping. This
# script is the only check that actually exercises the new filters: it seeds
# rows belonging to a DIFFERENT cloud and asserts the runner leaves them alone.
#
# Requires: psql, a running backend (the runner poll loop must be live).
# Usage: bash scripts/verify-cloud-scoping.sh
# ==============================================================================
set -euo pipefail

PSQL="psql ${SC_DATABASE_URL:-postgres://$(whoami)@127.0.0.1:5434/system_control} -qtAX"
FOREIGN="__VERIFY_OTHER_CLOUD__"
PASS=0
FAIL=0

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC}: $name"
  else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: $name -- expected '$expected', got '$actual'"
  fi
}

cleanup() {
  $PSQL -c "DELETE FROM release_events WHERE re_release_id LIKE '${FOREIGN}%';" >/dev/null
  $PSQL -c "DELETE FROM release_tracker WHERE id LIKE '${FOREIGN}%';" >/dev/null
}
trap cleanup EXIT

echo "==========================================="
echo "  Cloud scoping verification (migration 0045)"
echo "==========================================="

# The cloud this database is tagged with. Foreign rows get a different value.
OWN_CLOUD=$($PSQL -c "SELECT COALESCE(current_setting('scc.cloud_type', true), 'GCP');")
echo "  own cloud = ${OWN_CLOUD}; seeding rows as 'OTHER'"
echo ""

cleanup

# --- Seed -------------------------------------------------------------------
# Row 1: exactly the shape findRunnableReleaseTrackers picks up (CREATED +
# approved + no schedule_time), but tagged for another cloud.
$PSQL -c "
INSERT INTO release_tracker
  ( id, status, new_version, old_version, app_group, service, release_manager
  , env, priority, release_tag, category, is_approved, date_created, last_updated
  , cloud_type )
VALUES
  ( '${FOREIGN}_runnable', 'CREATED', 'v2', 'v1', 'VERIFY_AG', 'verify-svc', 'verify'
  , 'UAT', 0, '${FOREIGN}_tag', 'BackendService', true, now(), now()
  , 'OTHER' );" >/dev/null

# Row 2: a stale INPROGRESS row — what startup recovery would roll back.
$PSQL -c "
INSERT INTO release_tracker
  ( id, status, new_version, old_version, app_group, service, release_manager
  , env, priority, release_tag, category, is_approved, date_created, last_updated
  , cloud_type )
VALUES
  ( '${FOREIGN}_stale', 'INPROGRESS', 'v2', 'v1', 'VERIFY_AG', 'verify-stale', 'verify'
  , 'UAT', 0, '${FOREIGN}_tag2', 'BackendService', true, now() - interval '2 days'
  , now() - interval '2 days', 'OTHER' );" >/dev/null

# Row 3: a LOCKED VSEdit row — what releaseExpiredVsLocks would unlock.
$PSQL -c "
INSERT INTO release_tracker
  ( id, status, new_version, old_version, app_group, service, release_manager
  , env, priority, release_tag, category, date_created, last_updated, end_time
  , cloud_type )
VALUES
  ( '${FOREIGN}_vslock', 'LOCKED', '', '', 'VERIFY_AG', '', 'verify'
  , 'UAT', 0, '${FOREIGN}_tag3', 'VSEdit', now() - interval '2 days'
  , now() - interval '2 days', now() - interval '1 day', 'OTHER' );" >/dev/null

echo "[1] Seeded 3 foreign-cloud rows"
check "runnable row present" "1" "$($PSQL -c "SELECT count(*) FROM release_tracker WHERE id = '${FOREIGN}_runnable';")"
echo ""

# --- Wait for the runner to tick past them ----------------------------------
echo "[2] Waiting 45s for runner poll cycles..."
sleep 45
echo ""

# --- Assert the runner left every one of them alone -------------------------
echo "[3] Foreign rows untouched by the runner"

check "CREATED row NOT picked up (still CREATED)" \
  "CREATED" \
  "$($PSQL -c "SELECT status FROM release_tracker WHERE id = '${FOREIGN}_runnable';")"

check "no RUNNER_PICKED event emitted for it" \
  "0" \
  "$($PSQL -c "SELECT count(*) FROM release_events WHERE re_release_id = '${FOREIGN}_runnable' AND re_label = 'RUNNER_PICKED';")"

check "stale INPROGRESS row NOT rolled back (still INPROGRESS)" \
  "INPROGRESS" \
  "$($PSQL -c "SELECT status FROM release_tracker WHERE id = '${FOREIGN}_stale';")"

check "expired VSEdit lock NOT released (still LOCKED)" \
  "LOCKED" \
  "$($PSQL -c "SELECT status FROM release_tracker WHERE id = '${FOREIGN}_vslock';")"
echo ""

# --- Assert mobile rows stay globally visible -------------------------------
# cloud_type IS NULL means "not cluster-bound"; visibleToCloud must still match.
echo "[4] Mobile rows (cloud_type IS NULL) remain visible to every instance"
check "no mobile row was given a cloud tag by the backfill" \
  "0" \
  "$($PSQL -c "SELECT count(*) FROM release_tracker WHERE category = 'MobileBuild' AND cloud_type IS NOT NULL;")"
echo ""

# --- Assert the write path tags new rows ------------------------------------
echo "[5] Write path stamps cloud_type on cluster-bound rows"
check "no untagged cluster-bound rows" \
  "0" \
  "$($PSQL -c "SELECT count(*) FROM release_tracker WHERE category <> 'MobileBuild' AND cloud_type IS NULL;")"
echo ""

echo "==========================================="
echo -e "  ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "==========================================="
[ "$FAIL" -eq 0 ]
