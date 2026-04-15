# System Control Centre

## Architecture
- Two layers: Core/ (RBAC framework) + Products/ (self-contained product modules)
- One Haskell backend monolith + One React frontend
- Products + permissions derived from Haskell ADTs (not DB)
- Each product is fully self-contained -- owns its tables, types, queries, logic

## Common modules (use these — every product should reuse them)
- `Core.Environment`      — defines `Flow = ReaderT AppState IO`, the `MonadFlow` constraint synonym, `AppState`, `getDBEnv`, `getConfig`, `withDb`, `withConfig`, `forkFlow`, `logInfo/Error/Warning/Debug`
- `Core.Types.Id`         — `Id Person`, `Id Release`, etc. Phantom-typed Text (Show/JSON/HttpApi/SQL all derived)
- `Core.Types.Time`       — `Seconds`, `Minutes`, `Hours`, `Days` + `threadDelay (Seconds 5)` instead of `threadDelay 5_000_000`
- `Core.Http.Client`      — pooled `http-client` Manager + retry + timeout. Use `httpJson`/`httpRaw` instead of spawning curl
- `Core.Logging`          — `logInfoG`/`logErrorG` (global, write to file+console) + `withLogTag` for context propagation
- `Core.AppError`         — `ToAppError` typeclass, `APIError`/`AuthError`/`DBError`/`WorkflowError` hierarchy, JSON error envelopes
- `Core.Auth.Protected`   — type-level RBAC Servant combinator (`Protected 'AP_RELEASE_VIEW`)
- `Shared.API.Response`   — `APISuccess` (preferred for action endpoints) + legacy `APIResponse`

## Monad convention (read this before writing handlers)

The codebase uses a `MonadFlow` constraint **synonym** (not a typeclass) defined in `Core/Environment.hs`:

```haskell
type MonadFlow m = (MonadIO m, MonadThrow m, MonadCatch m, MonadMask m, MonadReader AppState m)
type Flow        = ReaderT AppState IO
```

This is the same shape NammaYatri uses internally — a ConstraintKinds alias, **not** a class with instances. Queries and reusable helpers are written polymorphic in `m` with a `MonadFlow m =>` constraint; Servant resolves them to concrete `Flow` at the handler boundary. The testability benefit: you can run queries in any `ReaderT AppState` stack (e.g. a test harness) without touching the call sites.

| Layer | Monad | When |
|---|---|---|
| HTTP handlers | `Flow` | Every Servant handler. AppState carries config + DB pool + logger. |
| Background workers | `Flow` | `Runner.hs` and friends. Use `runFlow appState (...)` to enter it from `IO`. |
| Queries (`Queries/*.hs`) | `MonadFlow m => ... -> m a` | Callers don't need to pass DBEnv. Use `withDb` / `withConfig` to reach the resources. |
| Pure utilities (K8s wrappers, HTTP client, parsers) | Raw `IO` | Leaf functions called from `Flow` via `liftIO` or `withDb`. |

**Recommendation for new code:** use `MonadFlow m =>` for queries and reusable helpers, and concrete `Flow` for Servant handlers. `forkFlow` requires concrete `Flow` (not polymorphic `m`) because it captures `AppState` to spawn a background thread — don't try to make spawn sites polymorphic.

**No `Core.AppM`** — that was a parallel "next-gen" framework that nobody used. Deleted. Don't recreate it.

**Adding a new query:**
```haskell
findFooById :: MonadFlow m => Id Foo -> m (Maybe Foo)
findFooById fid = withDb $ \db -> runDB db $ ...
```
Calls in handlers become a one-liner: `result <- findFooById fid`.

**`RuntimeConfigSnapshot`** (in `Products.Autopilot.RuntimeConfig`) — for hot loops (scheduler ticks, workflow steps) grab a snapshot once per iteration instead of reading each flag individually from DB.

**`forkFlow` error handling** — `forkFlow` now wraps the child action with `try @SomeException` + `logErrorIO`, so async crashes are caught and logged instead of silently killing the thread. Don't rely on this as a general error strategy — typed errors should still propagate normally through `MonadThrow`/`MonadCatch`; this is just a last-resort safety net.

## Local Setup

### Quick Start (one command)
```bash
nix develop          # from repo root — auto-via direnv if installed
sc-dev               # starts everything: pg + db init + backend ghcid + frontend
```

Nix/direnv/process-compose live at the repo root (`flake.nix`, `.envrc`, `nix/`). The backend Haskell project stays under `backend/`.

`sc-dev` brings up the full stack via process-compose:
- PostgreSQL on `127.0.0.1:5434` (data in `./.local/data/pg`, auto-init from `dev/sql-seed/`)
- DB migrations from `dev/migrations/system-control/` (auto-applied)
- Backend on port 8012 with ghcid hot-reload (changes in `src/` recompile in <5s)
- Frontend on port 5173 (vite dev server)

Press Ctrl+C to stop everything cleanly.

### Other dev commands (run inside `nix develop`)
| Command | What it does |
|---------|--------------|
| `sc-dev`     | Full stack via process-compose (recommended) |
| `sc-build`   | `cabal build` |
| `sc-test`    | `cabal test` |
| `sc-test-api`| API integration tests (server must be running) |
| `sc-format`  | `treefmt` (fourmolu) |
| `sc-help`    | Show this list |

### Reset DB
```bash
rm -rf .local/data/pg
sc-dev   # next start re-initialises everything
```

### Environment Variables
| Variable | Default | Description |
|----------|---------|-------------|
| PORT | 8012 | Backend server port |
| SC_DATABASE_URL | postgres://$(whoami)@127.0.0.1:5434/system_control | DB connection (set by `nix develop`) |
| SC_CONFIG_PATH | ./dhall-configs/system-control.dhall | Dhall config file path |

## Default Login
- Email: admin@juspay.in
- Password: admin123 (superadmin, has access to everything)

## Adding a New Product
1. Backend: Create Products/MyProduct/ folder with Manifest.hs, Routes.hs, Types/Permission.hs
2. Backend: Add to ProductSlug ADT + Permission union in Products/Types.hs
3. Backend: Add to Products/Registry.hs
4. Frontend: Create products/my-product/ folder with pages/, api.ts, hooks.ts, types.ts
5. Frontend: Add to products/registry.ts
6. DB: Add system roles to sc_role for the new product slug

## Type Safety Rules
- Permissions are ADTs (AutopilotPermission, ConfigManagerPermission) -- not Text
- ProductSlug is an ADT -- not Text
- ReleaseStatus transitions enforced by validTransitions function
- AuditAction, OverrideType, SystemRole are all ADTs
- Product typeclass (IsProduct) enforces completeness -- missing implementation = won't compile
- Compile with -Wall -- non-exhaustive patterns catch missing cases

## DB Schema
- Autopilot tables: deployment_config, release_tracker, release_events, server_config
- deployment_config: unified product+service config (product-level rows have service IS NULL)
  - Column `app_group` (was `product` before 0007 migration) identifies the group
  - server_config.product still uses `product` (unchanged)
- release_tracker: `app_group` column (was `product`), `events` and `is_art_recorder` columns dropped
- Haskell domain type: `ReleaseTracker { appGroup :: Text }` maps to DB `app_group`
- API accepts both `"appGroup"` and `"product"` in JSON for backward compatibility
- VS edit data (old/new VS) stored as SNAPSHOT events in release_events, not udf fields
- RBAC tables: sc_person, sc_role, sc_person_product_access, sc_person_permission_override, sc_registration_token, sc_audit_log
- NO sc_product or sc_permission tables -- these are derived from Haskell ADTs

## Key Directories
- Backend Core: backend/src/Core/ (auth, admin, server, config, DB)
- Backend Products: backend/src/Products/ (autopilot, config-manager)
- Frontend Core: frontend/src/core/ (auth, admin, layout)
- Frontend Products: frontend/src/products/ (releases, configmap, config)
- Frontend Shared UI: frontend/src/shared/ui/

## Cloud DB (DO NOT MODIFY -- read only for reference)
NammaAP_DATABASE_URL=postgres://<user>:<password>@<aiven-host>:<port>/<db>?sslmode=require
# Actual connection string is stored out-of-repo (password vault / k8s secret).

## Important
- NEVER add "Co-Authored-By: Claude" to commit messages
- All edit APIs are RBAC-controlled -- no open access
- Test with -Wall to catch missing pattern matches
