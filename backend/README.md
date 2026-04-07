# Namma AP

## Local Setup

### Prerequisites

- **GHC 9.2.7** and **Cabal** (or use [Nix](https://nixos.org/) for a reproducible environment)
- **PostgreSQL** (local or remote)
- **kubectl** (for Kubernetes operations)

### Quick Start (one command)

```bash
nix develop          # enter the dev shell (auto via direnv if installed)
sc-dev               # starts everything: postgres + db init + backend + frontend
```

`sc-dev` brings up the full stack via process-compose:
- **PostgreSQL** on `127.0.0.1:5434` — data in `./.local/data/pg`, auto-init from `dev/sql-seed/`
- **DB migrations** from `dev/migrations/system-control/` (idempotent, re-applied each start)
- **Backend** on `:8012` with `ghcid` hot-reload — saving any `.hs` file recompiles in seconds
- **Frontend** on `:5173` (vite dev server)

Press Ctrl+C to stop everything cleanly.

To reset the DB completely:
```bash
rm -rf .local/data/pg
sc-dev
```

### Run Modes

| `APP_STATE`   | Behaviour                                      |
|---------------|-------------------------------------------------|
| `SERVER`      | HTTP API server **+** background release worker |
| `RUNNER`      | Background release worker only                  |
| *(unset)*     | HTTP API server only                            |

### Database Connection

`sc-dev` auto-exports `SC_DATABASE_URL=postgres://$(whoami)@127.0.0.1:5434/system_control`,
so for normal local dev you don't need to set anything.

For cloud / custom setups, the binary resolves DB connection in this order:
1. `SC_DATABASE_URL` (recommended) — also accepts `NammaAP_DATABASE_URL` as deprecated fallback
2. Individual vars: `SC_POSTGRES_HOST` / `_PORT` / `_USER` / `_PASSWORD` / `_DB`

The `.env` file is read automatically — no need to `source` it.

### Environment Variables

See [`.env.example`](.env.example) for the full list. Key ones (canonical `SC_*` names,
`NammaAP_*` is the deprecated fallback):

| Variable | Default | Description |
|----------|---------|-------------|
| `APP_STATE` | *(server only)* | Run mode: `SERVER`, `RUNNER`, or unset |
| `PORT` | `8012` | HTTP server port |
| `SC_ENV` | `production` | Environment name |
| `SC_KUBECTL_BIN` | `kubectl` | Path to kubectl binary |
| `SC_MAX_K8S_RETRIES` | `3` | kubectl retry attempts |

---

## What is Namma AP?

Namma AP is a release orchestration engine for [NammaYatri](https://nammayatri.in). It manages coordinated deployments of microservices on Kubernetes through a Mobius-style workflow state machine backed by PostgreSQL.

### Core Capabilities

- **Progressive Rollouts** — deploys services in configurable stages (e.g. 10% → 50% → 100%) with cooloff periods and monitoring between steps
- **Multi-type Releases** — supports backend services, schedulers, CronJobs, one-off jobs, ConfigMap updates, and mobile app bundles
- **Kubernetes Orchestration** — manages Deployments, VirtualServices, DestinationRules, HPAs, and ConfigMaps via kubectl
- **Approval Workflows** — release locking, approval gates, and infrastructure sign-off
- **A/B Testing** — optional integration with a decision engine for traffic-splitting experiments
- **Audit Trail** — every release state change is logged as an event in PostgreSQL
- **Runtime Configuration** — tunable settings via `server_config` table without redeployment

### How It Works

1. A release tracker is created via the API with source/target versions and a rollout strategy
2. The background worker picks up approved trackers and executes them through a state machine:
   `Init → CreateDeployment → UpdateService → ApplyConfigMap → ApplyDestinationRule → FlipVirtualService → Monitoring → Stabilize → Done`
3. Each stage is checkpointed to the database — if the process restarts, it resumes from the last completed stage
4. On failure, releases can be rolled back or reverted

### API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/products` | List all products |
| `POST` | `/products` | Create/update product |
| `GET` | `/products/{product}/services` | List services for a product |
| `POST` | `/services` | Create/update service config |
| `GET` | `/releases` | List releases (query: `from`, `to`) |
| `POST` | `/releases/create` | Create a release tracker |
| `GET` | `/releases/{id}` | Get release details |
| `GET` | `/releases/{id}/events` | Get release event log |
| `POST` | `/releases/{id}/approve` | Approve a release |
| `POST` | `/releases/{id}/trigger` | Manually trigger execution |
| `POST` | `/releases/{id}/rollback` | Initiate rollback |
| `POST` | `/releases/{id}/revert` | Create a revert release |
| `POST` | `/releases/{id}/discard` | Discard a release |
| `POST` | `/releases/{id}/update` | Update tracker fields |
| `GET` | `/configmap` | Fetch K8s ConfigMap (query: `PRODUCT`, `NAME`) |
| `GET/POST` | `/tracker/configmap/...` | ConfigMap tracker CRUD |
| `GET` | `/envs` | Fetch deployment env vars |
| `GET` | `/server-config` | List runtime server configs |
| `POST` | `/server-config` | Upsert a server config |

### Project Structure

```
app/Main.hs                          # Entry point — selects SERVER vs RUNNER mode
bin/                                 # Dev helper scripts (sc-dev, sc-build, sc-test, sc-format, ...)
src/
  Core/                              # Shared framework (RBAC, server, DB, config)
    Auth/                            # Login, tokens, permission middleware
    Admin/                           # User/role/permission CRUD (superadmin)
    Config.hs                        # Bootstrap config from env vars / .env
    Config/                          # Runtime-tunable configs
    DB/Connection.hs                 # PostgreSQL pool + ensureSchema (runtime DDL)
    Environment.hs                   # AppState, DBEnv, Flow monad
    Server.hs                        # HTTP server (Servant + Warp + auth middleware)
    Utils/                           # Flow monad utilities
  Products/                          # Self-contained product modules
    Types.hs                         # ProductSlug + Permission ADTs (source of truth)
    Registry.hs                      # Route -> permission mappings per product
    Autopilot/                       # Releases, ConfigMaps, VS edits, server config
      Routes.hs                      # Servant API definition
      Actions/                       # HTTP handlers (Release, Config, ConfigMap, K8sResource, VSEdit)
      Queries/                       # Database queries
      Types/                         # Domain types (incl. Permission ADT)
      Workflow/                      # Release workflow state machines
      K8s/                           # kubectl execution wrappers
      Runner.hs                      # Background worker loop
      Sync.hs, DecisionEngine.hs, Notifications.hs, Discovery.hs, RuntimeConfig.hs
  Shared/                            # Cross-product helpers (Error, JSON, Config, Queries, Types)
scripts/                             # test-api.sh (integration tests)
dev/                                 # Canonical sql-seed/ + migrations/system-control/ (used by sc-dev)
Dockerfile                           # Multi-stage Docker build
flake.nix                            # Nix reproducible environment + process-compose dev stack
```
