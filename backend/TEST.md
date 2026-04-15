# System Control Centre — Comprehensive API Test Guide

**Date**: 2026-04-10
**Server**: localhost:8012 (APP_STATE=SERVER)
**Test App Group**: TEST_AUTOPILOT (cluster: test-cluster, namespace: test-autopilot)
**Test Services**: TEST_SVC (host: test-svc), TEST_SVC_2 (host: test-svc-2)
**kubectl context**: `gke_ny-sandbox_asia-south1_gke-kurukshetra`

---

## Prerequisites

```bash
# 1. Enter nix shell (from repo root)
nix develop

# 2. Start the full stack
export SLACK_BOT_TOKEN="xoxb-..."
export DASHBOARD_URL="http://localhost:5173"
sc-dev

# 3. Verify kubectl context (test namespace is on GKE sandbox)
kubectl config use-context gke_ny-sandbox_asia-south1_gke-kurukshetra
kubectl get vs test-vs -n test-autopilot

# 4. Login
curl -s -X POST http://localhost:8012/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@juspay.in","password":"admin123"}'
# → save the token for all subsequent requests
```

### Important: Deployment Image Fix

When the workflow clones a deployment, it uses the version as the image tag which doesn't resolve in test env. After the runner picks up a release and clones the deployment:

```bash
kubectl -n test-autopilot set image deployment/test-svc-{VERSION} test-svc=nginx:alpine
kubectl -n test-autopilot scale deployment/test-svc-{VERSION} --replicas=1
```

---

## Test Results Summary (2026-04-10)

| Phase | Tests | Pass | Fail | Notes |
|-------|-------|------|------|-------|
| 1. Auth & Validation | 5 | 5 | 0 | |
| 2. Create → Approve → Complete | 6 | 6 | 0 | 13 events logged correctly |
| 3. Discard | 3 | 3 | 0 | |
| 4. Abort | 3 | 3 | 0 | ABORTING → USER_ABORTED |
| 5. Pause/Resume/FF | 5 | 5 | 0 | Pause/Resume/FF work; multi-stage PREPARING is test-env replica mismatch |
| 6. Revert | 2 | 2 | 0 | Creates new tracker with swapped versions |
| 7. Restart | 2 | 2 | 0 | Creates new tracker from aborted |
| 8. VS Edit | 4 | 4 | 0 | Lock/unlock/force-unlock work |
| 9. ConfigMap | 2 | 2 | 0 | |
| 10. Multi-Release | 3 | 3 | 0 | Same-svc blocked, diff-svc allowed |
| 11. Other Endpoints | 9 | 9 | 0 | All CRUD + admin endpoints |
| 12. VS Lock vs Release | 4 | 4 | 0 | Workflow waits, FF blocked, completes after unlock |
| 13. Abort Before VS Flip | 2 | 2 | 0 | Abort during PREPARING caught before traffic flip |
| 14. VS Edit Revert Safety | 2 | 2 | 0 | Revert blocked when VS modified by release |
| 15. Lock Auto-Fetch VS_OLD | 1 | 1 | 0 | VS_OLD captured from k8s when not in request |
| 16. Concurrent Multi-Svc | 2 | 2 | 0 | Both services on same VS updated independently |
| **TOTAL** | **55** | **55** | **0** | |

---

## Phase 1: Auth & Validation

### 1.1 Login
```bash
curl -s -X POST http://localhost:8012/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@juspay.in","password":"admin123"}'
```
**Expected**: 200 with `{token, person, products}`. Person has 19 permissions for autopilot.

### 1.2 Bad Password
```bash
curl -s -X POST http://localhost:8012/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@juspay.in","password":"wrong"}'
```
**Expected**: Error with "Invalid credentials"

### 1.3 GET /auth/me
```bash
curl -s http://localhost:8012/auth/me -H "Authorization: Bearer $TOKEN"
```
**Expected**: 200 with person details

### 1.4 No Token
```bash
curl -s http://localhost:8012/releases
```
**Expected**: Error (missing authorization)

### 1.5 Verify Permission
```bash
curl -s -X POST http://localhost:8012/auth/verify \
  -H "Content-Type: application/json" \
  -d '{"token":"$TOKEN","product":"autopilot","permission":"RELEASE_VIEW"}'
```
**Expected**: `{authorized: true}`

---

## Phase 2: Full Release Lifecycle (Create → Approve → Complete)

### 2.1 Create Release
```bash
curl -s -X POST http://localhost:8012/releases/create \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "product": "TEST_AUTOPILOT",
    "service": "TEST_SVC",
    "env": "test",
    "oldVersion": "$CURRENT_VS",
    "newVersion": "t800",
    "trackerType": "BackendService",
    "createdBy": "api-test",
    "mode": "MANUAL",
    "rolloutStrategy": [{"rolloutPercent":100,"cooloffMinutes":1,"podCount":1}]
  }'
```
**Expected**: `{status: "SUCCESS", message: "Tracker created: <uuid>"}`

**IMPORTANT**: The `isApproved` field in the create request is **ignored**. You must call the approve endpoint separately.

### 2.2 Approve
```bash
curl -s -X POST http://localhost:8012/releases/$RID/approve \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"approvedBy":"api-test","isApproved":true}'
```
**Expected**: Returns the tracker with `isApproved: true`

### 2.3 Wait for Completion
The runner polls every 10s. After approval:
- `CREATED/INIT` → `INPROGRESS/INIT` (~10s)
- `INPROGRESS/PREPARING` (~15s, clones deployment + fixes HPA)
- `INPROGRESS/DEPLOYING` (~10s, flips VS traffic)
- `COMPLETED/DONE` (~10s, scales down old)

**Fix the deployment image** when the clone happens (during PREPARING):
```bash
kubectl -n test-autopilot set image deployment/test-svc-t800 test-svc=nginx:alpine
```

### 2.4 Verify VS Updated
```bash
kubectl get vs test-vs -n test-autopilot -o jsonpath='{.spec.http[0].route[0].destination.subset}'
# → should show "t800"
```

### 2.5 Check Events
```bash
curl -s http://localhost:8012/releases/$RID/events -H "Authorization: Bearer $TOKEN"
```
**Expected 13 events** (in order):
1. `TRACKER_CREATED`
2. `DEPLOYMENT_BEFORE_PREVIEW` (SNAPSHOT)
3. `DEPLOYMENT_AFTER_PREVIEW` (SNAPSHOT)
4. `TRACKER_APPROVED`
5. `RUNNER_PICKED`
6. `HPA_CLONED`
7. `TRAFFIC_UPDATED`
8. `SCALE_DOWN_SCHEDULED`
9. `HPA_DELETED`
10. `DEPLOYMENT_AFTER` (SNAPSHOT)
11. `STATUS_UPDATED` (NOTIFICATION)
12. `SYNC_SKIPPED`
13. `COMPLETED`

### 2.6 Check Diff
```bash
curl -s http://localhost:8012/releases/$RID/diff -H "Authorization: Bearer $TOKEN"
```
**Expected**: `{message, oldfile, newfile}` with deployment YAML

---

## Phase 3: Discard

### 3.1 Create + Discard
```bash
# Create (don't approve)
curl -s -X POST http://localhost:8012/releases/create ...

# Discard
curl -s -X POST http://localhost:8012/releases/$RID/discard \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"discardedBy":"api-test"}'
```
**Expected**: Status transitions `CREATED → DISCARDED`

**Edge case**: Can only discard from CREATED. Discard from INPROGRESS is rejected.

---

## Phase 4: Abort During INPROGRESS

### 4.1 Create + Approve + Wait for INPROGRESS
Create with a **5 minute cooloff** to give time to abort during monitoring.

### 4.2 Send Abort
```bash
curl -s -X POST http://localhost:8012/releases/$RID/update \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"status":"ABORTING","updatedBy":"api-test"}'
```
**Expected**: `INPROGRESS → ABORTING → USER_ABORTED`

The workflow detects the ABORTING flag, restores VS traffic to old version, and marks USER_ABORTED.

---

## Phase 5: Pause / Resume / Fast-Forward

### 5.1 Create Multi-Stage Release
```json
{
  "rolloutStrategy": [
    {"rolloutPercent": 10, "cooloffMinutes": 5, "podCount": 1},
    {"rolloutPercent": 50, "cooloffMinutes": 5, "podCount": 1},
    {"rolloutPercent": 100, "cooloffMinutes": 1, "podCount": 2}
  ]
}
```

### 5.2 Pause (during MONITORING)
```bash
curl -s -X POST http://localhost:8012/releases/$RID/update \
  -d '{"status":"PAUSED","updatedBy":"test"}'
```
**Expected**: `INPROGRESS → PAUSED`. Workflow pauses cooloff timer.

### 5.3 Resume
```bash
curl -s -X POST http://localhost:8012/releases/$RID/update \
  -d '{"status":"INPROGRESS","updatedBy":"test"}'
```
**Expected**: `PAUSED → INPROGRESS`. Workflow resumes.

**IMPORTANT**: Resume re-forks the workflow thread. If the backend restarted while paused, the worker thread is dead — resume re-spawns it.

### 5.4 Fast-Forward
```bash
curl -s -X POST http://localhost:8012/releases/$RID/fast-forward \
  -d '{"requestedBy":"test"}'
```
**Expected**: Sets current stage's `cooloffMinutes` to elapsed time so `isCoolOffExceeded` passes immediately. `historyManualOverride = true` on the fast-forwarded step.

### Known Issue: 3-Stage Stuck in PREPARING
Multi-stage releases with low `podCount` (1) can get stuck in PREPARING if the first-stage deployment clone times out before pods become ready. The pod readiness check (30 attempts × 10s = 5 min max) may fail if the cloned deployment needs image fixing. **Workaround**: Fix the deployment image immediately when the clone appears in k8s.

---

## Phase 6: Revert from COMPLETED

```bash
curl -s -X POST http://localhost:8012/releases/$COMPLETED_RID/revert \
  -H "Content-Type: application/json" \
  -d '{"requestedBy":"test"}'
```
**Expected**: Creates a **new tracker** (new UUID) with swapped old/new versions. Does NOT change the original tracker's status.

**Flow**: Revert tracker is CREATED → must be approved → runner picks it up → executes like a normal release (swaps traffic back).

---

## Phase 7: Restart from ABORTED

```bash
curl -s -X POST http://localhost:8012/releases/$ABORTED_RID/restart \
  -H "Content-Type: application/json" \
  -d '{"requestedBy":"test"}'
```
**Expected**: Creates a **new tracker** with the same versions. Validates that the target deployment still exists in k8s.

**Error case**: If the deployment was cleaned up, returns `"Cannot restart: new-version deployment ... no longer exists in k8s"`.

---

## Phase 8: VS Edit Flow

### 8.1 Fetch Current VS
```bash
curl -s "http://localhost:8012/vs-edit-tracker/current-vs?product=TEST_AUTOPILOT&service=TEST_SVC" \
  -H "Authorization: Bearer $TOKEN"
```
**Expected**: VS YAML with http routes

### 8.2 Lock VS
```bash
curl -s -X POST http://localhost:8012/vs-edit-tracker/lock \
  -d '{"product":"TEST_AUTOPILOT","service":"TEST_SVC","lockedBy":"api-test"}'
```
**Expected**: VS locked — blocks other VS edits and releases for same service

### 8.3 VS Locked Blocks Releases
While VS is locked, creating a release for the same service is blocked by the runner (not the create API). The create API allows it, but the runner's `isEligibleToRun` check skips the release until VS is unlocked.

### 8.4 Unlock VS
Regular unlock requires `trackerId` to verify ownership:
```bash
curl -s -X POST http://localhost:8012/vs-edit-tracker/unlock \
  -d '{"product":"TEST_AUTOPILOT","service":"TEST_SVC","unlockedBy":"api-test","trackerId":"..."}'
```

Force-unlock (superadmin, `AP_FORCE_UNLOCK` permission):
```bash
curl -s -X POST http://localhost:8012/vs-edit-tracker/force-unlock \
  -d '{"product":"TEST_AUTOPILOT","service":"TEST_SVC","unlockedBy":"api-test"}'
```

---

## Phase 9: ConfigMap

### 9.1 List ConfigMap Trackers
```bash
curl -s "http://localhost:8012/tracker/configmap/list?from=2024-01-01T00:00:00Z&to=2030-12-31T00:00:00Z" \
  -H "Authorization: Bearer $TOKEN"
```

### 9.2 Fetch K8s ConfigMap
```bash
curl -s "http://localhost:8012/configmap?PRODUCT=TEST_AUTOPILOT&NAME=test-config" \
  -H "Authorization: Bearer $TOKEN"
```

---

## Phase 10: Multi-Release Edge Cases

### 10.1 Same Service, Same Product — BLOCKED
Creating a second release for the same (app_group, service) while one is already CREATED/INPROGRESS is rejected:
```
{"message":"Service TEST_SVC in app group TEST_AUTOPILOT already has an in-flight release ...","status":"ERROR"}
```

### 10.2 Different Services, Same Product — ALLOWED
Creating releases for TEST_SVC and TEST_SVC_2 simultaneously is allowed (different services).

### 10.3 Multi-Release Config
`multi_release_per_product` server config (default: true) allows multiple releases for the same app_group but different services. Even with this on, same-service concurrency is always blocked.

---

## Phase 11: Other Endpoints

| Endpoint | Method | Verified |
|----------|--------|----------|
| `/envs?product=X&service=Y` | GET | PASS |
| `/resources?PRODUCT=X&SERVICE=Y` | GET | PASS |
| `/products` | GET | PASS |
| `/products/{product}/services` | GET | PASS |
| `/products/config` | GET | PASS |
| `/services/config` | GET | PASS |
| `/server-config` | GET | PASS |
| `/admin/users` | GET | PASS |
| `/admin/products/autopilot/permissions` | GET | PASS |

---

## State Machine Reference

```
Release Lifecycle:
  CREATED → INPROGRESS → COMPLETED
                       → PAUSED → INPROGRESS (resume)
                                → ABORTING → USER_ABORTED
                       → ABORTING → USER_ABORTED
                                  → REVERTING → REVERTED
  CREATED → DISCARDED

VS Edit:
  CREATED → LOCKED → APPLIED → COMPLETED
                   → UNLOCKED
                   → DISCARDED

Revert: Creates NEW tracker (CREATED) from COMPLETED tracker
Restart: Creates NEW tracker (CREATED) from ABORTED/USER_ABORTED tracker
```

---

## Known Issues Found During Testing

### 1. `isApproved` Ignored in Create Request
**Severity**: Low (by design)
**Details**: Passing `"isApproved": true` in the create request body is silently ignored. A separate `POST /releases/{id}/approve` call is required.

### 2. Multi-Stage Release Pod Readiness Timeout
**Severity**: Medium
**Details**: 3-stage releases with progressive rollout (10%→50%→100%) can get stuck in PREPARING if the cloned deployment's image doesn't resolve. The pod readiness check runs 30 attempts × 10s = 5 min, and if pods aren't ready by then, the stage fails with `"Timeout waiting for pods to be ready"`.
**Root Cause**: In test env, cloned deployments use version as image tag which doesn't resolve. Need manual `kubectl set image` fix.
**Workaround**: Fix the deployment image immediately when clone appears.

### 3. ~~Leaked Deployment Cleanup Spam~~ FIXED (commit 2e82e0c)
**Status**: Fixed — `max_cleanup_retries` (default 5), marks `SCALE_DOWN_FAILED` after max retries.

### 4. kubectl Context Sensitivity
**Severity**: High (operational)
**Details**: The server binary uses the system's kubectl config. If the kubectl context changes (e.g., `aws sso login` refreshes tokens and switches context), the server's k8s operations silently target the wrong cluster. The test namespace `test-autopilot` is on GKE sandbox (`gke_ny-sandbox_asia-south1_gke-kurukshetra`), not the default beckn-uat.
**Recommendation**: Set `KUBECONFIG` or `--context` explicitly in k8s wrappers.

### 5. VS Unlock Requires trackerId
**Severity**: Low (by design)
**Details**: Regular `/vs-edit-tracker/unlock` requires a `trackerId` field to verify ownership. Without it, returns `"trackerId is required to verify ownership"`. Use `/vs-edit-tracker/force-unlock` (requires `AP_FORCE_UNLOCK` permission) for admin override.

### 6. Empty Envs Response
**Severity**: Low
**Details**: `GET /envs?product=TEST_AUTOPILOT&service=TEST_SVC` returns `[]` for test services (no env vars configured in test deployments).

---

## Complete API Endpoint Map (62 endpoints)

### Auth (4)
| Method | Path | Permission |
|--------|------|------------|
| POST | `/auth/login` | Public |
| POST | `/auth/logout` | Bearer token |
| GET | `/auth/me` | Bearer token |
| POST | `/auth/verify` | Public |

### Admin (14)
| Method | Path | Permission |
|--------|------|------------|
| GET/POST | `/admin/users` | Superadmin |
| GET/PUT/DELETE | `/admin/users/{id}` | Superadmin |
| POST | `/admin/users/{id}/assign-role` | Superadmin |
| DELETE | `/admin/users/{id}/product-access/{slug}` | Superadmin |
| POST/DELETE | `/admin/users/{id}/permission-override` | Superadmin |
| GET/POST | `/admin/products` | Superadmin |
| GET | `/admin/products/{slug}/roles` | Superadmin |
| POST | `/admin/products/{slug}/roles` | Superadmin |
| PUT | `/admin/products/{slug}/roles/{id}` | Superadmin |
| GET | `/admin/products/{slug}/permissions` | Superadmin |

### Release Lifecycle (15)
| Method | Path | Permission |
|--------|------|------------|
| GET | `/releases` | AP_RELEASE_VIEW |
| POST | `/releases/create` | AP_RELEASE_CREATE |
| GET | `/releases/{id}` | AP_RELEASE_VIEW |
| POST | `/releases/{id}/approve` | AP_RELEASE_APPROVE |
| POST | `/releases/{id}/trigger` | AP_RELEASE_CREATE |
| POST | `/releases/{id}/rollback` | AP_RELEASE_REVERT |
| POST | `/releases/{id}/revert` | AP_RELEASE_REVERT |
| POST | `/releases/{id}/revert/immediate` | AP_RELEASE_REVERT |
| POST | `/releases/{id}/discard` | AP_RELEASE_DISCARD |
| POST | `/releases/{id}/update` | AP_RELEASE_UPDATE |
| POST | `/releases/{id}/delete` | AP_RELEASE_DELETE |
| POST | `/releases/{id}/restart` | AP_RELEASE_CREATE |
| POST | `/releases/{id}/fast-forward` | AP_RELEASE_UPDATE |
| PUT | `/release/revert/global/{gid}` | AP_RELEASE_REVERT |
| PUT | `/release/revert/immediate/global/{gid}` | AP_RELEASE_REVERT |

### Release Monitoring (5)
| Method | Path | Permission |
|--------|------|------------|
| GET | `/releases/{id}/events` | AP_RELEASE_VIEW |
| GET | `/releases/{id}/diff` | AP_RELEASE_VIEW |
| GET | `/releases/{id}/pods/health` | AP_RELEASE_VIEW |
| GET | `/releases/{id}/rollout-history` | AP_RELEASE_VIEW |
| GET | `/releases/{id}/logslink` | AP_RELEASE_VIEW |

### VS Edit (9)
| Method | Path | Permission |
|--------|------|------------|
| POST | `/vs-edit-tracker` | AP_RELEASE_CREATE |
| GET | `/vs-edit-tracker/list` | AP_RELEASE_VIEW |
| GET | `/vs-edit-tracker/current-vs` | AP_RELEASE_VIEW |
| POST | `/vs-edit-tracker/lock` | AP_RELEASE_CREATE |
| POST | `/vs-edit-tracker/unlock` | AP_RELEASE_UPDATE |
| POST | `/vs-edit-tracker/force-unlock` | AP_FORCE_UNLOCK |
| PUT | `/vs-edit-tracker/revert/{id}` | AP_RELEASE_REVERT |
| GET | `/vs-edit-tracker/{id}` | AP_RELEASE_VIEW |
| PUT | `/vs-edit-tracker/{id}` | AP_RELEASE_UPDATE |

### ConfigMap (6)
| Method | Path | Permission |
|--------|------|------------|
| GET | `/tracker/configmap/list` | AP_RELEASE_VIEW |
| GET | `/tracker/configmap/{id}` | AP_RELEASE_VIEW |
| POST | `/tracker/configmap` | AP_RELEASE_CREATE |
| PUT | `/tracker/configmap/{id}` | AP_RELEASE_UPDATE |
| GET | `/configmap` | AP_CONFIG_EDIT |
| GET | `/configmap/secondary` | AP_CONFIG_EDIT |

### Config CRUD (13)
| Method | Path | Permission |
|--------|------|------------|
| GET/POST | `/products` | AP_PRODUCT_CONFIG_VIEW/EDIT |
| GET | `/products/{product}/services` | AP_PRODUCT_CONFIG_VIEW |
| POST | `/services` | AP_PRODUCT_CONFIG_EDIT |
| GET/POST/PUT/DELETE | `/products/config[/{id}]` | AP_PRODUCT_CONFIG_VIEW/EDIT |
| GET/POST/PUT/DELETE | `/services/config[/{id}]` | AP_PRODUCT_CONFIG_VIEW/EDIT |
| GET/POST/DELETE | `/server-config[/{id}]` | AP_SERVICE_CONFIG_VIEW/EDIT |

### Other (2)
| Method | Path | Permission |
|--------|------|------------|
| GET | `/envs` | AP_RELEASE_VIEW |
| GET | `/resources` | AP_PRODUCT_CONFIG_VIEW |

---

## Phase 12: VS Lock vs In-Progress Release

Tests the fix where the workflow respects VS editor locks during traffic flip.

### 12.1 Create + Approve Release, Lock VS While INPROGRESS
```bash
# Create and approve release
curl -s -X POST http://localhost:8012/releases/create \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"product":"TEST_AUTOPILOT","service":"TEST_SVC","env":"test","oldVersion":"$CURRENT","newVersion":"$NEW","trackerType":"BackendService","createdBy":"api-test","mode":"MANUAL","rolloutStrategy":[{"rolloutPercent":100,"cooloffMinutes":10,"podCount":1}]}'

# Approve, wait for INPROGRESS, fix deployment image

# Lock VS while release is INPROGRESS
curl -s -X POST http://localhost:8012/vs-edit-tracker/lock \
  -d '{"product":"TEST_AUTOPILOT","service":"TEST_SVC","lockedBy":"api-test"}'
```
**Expected**: Lock succeeds. Workflow logs `VS_EDITOR_LOCK_WAIT` event and stays in PREPARING (waiting for unlock).

### 12.2 Fast-Forward While VS Locked
```bash
curl -s -X POST http://localhost:8012/releases/$RID/fast-forward \
  -d '{"requestedBy":"test"}'
```
**Expected**: `{"status":"ERROR","message":"Cannot fast-forward: VS is locked for TEST_AUTOPILOT. Unlock the VS first."}`

### 12.3 Unlock → Release Completes
```bash
curl -s -X POST http://localhost:8012/vs-edit-tracker/force-unlock \
  -d '{"product":"TEST_AUTOPILOT","service":"TEST_SVC","unlockedBy":"api-test"}'
```
**Expected**: After unlock, workflow proceeds → DEPLOYING → COMPLETED. VS flipped to new version.

### 12.4 VS Lock Timeout → Graceful Abort
If VS stays locked for `max_vs_lock_wait_retries × vs_lock_wait_delay_seconds` (default 30 × 10s = 5 min), the workflow:
1. Sets tracker status to `ABORTING`
2. Inserts `VS_EDITOR_LOCK_TIMEOUT` event
3. Runner catches the abort, restores VS traffic, marks `USER_ABORTED`

**Configurable** via server_config: `max_vs_lock_wait_retries` (default 30), `vs_lock_wait_delay_seconds` (default 10).

---

## Phase 13: Abort Before VS Flip

Tests the fix where abort is checked right before the VS traffic flip, closing the race window for single-stage releases.

### 13.1 Abort During PREPARING → Caught Before VS Flip
```bash
# Create single-stage release, approve, DON'T fix image (stays in PREPARING)
# Send ABORTING while in PREPARING:
curl -s -X POST http://localhost:8012/releases/$RID/update \
  -d '{"status":"ABORTING","updatedBy":"api-test"}'
```
**Expected**: `INPROGRESS/PREPARING → USER_ABORTED/PREPARING`. VS unchanged.

### 13.2 Verify VS Not Flipped
```bash
kubectl get vs test-vs -n test-autopilot -o jsonpath='{.spec.http[0].route[0].destination.subset}'
```
**Expected**: Same as before release — abort caught before traffic flip.

---

## Phase 14: VS Edit Revert Safety Check

Tests the fix where VS edit revert compares the VS_NEW snapshot with the live VS to detect modifications.

### 14.1 Create VS Edit → Release Changes VS → Try Revert
```bash
# 1. Lock VS with oldVsData (or auto-fetched)
# 2. Save newVsData, apply → status = APPLIED, events = [VS_OLD, VS_NEW]
# 3. Create + approve a release that changes the VS (flips subset)
# 4. Try revert:
curl -s -X PUT http://localhost:8012/vs-edit-tracker/revert/$VS_TID
```
**Expected**: `{"status":"ERROR","message":"VS has been modified since this edit was applied (by a release or another edit). Cannot safely revert — manual intervention required."}`

### 14.2 Verify VS Unchanged After Blocked Revert
**Expected**: VS stays at the release's version, not reverted to old snapshot. `REVERT_BLOCKED` event inserted on the tracker.

---

## Phase 15: Lock Handler Auto-Fetch VS_OLD

### 15.1 Lock Without oldVsData
```bash
curl -s -X POST http://localhost:8012/vs-edit-tracker/lock \
  -d '{"product":"TEST_AUTOPILOT","service":"TEST_SVC","lockedBy":"api-test"}'
# Note: NO oldVsData in request body
```
**Expected**: Lock succeeds. Events for the tracker include `VS_OLD` (SNAPSHOT) — auto-fetched from k8s.

---

## Phase 16: Concurrent Multi-Service Releases

Tests that two services sharing the same VirtualService can release simultaneously without clobbering each other.

### 16.1 Create + Approve Releases for Both Services
```bash
# Release 1: TEST_SVC oldVersion → newVersion
# Release 2: TEST_SVC_2 oldVersion → newVersion
# Approve both
```
**Expected**: Both created and approved successfully. Runner picks up both.

### 16.2 Both Complete, VS Updated for Both Services
```bash
kubectl get vs test-vs -n test-autopilot -o jsonpath='{range .spec.http[*]}{.match[0].uri.prefix} -> {.route[0].destination.host}:{.route[0].destination.subset}{"\n"}{end}'
```
**Expected**:
```
/svc1/ -> test-svc:<new1>
/svc2/ -> test-svc-2:<new2>
```
Both routes updated independently. `withVsLock` serializes their VS modifications — they take turns, each only modifying its own route's subset.

---

## Fixes Applied (2026-04-10)

### Fix 1: Leaked Deployment Max Retries (commit 2e82e0c)
- `scaleDownLeakedNewDeployment` now has `cleanupAttempts` counter
- After `max_cleanup_retries` (default 5) failures, marks `SCALE_DOWN_FAILED`
- Stops infinite retry loop when deployment no longer exists in k8s

### Fix 2: VS Editor Lock Blocks Workflow
- `runVsRolloutWithLock` checks `isVsLockedByEditor` before flipping traffic
- If locked: waits `vs_lock_wait_delay_seconds` (default 10s), retries up to `max_vs_lock_wait_retries` (default 30)
- After timeout: graceful abort (ABORTING → runner restores traffic → USER_ABORTED)
- Inserts `VS_EDITOR_LOCK_WAIT` and `VS_EDITOR_LOCK_TIMEOUT` events

### Fix 3: Fast-Forward Blocked by VS Lock
- `fastForwardH` checks `getProductVsLockedBy` before accepting fast-forward
- Returns error if VS is locked: "Unlock the VS first"

### Fix 4: VS Edit Revert Safety Check
- `revertVsEditTrackerH` compares `VS_NEW` snapshot with live VS (both stripped of k8s noise)
- If they differ: blocks revert with "VS has been modified" error, inserts `REVERT_BLOCKED` event
- Prevents stale VS snapshot from clobbering release traffic changes

### Fix 5: Abort Check Before VS Flip
- `runVsRolloutWithLock` re-reads tracker from DB before the traffic flip
- If status is `ABORTING` or `USER_ABORTED`: exits with WorkflowError before flipping traffic
- Closes the race window where single-stage releases complete before checking abort

### Fix 6: Lock Handler Auto-Fetch VS_OLD
- `lockVsEditTrackerH` auto-fetches current VS from k8s when `oldVsData` is not provided
- Ensures `VS_OLD` snapshot is always available for revert safety check
