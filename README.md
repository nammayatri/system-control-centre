# System Control Centre

Centralized release management and configuration platform with role-based access control, automated deployment workflows, and progressive rollout strategies for Kubernetes-based backend services, mobile apps, and infrastructure.

## Architecture

The system follows a two-layer architecture: **Core** (authentication, RBAC, admin) and **Products** (self-contained product modules that plug into the core).

- **Backend**: Haskell (Servant HTTP framework + Beam ORM + PostgreSQL). Products and permissions are defined as Haskell ADTs, not database rows -- the compiler enforces completeness.
- **Frontend**: React + TypeScript + Vite + TailwindCSS.
- **Background Runner**: A polling loop that picks up approved releases and dispatches them to category-specific workflow executors. Includes an abort handler, pod polling with CrashLoopBackOff detection, delayed scale-down of old deployments, and version validation before execution.

```
                    +---------------------------+
                    |      React Frontend       |
                    |  (TypeScript + Vite + TW) |
                    |         :5173             |
                    +------------+--------------+
                                 |
                    +------------v--------------+
                    |     Haskell Backend        |
                    |         :8012             |
                    |                           |
                    |  Core/                    |
                    |    Auth (login, RBAC)     |
                    |    Admin (users, roles)   |
                    |    Config (bootstrap)     |
                    |                           |
                    |  Products/                |
                    |    Autopilot/             |
                    |      Actions/ (5 modules) |
                    |      Routes (API wiring)  |
                    |      Workflows            |
                    |      Runner (background)  |
                    +------------+--------------+
                                 |
                    +------------v--------------+
                    |      PostgreSQL            |
                    |   (system_control DB)      |
                    +---------------------------+
```

**Two layers only:**
- **Core/** -- RBAC framework (auth, admin, server, config, DB). Never changes for new products.
- **Products/** -- Each product is self-contained (routes, queries, K8s, workflows, types).

## Module Structure

The Autopilot backend was refactored from a single Routes.hs into domain-specific Action modules. Routes.hs now contains only the Servant API type definitions and handler wiring.

```
Products/Autopilot/
├── Actions/
│   ├── Release.hs      (1035 lines — release lifecycle: CRUD, approve, trigger, revert, abort, restart, fast-forward, diff, pods, rollout history)
│   ├── VSEdit.hs        (380 lines — VS editor: lock/unlock, apply, revert, list)
│   ├── ConfigMap.hs     (322 lines — configmap tracker CRUD, K8s configmap fetch)
│   ├── Config.hs        (241 lines — product config, service config, server config, discovery)
│   └── K8sResource.hs   (232 lines — env vars, K8s resources, configmap K8s endpoints)
├── Routes.hs            (146 lines — API type + wiring only)
├── Queries.hs           (DB queries via Beam ORM)
├── Workflows/           (category-specific deployment workflows)
├── Runner.hs            (background polling loop)
├── Types/
│   ├── API.hs           (typed request/response types, newtypes)
│   ├── Permission.hs    (permission ADT)
│   ├── Schema.hs        (Beam table definitions)
│   └── Release.hs       (status, category, workflow status ADTs)
└── ...
```

## Type Safety

### Typed Response Types

48 of 57 endpoints return typed Haskell response types (the remaining 9 return dynamic K8s JSON from kubectl). 16 typed response types are defined in `Products/Autopilot/Types/API.hs`:

`APIResponse`, `ProductResponse`, `ServiceResponse`, `ProductConfigResponse`, `ReleaseConfigResponse`, `PodHealthResponse`, `DiffResponse`, `ResourcesResponse`, `VsEditTrackerResponse`, `ServerConfigResponse`, `ConfigMapResponse`, `ConfigMapListResponse`, `ConfigMapK8sResponse`, `ReleaseEventResponse`, `ErrorResponse`, `VsLockErrorResponse`

### Newtypes for IDs

3 newtypes prevent accidental parameter swaps in Servant route handlers:

```haskell
newtype ReleaseId   = ReleaseId   { unReleaseId   :: Text }
newtype ProductSlug = ProductSlug { unProductSlug :: Text }
newtype ServiceSlug = ServiceSlug { unServiceSlug :: Text }
```

### Shared Utilities

- **`Shared/JSON.hs`** -- Generic JSON deriving with shared options (camelCase field labels, tag encoding) used across all response types.
- **`Shared/Error.hs`** -- Typed error ADT ready for migration from ad-hoc Text errors to structured error responses.

## Performance

### Database Indexes

15 indexes across all tables, defined in `dev/migrations/system-control/0002-add-indexes.sql`:

| Table | Index | Columns |
|-------|-------|---------|
| release_tracker | idx_rt_status | status |
| release_tracker | idx_rt_app_group_env | app_group, env |
| release_tracker | idx_rt_created_at | date_created DESC |
| release_tracker | idx_rt_is_approved | is_approved |
| release_tracker | idx_rt_global_id | global_id (partial, WHERE NOT NULL) |
| release_tracker | idx_rt_updated_at | last_updated DESC |
| release_events | idx_re_release_id | re_release_id |
| deployment_config | idx_dc_app_group | app_group |
| deployment_config | idx_dc_app_group_service | app_group, service |
| server_config | idx_sc_name | name |
| sc_person | idx_person_email | email |
| sc_role | idx_role_product | product_slug |
| sc_person_product_access | idx_access_person | person_id |
| sc_person_permission_override | idx_override_person | person_id, product_slug |
| sc_registration_token | idx_token_value | token |

### Connection Pool

Configured in `Core/DB/Connection.hs` via `Data.Pool.createPool`:

- **Stripes:** 4
- **Idle timeout:** 30 seconds
- **Max connections per stripe:** 20

## Quick Start

### Prerequisites

- Nix (with flakes enabled) or GHC 9.2.7 + Cabal
- PostgreSQL running locally
- Node.js 18+ and npm (for frontend)
- `kubectl` configured for your target cluster (if deploying)

### Backend Setup

```bash
cd backend

# Option A: Nix (recommended, all-in-one)
nix develop --accept-flake-config
bash scripts/run.sh   # creates DB + builds + starts server on :8012

# Option B: Step by step
bash scripts/setup-db.sh           # create DB, schema, seed data
cabal build                        # compile
cabal run namma-ap-exe             # start server on :8012
```

Available commands in the Nix shell:

```
sc-setup-db    Setup local database (create + migrate + seed)
sc-build       Compile the backend
sc-run         Setup DB + build + start server (all-in-one)
sc-server      Start server only (assumes already built)
sc-hpack       Regenerate .cabal from package.yaml
sc-format      Format all Haskell source files (fourmolu)
sc-test        Run test suite
sc-migrate     Apply SQL migrations from dev/migrations/
sc-test-api    Test all APIs (server must be running)
```

### Frontend Setup

```bash
cd frontend
npm install
npm run dev    # starts on :5173
```

### Default Login

| Field    | Value            |
|----------|------------------|
| Email    | admin@juspay.in  |
| Password | admin123         |

This is the superadmin account with full access to all products and admin operations.

## RBAC System

### How It Works

1. User calls `POST /auth/login` with email and password.
2. Server returns a UUID token (24-hour TTL). Multiple concurrent sessions are allowed; old tokens expire naturally.
3. All subsequent requests include `Authorization: Bearer <token>`.
4. The WAI middleware intercepts every request:
   - Public routes (`POST /auth/login`, `POST /auth/verify`, `GET /health`) bypass auth entirely.
   - Admin routes (`/admin/*`) require a valid token; the handler checks superadmin status internally.
   - All other routes are matched against the route-permission registry. The middleware resolves the required permission, loads the person's product access and role, computes effective permissions (role + overrides), and checks membership.
5. Superadmins bypass all permission checks on all routes.

### Roles

**System roles** (cannot be deleted, seeded per product):

| Role    | Default Permissions |
|---------|---------------------|
| Admin   | All 15 permissions for the product |
| Manager | All except `PRODUCT_CONFIG_EDIT` and `SERVICE_CONFIG_EDIT` (13 permissions) |
| Viewer  | `RELEASE_VIEW`, `PRODUCT_CONFIG_VIEW`, `SERVICE_CONFIG_VIEW` only (3 permissions) |

**Custom roles** can be created via the admin API with an explicit list of permissions.

### Permission Resolution

A person's effective permissions for a product are computed as:

```
base_permissions (from role's permissions[] array)
+ GRANT overrides
- DENY overrides
= effective_permissions
```

Override types:
- `GRANT` -- adds a permission the role does not include.
- `DENY` -- removes a permission the role would normally include.

Overrides are per-person, per-product, per-permission, stored in `sc_person_permission_override`. A unique constraint prevents duplicate overrides for the same (person, product, permission) combination.

### Permissions List

All 15 Autopilot permissions:

| Permission             | Wire Name            | Description                              |
|------------------------|----------------------|------------------------------------------|
| AP_RELEASE_VIEW        | RELEASE_VIEW         | View releases and events                 |
| AP_RELEASE_CREATE      | RELEASE_CREATE       | Create new releases                      |
| AP_RELEASE_APPROVE     | RELEASE_APPROVE      | Approve releases for deployment          |
| AP_RELEASE_REVERT      | RELEASE_REVERT       | Revert completed releases                |
| AP_RELEASE_DISCARD     | RELEASE_DISCARD      | Discard created releases                 |
| AP_RELEASE_PAUSE       | RELEASE_PAUSE        | Pause in-progress releases               |
| AP_RELEASE_RESUME      | RELEASE_RESUME       | Resume paused releases                   |
| AP_RELEASE_ABORT       | RELEASE_ABORT        | Abort in-progress releases               |
| AP_RELEASE_UPDATE      | RELEASE_UPDATE       | Update release metadata                  |
| AP_RELEASE_DELETE       | RELEASE_DELETE       | Delete releases                          |
| AP_MANAGE_STAGGER      | MANAGE_STAGGER       | Manage rollout stagger configuration     |
| AP_PRODUCT_CONFIG_VIEW | PRODUCT_CONFIG_VIEW  | View product configurations              |
| AP_PRODUCT_CONFIG_EDIT | PRODUCT_CONFIG_EDIT  | Edit product configurations              |
| AP_SERVICE_CONFIG_VIEW | SERVICE_CONFIG_VIEW  | View server configurations               |
| AP_SERVICE_CONFIG_EDIT | SERVICE_CONFIG_EDIT  | Edit server configurations               |

## Release Manager

### Release Lifecycle

```
Created --> InProgress --> Completed
         |             |-> Paused ---------> InProgress (resume)
         |             |                 |-> Aborting
         |             |                 |-> Reverting
         |             |-> Aborting ------> Aborted
         |             |                |-> UserAborted
         |             |                |-> Reverting
         |             |                |-> Restarting
         |             |-> Restarting ---> InProgress
         |-> Discarding -> Discarded

Completed --> Reverting --> Reverted
                        |-> Paused
                        |-> UserAborted
                        |-> Restarting
```

**Terminal states:** `Completed`, `Aborted`, `UserAborted`, `Discarded`, `Reverted`.

Status transitions are enforced by `validateStatusTransition` (per-service) and `validateGlobalStatusTransition` (cross-service) functions. Invalid transitions return an error.

### Release Categories

| Category          | Workflow Handler                  | Deployment Target  | Description                            |
|-------------------|-----------------------------------|--------------------|----------------------------------------|
| BackendService    | BackendServiceWorkflow            | kubernetes         | REST APIs, gRPC microservices          |
| BackendScheduler  | BackendSchedulerWorkflow          | kubernetes         | Pod-count based scheduled jobs (no VS/DR) |
| BackendCronJob    | BackendCronJobWorkflow            | kubernetes         | Cron-triggered jobs (image update)     |
| BackendJob        | BackendJobWorkflow                | kubernetes         | One-off batch processing jobs          |
| BackendConfig     | BackendConfigWorkflow             | kubernetes-config  | ConfigMap and Secret updates           |
| MobileAppAndroid  | MobileAppAndroidWorkflow          | play-store         | Android apps (Play Store)              |
| MobileAppIOS      | Not yet implemented               | app-store          | iOS apps (App Store)                   |
| WebApplication    | Not yet implemented               | s3-cdn             | Web frontends (S3/CDN)                 |
| Infrastructure    | Not yet implemented               | terraform          | Infrastructure as code                 |

### Workflow Stages

Every release, regardless of category, progresses through generic workflow stages tracked by `ReleaseWFStatus`:

```
Init --> Preparing --> Deploying --> Monitoring --> Finalizing --> Done
                                                       |
                                                  RollingBack (on error)
```

| Stage       | Purpose                                                             |
|-------------|---------------------------------------------------------------------|
| Init        | Validation and precondition checks (cluster reachability, internal VS detection) |
| Preparing   | Pre-deployment preparation (ConfigMap apply, deployment clone/create, DestinationRule, HPA clone) |
| Deploying   | Active deployment/rollout (progressive traffic shift: 75/25 -> 50/50 -> 0/100) |
| Monitoring  | Post-deployment health checks (pod polling every 10s, max 5 min, CrashLoopBackOff/ImagePullBackOff detection) |
| Finalizing  | Cleanup old resources (scale down old deployment, capture AFTER snapshots, optional delete) |
| Done        | Successfully completed, Slack notification sent                     |
| RollingBack | Error state -- reverting to previous version                        |

### Background Runner

The runner (`Products.Autopilot.Runner.runnerLoop`) is a background polling loop with 5 steps:

**Step 1: Find and pick runnable releases**
- Polls every `release_watch_delay` seconds (default 20, configurable via `server_config`).
- Finds releases with status `Created`, approved (`is_approved = true`), schedule time arrived.
- Checks eligibility: for K8s-backed categories, VirtualService must not be locked (`deployment_config.vs_locked_by`), and no ongoing release for the same product+env (unless `multi_release_per_product` is enabled). BackendConfig, MobileApp, WebApp, and Infrastructure categories are always eligible.
- Sorts by priority (higher first), then by schedule time. When `multi_release_per_product` is off, at most one release per product+env is picked per poll.

**Step 2: Validate version and dispatch**
- For K8s releases, compares the tracker's `oldVersion` against the running VirtualService primary subset. If a mismatch is detected, the release is auto-discarded with a `VERSION_MISMATCH` event and Slack notification. Skipped for new services or when oldVersion is `unknown`/`new`/empty.
- Marks `InProgress`, records `RUNNER_PICKED` event, dispatches to the category-specific workflow via `Workflow.Factory.executeReleaseWorkflow`.
- On success: records `COMPLETED` event. On failure: marks `Aborted` (or `UserAborted` if the previous status was `Aborting`), records `FAILED` event, restores VS traffic to old version, scales down new deployment to 0, sends Slack abort notification.

**Step 3: Handle aborting releases (Abort Handler)**
- Finds all releases in `Aborting` status.
- For each: restores VirtualService traffic to 100% old version, scales down new deployment to 0 replicas, marks as `UserAborted`, records `ABORT_HANDLED` event, sends Slack abort notification.
- Best-effort: errors in VS restore are logged but do not prevent status transition.

**Step 4: Cleanup jobs** (planned, not yet reimplemented)

**Step 5: Scale-down of old deployments after delay**
- Finds completed releases where `pods_scale_down_delay_config` hours have elapsed since completion.
- Scales the old version's deployment to 0 replicas.
- Updates tracker's `podsScaleDownStatus` to `ScaleDownCompleted`.
- Records `OLD_PODS_SCALED_DOWN` event.

### Rollout Strategy

Releases support progressive rollout defined as a list of `RolloutStep`:

```json
[
  { "rolloutPercent": 10, "cooloffSeconds": 300, "podPercent": 20 },
  { "rolloutPercent": 50, "cooloffSeconds": 600, "podPercent": 50 },
  { "rolloutPercent": 100, "cooloffSeconds": 0, "podPercent": 100 }
]
```

Each step specifies:
- `rolloutPercent` -- percentage of traffic routed to new version (VirtualService weight).
- `cooloffSeconds` -- wait time at this stage before proceeding or making a decision.
- `podPercent` -- percentage of pods to run the new version.

Rollout history tracks each completed step with timestamps, decision (Continue/Wait/Abort), decision reason, whether a manual override occurred, and HS decision data. Rollout history is editable inline from the release summary page.

### Deployment Snapshots and Diffs

During workflow execution, YAML snapshots are captured before and after deployment:

- **DEPLOYMENT_BEFORE / DEPLOYMENT_AFTER** -- deployment state snapshots stored as release events.
- **VS_BEFORE / VS_AFTER** -- VirtualService configuration snapshots.
- K8s metadata is stripped from snapshots (annotations, resourceVersion, uid, managedFields, status) to produce clean diffs.

The diff endpoint (`GET /releases/:id/diff?type=<type>`) retrieves these snapshots and returns before/after comparisons. Supported `type` values: `deployment`, `vs`, `configmap`. Diffs are displayed in YAML format (not JSON) on the frontend.

### HPA Clone

When `scaling_with_hpa_enabled` includes the product (JSON array in server_config), the workflow clones the HPA (Horizontal Pod Autoscaler) from the old version to the new version during the Preparing stage:

- Checks if an HPA exists for the old deployment (`<service>-<oldVersion>-hpa`).
- Reads current replicas from the old deployment to calculate HPA min/max.
- Clones with min = max(1, desiredReplicas) and max = max(min, round(desiredReplicas * hpa_min_max_ratio)).
- Records `HPA_CLONED` event on success. Failure is non-fatal.

### Internal VS Validation

During the Init stage, the workflow checks for the existence of `<service>-internal-vs` (internal VirtualService). If found, it logs an `INTERNAL_VS_FOUND` event. This allows operators to track services that have internal routing rules.

### Safety Checks

| Check | When | Behavior |
|-------|------|----------|
| Same version rejection | Create | Rejects if `oldVersion == newVersion` |
| Invalid version format | Create | Rejects versions not matching `[a-z0-9]([-a-z0-9]*[a-z0-9])?` |
| Maintenance mode | Create | Rejects all creates when `ap_under_maintenance` flag is set |
| Duplicate deployment | Create | Rejects if deployment `<service>-<newVersion>` already exists in K8s |
| Shell command injection | All K8s commands | `shellQuote` wraps all user-provided values in single quotes |
| kubectl timeout | All K8s commands | 5-minute timeout on all kubectl executions |
| Version validation | Runner (before dispatch) | Compares tracker's `oldVersion` against live VirtualService primary subset; discards on mismatch |
| Delete blocked for active | Delete | Blocks deletion of releases in non-terminal statuses |
| VS traffic restore on abort | Runner (abort handler) | Restores 100% traffic to old version, scales new deployment to 0 |
| Old deployment exists check | Revert | Verifies old deployment exists in K8s before creating revert tracker |

### Multi-Cloud Sync

Sync to a secondary cluster is triggered after a release reaches `Completed` status. All gates must pass:

| Gate | Source |
|------|--------|
| `k8s_enabled` | server_config (must be true) |
| `sync_cluster_enabled` | server_config (must be true) |
| Product has `sync_cluster` | deployment_config.sync_cluster (must be non-empty) |
| Release has `udf1 = "true"` | release_tracker.udf1 |

Sync behavior:
- **Forward sync**: POSTs a new release to the sync cluster URL (`SYNC_CLUSTER_URL` env var) with the same version, rollout strategy (overridable via `syncClusterRolloutStrategy`), and metadata.
- **Revert sync**: PUTs to the sync cluster to revert by global_id.
- **Immediate revert sync**: PUTs to the immediate revert endpoint on the sync cluster.
- **Auth**: Pomerium JWT (`x-pomerium-jwt-assertion` header) is preferred; falls back to Basic auth (`SYNC_CLUSTER_BASE_AUTH` env var) if no forwarded headers are present.
- **Retry**: 2 attempts with event logging for each attempt (SYNC_REQUEST, SYNC_RESPONSE, SYNC_FAILED, SYNC_FAILED_RETRY, SYNC_FAILED_FINAL).

### Slack Notifications

Thread-aware Slack notifications using Block Kit with colored sidebars:

| Color | Status |
|-------|--------|
| Blue (#2563eb) | Created |
| Cyan (#0891b2) | Approved |
| Amber (#d97706) | InProgress |
| Green (#16a34a) | Completed |
| Red (#dc2626) | Aborted |
| Indigo (#6366f1) | Paused |
| Violet (#7c3aed) | Reverted |
| Zinc (#71717a) | Default (updated, deleted, scaled down) |

34 notification functions:

**Release notifications (15):**
1. `notifyReleaseCreated` -- starts a new Slack thread (header link + version line)
2. `notifyReleaseApproved`
3. `notifyReleaseProgress` -- includes traffic percentage and routing details
4. `notifyReleaseCompleted`
5. `notifyReleaseAborted` -- includes traffic restoration info
6. `notifyReleasePaused`
7. `notifyReleaseResumed`
8. `notifyReleaseReverted`
9. `notifyReleaseDiscarded`
10. `notifyReleaseDeleted`
11. `notifyReleaseUpdated` -- includes detail text
12. `notifyReleaseRestarted`
13. `notifyReleaseFastForwarded`
14. `notifyImmediateReverted`
15. `notifyPodsScaledDown`

**VS edit notifications (7):**
16. `notifyVsEditCreated`
17. `notifyVsEditLocked` -- includes clickable dashboard link
18. `notifyVsEditApplied`
19. `notifyVsEditApproved`
20. `notifyVsEditDiscarded`
21. `notifyVsEditReverted`
22. `notifyVsEditUnlocked`

**ConfigMap notifications (11):**
23. `notifyConfigMapCreated` -- starts its own thread
24. `notifyConfigMapUpdated`
25. `notifyConfigMapApproved`
26. `notifyConfigMapInProgress`
27. `notifyConfigMapCompleted`
28. `notifyConfigMapAborted`
29. `notifyConfigMapPaused`
30. `notifyConfigMapResumed`
31. `notifyConfigMapReverted`
32. `notifyConfigMapDiscarded`
33. `notifyConfigMapFastForwarded`

**Generic (1):**
34. `notifyGenericThreadMessage` -- generic message in a release's thread

Threading: The first message (Created or ConfigMap Created) starts a Slack thread. All subsequent messages reply in that thread using the `thread_ts` stored in `release_tracker.udf3`.

Requirements: `SLACK_BOT_TOKEN` env var, `slack_enabled = true` in server_config, and a Slack channel configured per service in `deployment_config.slack_channel`. HTTP timeout is 10 seconds.

## API Reference

All endpoints require `Authorization: Bearer <token>` unless marked as public.

**71 total endpoints** across 4 route groups + 1 health check.

### 1. Auth (4 endpoints)

| Method | Path           | Permission | Description |
|--------|----------------|------------|-------------|
| POST   | /auth/login    | Public     | Authenticate with email and password, returns token |
| POST   | /auth/verify   | Public     | Verify token and check specific permission |
| POST   | /auth/logout   | Token only | Deactivate current token |
| GET    | /auth/me       | Token only | Get current user profile and product access |

### 2. Admin (15 endpoints)

All admin endpoints require superadmin status. Non-superadmins receive `"Unauthorized: superadmin required"`.

| Method | Path | Description |
|--------|------|-------------|
| GET    | /admin/users | List all users |
| POST   | /admin/users | Create a new user |
| GET    | /admin/users/:userId | Get user details with products, permissions, and overrides |
| PUT    | /admin/users/:userId | Update user (firstName, lastName, isActive, isSuperadmin) |
| DELETE | /admin/users/:userId | Deactivate user (soft delete) |
| POST   | /admin/users/:userId/assign-role | Assign a role to a user for a product |
| DELETE | /admin/users/:userId/product-access/:slug | Revoke product access for a user |
| POST   | /admin/users/:userId/permission-override | Add GRANT or DENY permission override |
| DELETE | /admin/users/:userId/permission-override/:overrideId | Remove a permission override |
| GET    | /admin/products | List all products (derived from ProductSlug ADT) |
| POST   | /admin/products | Not supported -- returns error; products are defined in code |
| GET    | /admin/products/:slug/roles | List roles for a product |
| POST   | /admin/products/:slug/roles | Create a custom role with explicit permissions |
| PUT    | /admin/products/:slug/roles/:roleId | Update role description and permissions |
| GET    | /admin/products/:slug/permissions | List all permissions for a product (from ADT) |

### 3. Releases (18 endpoints)

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| GET    | /releases | RELEASE_VIEW | List releases. Optional query: `?from=ISO&to=ISO` |
| POST   | /releases/create | RELEASE_CREATE | Create a new release tracker |
| GET    | /releases/:id | RELEASE_VIEW | Get single release tracker |
| POST   | /releases/:id/approve | RELEASE_APPROVE | Approve release for deployment |
| POST   | /releases/:id/trigger | RELEASE_CREATE | Schedule release for immediate execution |
| POST   | /releases/:id/rollback | RELEASE_REVERT | Request rollback (sets status to Aborting) |
| POST   | /releases/:id/revert | RELEASE_REVERT | Create a revert release tracker (swaps old/new version) |
| PUT    | /release/revert/global/:globalId | RELEASE_REVERT | Revert by global ID |
| PUT    | /release/revert/immediate/global/:globalId | RELEASE_REVERT | Immediate revert by global ID |
| POST   | /releases/:id/discard | RELEASE_DISCARD | Discard a created release |
| POST   | /releases/:id/update | RELEASE_UPDATE | Update tracker fields (status, mode, priority, rollout, etc.) |
| GET    | /releases/:id/events | RELEASE_VIEW | List release events (audit trail) |
| POST   | /releases/:id/delete | RELEASE_DELETE | Permanently delete release and its events |
| GET    | /releases/:id/diff | RELEASE_VIEW | Get deployment/VS/configmap diff. Query: `?type=vs` |
| GET    | /releases/:id/pods/health | RELEASE_VIEW | Get pod health status for the release |
| POST   | /releases/:id/revert/immediate | RELEASE_REVERT | Immediate revert with optional sync to secondary cluster |
| POST   | /releases/:id/restart | RELEASE_CREATE | Restart a paused or failed release |
| POST   | /releases/:id/fast-forward | RELEASE_UPDATE | Fast-forward to next rollout step |

### 4. Rollout History (1 endpoint)

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| GET    | /releases/:id/rollout-history | RELEASE_VIEW | Get rollout history for a release |

### 5. Product and Service Config (10 endpoints)

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| GET    | /products/config | PRODUCT_CONFIG_VIEW | List all product configs |
| POST   | /products/config | PRODUCT_CONFIG_EDIT | Create a product config entry |
| GET    | /products/config/:id | PRODUCT_CONFIG_VIEW | Get single product config |
| PUT    | /products/config/:id | PRODUCT_CONFIG_EDIT | Update product config |
| DELETE | /products/config/:id | PRODUCT_CONFIG_EDIT | Delete product config |
| GET    | /services/config | PRODUCT_CONFIG_VIEW | List release configs. Optional: `?product=Beckn` |
| POST   | /services/config | PRODUCT_CONFIG_EDIT | Create a release config entry |
| GET    | /services/config/:id | PRODUCT_CONFIG_VIEW | Get single release config |
| PUT    | /services/config/:id | PRODUCT_CONFIG_EDIT | Update release config |
| DELETE | /services/config/:id | PRODUCT_CONFIG_EDIT | Delete release config |

### 6. Server Config (2 endpoints)

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| GET    | /server-config | SERVICE_CONFIG_VIEW | List all server config entries with registry metadata |
| POST   | /server-config | SERVICE_CONFIG_EDIT | Upsert a server config value |

### 7. VS Edit Tracker (8 endpoints)

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| POST   | /vs-edit-tracker | RELEASE_CREATE | Create a new VS edit tracker entry |
| GET    | /vs-edit-tracker/list | RELEASE_VIEW | List VS edit trackers. Optional: `?from=ISO&to=ISO` |
| GET    | /vs-edit-tracker/current-vs | RELEASE_VIEW | Fetch current VirtualService YAML from K8s |
| POST   | /vs-edit-tracker/lock | RELEASE_CREATE | Lock a VirtualService for editing |
| POST   | /vs-edit-tracker/unlock | RELEASE_UPDATE | Unlock a VirtualService |
| PUT    | /vs-edit-tracker/revert/:id | RELEASE_REVERT | Revert a VS edit (apply old_vs_data back) |
| GET    | /vs-edit-tracker/:id | RELEASE_VIEW | Get single VS edit tracker |
| PUT    | /vs-edit-tracker/:id | RELEASE_UPDATE | Update VS edit tracker (newVsData, status, approvedBy, info) |

### 8. K8s Resources and Environments (3 endpoints)

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| GET    | /resources | PRODUCT_CONFIG_VIEW | Fetch K8s resources (deployments, pods, etc.) for a product/service |
| GET    | /envs | RELEASE_VIEW | Fetch deployment env vars from primary cluster |
| GET    | /envs/secondary | RELEASE_VIEW | Fetch deployment env vars from secondary/sync cluster |

### 9. ConfigMap Tracker (6 endpoints)

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| GET    | /tracker/configmap/list | RELEASE_VIEW | List ConfigMap release trackers. Optional: `?from=ISO&to=ISO` |
| GET    | /tracker/configmap/:id | RELEASE_VIEW | Get single ConfigMap release tracker |
| POST   | /tracker/configmap | RELEASE_CREATE | Create a ConfigMap release tracker |
| PUT    | /tracker/configmap/:id | RELEASE_UPDATE | Update ConfigMap tracker |
| GET    | /configmap | RELEASE_VIEW | Fetch live ConfigMap from primary K8s cluster |
| GET    | /configmap/secondary | RELEASE_VIEW | Fetch live ConfigMap from secondary K8s cluster |

### 10. Product Discovery (4 endpoints)

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| GET    | /products | PRODUCT_CONFIG_VIEW | List all product configs (cluster, namespace, VS info) |
| POST   | /products | PRODUCT_CONFIG_EDIT | Upsert product config (legacy endpoint) |
| GET    | /products/:product/services | PRODUCT_CONFIG_VIEW | Discover services via VirtualService or DB fallback |
| POST   | /services | PRODUCT_CONFIG_EDIT | Upsert release config (legacy endpoint) |

### 11. Health (1 endpoint)

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| GET    | /health | Public | Health check (bypasses auth middleware) |

## Database Schema

10 tables across two domains: Autopilot (release management) and RBAC (access control). 15 performance indexes are defined in `dev/migrations/system-control/0002-add-indexes.sql` (see [Performance](#performance) section for the full list).

### 1. release_tracker

Tracks the lifecycle of every release (including VS edits with `category = 'VSEdit'`). 35 columns.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | text | NOT NULL | Primary key (UUID) |
| status | text | NOT NULL | Release lifecycle status (Created, InProgress, Completed, Aborted, UserAborted, Discarded, Discarding, Paused, Aborting, Reverting, Reverted, Restarting) |
| description | text | YES | Human-readable description |
| new_version | text | NOT NULL | Target version being deployed |
| old_version | text | NOT NULL | Previous/current running version |
| app_group | text | NOT NULL | Product/service group name (e.g., "Beckn") |
| service | text | NOT NULL | Specific service name (e.g., "rider-app") |
| mode | text | YES | Execution mode: "Auto" or "Manual" |
| date_created | timestamptz | NOT NULL | Creation timestamp (default: now()) |
| last_updated | timestamptz | NOT NULL | Last update timestamp (auto-updated by trigger) |
| start_time | timestamptz | YES | When workflow execution started |
| end_time | timestamptz | YES | When workflow execution completed |
| release_manager | text | NOT NULL | Creator/owner email address |
| env | text | NOT NULL | Target environment (e.g., "UAT", "production") |
| priority | integer | NOT NULL | Job priority (higher values are picked first by the runner) |
| rollout_strategy | text | YES | JSON-serialized array of RolloutStep objects |
| rollout_history | text | YES | JSON-serialized array of completed rollout steps with decisions |
| schedule_time | timestamptz | YES | Earliest time the runner will pick this job |
| release_tag | text | NOT NULL | Auto-generated or user-provided release tag |
| change_log | text | YES | Changelog text |
| release_context | text | YES | JSON-serialized target state (K8sDeploymentState, ConfigState, etc.) |
| info | text | YES | Additional info or notes |
| udf1 | text | YES | User-defined field 1 (used for sync flag: "true" = was synced) |
| udf2 | text | YES | User-defined field 2 |
| udf3 | text | YES | User-defined field 3 (stores Slack thread_ts for threaded notifications) |
| is_approved | boolean | YES | Whether the release has been approved for execution |
| is_infra_approved | boolean | YES | Whether infrastructure team approval has been granted |
| metadata | text | YES | JSON metadata (docker-image, internal-vs-name, etc.) |
| global_id | text | YES | Cross-cluster global identifier for multi-cloud sync |
| new_service | boolean | YES | Flag for first-time service deployments (skips version validation) |
| cronjob_suspend | boolean | YES | Whether to suspend cron job during release |
| ab_hs_status | text | YES | A/B testing health score status |
| category | text | YES | Release category: BackendService, BackendScheduler, BackendCronJob, BackendJob, BackendConfig, MobileAppAndroid, MobileAppIOS, WebApplication, Infrastructure |
| release_wf_status | text | YES | Generic workflow stage: Init, Preparing, Deploying, Monitoring, Finalizing, Done, RollingBack |
| approved_by | text | YES | Email of the person who approved the release |

Indexes: `release_tracker_pkey` (btree on `id`).
Trigger: `release_tracker_update_timestamp` -- auto-updates `last_updated` on every UPDATE.

### 2. release_events

Immutable event log for release lifecycle audit trail.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| re_id | bigint | NOT NULL | Auto-incrementing primary key |
| re_release_id | text | NOT NULL | Foreign key to release_tracker.id |
| re_category | text | NOT NULL | Event category (e.g., "BUSINESS", "SYSTEM") |
| re_label | text | NOT NULL | Event label (e.g., "TRACKER_CREATED", "RUNNER_PICKED", "COMPLETED", "FAILED", "ROLLBACK_REQUESTED", "VERSION_MISMATCH", "STATUS_UPDATED", "TRACKER_APPROVED", "REVERT_TRACKER_CREATED", "ABORT_HANDLED", "VS_TRAFFIC_RESTORED", "OLD_PODS_SCALED_DOWN", "HPA_CLONED", "INTERNAL_VS_FOUND", "SYNC_TRIGGERED", "SYNC_RESPONSE", "SYNC_FAILED") |
| re_payload | jsonb | NOT NULL | Event payload (tracker snapshot, error details, messages, etc.) |
| re_created_at | timestamptz | NOT NULL | Event timestamp |

### 3. deployment_config

Unified product and service deployment configuration (replaces the former `product_config` and `release_config` tables). Product-level rows have `service IS NULL`; service-level rows have `service IS NOT NULL`.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | integer | NOT NULL | Auto-incrementing primary key |
| app_group | text | NOT NULL | Product/service group name (e.g., "Beckn") |
| service | text | YES | Service name (NULL = product-level config) |
| cluster | text | YES | Target K8s cluster |
| namespace | text | YES | Target K8s namespace |
| vs_name | text | YES | VirtualService name in K8s |
| product_acronym | text | YES | Short acronym for the product |
| product_type | text | YES | Type: "SERVICE", "SCHEDULER", etc. |
| sync_cluster | text | YES | Secondary cluster for multi-cloud sync |
| need_infra_approval | boolean | YES | Whether infrastructure team must approve releases |
| vs_locked_by | text | YES | Email of the person holding the VS lock |
| vs_lock_timestamp | timestamptz | YES | When the VS lock was acquired |
| service_host | text | YES | Service host URL |
| service_type | text | YES | Service type ("SERVICE", "SCHEDULER", etc.) |
| rollout_strategy | text | YES | Default rollout strategy as JSON array |
| revert_strategy | text | YES | Revert-specific rollout strategy JSON |
| decision_config | text | YES | Decision engine configuration JSON |
| slack_channel | text | YES | Slack channel ID for notifications |

Unique constraint: `uq_deployment_config` on `(app_group, COALESCE(service, ''))`.

### 4. server_config

Runtime configuration key-value store. Values are read at runtime without server restart.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | integer | NOT NULL | Primary key |
| type | text | NOT NULL | Config type identifier (e.g., "SYSTEM") |
| name | text | NOT NULL | Config key name (e.g., "release_watch_delay") |
| value | text | NOT NULL | Config value as string (parsed at read time) |
| last_updated | timestamptz | NOT NULL | Last modification timestamp (default: CURRENT_TIMESTAMP) |
| enabled | integer | NOT NULL | 0 = disabled (ignored), 1 = enabled (default: 0) |
| product | text | YES | Product scope (NULL = global config) |

Unique constraint: `server_config_name_product_unique` on `(name, COALESCE(product, ''))`.

### 5. sc_person

User accounts for the control centre.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | uuid | NOT NULL | Primary key (default: gen_random_uuid()) |
| email | text | NOT NULL | Unique email address |
| first_name | text | NOT NULL | First name |
| last_name | text | NOT NULL | Last name |
| password_hash | text | NOT NULL | Password hash |
| is_active | boolean | NOT NULL | Account active status (default: true) |
| is_superadmin | boolean | NOT NULL | Superadmin flag -- bypasses all permission checks (default: false) |
| created_at | timestamptz | NOT NULL | Account creation timestamp (default: now()) |
| updated_at | timestamptz | NOT NULL | Last update timestamp (default: now()) |

Unique constraint: `sc_person_email_key` on `email`.

### 6. sc_role

Role definitions per product. Each role has an explicit list of permissions.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | uuid | NOT NULL | Primary key (default: gen_random_uuid()) |
| product_slug | text | NOT NULL | Product this role belongs to (e.g., "autopilot") |
| name | text | NOT NULL | Role name (unique per product) |
| description | text | YES | Role description |
| is_system_role | boolean | NOT NULL | System roles (Admin, Manager, Viewer) cannot be deleted (default: false) |
| permissions | text[] | YES | Array of permission action strings (default: empty array) |
| created_at | timestamptz | NOT NULL | Creation timestamp (default: now()) |

Unique constraint: `sc_role_product_slug_name_key` on `(product_slug, name)`.

### 7. sc_person_product_access

Maps a person to a role within a specific product. One role per person per product.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | uuid | NOT NULL | Primary key (default: gen_random_uuid()) |
| person_id | uuid | NOT NULL | FK to sc_person.id (CASCADE on delete) |
| product_slug | text | NOT NULL | Product slug (e.g., "autopilot") |
| role_id | uuid | NOT NULL | FK to sc_role.id |
| granted_by | uuid | YES | FK to sc_person.id (who granted access) |
| created_at | timestamptz | NOT NULL | Assignment timestamp (default: now()) |

Unique constraint: `(person_id, product_slug)` -- one role per person per product.

### 8. sc_person_permission_override

Per-person permission overrides (GRANT or DENY) that modify the base role permissions.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | uuid | NOT NULL | Primary key (default: gen_random_uuid()) |
| person_id | uuid | NOT NULL | FK to sc_person.id (CASCADE on delete) |
| product_slug | text | NOT NULL | Product slug |
| permission_action | text | NOT NULL | Permission being overridden (e.g., "RELEASE_APPROVE") |
| override_type | text | NOT NULL | "GRANT" or "DENY" (enforced by CHECK constraint) |
| granted_by | uuid | YES | FK to sc_person.id (who created the override) |
| created_at | timestamptz | NOT NULL | Creation timestamp (default: now()) |

Unique constraint: `(person_id, product_slug, permission_action)` -- one override per permission per person per product.
Check constraint: `override_type IN ('GRANT', 'DENY')`.

### 9. sc_registration_token

Active session tokens for authenticated users.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | uuid | NOT NULL | Primary key (default: gen_random_uuid()) |
| person_id | uuid | NOT NULL | FK to sc_person.id (CASCADE on delete) |
| token | text | NOT NULL | Unique token value (UUID string) |
| is_active | boolean | NOT NULL | Whether token is active (default: true). Set to false on logout. |
| created_at | timestamptz | NOT NULL | Token creation timestamp (default: now()) |
| expires_at | timestamptz | NOT NULL | Token expiry time (24 hours from creation) |

Unique constraint: `sc_registration_token_token_key` on `token`.

### 10. sc_audit_log

Audit trail for admin operations.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | uuid | NOT NULL | Primary key (default: gen_random_uuid()) |
| person_id | uuid | YES | FK to sc_person.id (who performed the action) |
| action | text | NOT NULL | Action type: "USER_CREATED", "USER_DEACTIVATED", "ROLE_ASSIGNED", "ACCESS_REVOKED" |
| entity_type | text | YES | Entity type affected (e.g., "person", "person_product_access") |
| entity_id | text | YES | ID of the affected entity |
| details | jsonb | YES | Additional structured details |
| created_at | timestamptz | NOT NULL | Action timestamp (default: now()) |

## Configuration

### Bootstrap Config (Environment Variables)

Loaded once at startup from environment variables or a `.env` file in the backend directory.

| Variable | Default | Description |
|----------|---------|-------------|
| APP_STATE | SERVER | Application mode (SERVER = server + runner, RUNNER = runner only) |
| PORT | 8012 | HTTP server port |
| NammaAP_ENV | production | Environment name |
| NammaAP_KUBECTL_BIN | kubectl | Path to kubectl binary |
| NammaAP_DEFAULT_NAMESPACE | default | Default K8s namespace |
| NammaAP_MAX_K8S_RETRIES | 3 | Max retries for K8s commands |
| NammaAP_DATABASE_URL | (none) | Full PostgreSQL connection URL (takes priority over individual fields) |
| NammaAP_POSTGRES_HOST | 127.0.0.1 | PostgreSQL host |
| NammaAP_POSTGRES_PORT | 5432 | PostgreSQL port |
| NammaAP_POSTGRES_USER | postgres | PostgreSQL user |
| NammaAP_POSTGRES_PASSWORD | postgres | PostgreSQL password |
| NammaAP_POSTGRES_DB | namma_ap | PostgreSQL database name |
| SYNC_CLUSTER_URL | (empty) | Secondary cluster API URL for multi-cloud sync |
| SYNC_CLUSTER_BASE_AUTH | (empty) | Basic auth credentials for secondary cluster |
| SLACK_BOT_TOKEN | (empty) | Slack bot token for release notifications |
| DASHBOARD_URL | http://localhost:5173 | Frontend URL for clickable links in Slack notifications |

DB resolution order: `NammaAP_DATABASE_URL` is tried first. If unset, individual `NammaAP_POSTGRES_*` fields are used.

### Runtime Config (server_config table)

These configs are read from the `server_config` database table at runtime and can be changed without restarting the server. Edit them via `POST /server-config` or through the dashboard.

**Global Configs:**

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| mailing_enabled | bool | false | Enable email notifications |
| slack_enabled | bool | false | Enable Slack notifications for release events |

**Autopilot -- Deployment:**

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| k8s_enabled | bool | true | Enable Kubernetes operations |
| approve_all_releases | bool | false | Auto-approve all new releases (for system-triggered releases) |
| ap_under_maintenance | json | {} | Maintenance mode JSON (with owner and flag) |
| release_start_delay | int | 0 | Delay before starting release (seconds) |
| multi_release_per_product | bool | false | Allow multiple concurrent releases per product+env |
| max_k8s_retries | int | 3 | Maximum K8s command retry attempts |

**Autopilot -- Sync:**

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| sync_cluster_enabled | bool | false | Enable multi-cloud sync to secondary cluster |
| sync_rollout_strategy_config | json | {} | Rollout strategy override for sync cluster releases |

**Autopilot -- Monitoring:**

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| release_watch_delay | int | 20 | Runner poll interval in seconds |
| collect_metrics_delay | int | 60 | Metrics collection interval in seconds |
| global_changelog_tracker_enabled | bool | false | Enable global changelog tracking |

**Autopilot -- Scaling:**

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| scale_down_pods_on_completion | bool | true | Scale down old pods after release completes |
| pods_scale_down_delay_config | double | 0.0 | Delay before scaling down old pods (hours) |
| scaling_with_hpa_enabled | json | [] | Products with HPA scaling enabled (JSON array of product names) |
| hpa_max_replicas_buffer | int | 1 | Buffer added to HPA max replicas calculation |
| hpa_min_max_ratio | double | 1.0 | HPA min/max replica ratio |

**Autopilot -- A/B Testing:**

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| decision_engine_enabled | bool | false | Enable A/B testing decision engine |

## Frontend Features

### Layout

- Full-width layout (no `max-w-6xl` container constraint)
- Base font size: 15px
- Professional flat design (no gradients, glassmorphism, or decorative effects)

### Release List Page

- Date range presets: Last 30 mins, Last 1 hour, Last 6 hours, Today, Yesterday, Last 2 days, Last 7 days, Last 30 days, This month, Last month, Custom range
- Filters: search (text), status dropdown, product dropdown
- Sorting: by date created (asc/desc)
- Pagination with configurable page size
- Actions per row: Clone release, Copy release ID
- Status badges with color coding
- Refresh button for manual reload

### Create Release Page

- Product/service dropdown (auto-populated from deployment_config)
- Environment selector with available environments
- New service toggle (skips old version validation)
- Docker image field (from metadata)
- Rollout strategy stage editor: add/remove stages, configure rollout%, cooloff, pods%
- Default 5 stages (5%, 25%, 50%, 75%, 100%)
- Release sync toggle (udf1 = "true" for multi-cloud sync)
- Secondary cluster rollout strategy with separate stage editor
- **Env Switch toggle**: Monaco editor for custom environment variables (injected into deployment)
- **ConfigMap toggle**: Monaco editor for ConfigMap data (applied during release)
- New service paths: deploy file path, VS file path, DR file path
- Clone mode: pre-fills from existing release (accessed via /releases/:id/clone)

### Release Summary Page

- Header with status badge, product/service/env info, version arrow (old -> new)
- Action buttons (permission-gated): Approve, Trigger, Pause, Resume, Abort, Revert, Immediate Revert, Delete, Restart, Fast Forward
- Confirmation dialogs for destructive actions
- Tabbed interface (4 tabs: `Summary | Events | ENV Diff | JSON Data`):
  - **Summary tab**: Release details (mode, priority, schedule, timestamps, release tag, description, changelog), inline Rollout History sub-section with editable rollout strategy, deployment status with pod health, observability links (Grafana, Kibana), edit dialog for metadata updates
  - **Events tab**: Searchable event timeline with expandable JSON payloads
  - **ENV Diff tab**: YAML diff viewer (react-diff-viewer) with type switcher (Deployment / VirtualService / ConfigMap) for before/after snapshots
  - **JSON Data tab**: Raw release tracker JSON

### ConfigMap Pages

- List page with date range filtering
- Create page with product/service selection
- Summary page with ConfigMap name dropdown, secondary cluster diff, Monaco YAML editor

### VS Editor Pages

VS edits are stored in `release_tracker` with `category = 'VSEdit'` (no separate table). Old/new VS data is stored as SNAPSHOT events in `release_events`. VS locking is managed via `deployment_config.vs_locked_by` and `deployment_config.vs_lock_timestamp`.

Workflow: Lock -> Edit -> Save (CREATED) -> Approve -> Apply (kubectl to K8s) / Discard

- List page with VS edit tracker entries
- Edit page with live VS fetch from K8s
- Summary page with lock/unlock/apply/revert/approve/discard actions and Slack notifications
- Lock system with configurable expiry (lock_expiry_delay_minutes in server_config)

### Product and Service Config Pages

- Product config CRUD with cluster, namespace, VirtualService, sync cluster, infra approval fields
- Service config CRUD with rollout strategy, revert strategy, Slack channel, service type fields

### Server Config Page

- Lists all runtime config entries with current values
- Grouped by category (Deployment, Sync, Monitoring, Scaling, A/B Testing)
- Shows type, default value, and description from the config registry
- Inline edit with upsert

### Admin Pages

- User management: list, create, edit, activate/deactivate, superadmin toggle
- Product access: assign roles per product
- Permission overrides: add GRANT/DENY overrides per user per product
- Role management: list roles, create custom roles, edit permissions

## Testing

### Unit Tests (151 assertions)

Run with `cabal test` or `sc-test` in the Nix shell.

7 test groups covering:

1. **Status transition tests** -- validates `validateStatusTransition` for all valid and invalid per-service transitions (Created->InProgress, InProgress->Paused, terminal state immutability, etc.)
2. **Global status transition tests** -- validates `validateGlobalStatusTransition` for cross-service transitions (Completed->Reverting, InProgress->Restarting, Aborting->Restarting, etc.)
3. **Version validation tests** -- validates `isValidK8sVersion` for valid versions (alphanumeric, dashes), invalid versions (dots, spaces, semicolons, special chars, leading/trailing dashes), and case insensitivity
4. **Shell quoting tests** -- validates `shellQuote` for safe wrapping of user input (empty strings, spaces, dollar signs, backticks, single quotes, semicolons, pipes, newlines)
5. **Permission tests** -- validates Admin/Manager/Viewer role defaults, permission text round-trips, effective permission computation (GRANT adds, DENY removes, no duplicates), ProductSlug and OverrideType round-trips, allPermissionsText and defaultPermissionsText
6. **Release tag generation tests** -- validates tag format (PRODUCT_YYYYMMDD_VERSION_SERVICE_MODE_ENV_PRIORITY), revert tag suffix, and component extraction
7. **Terminal/aborted status helper tests** -- validates `isTerminalStatus` and `isAbortedStatus` for all status values

### Integration Tests (44 assertions)

Run with `bash scripts/test-api.sh` or `sc-test-api` (requires server to be running).

17 test sections:

1. **Auth tests** -- login with valid/invalid credentials, missing fields, GET /auth/me with valid/invalid/no token
2. **Safety validations** -- same version rejection, empty version rejection, injection character rejection, valid data acceptance
3. **Release CRUD and listing** -- list releases, get single release, get events, get nonexistent release
4. **Invalid status transitions** -- fast-forward/restart/revert/discard on nonexistent releases
5. **Product config CRUD** -- list, create, get, update, delete product configs
6. **Service config CRUD** -- list, create, get, update, delete service configs
7. **Server config** -- list, upsert, verify presence
8. **VS edit tracker** -- list VS edit trackers
9. **ConfigMap endpoints** -- primary and secondary ConfigMap fetch
10. **Environment endpoints** -- primary and secondary env fetch
11. **Resources endpoint** -- fetch K8s resources
12. **Admin endpoints** -- list users, list products, list permissions, list roles
13. **Health endpoint** -- health check
14. **Auth verify** -- verify valid token + permission, verify invalid token
15. **ConfigMap tracker** -- list ConfigMap trackers
16. **Logout** -- logout and verify token deactivation
17. **Cleanup** -- delete test releases, clean up test server config

## Adding a New Product

1. **Create the product module** -- add a new directory `backend/src/Products/MyProduct/` containing:
   - `Types/Permission.hs` -- define a `MyProductPermission` ADT with all permissions and a `permissionDescription` function.
   - `Config.hs` -- define runtime config entries as `[ConfigEntry]`.
   - `Routes.hs` -- define the Servant API type and handler implementations.

2. **Register in `Products/Types.hs`**:
   - Add to `ProductSlug` ADT: `data ProductSlug = Autopilot | MyProduct`
   - Add mapping cases in `productSlugToText` and `textToProductSlug`.
   - Add to `Permission` union: `| MyProductPerm MyProductPermission`
   - Add cases in `allPermissions`, `defaultPermissions`, `isViewPerm`, `isEditPerm`.

3. **Register routes in `Products/Registry.hs`**:
   - Add route-to-permission mappings to `allProductPermissions`.

4. **Wire into server** in `Core/Server.hs`:
   - Add routes to `FullAPI` type.
   - Add handler to `fullServer`.

5. **Register configs** in `Shared/Config/Registry.hs`:
   - Import your product's config module and add to `allConfigEntries`.

6. **Frontend**:
   - Create `frontend/src/products/my-product/` with `pages/`, `api.ts`, `hooks.ts`, `types.ts`.
   - Register in `frontend/src/products/registry.ts`. Routes and sidebar auto-wire from the registry.

7. **Database**:
   - Seed system roles for the new product slug:
     ```sql
     INSERT INTO sc_role (product_slug, name, description, is_system_role, permissions) VALUES
       ('my-product', 'Admin', 'Full access', true, ARRAY['PERM_1', 'PERM_2', ...]),
       ('my-product', 'Manager', 'Standard access', true, ARRAY['PERM_1', ...]),
       ('my-product', 'Viewer', 'Read-only', true, ARRAY['PERM_VIEW']);
     ```
   - Create any product-specific tables needed by your queries.

Compile with `-Wall` to catch missing pattern matches on the new ADT constructors -- the compiler will flag every location that needs updating.
