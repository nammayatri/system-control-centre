# System Control Centre — Product Organization

## Core Modules (shared)
- `Auth/` — Login, token management, permission middleware
- `Admin/` — User, role, product, permission CRUD (superadmin only)
- `Config.hs` — Bootstrap configuration
- `DB/` — Database connection pooling
- `Environment.hs` — App state, Flow monad
- `Server.hs` — HTTP server (Servant + Warp + auth middleware)
- `Types/` — Shared types (API responses, storage schema)
- `Utils/` — Flow monad utilities

## Product: Releases (backend-releases)
- `App/Routes/Core.hs` — Release API endpoints
- `App/Storage/Queries/` — Release database queries
- `K8s/` — Kubernetes operations (deployments, VirtualServices, etc.)
- `Workflow/` — Release workflow engine (state machine, factory)
- `Runner.hs` — Background worker for release execution
- `Service/Sync.hs` — Cross-cluster sync
- `Types/Release.hs` — Release types
- `Types/Target/` — Platform-specific target types (K8s, PlayStore, AppStore)

## Product: Config Manager (config-manager) — Future
- Will handle ConfigMap/Secret management
- Routes, handlers, types in dedicated modules

## Adding a New Product
1. Add route module under `App/Routes/` or new directory
2. Register routes in `Server.hs` (add to FullAPI type)
3. Add permissions in `scripts/rbac_seed.sql`
4. Add route-permission mapping in `Auth/Middleware.hs`
5. Add frontend product folder
