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
- `Workflow/` — Workflow specs and helpers:
  - `BackendServiceWorkflow.hs` — `backendServiceSpec :: WorkflowSpec ReleaseState` for K8s service rollouts (VS traffic shifting, decision engine, post-monitoring)
  - `BackendSchedulerWorkflow.hs` — `backendSchedulerSpec :: WorkflowSpec ReleaseState` for pod-count based scheduler rollouts
  - `BackendConfigWorkflow.hs` — `backendConfigWorkflow :: ReleaseWorkFlow ()` for ConfigMap / Secret applies (still on the legacy `|>>` pattern; spec-based migration is a future PR)
  - `Factory.hs` — `getWorkflowForCategory` dispatch table
  - `Helpers.hs` — shared helpers (`persistWorkflowState`, `captureDeploymentSnapshot`, `withK8sContext`, plus the legacy `|>>` / `cprV2` operator still used by `BackendConfigWorkflow.hs`)
  - `StageHelpers.hs` — `mkLegacyStateFlowStage` adapter for wrapping existing `StateFlow` bodies as `Stage` values
  - `Recorded.hs` — re-export shim for `Core.Workflow.Recorded`
  - `Types.hs` — `ReleaseState`, `ReleaseWorkFlow`, `StateFlow`, `StageOutcome`
- `K8s/` — kubectl execution wrappers (`Deployment.hs`, `VirtualService.hs`, `DestinationRule.hs`, `HPA.hs`, `Execute.hs`, `Kubectl.hs`)
- `Runner.hs` — Background worker that polls and executes releases
- `Sync.hs` — Cross-cluster sync for releases
- `DecisionEngine.hs` — Prometheus / AB / Health Score gates (disabled by default)
- `Notifications.hs` — Slack notification dispatch
- `Discovery.hs`, `Config.hs`, `RuntimeConfig.hs` — product configuration helpers
- `Types/Permission.hs` — `AutopilotPermission` ADT (one constructor per permission)

### Workflow engine: `Core.Workflow.*` (shared across all products)

The workflow engine itself lives in `src/Core/Workflow/` and is **fully product-agnostic**. Any SCC product (Autopilot today, future products tomorrow) reuses the same engine by parameterizing it over its own state type:

- `Core.Workflow.Recorded` — checkpointed state-transformer monad. Generic over `s` and `m`. The header comment says: *"Every SCC product that needs resumable, checkpointed workflows reuses this exact engine by choosing its own state type @s@ and base monad @m@."*
- `Core.Workflow.Types` — `WorkFlowError = DomainError | RetriableError` (two-bucket error classification used by every workflow).
- `Core.Workflow.Stage` — `Stage s` (a workflow stage as a __value__, with `stageGuard`/`stagePreCheck`/`stageExec`/`stageOnError`/`stageAcquireLocks`/`stageOnAdvance` fields), `StageM s m` constraint synonym, `StageOutcome` (`StageSuccess | StageWaiting | StageAbort`), `LockHandle`, `mkStage` smart constructor.
- `Core.Workflow.Spec` — `WorkflowSpec s` (a workflow as a __value__, with `wsName`/`wsStages`/`wsRollback`/`wsPersist` fields).
- `Core.Workflow.Engine` — `runWorkflowSpec` (entry point), `runStage`, `withLockBracket` (bracket-based lock release), `liftStateFlow` (adapter for legacy `StateFlow` bodies).

Each stage runs through the canonical six-step lifecycle: __skip-check → acquire-locks → pre-check → exec → validate → advance-and-persist__. Same lifecycle for every stage in every product. Same monad stack — `ReleaseWorkFlow = ExceptT WorkFlowError (Recorded ReleaseState Flow)`. Same `Recorded`-based checkpoint resumption.

### Adding a new release category to an existing product (Autopilot)

For a new K8s release type (e.g. a new variant of BackendService for some specialized workload):

1. Add a new constructor to `ReleaseCategory` in `src/Products/Autopilot/Types/Workflow.hs`.
2. Add a new entry to `getDefaultDeploymentTarget` and `migrateTrackerTypeToCategory`.
3. Add a new `WorkflowSpec ReleaseState` value in a new module under `src/Products/Autopilot/Workflow/`. The spec is just a list of stages — you can reuse existing stage definitions (e.g. the existing `serviceStageInit` from `BackendServiceWorkflow.hs`) or build new ones via `mkLegacyStateFlowStage` if you have existing `StateFlow` code, or via `mkStage` directly if writing fresh code.
4. Wire the dispatch in `src/Products/Autopilot/Workflow/Factory.hs:getWorkflowForCategory` — add a new case mapping the category to `runWorkflowSpec yourSpec`.
5. Update the parser in `src/Products/Autopilot/Queries/ReleaseTracker.hs:parseReleaseCategory` to recognize the new category from DB strings.
6. Update the eligibility check in `src/Products/Autopilot/Runner.hs:isEligibleToRun` if the new category needs special gating.

### Adding a new top-level product (e.g. FrontendRelease)

The product system is type-driven — adding a product requires touching three places, after which the compiler enforces completeness.

1. **Create the product folder** under `src/Products/MyProduct/` with at least:
   - `Routes.hs` — Servant API type and handler server
   - `Types/Permission.hs` — `MyProductPermission` ADT (`deriving Enum, Bounded`) and `myProductPermissionToText`
   - `Types/State.hs` — your own `MyProductState` record type (analogous to Autopilot's `ReleaseState`)
   - `Workflow/` — `WorkflowSpec MyProductState` values for each release type, plus per-product persist function
   - `Actions/`, `Queries/` as needed
2. **Reuse the workflow engine** from `Core.Workflow.*`:
   - Each `WorkflowSpec MyProductState` is dispatched by `runWorkflowSpec :: WorkflowSpec MyProductState -> ExceptT WorkFlowError (Recorded MyProductState Flow) ()`
   - The same canonical six-step lifecycle runs every stage, same as Autopilot
   - The same `Recorded`-based checkpoint resumption applies
3. **Register the product** in `src/Products/Types.hs`:
   - Add a constructor to the `ProductSlug` ADT (e.g. `| MyProduct`)
   - Extend `productSlugToText` / `textToProductSlug`
   - Extend the `Permission` union with a `MyProductPerm MyProductPermission` constructor and update `permissionToText`, `allPermissions`, `isViewPerm`, `isEditPerm`
4. **Mount the API** in `src/Core/Server.hs`:
   - Import `MyProduct.Routes` and add it to the `FullAPI` type
   - Add the handler to `fullServer`
5. **Wire RBAC** by adding the `Protected '<perm>` Servant combinators to your routes in `MyProduct.Routes`
6. **Seed system roles** for the new product slug in the RBAC seed under `dev/sql-seed/system-control-seed.sql`
7. **Add the frontend product folder** under `frontend/src/products/myproduct/` and register it in `frontend/src/products/registry.ts`

Build with `-Wall` after the change — non-exhaustive pattern matches in `permissionToText`, `allPermissions`, and the per-product `permissionDescription` will be flagged immediately if any case is missing.
