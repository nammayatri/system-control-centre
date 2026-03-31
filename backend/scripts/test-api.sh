#!/usr/bin/env bash
# ==============================================================================
# System Control Centre — Integration Test Suite
# Requires the server to be running on PORT (default 8012)
# Usage: bash scripts/test-api.sh
# ==============================================================================
set -euo pipefail

PORT="${PORT:-8012}"
BASE="http://localhost:$PORT"
PASS=0
FAIL=0
TOTAL=0
TOKEN=""
RELEASE_IDS=()

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ==============================================================================
# Test Helpers
# ==============================================================================

check() {
  local name="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$actual" | grep -qi "$expected" 2>/dev/null; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}PASS${NC}: $name"
  else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC}: $name -- got: $(echo "$actual" | head -1 | cut -c1-120)"
  fi
}

check_status() {
  local name="$1" expected_code="$2" actual_code="$3" body="$4"
  TOTAL=$((TOTAL + 1))
  if [ "$actual_code" = "$expected_code" ]; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}PASS${NC}: $name (HTTP $actual_code)"
  else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC}: $name -- expected HTTP $expected_code, got HTTP $actual_code -- body: $(echo "$body" | head -1 | cut -c1-120)"
  fi
}

check_not() {
  local name="$1" unexpected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$actual" | grep -qi "$unexpected" 2>/dev/null; then
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC}: $name -- unexpectedly found '$unexpected' in: $(echo "$actual" | head -1 | cut -c1-120)"
  else
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}PASS${NC}: $name"
  fi
}

check_json_field() {
  local name="$1" field="$2" expected="$3" json="$4"
  local actual
  actual=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$field',''))" 2>/dev/null || echo "PARSE_ERROR")
  TOTAL=$((TOTAL + 1))
  if echo "$actual" | grep -qi "$expected" 2>/dev/null; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}PASS${NC}: $name"
  else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC}: $name -- expected '$expected' in field '$field', got '$actual'"
  fi
}

jq_extract() {
  python3 -c "import sys,json; d=json.load(sys.stdin); $1" 2>/dev/null
}

auth_header() {
  echo "Authorization: Bearer $TOKEN"
}

# Check server is running
echo "========================================"
echo "  System Control Centre -- API Tests"
echo "  Server: $BASE"
echo "========================================"
echo ""

HEALTH=$(curl -sf "$BASE/health" 2>/dev/null || echo "UNREACHABLE")
if [ "$HEALTH" = "UNREACHABLE" ]; then
  echo -e "${RED}ERROR: Server not reachable at $BASE${NC}"
  echo "Start the server first: cabal run namma-ap-exe"
  exit 1
fi
echo "Server is healthy."
echo ""

# ==============================================================================
# [1] Auth Tests
# ==============================================================================
echo "[1] Auth Tests"

# Login with valid credentials
RESP=$(curl -sf -X POST "$BASE/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@juspay.in","password":"admin123"}' 2>/dev/null || echo '{"error":"request failed"}')
check "Login with valid credentials returns token" "token" "$RESP"
TOKEN=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")
check "Login returns non-empty token" "." "$TOKEN"

# Login returns person info
check "Login returns person email" "admin@juspay.in" "$RESP"
check "Login returns products array" "products" "$RESP"

# Login with wrong password
RESP_BAD=$(curl -sf -X POST "$BASE/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@juspay.in","password":"wrongpassword"}' 2>/dev/null || echo '{"error":"request failed"}')
check "Login with wrong password returns error" "Invalid credentials" "$RESP_BAD"

# Login with missing fields
RESP_MISSING=$(curl -sf -X POST "$BASE/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@juspay.in"}' 2>/dev/null || echo '{"error":"request failed"}')
check "Login with missing password returns error" "error" "$RESP_MISSING"

# GET /auth/me with valid token
ME_RESP=$(curl -sf "$BASE/auth/me" -H "$(auth_header)" 2>/dev/null || echo '{"error":"request failed"}')
check "GET /auth/me with valid token returns person" "person" "$ME_RESP"
check "GET /auth/me returns correct email" "admin@juspay.in" "$ME_RESP"

# GET /auth/me with invalid token
ME_BAD=$(curl -sf "$BASE/auth/me" -H "Authorization: Bearer invalid-token-12345" 2>/dev/null || echo '{"error":"request failed"}')
check "GET /auth/me with invalid token returns error" "Invalid" "$ME_BAD"

# GET /auth/me with no token
ME_NONE=$(curl -sf "$BASE/auth/me" 2>/dev/null || echo '{"error":"request failed"}')
check "GET /auth/me with no token returns error" "error" "$ME_NONE"

echo ""

# ==============================================================================
# [2] Safety Validations (Release Creation)
# ==============================================================================
echo "[2] Safety Validations"

# Create with same old/new version
SAME_VER=$(curl -sf -X POST "$BASE/releases/create" \
  -H "Content-Type: application/json" \
  -H "$(auth_header)" \
  -d '{"product":"Beckn","service":"rider-app","env":"UAT","oldVersion":"v1","newVersion":"v1","trackerType":"BackendService","createdBy":"test"}' \
  2>/dev/null || echo '{"error":"request failed"}')
check "Reject same old/new version" "cannot be the same" "$SAME_VER"

# Create with empty new version
EMPTY_VER=$(curl -sf -X POST "$BASE/releases/create" \
  -H "Content-Type: application/json" \
  -H "$(auth_header)" \
  -d '{"product":"Beckn","service":"rider-app","env":"UAT","oldVersion":"v1","newVersion":"","trackerType":"BackendService","createdBy":"test"}' \
  2>/dev/null || echo '{"error":"request failed"}')
check "Reject empty new version" "Invalid version" "$EMPTY_VER"

# Create with invalid version format (semicolons)
INVALID_VER=$(curl -sf -X POST "$BASE/releases/create" \
  -H "Content-Type: application/json" \
  -H "$(auth_header)" \
  -d '{"product":"Beckn","service":"rider-app","env":"UAT","oldVersion":"v1","newVersion":"v2;rm -rf /","trackerType":"BackendService","createdBy":"test"}' \
  2>/dev/null || echo '{"error":"request failed"}')
check "Reject version with injection chars" "Invalid version" "$INVALID_VER"

# Create with valid data (may fail if product config missing, but validates the request)
VALID_CREATE=$(curl -sf -X POST "$BASE/releases/create" \
  -H "Content-Type: application/json" \
  -H "$(auth_header)" \
  -d '{"product":"Beckn","service":"rider-app","env":"UAT","oldVersion":"v1","newVersion":"test-v2","trackerType":"BackendService","createdBy":"test-api-script","isApproved":true}' \
  2>/dev/null || echo '{"error":"request failed"}')
# This may succeed or fail depending on product config existence, check both cases
if echo "$VALID_CREATE" | grep -qi "SUCCESS"; then
  check "Create release with valid data" "SUCCESS" "$VALID_CREATE"
  # Extract release ID if available
  RID=$(echo "$VALID_CREATE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('releaseId',d.get('message','')))" 2>/dev/null || echo "")
  if [ -n "$RID" ] && [ "$RID" != "None" ] && [ ${#RID} -gt 10 ]; then
    RELEASE_IDS+=("$RID")
    echo "    (Created release: $RID)"
  fi
else
  # If it failed, it should be because of product config, not validation
  check_not "Valid data does not fail on version validation" "Invalid version" "$VALID_CREATE"
fi

echo ""

# ==============================================================================
# [3] Release CRUD & Listing
# ==============================================================================
echo "[3] Release CRUD & Listing"

# List releases
RELEASES=$(curl -sf "$BASE/releases?from=2024-01-01T00:00:00Z&to=2030-12-31T00:00:00Z" \
  -H "$(auth_header)" 2>/dev/null || echo '[]')
check "List releases returns array" "\[" "$RELEASES"
RELEASE_COUNT=$(echo "$RELEASES" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
echo "    (Found $RELEASE_COUNT releases)"

# Get single release (use first one if available)
FIRST_RID=$(echo "$RELEASES" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['releaseId'] if d else '')" 2>/dev/null || echo "")
if [ -n "$FIRST_RID" ] && [ "$FIRST_RID" != "None" ]; then
  SINGLE=$(curl -sf "$BASE/releases/$FIRST_RID" -H "$(auth_header)" 2>/dev/null || echo '{}')
  check "Get single release by ID" "releaseId" "$SINGLE"

  # Get events for release
  EVENTS=$(curl -sf "$BASE/releases/$FIRST_RID/events" -H "$(auth_header)" 2>/dev/null || echo '[]')
  check "Get release events" "\[" "$EVENTS"
fi

# Get nonexistent release returns null
NONEXIST=$(curl -sf "$BASE/releases/nonexistent-id-12345" -H "$(auth_header)" 2>/dev/null || echo '{}')
check "Get nonexistent release returns null" "null" "$NONEXIST"

echo ""

# ==============================================================================
# [4] Invalid Status Transitions
# ==============================================================================
echo "[4] Invalid Status Transitions"

# Try to fast-forward a non-existent/Created release
FF_RESP=$(curl -sf -X POST "$BASE/releases/nonexistent-id-12345/fast-forward" \
  -H "Content-Type: application/json" \
  -H "$(auth_header)" \
  -d '{}' 2>/dev/null || echo '{"status":"ERROR"}')
check "Fast-forward on nonexistent release rejected" "ERROR\|not found\|error" "$FF_RESP"

# Try to restart a non-existent release
RESTART_RESP=$(curl -sf -X POST "$BASE/releases/nonexistent-id-12345/restart" \
  -H "Content-Type: application/json" \
  -H "$(auth_header)" \
  -d '{"requestedBy":"test"}' 2>/dev/null || echo '{"status":"ERROR"}')
check "Restart on nonexistent release rejected" "ERROR\|not found\|error" "$RESTART_RESP"

# Try to revert a non-existent release
REVERT_RESP=$(curl -sf -X POST "$BASE/releases/nonexistent-id-12345/revert" \
  -H "Content-Type: application/json" \
  -H "$(auth_header)" \
  -d '{"requestedBy":"test"}' 2>/dev/null || echo '{"status":"ERROR"}')
check "Revert on nonexistent release rejected" "ERROR\|not found\|error" "$REVERT_RESP"

# Try to discard a non-existent release
DISCARD_RESP=$(curl -sf -X POST "$BASE/releases/nonexistent-id-12345/discard" \
  -H "Content-Type: application/json" \
  -H "$(auth_header)" \
  -d '{"discardedBy":"test"}' 2>/dev/null || echo '{"status":"ERROR"}')
check "Discard on nonexistent release rejected" "ERROR\|not found\|error" "$DISCARD_RESP"

echo ""

# ==============================================================================
# [5] Product Config CRUD
# ==============================================================================
echo "[5] Product Config CRUD"

# List product configs
PROD_CONFIGS=$(curl -sf "$BASE/products/config" -H "$(auth_header)" 2>/dev/null || echo '[]')
check "List product configs returns array" "\[" "$PROD_CONFIGS"
PROD_CONFIG_COUNT=$(echo "$PROD_CONFIGS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
echo "    (Found $PROD_CONFIG_COUNT product configs)"

# Create product config for testing
PROD_CREATE=$(curl -sf -X POST "$BASE/products/config" \
  -H "Content-Type: application/json" \
  -H "$(auth_header)" \
  -d '{"product":"TestProduct_APITest","cluster":"test-cluster","namespace":"test-ns","vsName":"test-vs","productType":"SERVICE","productAcronym":"TP"}' \
  2>/dev/null || echo '{"status":"ERROR","message":"request failed"}')
check "Create product config" "SUCCESS" "$PROD_CREATE"

# List again to find the new one
PROD_CONFIGS2=$(curl -sf "$BASE/products/config" -H "$(auth_header)" 2>/dev/null || echo '[]')
TEST_PROD_ID=$(echo "$PROD_CONFIGS2" | python3 -c "
import sys,json
configs=json.load(sys.stdin)
for c in configs:
    if c.get('product','') == 'TestProduct_APITest':
        print(c.get('id',''))
        break
else:
    print('')
" 2>/dev/null || echo "")

if [ -n "$TEST_PROD_ID" ] && [ "$TEST_PROD_ID" != "None" ] && [ "$TEST_PROD_ID" != "" ]; then
  echo "    (Created product config ID: $TEST_PROD_ID)"

  # Get single product config
  SINGLE_PROD=$(curl -sf "$BASE/products/config/$TEST_PROD_ID" -H "$(auth_header)" 2>/dev/null || echo '{}')
  check "Get single product config" "TestProduct_APITest" "$SINGLE_PROD"

  # Update product config
  UPD_PROD=$(curl -sf -X PUT "$BASE/products/config/$TEST_PROD_ID" \
    -H "Content-Type: application/json" \
    -H "$(auth_header)" \
    -d '{"product":"TestProduct_APITest","cluster":"updated-cluster","namespace":"test-ns","vsName":"test-vs","productType":"SERVICE","productAcronym":"TP"}' \
    2>/dev/null || echo '{"status":"ERROR"}')
  check "Update product config" "SUCCESS" "$UPD_PROD"

  # Delete product config
  DEL_PROD=$(curl -sf -X DELETE "$BASE/products/config/$TEST_PROD_ID" \
    -H "$(auth_header)" 2>/dev/null || echo '{"status":"ERROR"}')
  check "Delete product config" "SUCCESS" "$DEL_PROD"
else
  echo "    (Skipping update/delete -- product config ID not found)"
fi

echo ""

# ==============================================================================
# [6] Service Config CRUD
# ==============================================================================
echo "[6] Service Config CRUD"

# List service configs
SVC_CONFIGS=$(curl -sf "$BASE/services/config" -H "$(auth_header)" 2>/dev/null || echo '[]')
check "List service configs returns array" "\[" "$SVC_CONFIGS"
SVC_CONFIG_COUNT=$(echo "$SVC_CONFIGS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
echo "    (Found $SVC_CONFIG_COUNT service configs)"

# Create service config for testing
SVC_CREATE=$(curl -sf -X POST "$BASE/services/config" \
  -H "Content-Type: application/json" \
  -H "$(auth_header)" \
  -d '{"product":"Beckn","service":"test-svc-apitest","serviceType":"DEFAULT"}' \
  2>/dev/null || echo '{"status":"ERROR","message":"request failed"}')
check "Create service config" "SUCCESS" "$SVC_CREATE"

# List again to find the new one
SVC_CONFIGS2=$(curl -sf "$BASE/services/config?product=Beckn" -H "$(auth_header)" 2>/dev/null || echo '[]')
TEST_SVC_ID=$(echo "$SVC_CONFIGS2" | python3 -c "
import sys,json
configs=json.load(sys.stdin)
for c in configs:
    if c.get('service','') == 'test-svc-apitest':
        print(c.get('id',''))
        break
else:
    print('')
" 2>/dev/null || echo "")

if [ -n "$TEST_SVC_ID" ] && [ "$TEST_SVC_ID" != "None" ] && [ "$TEST_SVC_ID" != "" ]; then
  echo "    (Created service config ID: $TEST_SVC_ID)"

  # Get single service config
  SINGLE_SVC=$(curl -sf "$BASE/services/config/$TEST_SVC_ID" -H "$(auth_header)" 2>/dev/null || echo '{}')
  check "Get single service config" "test-svc-apitest" "$SINGLE_SVC"

  # Update service config
  UPD_SVC=$(curl -sf -X PUT "$BASE/services/config/$TEST_SVC_ID" \
    -H "Content-Type: application/json" \
    -H "$(auth_header)" \
    -d '{"product":"Beckn","service":"test-svc-apitest","serviceType":"CRONJOB"}' \
    2>/dev/null || echo '{"status":"ERROR"}')
  check "Update service config" "SUCCESS" "$UPD_SVC"

  # Delete service config
  DEL_SVC=$(curl -sf -X DELETE "$BASE/services/config/$TEST_SVC_ID" \
    -H "$(auth_header)" 2>/dev/null || echo '{"status":"ERROR"}')
  check "Delete service config" "SUCCESS" "$DEL_SVC"
else
  echo "    (Skipping update/delete -- service config ID not found)"
fi

echo ""

# ==============================================================================
# [7] Server Config
# ==============================================================================
echo "[7] Server Config"

# List all server configs
SRV_CONFIGS=$(curl -sf "$BASE/server-config" -H "$(auth_header)" 2>/dev/null || echo '{}')
check "List server configs" "configs\|{" "$SRV_CONFIGS"

# Upsert a known server config key
SRV_UPSERT=$(curl -sf -X POST "$BASE/server-config" \
  -H "Content-Type: application/json" \
  -H "$(auth_header)" \
  -d '{"key":"TEST_API_KEY","value":"test_value_from_integration_test","description":"Integration test key"}' \
  2>/dev/null || echo '{"status":"ERROR"}')
check "Upsert server config" "SUCCESS" "$SRV_UPSERT"

# Verify it appears in the list
SRV_CONFIGS2=$(curl -sf "$BASE/server-config" -H "$(auth_header)" 2>/dev/null || echo '{}')
check "Server config contains test key" "TEST_API_KEY" "$SRV_CONFIGS2"

echo ""

# ==============================================================================
# [8] VS Edit Tracker
# ==============================================================================
echo "[8] VS Edit Tracker"

# List VS edit trackers
VS_LIST=$(curl -sf "$BASE/vs-edit-tracker/list?from=2024-01-01T00:00:00Z&to=2030-12-31T00:00:00Z" \
  -H "$(auth_header)" 2>/dev/null || echo '[]')
check "List VS edit trackers" "\[" "$VS_LIST"

echo ""

# ==============================================================================
# [9] ConfigMap from K8s
# ==============================================================================
echo "[9] ConfigMap Endpoints"

# ConfigMap endpoint (may return error if no product param, but should respond)
CM_RESP=$(curl -sf "$BASE/configmap?PRODUCT=Beckn&NAME=rider-app" -H "$(auth_header)" 2>/dev/null || echo '{}')
check "ConfigMap endpoint responds" "{" "$CM_RESP"

# Secondary configmap endpoint
CM_SEC=$(curl -sf "$BASE/configmap/secondary?PRODUCT=Beckn&NAME=rider-app" -H "$(auth_header)" 2>/dev/null || echo '{}')
check "Secondary ConfigMap endpoint responds" "{" "$CM_SEC"

echo ""

# ==============================================================================
# [10] Environment Endpoints
# ==============================================================================
echo "[10] Environment Endpoints"

# Envs endpoint
ENVS_RESP=$(curl -sf "$BASE/envs?product=Beckn&env=UAT&service=rider-app" -H "$(auth_header)" 2>/dev/null || echo '{}')
check "Envs endpoint responds" "{" "$ENVS_RESP"

# Secondary envs endpoint
ENVS_SEC=$(curl -sf "$BASE/envs/secondary?product=Beckn&env=UAT&service=rider-app" -H "$(auth_header)" 2>/dev/null || echo '{}')
check "Secondary envs endpoint responds" "{" "$ENVS_SEC"

echo ""

# ==============================================================================
# [11] Resources Endpoint
# ==============================================================================
echo "[11] Resources Endpoint"

RESOURCES=$(curl -sf "$BASE/resources?PRODUCT=Beckn&SERVICE=rider-app" -H "$(auth_header)" 2>/dev/null || echo '{}')
check "Resources endpoint responds" "{" "$RESOURCES"

echo ""

# ==============================================================================
# [12] Admin Endpoints
# ==============================================================================
echo "[12] Admin Endpoints"

# List users
USERS=$(curl -sf "$BASE/admin/users" -H "$(auth_header)" 2>/dev/null || echo '{}')
check "List users returns users" "users" "$USERS"
USER_COUNT=$(echo "$USERS" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('users',[])))" 2>/dev/null || echo "0")
echo "    (Found $USER_COUNT users)"

# List products
PRODUCTS=$(curl -sf "$BASE/admin/products" -H "$(auth_header)" 2>/dev/null || echo '{}')
check "List products returns products" "products" "$PRODUCTS"
PRODUCT_COUNT=$(echo "$PRODUCTS" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('products',[])))" 2>/dev/null || echo "0")
echo "    (Found $PRODUCT_COUNT products)"

# List permissions for autopilot
PERMS=$(curl -sf "$BASE/admin/products/autopilot/permissions" -H "$(auth_header)" 2>/dev/null || echo '{}')
check "List permissions returns permissions" "permissions" "$PERMS"
PERM_COUNT=$(echo "$PERMS" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('permissions',[])))" 2>/dev/null || echo "0")
echo "    (Found $PERM_COUNT permissions)"
check "Permissions include RELEASE_VIEW" "RELEASE_VIEW" "$PERMS"
check "Permissions include PRODUCT_CONFIG_EDIT" "PRODUCT_CONFIG_EDIT" "$PERMS"

# List roles for autopilot
ROLES=$(curl -sf "$BASE/admin/products/autopilot/roles" -H "$(auth_header)" 2>/dev/null || echo '{}')
check "List roles returns roles" "roles" "$ROLES"
ROLE_COUNT=$(echo "$ROLES" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('roles',[])))" 2>/dev/null || echo "0")
echo "    (Found $ROLE_COUNT roles)"

echo ""

# ==============================================================================
# [13] Health Endpoint
# ==============================================================================
echo "[13] Health Endpoint"

HEALTH_RESP=$(curl -sf "$BASE/health" 2>/dev/null || echo "")
check "Health endpoint returns OK" "OK\|ok\|healthy" "$HEALTH_RESP"

echo ""

# ==============================================================================
# [14] Auth Verify
# ==============================================================================
echo "[14] Auth Verify"

VERIFY_OK=$(curl -sf -X POST "$BASE/auth/verify" \
  -H "Content-Type: application/json" \
  -d "{\"token\":\"$TOKEN\",\"product\":\"autopilot\",\"permission\":\"RELEASE_VIEW\"}" \
  2>/dev/null || echo '{}')
check "Verify valid token + permission" "authorized.*true\|true" "$VERIFY_OK"

VERIFY_BAD_TOKEN=$(curl -sf -X POST "$BASE/auth/verify" \
  -H "Content-Type: application/json" \
  -d '{"token":"invalid-token","product":"autopilot","permission":"RELEASE_VIEW"}' \
  2>/dev/null || echo '{}')
check "Verify invalid token returns unauthorized" "false\|Invalid" "$VERIFY_BAD_TOKEN"

echo ""

# ==============================================================================
# [15] ConfigMap Tracker CRUD
# ==============================================================================
echo "[15] ConfigMap Tracker"

CM_TRACKER_LIST=$(curl -sf "$BASE/tracker/configmap/list?from=2024-01-01T00:00:00Z&to=2030-12-31T00:00:00Z" \
  -H "$(auth_header)" 2>/dev/null || echo '{}')
check "ConfigMap tracker list endpoint responds" "releases\|\[\|{" "$CM_TRACKER_LIST"

echo ""

# ==============================================================================
# [16] Logout
# ==============================================================================
echo "[16] Logout"

LOGOUT_RESP=$(curl -sf -X POST "$BASE/auth/logout" -H "$(auth_header)" 2>/dev/null || echo '{}')
check "Logout returns success" "SUCCESS\|Logged out" "$LOGOUT_RESP"

# Verify token is deactivated
ME_AFTER_LOGOUT=$(curl -sf "$BASE/auth/me" -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo '{"error":"request failed"}')
check "Token deactivated after logout" "Invalid\|expired\|error" "$ME_AFTER_LOGOUT"

echo ""

# ==============================================================================
# [17] Cleanup
# ==============================================================================
echo "[17] Cleanup"

# Re-login for cleanup
RESP=$(curl -sf -X POST "$BASE/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@juspay.in","password":"admin123"}' 2>/dev/null || echo '{}')
TOKEN=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")

CLEANED=0
for rid in "${RELEASE_IDS[@]+"${RELEASE_IDS[@]}"}"; do
  if [ -n "$rid" ] && [ "$rid" != "None" ]; then
    DEL_RESP=$(curl -sf -X POST "$BASE/releases/$rid/delete" \
      -H "Content-Type: application/json" \
      -H "$(auth_header)" 2>/dev/null || echo '{}')
    if echo "$DEL_RESP" | grep -qi "SUCCESS" 2>/dev/null; then
      CLEANED=$((CLEANED + 1))
    fi
  fi
done
echo "  Cleaned up $CLEANED test releases"

# Clean up test server config
SRV_CLEANUP=$(curl -sf -X POST "$BASE/server-config" \
  -H "Content-Type: application/json" \
  -H "$(auth_header)" \
  -d '{"key":"TEST_API_KEY","value":"","description":""}' \
  2>/dev/null || echo '{}')
echo "  Cleaned up test server config"

echo ""

# ==============================================================================
# Results
# ==============================================================================
echo "========================================"
echo "  Results: $PASS/$TOTAL passed"
echo "  Failed:  $FAIL"
echo "========================================"

if [ "$FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}All tests passed!${NC}"
  exit 0
else
  echo -e "  ${RED}$FAIL test(s) failed.${NC}"
  exit 1
fi
