# Namma AP

## Local Setup

### Prerequisites

- **GHC 9.2.7** and **Cabal** (or use [Nix](https://nixos.org/) for a reproducible environment)
- **PostgreSQL** (local or remote)
- **kubectl** (for Kubernetes operations)

### Quick Start

```bash
# 1. (Optional) Enter nix shell for reproducible deps
nix develop

# 2. Copy and configure environment
cp .env.example .env
# Edit .env — at minimum set your Postgres connection:
#   NammaAP_DATABASE_URL=postgres://user:pass@localhost:5432/namma_ap
# Or set individual vars: NammaAP_POSTGRES_HOST, _PORT, _USER, _PASSWORD, _DB

# 3. Create the database
createdb namma_ap
psql namma_ap < scripts/base_schema_postgres.sql

# 4. Build
cabal build

# 5. Run (server + background worker)
APP_STATE=SERVER cabal run namma-ap-exe
```

The server starts on `http://localhost:8012` (configurable via `PORT`).

### Run Modes

| `APP_STATE`   | Behaviour                                      |
|---------------|-------------------------------------------------|
| `SERVER`      | HTTP API server **+** background release worker |
| `RUNNER`      | Background release worker only                  |
| *(unset)*     | HTTP API server only                            |

### Database Connection

Resolved in order:
1. `NammaAP_DATABASE_URL` (recommended for cloud Postgres)
2. `DATABASE_URL`
3. Individual vars: `NammaAP_POSTGRES_HOST` / `_PORT` / `_USER` / `_PASSWORD` / `_DB`

The `.env` file is read automatically — no need to `source` it.

### Environment Variables

See [`.env.example`](.env.example) for the full list. Key ones:

| Variable | Default | Description |
|----------|---------|-------------|
| `APP_STATE` | *(server only)* | Run mode: `SERVER`, `RUNNER`, or unset |
| `PORT` | `8012` | HTTP server port |
| `NammaAP_ENV` | `production` | Environment name |
| `NammaAP_KUBECTL_BIN` | `kubectl` | Path to kubectl binary |
| `NammaAP_RUNNER_POLL_SECONDS` | `20` | Worker poll interval |
| `NammaAP_STAGGER_COOLOFF_SECONDS` | `120` | Cooloff between rollout steps |
| `NammaAP_MAX_K8S_RETRIES` | `3` | kubectl retry attempts |
| `NammaAP_MAINTENANCE_MODE` | `False` | Disable release execution |

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
src/
  NammaAP/Config.hs                  # Bootstrap config from env vars / .env
  NammaAP/Config/Runtime.hs          # Runtime-tunable configs from DB
  NammaAP/Server.hs                  # HTTP server (Servant + Warp)
  NammaAP/Runner.hs                  # Worker loop — polls and executes releases
  NammaAP/Environment.hs             # AppState, DBEnv, Flow monad
  NammaAP/DB/Connection.hs           # PostgreSQL connection pool
  NammaAP/Types/                     # Domain types (Release, Config, API)
  NammaAP/Workflow/                  # State machine engine
  NammaAP/Release/                   # Workflow implementations per release type
  NammaAP/K8s/                       # kubectl execution wrappers
  NammaAP/App/Storage/Queries/       # Database queries
scripts/
  base_schema_postgres.sql           # Full PostgreSQL schema
Dockerfile                           # Multi-stage Docker build
flake.nix                            # Nix reproducible environment
```
