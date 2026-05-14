#!/usr/bin/env bash
# setup-mobile-local.sh
# ─────────────────────────────────────────────────────────────────────────────
# Configures the SCC local Postgres with GitHub App + Play Console credentials
# read from backend/dev/local-mobile-secrets.env, flips the mobile dispatch
# feature flag, and optionally enables apps in app_catalog.
#
# Usage:
#   nix develop --command bash backend/scripts/setup-mobile-local.sh
#
# Prerequisites:
#   1. sc-dev has run at least once so the DB + schema exist.
#   2. backend/dev/local-mobile-secrets.env exists and is filled in
#      (copy from local-mobile-secrets.env.example).
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# Resolve repo root regardless of where the script is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SECRETS_FILE="$REPO_ROOT/backend/dev/local-mobile-secrets.env"
EXAMPLE_FILE="$REPO_ROOT/backend/dev/local-mobile-secrets.env.example"

# ── Colors for clearer output ────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; RESET=''
fi

info()  { printf "%s[info]%s  %s\n"  "$BLUE"   "$RESET" "$*"; }
ok()    { printf "%s[ok]%s    %s\n"  "$GREEN"  "$RESET" "$*"; }
warn()  { printf "%s[warn]%s  %s\n"  "$YELLOW" "$RESET" "$*"; }
fail()  { printf "%s[fail]%s  %s\n"  "$RED"    "$RESET" "$*" >&2; exit 1; }

# ── 1. Sanity checks ─────────────────────────────────────────────────────────

if ! command -v psql >/dev/null 2>&1; then
    fail "psql not found on PATH. Run inside 'nix develop' or install postgres client tools."
fi

if [[ ! -f "$SECRETS_FILE" ]]; then
    warn "Secrets file missing: $SECRETS_FILE"
    echo
    echo "  Copy the example file and fill in real values:"
    echo "    cp $EXAMPLE_FILE $SECRETS_FILE"
    echo "    \$EDITOR $SECRETS_FILE"
    echo
    fail "Aborting until secrets file is present."
fi

# ── 2. Source the secrets file ───────────────────────────────────────────────

# shellcheck disable=SC1090
source "$SECRETS_FILE"

# Default the DB URL if not overridden in the secrets file
: "${SC_DATABASE_URL:=postgres://$(whoami)@127.0.0.1:5434/system_control}"
export SC_DATABASE_URL

info "Using database: $SC_DATABASE_URL"

# Verify DB is reachable
if ! psql "$SC_DATABASE_URL" -c "SELECT 1" >/dev/null 2>&1; then
    fail "Cannot connect to $SC_DATABASE_URL. Is 'sc-dev' running?"
fi
ok "Database connection verified"

# Verify the mobile schema exists
if ! psql "$SC_DATABASE_URL" -c "SELECT 1 FROM app_catalog LIMIT 1" >/dev/null 2>&1; then
    fail "app_catalog table missing. Run 'sc-dev' first so migration 0011 applies."
fi
ok "Mobile schema present"

# ── 3. Validate required values ──────────────────────────────────────────────

validate_required() {
    local var="$1" val="${!1:-}"
    [[ -n "$val" ]] || fail "Required value missing: $var (edit $SECRETS_FILE)"
}

validate_file() {
    local var="$1" path="${!1:-}"
    [[ -n "$path" ]] || fail "Required path missing: $var (edit $SECRETS_FILE)"
    [[ -f "$path" ]] || fail "Path does not exist: $var=$path"
    [[ -r "$path" ]] || fail "Path not readable: $var=$path"
}

validate_required GITHUB_APP_ID
validate_required GITHUB_APP_INSTALLATION_ID
validate_file     GITHUB_APP_PRIVATE_KEY_PATH
validate_file     PLAY_SERVICE_ACCOUNT_JSON_PATH
validate_required MOBILE_DISPATCH_ENABLED

ok "All required values present"

# Optional iOS / App Store Connect setup. If ASC_ISSUER_ID is blank we
# skip iOS-side server_config updates entirely — the script keeps
# working for Android-only contributors with no change in behaviour.
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_PRIVATE_KEY_P8_PATH="${ASC_PRIVATE_KEY_P8_PATH:-}"
ASC_ENABLED=0
if [[ -n "$ASC_ISSUER_ID" ]]; then
    validate_required ASC_KEY_ID
    validate_file     ASC_PRIVATE_KEY_P8_PATH
    ASC_ENABLED=1
    ok "App Store Connect (iOS) credentials present"
else
    info "App Store Connect (iOS) credentials not provided — skipping iOS server_config rows"
fi

# ── 4. Read file contents ────────────────────────────────────────────────────

GH_PRIVATE_KEY="$(cat "$GITHUB_APP_PRIVATE_KEY_PATH")"
PLAY_JSON="$(jq -c . "$PLAY_SERVICE_ACCOUNT_JSON_PATH" 2>/dev/null || cat "$PLAY_SERVICE_ACCOUNT_JSON_PATH")"

# Basic shape validation
if ! grep -q "BEGIN" <<< "$GH_PRIVATE_KEY"; then
    fail "GitHub App private key doesn't look like a PEM file (missing BEGIN line)"
fi
if ! echo "$PLAY_JSON" | grep -q "service_account"; then
    warn "Play Console JSON doesn't have a 'service_account' type field — verify it's the right key file"
fi

# Read the ASC .p8 if iOS setup was opted into. The .p8 is a PEM-format
# EC private key; check the BEGIN line same way we check the GH PEM.
ASC_P8=""
if (( ASC_ENABLED == 1 )); then
    ASC_P8="$(cat "$ASC_PRIVATE_KEY_P8_PATH")"
    if ! grep -q "BEGIN" <<< "$ASC_P8"; then
        fail "ASC private key doesn't look like a PEM file (missing BEGIN line). Did you download the .p8?"
    fi
fi

ok "Credentials loaded from disk"

# ── 5. Update server_config ──────────────────────────────────────────────────

# psql variable binding via -v is safer than string interpolation for the
# multi-line PEM and the JSON blob. We use the :'<var>' quoted-variable syntax.
psql "$SC_DATABASE_URL" -v ON_ERROR_STOP=1 \
    -v "app_id=$GITHUB_APP_ID" \
    -v "installation_id=$GITHUB_APP_INSTALLATION_ID" \
    -v "private_key=$GH_PRIVATE_KEY" \
    -v "play_json=$PLAY_JSON" \
    -v "dispatch_enabled=$MOBILE_DISPATCH_ENABLED" \
    <<'SQL'
UPDATE server_config SET value = :'app_id',          enabled = 1 WHERE name = 'github_app_id';
UPDATE server_config SET value = :'installation_id', enabled = 1 WHERE name = 'github_app_installation_id';
UPDATE server_config SET value = :'private_key',     enabled = 1 WHERE name = 'github_app_private_key';
UPDATE server_config SET value = :'play_json',       enabled = 1 WHERE name = 'play_console_service_account_json';
UPDATE server_config SET value = :'dispatch_enabled', enabled = 1 WHERE name = 'mobile_dispatch_enabled';
SQL

ok "server_config rows updated (Android side)"

# iOS / App Store Connect server_config rows. Only updated if the
# operator supplied ASC creds in the env file. Three rows total —
# mirrors how the Android side keeps 3 GH App rows + 1 Play JSON row.
if (( ASC_ENABLED == 1 )); then
    psql "$SC_DATABASE_URL" -v ON_ERROR_STOP=1 \
        -v "asc_issuer=$ASC_ISSUER_ID" \
        -v "asc_key_id=$ASC_KEY_ID" \
        -v "asc_p8=$ASC_P8" \
        <<'SQL'
UPDATE server_config SET value = :'asc_issuer', enabled = 1 WHERE name = 'app_store_connect_issuer_id';
UPDATE server_config SET value = :'asc_key_id', enabled = 1 WHERE name = 'app_store_connect_key_id';
UPDATE server_config SET value = :'asc_p8',     enabled = 1 WHERE name = 'app_store_connect_private_key_p8';
SQL
    ok "server_config rows updated (iOS / App Store Connect side)"
fi

# ── 6. Enable apps in catalog ────────────────────────────────────────────────

ENABLE_APPS="${ENABLE_APPS:-}"

if [[ -z "$ENABLE_APPS" || "$ENABLE_APPS" == "none" ]]; then
    info "No apps requested to enable (ENABLE_APPS empty or 'none')"
elif [[ "$ENABLE_APPS" == "all" ]]; then
    psql "$SC_DATABASE_URL" -v ON_ERROR_STOP=1 -c "UPDATE app_catalog SET enabled = true;"
    ok "Enabled ALL apps in app_catalog"
else
    # Comma-separated → quoted list for IN (...) clause
    IFS=',' read -ra apps_arr <<< "$ENABLE_APPS"
    in_list="$(printf "'%s'," "${apps_arr[@]}")"
    in_list="${in_list%,}"
    affected="$(psql "$SC_DATABASE_URL" -v ON_ERROR_STOP=1 -tA -c "UPDATE app_catalog SET enabled = true WHERE name IN ($in_list) RETURNING name;" | tr '\n' ' ')"
    if [[ -z "$affected" ]]; then
        warn "ENABLE_APPS=$ENABLE_APPS matched no rows in app_catalog (check spelling against the seed)"
    else
        ok "Enabled apps: $affected"
    fi
fi

# ── 7. Sandbox redirection (optional) ────────────────────────────────────────

if [[ -n "${SANDBOX_GITHUB_REPO:-}" && -n "${SANDBOX_WORKFLOW_PATH:-}" ]]; then
    psql "$SC_DATABASE_URL" -v ON_ERROR_STOP=1 \
        -v "repo=$SANDBOX_GITHUB_REPO" \
        -v "wf_path=$SANDBOX_WORKFLOW_PATH" \
        -c "UPDATE app_catalog SET github_repo = :'repo', workflow_path = :'wf_path' WHERE enabled = true;"
    ok "Redirected enabled apps to sandbox $SANDBOX_GITHUB_REPO @ $SANDBOX_WORKFLOW_PATH"
elif [[ -n "${SANDBOX_GITHUB_REPO:-}" || -n "${SANDBOX_WORKFLOW_PATH:-}" ]]; then
    warn "Sandbox override partially set — both SANDBOX_GITHUB_REPO and SANDBOX_WORKFLOW_PATH are required; skipping redirection"
fi

# ── 8. Final verification ────────────────────────────────────────────────────

echo
info "─── Final state ───"

psql "$SC_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
\echo
\echo Server config (secrets shown as length only):
SELECT name,
       enabled,
       CASE WHEN type = 'secret' THEN '<' || LENGTH(value) || ' chars>'
            ELSE value END AS value
  FROM server_config
 WHERE name IN ('github_app_id','github_app_installation_id','github_app_private_key',
                'play_console_service_account_json','mobile_dispatch_enabled','mobile_run_poll_seconds',
                'app_store_connect_issuer_id','app_store_connect_key_id','app_store_connect_private_key_p8')
 ORDER BY name;

\echo
\echo App catalog (only enabled rows shown):
SELECT name, surface, platform, github_repo, workflow_path, enabled
  FROM app_catalog
 WHERE enabled = true
 ORDER BY name;

\echo
\echo Mobile RBAC grants:
SELECT name, permissions
  FROM sc_role
 WHERE product_slug='autopilot'
 ORDER BY name;
SQL

echo
ok "Setup complete."
echo
echo "Next steps:"
echo "  1. Restart sc-dev so the backend re-reads the new server_config values"
echo "     (or wait ~30s for the runner's RuntimeConfig refresh)."
echo "  2. Open http://localhost:5173 → log in as admin@juspay.in / admin123."
echo "  3. Navigate to Mobile Releases tile → New Mobile Release."
echo "  4. Pick your enabled app and verify the version preview hits Play Console."
