# System Control Centre

Centralized release management and configuration platform with role-based access control, automated deployment workflows, and progressive rollout strategies for Kubernetes-based backend services, mobile apps, and infrastructure.

## Architecture

The system follows a two-layer architecture: **Core** (authentication, RBAC, admin) and **Products** (self-contained product modules that plug into the core).

- **Backend**: Haskell (Servant HTTP framework + Beam ORM + PostgreSQL). Products and permissions are defined as Haskell ADTs, not database rows -- the compiler enforces completeness.
- **Frontend**: React + TypeScript + Vite + TailwindCSS.
- **Background Runner**: A polling loop that picks up approved releases and dispatches them to category-specific workflow executors (BackendService, Scheduler, CronJob, Job, Config, Android).

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
                    |      Routes, Queries      |
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
| Admin   | All 14 permissions for the product |
| Manager | All except `PRODUCT_CONFIG_EDIT` and `SERVICE_CONFIG_EDIT` (12 permissions) |
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

All 14 Autopilot permissions:

| Permission           | Wire Name            | Description                              |
|----------------------|----------------------|------------------------------------------|
| AP_RELEASE_VIEW      | RELEASE_VIEW         | View releases and events                 |
| AP_RELEASE_CREATE    | RELEASE_CREATE       | Create new releases                      |
| AP_RELEASE_APPROVE   | RELEASE_APPROVE      | Approve releases for deployment          |
| AP_RELEASE_REVERT    | RELEASE_REVERT       | Revert completed releases                |
| AP_RELEASE_DISCARD   | RELEASE_DISCARD      | Discard created releases                 |
| AP_RELEASE_PAUSE     | RELEASE_PAUSE        | Pause in-progress releases               |
| AP_RELEASE_RESUME    | RELEASE_RESUME       | Resume paused releases                   |
| AP_RELEASE_ABORT     | RELEASE_ABORT        | Abort in-progress releases               |
| AP_RELEASE_UPDATE    | RELEASE_UPDATE       | Update release metadata                  |
| AP_MANAGE_STAGGER    | MANAGE_STAGGER       | Manage rollout stagger configuration     |
| AP_PRODUCT_CONFIG_VIEW | PRODUCT_CONFIG_VIEW | View product configurations              |
| AP_PRODUCT_CONFIG_EDIT | PRODUCT_CONFIG_EDIT | Edit product configurations              |
| AP_SERVICE_CONFIG_VIEW | SERVICE_CONFIG_VIEW | View server configurations               |
| AP_SERVICE_CONFIG_EDIT | SERVICE_CONFIG_EDIT | Edit server configurations               |

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
| Init        | Validation and precondition checks (manifests, cluster capacity, signing keys) |
| Preparing   | Pre-deployment preparation (namespaces, ConfigMaps, APK uploads)    |
| Deploying   | Active deployment/rollout (traffic shift, staged rollout, image update) |
| Monitoring  | Post-deployment health checks (pod health, latency, error rates, crash rates) |
| Finalizing  | Cleanup old resources (scale down, archive, promote)                |
| Done        | Successfully completed                                              |
| RollingBack | Error state -- reverting to previous version                        |

### Background Runner

The runner (`Products.Autopilot.Runner.runnerLoop`) is a background polling loop:

1. **Poll** -- every `release_watch_delay` seconds (default 20, configurable via `server_config`).
2. **Find runnable releases** -- status `Created`, approved (`is_approved = true`), schedule time has arrived.
3. **Check eligibility** -- for K8s-backed categories: VirtualService must not be locked by the VS edit tracker, and no ongoing release for the same product+env (unless `multi_release_per_product` is enabled). BackendConfig, MobileApp, WebApp, and Infrastructure categories are always eligible.
4. **Pick jobs** -- when `multi_release_per_product` is off, at most one release per product+env is picked per poll. Jobs are sorted by priority (higher first), then by schedule time.
5. **Validate version** -- for K8s releases, compares the tracker's `oldVersion` against the running VirtualService primary subset. If a mismatch is detected, the release is auto-discarded with a `VERSION_MISMATCH` event and Slack notification. Skipped for new services or when oldVersion is `unknown`/`new`/empty.
6. **Dispatch** -- marks `InProgress`, records `RUNNER_PICKED` event, dispatches to the category-specific workflow via `Workflow.Factory.executeReleaseWorkflow`.
7. **Handle result** -- on success: records `COMPLETED` event. On failure: marks `Aborted` (or `UserAborted` if the previous status was `Aborting`), records `FAILED` event, sends Slack abort notification.

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

Rollout history tracks each completed step with: timestamps, decision (Continue/Wait/Abort), decision reason, whether a manual override occurred, and HS decision data.

### Snapshot and Diff

During workflow execution, deployment snapshots (deployment state, VirtualService config, ConfigMap contents) are captured as release events with labels like `DEPLOYMENT_SNAPSHOT`, `VS_SNAPSHOT`, etc. The diff endpoint (`GET /releases/:id/diff?type=vs`) retrieves these snapshots and returns before/after comparisons. Supported `type` values: `deployment`, `vs`, `configmap`.

### Slack Notifications

Thread-aware Slack notifications. The first message (`TRACKER_CREATED`) starts a Slack thread. All subsequent messages reply in that thread using the `thread_ts` stored in `release_tracker.udf3`.

Events that trigger notifications:
- Release created, approved
- Release progress updates
- Release completed, aborted
- Release paused, resumed
- Release reverted
- Pods scaled down

Requirements: `SLACK_BOT_TOKEN` env var and `slack_enabled = true` in server_config. Slack channel is configured per service in `release_config.slack_webhook_urls`.

## API Reference

All endpoints require `Authorization: Bearer <token>` unless marked as public.

### 1. Auth (4 endpoints)

| Method | Path           | Permission | Description |
|--------|----------------|------------|-------------|
| POST   | /auth/login    | Public     | Authenticate with email and password, returns token |
| POST   | /auth/verify   | Public     | Verify token and check specific permission |
| POST   | /auth/logout   | Token only | Deactivate current token |
| GET    | /auth/me       | Token only | Get current user profile and product access |

**POST /auth/login**

Request:
```json
{ "email": "admin@juspay.in", "password": "admin123" }
```

Response:
```json
{
  "token": "uuid-string",
  "person": {
    "id": "uuid",
    "email": "admin@juspay.in",
    "firstName": "Admin",
    "lastName": "User",
    "isSuperadmin": true
  },
  "products": [
    { "slug": "autopilot", "role": "Admin", "permissions": ["RELEASE_VIEW", "RELEASE_CREATE", ...] }
  ]
}
```

**POST /auth/verify**

Request:
```json
{ "token": "uuid-string", "product": "autopilot", "permission": "RELEASE_CREATE" }
```

Response:
```json
{
  "authorized": true,
  "person": { "id": "uuid", "email": "...", "firstName": "...", "lastName": "..." }
}
```

**GET /auth/me**

Response: same structure as the login response but without the `token` field (returns `person` and `products`).

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

**POST /admin/users**

Request:
```json
{
  "email": "user@example.com",
  "firstName": "Jane",
  "lastName": "Doe",
  "password": "secret",
  "isSuperadmin": false
}
```

Response:
```json
{ "id": "uuid-of-new-user", "status": "SUCCESS" }
```

**PUT /admin/users/:userId**

Request (all fields optional):
```json
{ "firstName": "Jane", "lastName": "Smith", "isActive": true, "isSuperadmin": false }
```

Response:
```json
{ "status": "SUCCESS", "message": "User updated" }
```

**POST /admin/users/:userId/assign-role**

Request:
```json
{ "productSlug": "autopilot", "roleId": "uuid-of-role" }
```

**POST /admin/users/:userId/permission-override**

Request:
```json
{ "productSlug": "autopilot", "permissionAction": "RELEASE_APPROVE", "overrideType": "GRANT" }
```

Response:
```json
{ "id": "uuid-of-override", "status": "SUCCESS" }
```

**POST /admin/products/:slug/roles**

Request:
```json
{
  "name": "Deployer",
  "description": "Can deploy but not configure",
  "permissions": ["RELEASE_VIEW", "RELEASE_CREATE", "RELEASE_APPROVE"]
}
```

Response:
```json
{ "id": "uuid-of-role", "status": "SUCCESS" }
```

**PUT /admin/products/:slug/roles/:roleId**

Request:
```json
{
  "description": "Updated description",
  "permissions": ["RELEASE_VIEW", "RELEASE_CREATE", "RELEASE_APPROVE", "RELEASE_REVERT"]
}
```

### 3. Releases (17 endpoints)

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
| POST   | /releases/:id/delete | RELEASE_DISCARD | Permanently delete release and its events |
| GET    | /releases/:id/diff | RELEASE_VIEW | Get deployment/VS/configmap diff. Query: `?type=vs` |
| GET    | /releases/:id/pods/health | RELEASE_VIEW | Get pod health status for the release |
| POST   | /releases/:id/revert/immediate | RELEASE_REVERT | Immediate revert with optional sync to secondary cluster |
| POST   | /releases/:id/restart | RELEASE_CREATE | Restart a paused or failed release |
| POST   | /releases/:id/fast-forward | RELEASE_UPDATE | Fast-forward to next rollout step |

**POST /releases/create**

Request:
```json
{
  "product": "Beckn",
  "service": "rider-app",
  "env": "UAT",
  "trackerType": "BackendService",
  "createdBy": "user@example.com",
  "oldVersion": "unknown",
  "newVersion": "v2.1.0",
  "rolloutStrategy": [
    { "rolloutPercent": 10, "cooloffSeconds": 300, "podPercent": 20 },
    { "rolloutPercent": 100, "cooloffSeconds": 0, "podPercent": 100 }
  ],
  "mode": "AUTO",
  "priority": 0,
  "description": "Feature release",
  "metadata": { "docker-image": "registry/rider-app:v2.1.0" }
}
```

Response:
```json
{ "status": "SUCCESS", "message": "Tracker created: <uuid>" }
```

Additional optional fields: `requestedCluster`, `approvedBy`, `releaseTag`, `scheduleTime`, `info`, `changeLog`, `globalId`, `isApproved`, `isInfraApproved`, `newService`, `cronjobSuspend`, `udf1`, `udf2`, `udf3`, `isReleaseSync`, `isSystemTriggered`, `syncClusterUdf2`, `syncClusterRolloutStrategy`.

**POST /releases/:id/approve**

Request:
```json
{ "approvedBy": "approver@example.com", "isInfraApproved": true }
```

Response: the updated `ReleaseTracker` object (or `null` if not found).

**POST /releases/:id/trigger**

Request:
```json
{ "reason": "Manual trigger for hotfix" }
```

**POST /releases/:id/rollback**

Request:
```json
{ "reason": "High error rate observed" }
```

**POST /releases/:id/revert**

Request:
```json
{
  "requestedBy": "user@example.com",
  "info": "Revert due to error rate spike",
  "immediate": false,
  "isRevertSync": false
}
```

**POST /releases/:id/discard**

Request:
```json
{ "reason": "No longer needed" }
```

**POST /releases/:id/update**

Request (all fields optional):
```json
{
  "status": "Paused",
  "mode": "MANUAL",
  "releaseManager": "new-owner@example.com",
  "priority": 5,
  "scheduleTime": "2026-04-01T10:00:00Z",
  "description": "Updated description",
  "info": "Additional info",
  "rolloutStrategy": [{ "rolloutPercent": 100, "cooloffSeconds": 0, "podPercent": 100 }],
  "changeLog": "Updated changelog",
  "isApproved": true,
  "isInfraApproved": true,
  "udf1": "custom-value",
  "dockerImage": "registry/app:v2.1.1",
  "podsScaleDownDelay": 2.0
}
```

**POST /releases/:id/revert/immediate**

Request:
```json
{ "requestedBy": "user@example.com", "info": "Emergency revert", "isRevertSync": true }
```

**POST /releases/:id/restart**

Request:
```json
{ "requestedBy": "user@example.com", "reason": "Retry after transient failure" }
```

**POST /releases/:id/fast-forward**

Request:
```json
{ "requestedBy": "user@example.com", "reason": "Skip cooloff, push to 100%" }
```

**GET /releases/:id/diff?type=vs**

Query parameter `type`: `deployment`, `vs`, or `configmap`.

**GET /releases/:id/events**

Response:
```json
[
  {
    "category": "BUSINESS",
    "label": "TRACKER_CREATED",
    "data": { ... },
    "timestamp": "2026-03-30T10:00:00Z"
  }
]
```

### 4. Product and Service Config (10 endpoints)

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

**POST /products/config**

Request:
```json
{
  "product": "Beckn",
  "cluster": "prod-cluster",
  "namespace": "production",
  "vsName": "beckn-vs",
  "productType": "SERVICE",
  "productAcronym": "BK",
  "repoName": "nammayatri/Backend",
  "releaseBranch": "main",
  "syncCluster": "secondary-cluster",
  "needInfraApproval": true
}
```

**POST /services/config**

Request:
```json
{
  "product": "Beckn",
  "service": "rider-app",
  "serviceType": "SERVICE",
  "emails": "team@example.com",
  "serviceHost": "rider-app-svc",
  "rolloutStrategyText": "[{\"rolloutPercent\":10,\"cooloffSeconds\":300,\"podPercent\":20}]",
  "revertStrategyText": "[{\"rolloutPercent\":100,\"cooloffSeconds\":0,\"podPercent\":100}]"
}
```

### 5. Server Config (2 endpoints)

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| GET    | /server-config | SERVICE_CONFIG_VIEW | List all server config entries with registry metadata |
| POST   | /server-config | SERVICE_CONFIG_EDIT | Upsert a server config value |

**POST /server-config**

Request:
```json
{ "name": "release_watch_delay", "value": "30", "enabled": 1 }
```

The GET endpoint returns all entries from the `server_config` table, enriched with metadata from the config registry (type, default value, description, group).

### 6. VS Edit Tracker (8 endpoints)

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

**POST /vs-edit-tracker**

Request:
```json
{
  "product": "Beckn",
  "service": "rider-app",
  "env": "UAT",
  "vsName": "beckn-vs",
  "createdBy": "user@example.com",
  "oldVsData": "<yaml content>",
  "info": "Traffic split for canary"
}
```

**POST /vs-edit-tracker/lock**

Request:
```json
{
  "product": "Beckn",
  "vsName": "beckn-vs",
  "env": "UAT",
  "lockedBy": "user@example.com",
  "oldVsData": "<yaml content>",
  "lockDurationMinutes": 30
}
```

**POST /vs-edit-tracker/unlock**

Request (provide either trackerId or product+vsName+env):
```json
{ "trackerId": "uuid", "product": "Beckn", "vsName": "beckn-vs", "env": "UAT" }
```

**GET /vs-edit-tracker/current-vs**

Query parameters: `?product=Beckn&service=rider-app`

### 7. K8s Resources (3 endpoints)

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| GET    | /resources | PRODUCT_CONFIG_VIEW | Fetch K8s resources (deployments, pods, etc.) for a product/service |
| GET    | /envs | RELEASE_VIEW | Fetch deployment env vars from primary cluster |
| GET    | /envs/secondary | RELEASE_VIEW | Fetch deployment env vars from secondary/sync cluster |

Query parameters: `?product=Beckn&service=rider-app&env=UAT` (or `?PRODUCT=Beckn&SERVICE=rider-app` for resources).

### 8. ConfigMap Tracker (6 endpoints)

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| GET    | /tracker/configmap/list | RELEASE_VIEW | List ConfigMap release trackers. Optional: `?from=ISO&to=ISO` |
| GET    | /tracker/configmap/:id | RELEASE_VIEW | Get single ConfigMap release tracker |
| POST   | /tracker/configmap | RELEASE_CREATE | Create a ConfigMap release tracker |
| PUT    | /tracker/configmap/:id | RELEASE_UPDATE | Update ConfigMap tracker |
| GET    | /configmap | RELEASE_VIEW | Fetch live ConfigMap from primary K8s cluster |
| GET    | /configmap/secondary | RELEASE_VIEW | Fetch live ConfigMap from secondary K8s cluster |

Query parameters for live fetch: `?PRODUCT=Beckn&NAME=rider-app-config`

### 9. Product Discovery (4 endpoints)

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| GET    | /products | PRODUCT_CONFIG_VIEW | List all product configs (cluster, namespace, VS info) |
| POST   | /products | PRODUCT_CONFIG_EDIT | Upsert product config (legacy endpoint) |
| GET    | /products/:product/services | PRODUCT_CONFIG_VIEW | Discover services via VirtualService or DB fallback |
| POST   | /services | PRODUCT_CONFIG_EDIT | Upsert release config (legacy endpoint) |

## Database Schema

### 1. release_tracker

Tracks the lifecycle of every release.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | text | NOT NULL | Primary key (UUID) |
| status | text | NOT NULL | Release lifecycle status (Created, InProgress, Completed, Aborted, UserAborted, Discarded, Discarding, Paused, Aborting, Reverting, Reverted, Restarting) |
| description | text | YES | Human-readable description |
| new_version | text | NOT NULL | Target version being deployed |
| old_version | text | NOT NULL | Previous/current running version |
| product | text | NOT NULL | Product/service group name (e.g., "Beckn") |
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
| events | text | YES | Legacy events field (deprecated; use release_events table) |
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
| is_art_recorder | integer | YES | ART (Automated Regression Testing) recorder flag |
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
| re_label | text | NOT NULL | Event label (e.g., "TRACKER_CREATED", "RUNNER_PICKED", "COMPLETED", "FAILED", "ROLLBACK_REQUESTED", "VERSION_MISMATCH", "STATUS_UPDATED", "TRACKER_APPROVED", "REVERT_TRACKER_CREATED") |
| re_payload | jsonb | NOT NULL | Event payload (tracker snapshot, error details, messages, etc.) |
| re_created_at | timestamptz | NOT NULL | Event timestamp |

### 3. product_config

Kubernetes deployment configuration per product (cluster, namespace, VirtualService).

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | bigint | NOT NULL | Primary key |
| product | text | NOT NULL | Product name |
| repo_name | text | NOT NULL | Git repository name |
| product_type | text | NOT NULL | Type: "SERVICE", "SCHEDULER", etc. |
| product_acronym | text | NOT NULL | Short acronym for the product |
| release_branch | text | NOT NULL | Default release branch (e.g., "main", "master") |
| need_infra_approval | boolean | YES | Whether infrastructure team must approve releases |
| need_infra_approval1 | boolean | YES | Secondary infrastructure approval flag |
| target_config | text | YES | JSON: cluster, namespace, vsName, syncCluster fields |

### 4. release_config

Per-service release configuration (rollout strategy, notification channels, decision config).

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | bigint | NOT NULL | Primary key |
| emails | text | YES | Notification email addresses (comma-separated) |
| rollout_strategy | text | YES | Default rollout strategy as JSON array |
| decision_config | text | YES | Decision engine configuration JSON |
| service | text | NOT NULL | Service name |
| product | text | NOT NULL | Parent product name |
| flags | text | YES | Feature flags JSON |
| slack_webhook_urls | text | YES | Slack channel ID for notifications |
| service_acronym | text | YES | Service abbreviation |
| service_type | text | YES | Service type ("SERVICE", "SCHEDULER", etc.) |
| bitbucket_path | text | YES | Repository path for the service |
| microservice_type | text | YES | Microservice classification |
| revert_strategy | text | YES | Revert-specific rollout strategy JSON |
| jira_webhook_url | text | YES | Jira integration webhook URL |
| target_config | text | YES | JSON: serviceHost and other target-specific config |

### 5. server_config

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

### 6. vs_edit_tracker

Tracks manual VirtualService edits with locking, approval, and revert capability.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | text | NOT NULL | Primary key (UUID) |
| product | text | NOT NULL | Product name |
| service | text | NOT NULL | Service name |
| env | text | NOT NULL | Environment |
| vs_name | text | NOT NULL | VirtualService name in K8s |
| old_vs_data | text | YES | Original VirtualService YAML/JSON before edit |
| new_vs_data | text | YES | Modified VirtualService YAML/JSON after edit |
| status | text | NOT NULL | Status (default: "CREATED") |
| created_by | text | NOT NULL | Creator email address |
| approved_by | text | YES | Approver email address |
| is_locked | boolean | YES | Whether VS is currently locked for editing (default: false) |
| locked_by | text | YES | Email of the person holding the lock |
| locked_at | timestamptz | YES | When the lock was acquired |
| lock_expiry | timestamptz | YES | When the lock automatically expires |
| monitoring_end_time | timestamptz | YES | End of post-edit monitoring period |
| info | text | YES | Additional notes |
| created_at | timestamptz | NOT NULL | Creation timestamp (default: now()) |
| updated_at | timestamptz | NOT NULL | Last update timestamp (default: now()) |

### 7. sc_person

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

### 8. sc_role

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

### 9. sc_person_product_access

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

### 10. sc_person_permission_override

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

### 11. sc_registration_token

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

### 12. sc_audit_log

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
| APP_STATE | SERVER | Application mode |
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
| prom_query_check_enabled | bool | false | Enable Prometheus query health checks |

**Autopilot -- Scaling:**

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| scale_down_pods_on_completion | bool | true | Scale down old pods after release completes |
| pods_scale_down_delay_config | double | 0.0 | Delay before scaling down old pods (hours) |
| scaling_with_hpa_enabled | json | [] | Products with HPA scaling enabled (JSON array of product names) |
| hpa_max_replicas_buffer | int | 1 | Buffer added to HPA max replicas calculation |
| hpa_min_max_ratio | double | 1.0 | HPA min/max replica ratio |
| pods_calculation_factor | double | 1.2 | Factor for pod count calculation |
| pods_creation_delay | int | 60 | Wait time for pod creation (seconds) |

**Autopilot -- A/B Testing:**

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| decision_engine_enabled | bool | false | Enable A/B testing decision engine |

**Autopilot -- Other:**

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| watcher_enabled | bool | true | Enable the background runner watcher |
| max_job_completion_hours | int | 3 | Max hours for job completion before timeout |
| revert_cooloff | int | 1 | Cooloff seconds before revert execution |
| lock_expiry_delay_minutes | int | 15 | VS lock auto-expiry in minutes |
| default_recording_time | double | 20.0 | Default recording time for ART (minutes) |

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
