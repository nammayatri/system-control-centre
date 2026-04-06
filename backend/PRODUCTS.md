# System Control Centre — Product Organization

The codebase is split into two layers:

- `src/Core/` — shared RBAC framework, auth, admin, HTTP server, DB connection
- `src/Products/` — self-contained product modules (each owns its routes, types, queries, workflows)

Products and permissions are derived from Haskell ADTs in `src/Products/Types.hs`, not from the database.

## Core Modules (shared)

- `src/Core/Auth/` — Login, token management, permission middleware (`Routes.hs`, `Middleware.hs`, `Queries.hs`, `Types.hs`)
- `src/Core/Admin/` — User, role, permission CRUD for superadmins (`Routes.hs`, `Queries.hs`, `Types.hs`)
- `src/Core/Config.hs` — Bootstrap configuration loaded from env vars / `.env`
- `src/Core/DB/Connection.hs` — PostgreSQL pool + `ensureSchema` (creates tables at runtime)
- `src/Core/Environment.hs` — `AppState`, `DBEnv`, `Flow` monad
- `src/Core/Server.hs` — Servant + Warp HTTP server, mounts auth/admin/product APIs through the auth middleware
- `src/Core/Utils/` — Flow monad utilities
- `src/Shared/` — Cross-product helpers (`Error.hs`, `JSON.hs`, shared `Config/`, `Queries/`, `Types/`)

## Product: Autopilot (`src/Products/Autopilot/`)

Owns backend releases, ConfigMap trackers, VS edit trackers, and runtime server configuration.

- `Routes.hs` — Servant API definition (`CoreAPI`) and `coreServer` handler wiring
- `Actions/` — HTTP handlers (`Release.hs`, `Config.hs`, `ConfigMap.hs`, `K8sResource.hs`, `VSEdit.hs`)
- `Queries/` — Database queries (`ReleaseTracker.hs`, `ProductService.hs`, `ServerConfig.hs`, `VsEditTracker.hs`)
- `Types/` — Domain types (`API.hs`, `Release.hs`, `Workflow.hs`, `Target.hs`, `Permission.hs`, plus `Storage/` and `Target/`)
- `Workflow/` — Release workflow state machines (`BackendServiceWorkflow.hs`, `BackendJobWorkflow.hs`, `BackendCronJobWorkflow.hs`, `BackendSchedulerWorkflow.hs`, `BackendConfigWorkflow.hs`, `MobileAppAndroidWorkflow.hs`, `Factory.hs`, `Helpers.hs`, `Recorded.hs`, `Types.hs`)
- `K8s/` — kubectl execution wrappers (`Deployment.hs`, `VirtualService.hs`, `DestinationRule.hs`, `HPA.hs`, `Execute.hs`, `Kubectl.hs`)
- `Runner.hs` — Background worker that polls and executes releases
- `Sync.hs` — Cross-cluster sync for releases
- `DecisionEngine.hs` — Prometheus / AB / Health Score gates (disabled by default)
- `Notifications.hs` — Slack notification dispatch
- `Discovery.hs`, `Config.hs`, `RuntimeConfig.hs` — product configuration helpers
- `Types/Permission.hs` — `AutopilotPermission` ADT (one constructor per permission)

## Product: Config Manager — Future

Planned as `src/Products/ConfigManager/` with the same shape (`Routes.hs`, `Actions/`, `Queries/`, `Types/`). Not yet present in the codebase.

## Adding a New Product

The product system is type-driven — adding a product requires touching three places, after which the compiler enforces completeness.

1. **Create the product folder** under `src/Products/MyProduct/` with at least:
   - `Routes.hs` — Servant API type and handler server
   - `Types/Permission.hs` — `MyProductPermission` ADT (`deriving Enum, Bounded`) and `myProductPermissionToText`
   - `Actions/`, `Queries/`, `Types/` as needed
2. **Register the product** in `src/Products/Types.hs`:
   - Add a constructor to the `ProductSlug` ADT (e.g. `| MyProduct`)
   - Extend `productSlugToText` / `textToProductSlug`
   - Extend the `Permission` union with a `MyProductPerm MyProductPermission` constructor and update `permissionToText`, `allPermissions`, `isViewPerm`, `isEditPerm`
3. **Register routes and permissions** in `src/Products/Registry.hs`:
   - Add a `myProductPermissions :: [ProductPermission]` list mapping `(method, path segments, permission, "myproduct")`
   - Append it to `allProductPermissions`
4. **Mount the API** in `src/Core/Server.hs`:
   - Import `MyProduct.Routes` and add it to the `FullAPI` type
   - Add the handler to `fullServer`
5. **Add dynamic-path RBAC entries** (routes with path captures) in `src/Core/Auth/Middleware.hs` under `findRoutePermission`
6. **Seed system roles** for the new product slug in the RBAC seed (`scripts/rbac_seed.sql` or the canonical seed under `dev/sql-seed/`)
7. **Add the frontend product folder** under `frontend/src/products/myproduct/` and register it in `frontend/src/products/registry.ts`

Build with `-Wall` after the change — non-exhaustive pattern matches in `permissionToText`, `allPermissions`, and the per-product `permissionDescription` will be flagged immediately if any case is missing.
