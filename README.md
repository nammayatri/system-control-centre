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

The backend is split into two layers: `Core/` (framework — auth, admin, server, DB) and `Products/` (self-contained product modules). `Shared/` holds truly cross-product utilities (JSON helpers, error types, generic config registry, generic `server_config` queries). The product-aware layer `Products/` (top level) hosts `Products.Types` (the `IsProduct` typeclass + `ProductSlug` / `Permission` union) and `Products.ConfigCatalog` so that `Shared/` can stay product-agnostic.

```
src/
├── Core/
│   ├── Auth/             (Permission, Protected, Queries, Routes, Types, Schema)
│   ├── Admin/            (Routes, Queries, Types)
│   ├── DB/Connection.hs
│   ├── Environment.hs    (Flow monad, AppState, inDB / inConfig helpers)
│   ├── Config.hs         (bootstrap config from env)
│   ├── Server.hs         (Servant + Warp wiring with Context '[DBEnv])
│   ├── Http/Client.hs, Logging.hs, AppError.hs, Types/{Id,Time}.hs
│   └── Middleware/RequestId.hs
├── Shared/
│   ├── API/Response.hs, JSON.hs, Error.hs, Types/Id.hs
│   ├── Config/{Registry,Runtime,Types}.hs
│   ├── Queries/ServerConfig.hs
│   └── Types/Storage/ServerConfig.hs
└── Products/
    ├── Types.hs          (IsProduct, ProductSlug, Permission union)
    ├── ConfigCatalog.hs  (allConfigEntries = globalConfigs ++ autopilotConfigs)
    └── Autopilot/
        ├── Routes.hs            (Servant API type, every route carries `Protected '<perm>`)
        ├── Actions/             (Release, VSEdit, ConfigMap, Config, K8sResource)
        ├── Queries/             (ReleaseTracker, ProductService, VsEditTracker)
        ├── Workflow/            (BackendService, BackendJob, BackendCronJob, BackendScheduler, BackendConfig, MobileAppAndroid, Factory, Helpers, Recorded, Types)
        ├── K8s/                 (Deployment, DestinationRule, HPA, VirtualService, Kubectl, Execute)
        ├── Types/               (API, Release, Workflow, Permission, Storage/Schema, Target/*)
        ├── Runner.hs, Sync.hs, DecisionEngine.hs, EventLog.hs
        ├── Notifications.hs, Discovery.hs, Config.hs, RuntimeConfig.hs
```

`MonadFlow` is exported from `Core.Environment` as a constraint **synonym** (not a typeclass): `type MonadFlow m = (MonadIO m, MonadThrow m, MonadCatch m, MonadMask m, MonadReader AppState m)`. Queries and reusable helpers are written `MonadFlow m => ... -> m a`; Servant handlers use the concrete `Flow = ReaderT AppState IO`. Use `inDB :: (DBEnv -> IO a) -> Flow a` and `inConfig` from `Core.Environment` instead of the manual `getDBEnv >>= liftIO . f` pattern.

## Type Safety

### Typed Response Types

Most endpoints return typed Haskell response types defined in `Products/Autopilot/Types/API.hs`; a handful return dynamic K8s JSON from kubectl. Typed response types include:

`APIResponse`, `ProductResponse`, `ServiceResponse`, `ProductConfigResponse`, `ReleaseConfigResponse`, `PodHealthResponse`, `DiffResponse`, `ResourcesResponse`, `VsEditTrackerResponse`, `ServerConfigResponse`, `ConfigMapResponse`, `ConfigMapListResponse`, `ConfigMapK8sResponse`, `ReleaseEventResponse`, `ErrorResponse`, `VsLockErrorResponse`

### Compile-time RBAC (Phase 3)

Every product route in `Products/Autopilot/Routes.hs` carries a `Protected '<permission>` Servant combinator immediately after its first path literal:

```haskell
"releases" :> Protected 'AP_RELEASE_VIEW :> QueryParam "from" Text :> ... :> Get '[JSON] [ReleaseTracker]
```

The `HasServer` instance in `Core.Auth.Protected` reads `DBEnv` from the Servant `Context '[DBEnv]`, validates the bearer token, looks up effective permissions, and passes an `AuthedPerson` proof to the handler as its first argument. Forgetting `Protected` on a new route is a compile error. There is no runtime route-walker, no `findRoutePermission`, no startup `assertAllRoutesMapped` — all of that Phase 2 machinery is gone. Admin and Auth routes intentionally use in-handler superadmin / token checks instead.

`AutopilotPermission` has 20 constructors (see [Permissions List](#permissions-list)). Adding one without handling it in `permissionDescription` triggers a `-Wall` warning.

### Shared Utilities

- **`Shared/JSON.hs`** -- Generic JSON deriving with shared options (camelCase field labels, tag encoding).
- **`Shared/Error.hs`** -- Typed error ADT for structured error responses.
- **`Shared/API/Response.hs`** -- Generic `APIResponse` wire envelope.
- **`Shared/Config/Registry.hs`** -- Generic `ConfigEntry` utilities; product-aware catalog lives in `Products.ConfigCatalog`.

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

- **Nix** with flakes enabled (recommended — manages everything including postgres + node + ghc)
- **direnv** (optional but recommended — auto-activates the dev shell on `cd`)
- `kubectl` configured for your target cluster (only needed for actual K8s deploys)

Without Nix you'd need: GHC 9.2.7, Cabal, PostgreSQL 14+, Node.js 20.19+, fourmolu — but `nix develop` provides all of these reproducibly.

### One-command dev (recommended)

```bash
cd backend
nix develop          # auto-activated by direnv if installed
sc-dev               # starts everything
```

`sc-dev` brings up via process-compose:
- PostgreSQL on 127.0.0.1:5434 (data in `./.local/data/pg`, auto-init from `dev/sql-seed/`)
- DB migrations from `dev/migrations/system-control/`
- Backend on `:8012` with ghcid hot-reload
- Frontend on `:5173` (vite dev server)

Press Ctrl+C to stop everything.

Available commands in the Nix shell:

```
sc-dev         Start everything (postgres + db init + backend ghcid + frontend)
sc-build       Compile the backend (cabal build)
sc-test        Run test suite (cabal test)
sc-test-api    API integration tests (server must be running)
sc-format      Format all Haskell files via treefmt (fourmolu)
sc-help        Show this list
```

To reset the DB: `rm -rf backend/.local/data/pg && sc-dev`

### Default Login

| Field    | Value            |
|----------|------------------|
| Email    | admin@juspay.in  |
| Password | admin123         |

This is the superadmin account with full access to all products and admin operations.

## Docker

Both services build into standalone `linux/amd64` images and deploy independently. The local dev workflow is `nix run .#dev` — Docker is for production / staging / anywhere nix isn't available.

### Frontend image

`VITE_*` env vars are baked into the JS bundle at build time. Build a separate image per environment with the right `--build-arg` values. The defaults match local dev so an unconfigured `docker build` still produces a runnable image.

| Build arg | Default | Purpose |
|---|---|---|
| `VITE_API_BASE_URL` | `http://localhost:8012` | Backend URL |
| `VITE_AUTH_API_BASE_URL` | *(empty)* | Auth URL — empty falls back to `VITE_API_BASE_URL` |
| `VITE_DEFAULT_ENV` | `UAT` | Initial env in the env switcher |
| `VITE_AVAILABLE_ENVS` | `UAT,PROD,INTEG_CLUSTER` | Comma-separated list shown in switcher |

```bash
# UAT build
cd frontend
docker build --platform=linux/amd64 \
  --build-arg VITE_API_BASE_URL=https://api.uat.example.com \
  --build-arg VITE_DEFAULT_ENV=UAT \
  --build-arg VITE_AVAILABLE_ENVS=UAT,PROD,INTEG_CLUSTER \
  -t scc-frontend:uat .

# PROD build
docker build --platform=linux/amd64 \
  --build-arg VITE_API_BASE_URL=https://api.example.com \
  --build-arg VITE_DEFAULT_ENV=PROD \
  --build-arg VITE_AVAILABLE_ENVS=PROD \
  -t scc-frontend:prod .

# Run locally
docker run --platform=linux/amd64 -p 8080:80 scc-frontend:uat
# → http://localhost:8080
```

The image is nginx-1.27-alpine serving the static `dist/` output. Includes:
- SPA fallback to `/index.html` for React Router
- gzip + long-cache for hashed `/assets/`
- `/healthz` endpoint for k8s/docker probes
- Final image ~50 MB

### Backend image

The backend is a Haskell binary built with GHC 9.2.7 (matches the nix-flake dev toolchain). The image bundles `kubectl`, `dhall-to-json`, `tini` for PID 1 / signal handling, runs as non-root user `namma:1001`, and ships the seed SQL + migrations so you can bootstrap a fresh DB from inside the container.

**The image is environment-agnostic** — no `dhall-configs/` and no secrets are baked in. Production provides the dhall config file at runtime via a mounted volume (matches NammaYatri's `<APPNAME>_CONFIG_PATH` pattern).

```bash
cd backend
docker build --platform=linux/amd64 -t scc-backend:latest .
```

| Env var | Required | Purpose |
|---|---|---|
| `SC_CONFIG_PATH` | yes | Path to the dhall config file (e.g., a mounted k8s Secret) |
| `SC_DATABASE_URL` | yes | Postgres connection string (or set `SC_POSTGRES_*` individually) |
| `APP_STATE` | no (default `SERVER`) | `SERVER` runs HTTP + runner; `RUNNER` runs only the worker |
| `PORT` | no (default `8012`) | HTTP listen port |
| `SLACK_BOT_TOKEN` | no | Slack bot token for release notifications |
| `DASHBOARD_URL` | no | Frontend URL embedded in Slack messages |
| `SC_KUBECTL_BIN` | no (default `kubectl`) | Path to kubectl binary inside the container |
| `SYNC_CLUSTER_URL` / `SYNC_CLUSTER_BASE_AUTH` | no | Secondary cluster sync endpoint + basic auth |

The first run on a fresh DB needs schema bootstrap. Either:
1. Mount the host's `dev/sql-seed/` and `dev/migrations/system-control/` into the postgres init dir, OR
2. Exec into the container and run the bundled SQL files manually:
   ```bash
   docker exec -it scc-backend sh -c 'psql "$SC_DATABASE_URL" -f /srv/namma-ap/dev/sql-seed/system-control-seed.sql'
   ```

Final image ~280 MB.

### Production deployment

The dhall config is passed in via a single base64-encoded env var, `DHALL_CONFIGS`. The container entrypoint (`scripts/scc-entrypoint.sh`) decodes it on startup, writes it to `/tmp/scc/system-control.dhall`, and execs the binary with `SC_CONFIG_PATH` set to that path. Same image runs everywhere — only the env var contents change per environment.

**Step 1**: Encode your dhall once at deploy time.

```bash
base64 -w0 < dhall-configs/system-control.dhall
# → ewogIGxvZ2dlckNmZyA9CiAgICB7IGxldmVsID0gIklORk8iCiAg...
```

**Step 2**: Create a single k8s Secret with the encoded dhall + bootstrap values.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: scc-secrets
type: Opaque
stringData:
  # Base64-encoded dhall body — decoded by scc-entrypoint.sh on container start
  DHALL_CONFIGS: "ewogIGxvZ2dlckNmZyA9CiAgICB7IGxldmVsID0gIklORk8iCiAg..."

  # Bootstrap env vars — read directly by the Haskell binary
  SC_DATABASE_URL: "postgres://scc:strong-password@scc-pg.svc:5432/system_control?sslmode=require"
  SLACK_BOT_TOKEN: "xoxb-real-token"
  SYNC_CLUSTER_BASE_AUTH: "Basic dXNlcjpwYXNz"
```

**Step 3**: Wire it into the Deployment. Every key in the Secret becomes an env var via `envFrom`.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: scc-backend
spec:
  replicas: 1                        # singleton: runner takes per-tracker DB locks
  selector: { matchLabels: { app: scc-backend } }
  template:
    metadata: { labels: { app: scc-backend } }
    spec:
      containers:
        - name: scc-backend
          image: ghcr.io/your-org/scc-backend:1.0.0
          ports: [{ containerPort: 8012 }]

          env:
            - { name: APP_STATE,     value: SERVER }
            - { name: PORT,          value: "8012" }
            - { name: SC_ENV,        value: production }
            - { name: DASHBOARD_URL, value: https://scc.example.com }

          # Single Secret holds DHALL_CONFIGS + all bootstrap env vars
          envFrom:
            - secretRef: { name: scc-secrets }

          readinessProbe:
            tcpSocket: { port: 8012 }
            initialDelaySeconds: 10
          livenessProbe:
            tcpSocket: { port: 8012 }
            initialDelaySeconds: 30
```

That's the entire production deploy. No volume mounts, no `subPath`, no separate ConfigMap.

**How it works at startup**:

```
scc-entrypoint.sh:
  if DHALL_CONFIGS is set:
    echo "$DHALL_CONFIGS" | base64 -d > /tmp/scc/system-control.dhall
    export SC_CONFIG_PATH=/tmp/scc/system-control.dhall
  exec namma-ap
```

If `DHALL_CONFIGS` is unset, the entrypoint is a no-op and the binary uses its built-in default path — perfect for local dev / testing.

**Why this pattern**:

- **One image, many environments** — `scc-backend:1.0.0` runs in UAT/staging/PROD unchanged. Only the Secret changes per env.
- **One Secret, one source of truth** — dhall body and bootstrap env vars live in the same place. Easier to audit, rotate, and reason about.
- **Works on every platform** — k8s, ECS, Cloud Run, Nomad, plain `docker run` — anything that supports env vars works. No file mounts required.
- **No secrets in the image** — `dhall-configs/` is `.dockerignore`d. A developer's local file can never leak.
- **Native k8s rotation** — edit the Secret, then `kubectl rollout restart deployment/scc-backend`.

### Local Docker run

For a quick smoke test on your laptop, either mount a dev dhall file:

```bash
docker run --platform=linux/amd64 -p 8012:8012 \
  -e SC_DATABASE_URL='postgres://postgres:postgres@host.docker.internal:5434/system_control' \
  -e SC_CONFIG_PATH='/etc/scc/system-control.dhall' \
  -e SLACK_BOT_TOKEN='xoxb-...' \
  -v "$PWD/backend/dhall-configs/system-control.dhall:/etc/scc/system-control.dhall:ro" \
  scc-backend:latest
```

…or pass it base64-encoded (same path as production):

```bash
docker run --platform=linux/amd64 -p 8012:8012 \
  -e SC_DATABASE_URL='postgres://postgres:postgres@host.docker.internal:5434/system_control' \
  -e DHALL_CONFIGS="$(base64 -w0 < backend/dhall-configs/system-control.dhall)" \
  -e SLACK_BOT_TOKEN='xoxb-...' \
  scc-backend:latest
```

### Build for both at once

```bash
docker build --platform=linux/amd64 -t scc-backend:latest backend/
docker build --platform=linux/amd64 \
  --build-arg VITE_API_BASE_URL=https://api.example.com \
  -t scc-frontend:latest frontend/
```

Push to ECR / GCR / Docker Hub and deploy on ECS / Cloud Run / Kubernetes / Nomad / etc. The two services are fully independent — no shared state, no docker-compose required.

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

**System roles** (cannot be deleted, seeded per product): `Admin`, `Manager`, `Viewer`. Defaults are seeded by the RBAC seed in `dev/sql-seed/system-control-seed.sql`. Admin gets all permissions for the product; Manager gets all except the `*_CONFIG_EDIT` set; Viewer gets the `*_VIEW` permissions only.

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

All 20 Autopilot permissions (defined as `AutopilotPermission` ADT in `Products/Autopilot/Types/Permission.hs`):

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
| AP_RELEASE_DELETE      | RELEASE_DELETE       | Delete releases                          |
| AP_MANAGE_STAGGER      | MANAGE_STAGGER       | Manage rollout stagger configuration     |
| AP_PRODUCT_CONFIG_VIEW | PRODUCT_CONFIG_VIEW  | View product configurations              |
| AP_PRODUCT_CONFIG_EDIT | PRODUCT_CONFIG_EDIT  | Edit product configurations              |
| AP_SERVICE_CONFIG_VIEW | SERVICE_CONFIG_VIEW  | View server configurations               |
| AP_SERVICE_CONFIG_EDIT | SERVICE_CONFIG_EDIT  | Edit server configurations               |
| AP_CONFIG_APPROVE      | CONFIG_APPROVE       | Approve ConfigMap and VS edit releases   |
| AP_CONFIG_EDIT         | CONFIG_EDIT          | Edit ConfigMap and VS edit releases      |
| AP_CONFIG_DISCARD      | CONFIG_DISCARD       | Discard ConfigMap and VS edit releases   |
| AP_CONFIG_REVERT       | CONFIG_REVERT        | Revert ConfigMap releases                |
| AP_FORCE_UNLOCK        | FORCE_UNLOCK         | Force-release a VS edit lock held by another user (operator recovery; superadmin only) |

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
  { "rolloutPercent": 10, "cooloffMinutes": 5,  "podPercent": 20 },
  { "rolloutPercent": 50, "cooloffMinutes": 10, "podPercent": 50 },
  { "rolloutPercent": 100, "cooloffMinutes": 0, "podPercent": 100 }
]
```

Each step specifies:
- `rolloutPercent` -- percentage of traffic routed to new version (VirtualService weight).
- `cooloffMinutes` -- wait time **in minutes** at this stage (matches Julia production semantics; the legacy `cooloffSeconds` field name was renamed). The workflow multiplies by 60 internally.
- `podPercent` -- percentage of pods to run the new version.

The embedded `rollout_history` payload inside `TRAFFIC_UPDATED` / `DECISION_RESULT` event records still uses Julia's `cooloff` key for external consumer compatibility.

Rollout history tracks each completed step with timestamps, decision (Continue/Wait/Abort), decision reason, whether a manual override occurred, and HS decision data. Rollout history is editable inline from the release summary page.

### Deployment Snapshots and Diffs

During workflow execution, YAML snapshots are captured before and after deployment:

- **DEPLOYMENT_BEFORE / DEPLOYMENT_AFTER** -- deployment state snapshots stored as release events.
- **VS_BEFORE / VS_AFTER** -- VirtualService configuration snapshots.
- K8s metadata is stripped from snapshots (annotations, resourceVersion, uid, managedFields, status) to produce clean diffs.

The diff endpoint (`GET /releases/:id/diff?type=<type>`) retrieves these snapshots and returns before/after comparisons. Supported `type` values: `deployment`, `vs`, `configmap`. Diffs are displayed in YAML format (not JSON) on the frontend.

### HPA Flow (Julia parity)

When `scaling_with_hpa_enabled` includes the product (JSON array in server_config), the workflow ensures the new version has an HPA via three branches, in order:

1. **Branch 1 — patch existing new HPA**: if `<service>-<newVersion>-hpa` already exists, patch its min/max and target ref to point at the new deployment.
2. **Branch 2 — clone old HPA**: if the old version's HPA (`<service>-<oldVersion>-hpa`) exists, clone it to the new version with min/max derived from current desired replicas (`hpa_default_min_pods_config`, `hpa_max_replicas_buffer`, `hpa_min_max_ratio`).
3. **Branch 3 — create from template**: otherwise create the HPA from the template at the path stored in the `hpa_template` server_config key.

Records `HPA_CLONED` (or equivalent) event on success. Failure is non-fatal. Old-version HPA deletion is performed as part of `cleanupOldVersion` after the rollout completes.

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

Cross-cluster sync triggers from three points: forward sync after `Completed`, standard revert, and immediate revert. All require these gates:

| Gate | Source |
|------|--------|
| `k8s_enabled` | server_config (must be true) |
| `sync_cluster_enabled` | server_config (must be true) |
| Product has `sync_cluster` | deployment_config.sync_cluster (must be non-empty) |
| Release has `sync_enabled = "true"` | release_tracker.sync_enabled (legacy column name: `udf1`) |

Sync behavior:
- **Forward sync** (on COMPLETED): POSTs a new release to the sync cluster URL (`SYNC_CLUSTER_URL` env var) with the same version, rollout strategy (overridable via `sync_rollout_strategy_config`), peer-specific env override forwarding (`env_override_data`), and metadata.
- **Standard revert sync**: `PUT /release/revert/global/:globalId` on the sync cluster.
- **Immediate revert sync**: `PUT /release/revert/immediate/global/:globalId` on the sync cluster.
- **Idempotent receive**: the receive endpoints look up by `global_id`. The DB enforces uniqueness via the partial unique index `uq_release_tracker_global_id ON release_tracker (global_id) WHERE global_id IS NOT NULL`, making sync replay safe.
- **Loop prevention**: the receiving cluster sets `isSystemTriggered` on the inbound tracker so it does not sync back to its source.
- **Auto-approve**: the inbound payload may carry `is_approved = true` so the receiver runs without re-approval.
- **Auth**: Pomerium JWT (`x-pomerium-jwt-assertion` header) is preferred; falls back to Basic auth (`SYNC_CLUSTER_BASE_AUTH` env var) if no forwarded headers are present.
- **Retry**: 2 attempts with event logging (`SYNC_REQUEST`, `SYNC_RESPONSE`, `SYNC_FAILED`, `SYNC_FAILED_RETRY`, `SYNC_FAILED_FINAL`).

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

Threading: The first message (Created or ConfigMap Created) starts a Slack thread. All subsequent messages reply in that thread using the `thread_ts` stored in `release_tracker.slack_thread_ts` (legacy column name: `udf3`). The first writer wins by atomic CAS (`UPDATE ... AND slack_thread_ts IS NULL`); concurrent writers become no-ops, so duplicate threads are impossible.

Requirements: `SLACK_BOT_TOKEN` env var, `slack_enabled = true` in server_config, and a Slack channel configured per service in `deployment_config.slack_channel`. HTTP timeout is 10 seconds.

## API Reference

All endpoints require `Authorization: Bearer <token>` unless marked as public. Product routes are gated at compile time by the `Protected '<perm>` Servant combinator (Phase 3 RBAC) — see `Products/Autopilot/Routes.hs` for the canonical list. Auth and Admin routes use in-handler superadmin / token checks instead.

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
| PUT    | /release/revert/global/:globalId | RELEASE_REVERT | Cross-cluster sync receive: standard revert by global ID (idempotent on `global_id`) |
| PUT    | /release/revert/immediate/global/:globalId | RELEASE_REVERT | Cross-cluster sync receive: immediate revert by global ID |
| POST   | /releases/:id/discard | RELEASE_DISCARD | Discard a created release |
| POST   | /releases/:id/update | RELEASE_UPDATE | Update tracker fields (status, mode, priority, rollout, etc.) |
| GET    | /releases/:id/events | RELEASE_VIEW | List release events (audit trail) |
| POST   | /releases/:id/delete | RELEASE_DELETE | Permanently delete release and its events |
| GET    | /releases/:id/diff | RELEASE_VIEW | Get deployment/VS/configmap diff. Query: `?type=vs` |
| GET    | /releases/:id/pods/health | RELEASE_VIEW | Get pod health status for the release |
| POST   | /releases/:id/revert/immediate | RELEASE_REVERT | Immediate revert with optional sync to secondary cluster |
| POST   | /releases/:id/restart | RELEASE_CREATE | Restart a paused or failed release |
| POST   | /releases/:id/fast-forward | RELEASE_UPDATE | Fast-forward to next rollout step |

### 4. Rollout History and Misc (2 endpoints)

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| GET    | /releases/:id/rollout-history | RELEASE_VIEW | Get rollout history for a release |
| GET    | /releases/:id/logslink | RELEASE_VIEW | Get observability link payload (Grafana / Kibana) for a release |

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
| GET    | /server-config | SERVICE_CONFIG_VIEW | List all server config entries with registry metadata. Optional: `?product=autopilot` |
| POST   | /server-config | SERVICE_CONFIG_EDIT | Upsert a server config value |
| DELETE | /server-config/:id | SERVICE_CONFIG_EDIT | Delete a server config entry by id |

### 7. VS Edit Tracker (8 endpoints)

| Method | Path | Permission | Description |
|--------|------|------------|-------------|
| POST   | /vs-edit-tracker | RELEASE_CREATE | Create a new VS edit tracker entry |
| GET    | /vs-edit-tracker/list | RELEASE_VIEW | List VS edit trackers. Optional: `?from=ISO&to=ISO` |
| GET    | /vs-edit-tracker/current-vs | RELEASE_VIEW | Fetch current VirtualService YAML from K8s |
| POST   | /vs-edit-tracker/lock | RELEASE_CREATE | Lock a VirtualService for editing |
| POST   | /vs-edit-tracker/unlock | RELEASE_UPDATE | Unlock a VirtualService (requires tracker ownership) |
| POST   | /vs-edit-tracker/force-unlock | FORCE_UNLOCK | Force-release a VS edit lock held by another user (operator recovery; superadmin only) |
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
| GET    | /configmap | CONFIG_EDIT | Fetch live ConfigMap from primary K8s cluster |
| GET    | /configmap/secondary | CONFIG_EDIT | Fetch live ConfigMap from secondary K8s cluster |

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

Tracks the lifecycle of every release (including VS edits with `category = 'VSEdit'` and ConfigMap releases).

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | text | NOT NULL | Primary key (UUID) |
| status | text | NOT NULL | Release lifecycle status (see [status enum](#release-lifecycle)) |
| description | text | YES | Human-readable description |
| new_version | text | NOT NULL | Target version being deployed |
| old_version | text | NOT NULL | Previous/current running version |
| app_group | text | NOT NULL | Product/service group name (was `product` before migration 0007). API JSON accepts both `appGroup` and `product` for back-compat. |
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
| sync_enabled | text | YES | Multi-cloud sync flag ("true" = sync to secondary cluster). Renamed from `udf1` in migration 0008. API JSON accepts both names. |
| env_override_data | text | YES | Env var overrides from the Env Switch editor. Renamed from `udf2` in migration 0008. API JSON accepts both names. |
| slack_thread_ts | text | YES | Slack `thread_ts` for threaded notifications (CAS write-once). Renamed from `udf3` in migration 0008. API JSON accepts both names. |
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

Indexes: `release_tracker_pkey` (btree on `id`); `uq_release_tracker_global_id` — partial UNIQUE on `global_id WHERE global_id IS NOT NULL` (idempotent cross-cluster sync receive); plus the perf indexes listed in [Performance](#performance).

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
| app_group | text | NOT NULL | Product/service group name (was `product` before migration 0007). API JSON accepts both `appGroup` and `product`. |
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
The canonical prefix is `SC_*` (System Control). The legacy `NammaAP_*` prefix is still
accepted as a deprecated fallback for one release cycle.

When using `sc-dev`, the dev shell auto-exports `SC_DATABASE_URL=postgres://$(whoami)@127.0.0.1:5434/system_control`
so you don't need to set anything.

| Variable | Default | Description |
|----------|---------|-------------|
| APP_STATE | SERVER | Application mode (SERVER = server + runner, RUNNER = runner only) |
| PORT | 8012 | HTTP server port |
| SC_ENV | production | Environment name |
| SC_KUBECTL_BIN | kubectl | Path to kubectl binary |
| SC_MAX_K8S_RETRIES | 3 | Max retries for K8s commands |
| SC_DATABASE_URL | (none) | Full PostgreSQL connection URL (takes priority over individual fields) |
| SC_POSTGRES_HOST | 127.0.0.1 | PostgreSQL host |
| SC_POSTGRES_PORT | 5432 | PostgreSQL port (sc-dev uses 5434) |
| SC_POSTGRES_USER | postgres | PostgreSQL user |
| SC_POSTGRES_PASSWORD | postgres | PostgreSQL password |
| SC_POSTGRES_DB | system_control | PostgreSQL database name |
| SYNC_CLUSTER_URL | (empty) | Secondary cluster API URL for multi-cloud sync |
| SYNC_CLUSTER_BASE_AUTH | (empty) | Basic auth credentials for secondary cluster |
| SLACK_BOT_TOKEN | (empty) | Slack bot token for release notifications |
| DASHBOARD_URL | http://localhost:5173 | Frontend URL for clickable links in Slack notifications |

DB resolution order: `SC_DATABASE_URL` is tried first. If unset, individual `SC_POSTGRES_*` fields are used.

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
| hpa_default_min_pods_config | int | 1 | Default minimum pods used when cloning / creating an HPA |
| hpa_template | text | (none) | Path to the HPA YAML template used by Branch 3 of the HPA flow (Julia parity) |
| pod_readiness_max_attempts | int | 30 | Max polling attempts before declaring pod readiness failed |
| pod_readiness_poll_seconds | int | 10 | Interval between pod readiness polls (seconds) |
| pod_restart_count_threshold | int | 3 | Restart count above which a pod is considered unhealthy (CrashLoopBackOff guard) |

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
- Release sync toggle (`sync_enabled = "true"` for multi-cloud sync)
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

### Unit Tests

Run with `cabal test` or `sc-test` in the Nix shell. Test groups cover:

1. **Status transition tests** -- validates `validateStatusTransition` for all valid and invalid per-service transitions (Created->InProgress, InProgress->Paused, terminal state immutability, etc.)
2. **Global status transition tests** -- validates `validateGlobalStatusTransition` for cross-service transitions (Completed->Reverting, InProgress->Restarting, Aborting->Restarting, etc.)
3. **Version validation tests** -- validates `isValidK8sVersion` for valid versions (alphanumeric, dashes), invalid versions (dots, spaces, semicolons, special chars, leading/trailing dashes), and case insensitivity
4. **Shell quoting tests** -- validates `shellQuote` for safe wrapping of user input (empty strings, spaces, dollar signs, backticks, single quotes, semicolons, pipes, newlines)
5. **Permission tests** -- validates Admin/Manager/Viewer role defaults, permission text round-trips, effective permission computation (GRANT adds, DENY removes, no duplicates), ProductSlug and OverrideType round-trips, allPermissionsText and defaultPermissionsText
6. **Release tag generation tests** -- validates tag format (PRODUCT_YYYYMMDD_VERSION_SERVICE_MODE_ENV_PRIORITY), revert tag suffix, and component extraction
7. **Terminal/aborted status helper tests** -- validates `isTerminalStatus` and `isAbortedStatus` for all status values

### Integration Tests

Run with `sc-test-api` (requires server to be running, e.g. via `sc-dev`). Test sections:

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

The canonical step-by-step is in [`backend/PRODUCTS.md`](backend/PRODUCTS.md). Summary:

1. **Create the product folder** under `backend/src/Products/MyProduct/` with `Routes.hs`, `Types/Permission.hs` (`MyProductPermission` ADT + `KnownPermission` instance per constructor), and `Actions/`, `Queries/`, `Types/` as needed. Mark every route in `Routes.hs` with `Protected '<MyProductPermission_Constructor>` so RBAC is enforced at compile time.
2. **Register in `Products/Types.hs`**: add to `ProductSlug` ADT, extend `productSlugToText` / `textToProductSlug`, extend the `Permission` union, and update `allPermissions` / `isViewPerm` / `isEditPerm`.
3. **Register configs in `Products/ConfigCatalog.hs`** if your product has runtime `server_config` entries (one-line append to `allConfigEntries`).
4. **Mount the API in `Core/Server.hs`**: add to `FullAPI` and to `fullServer`.
5. **Frontend**: create `frontend/src/products/my-product/` with `pages/`, `api.ts`, `hooks.ts`, `types.ts`, and register in `frontend/src/products/registry.ts` — routes and sidebar auto-wire from the registry.
6. **Database**: seed system roles for the new slug in the RBAC seed (`dev/sql-seed/system-control-seed.sql`); add any product-specific tables.

Compile with `-Wall` — non-exhaustive matches on the new ADT constructors will be flagged at every site that needs updating, and forgetting `Protected` on a route is a `HasServer` type error.
