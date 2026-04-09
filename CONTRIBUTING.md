# Contributing to System Control Centre

## Architecture Overview

The project follows a **two-layer architecture**:

### Core (never changes for new products)
- `backend/src/NammaAP/Core/` — Auth, Admin, Server, Config, DB
- `frontend/src/core/` — Auth context, Admin pages, Layout

### Products (each self-contained)
- `backend/src/NammaAP/Products/` — Each product has its own routes, queries, workflows, types
- `frontend/src/products/` — Each product has pages, api, hooks, types

## How the Code Flows

### Request Flow
1. User action in React frontend
2. React Query hook calls API function
3. API function calls axios client (with auth token interceptor)
4. Backend WAI middleware validates token + checks permission
5. Servant handler processes the request
6. Response flows back through React Query cache

### Auth Flow
1. Login → POST /auth/login → returns token + products + permissions
2. Token stored in localStorage (key: sc_token)
3. Axios interceptor adds Authorization header to every request
4. Backend middleware extracts token → finds person → checks product permission
5. Superadmins bypass all permission checks

### Permission Resolution
1. Get user's role for the product (from DB: sc_person_product_access)
2. System role → permissions derived from code (defaultPermissions function)
3. Custom role → permissions from DB (sc_role.permissions TEXT[] column)
4. Apply GRANT overrides (add extra permissions)
5. Apply DENY overrides (remove specific permissions)
6. Result = effective permissions

### Adding a New Feature to Existing Product

**Backend:**
1. Add route to `Products/Autopilot/Routes.hs` with the appropriate `Protected '<perm>` Servant combinator (compile-time RBAC — forgetting it is a type error)
2. Implement the handler. Use the existing `Flow = ReaderT AppState IO` monad with `MonadFlow` for queries and `inDB` / `inConfig` helpers
3. If a new permission is needed: add a constructor to `Products/Autopilot/Types/Permission.hs:AutopilotPermission`. The compiler will flag missing cases in `permissionDescription` etc. via `-Wall`

**Frontend:**
1. Add page component under `frontend/src/products/<product>/pages/`
2. Add API function and React Query hook under the same product folder
3. Add route to the `ProductDefinition` in `frontend/src/products/registry.ts`
4. Wrap edit actions in `<PermissionGate product="..." permission="...">`

### Adding a New Workflow / Release Type

Workflows are now defined as **values** (`WorkflowSpec s`) running through the product-agnostic engine in `Core.Workflow.*`. To add a new workflow:

**Within Autopilot** (e.g. a new K8s release category):
1. Add a constructor to `Products/Autopilot/Types/Workflow.hs:ReleaseCategory`
2. Define a new `WorkflowSpec ReleaseState` value in a new module under `Products/Autopilot/Workflow/`. Example shape:
   ```haskell
   myNewSpec :: WorkflowSpec ReleaseState
   myNewSpec = WorkflowSpec
       { wsName     = "MyNew"
       , wsStages   = [stage1, stage2, stage3]
       , wsRollback = \_err -> pure ()
       , wsPersist  = persistWorkflowState
       }
   ```
3. Each stage is a `Stage ReleaseState` value. Build them via `mkStage` (clean) or `mkLegacyStateFlowStage` (wrapping existing `StateFlow` bodies)
4. Wire dispatch in `Products/Autopilot/Workflow/Factory.hs:getWorkflowForCategory`
5. Update the parser in `Products/Autopilot/Queries/ReleaseTracker.hs:parseReleaseCategory`

**For a brand-new product** (e.g. `FrontendRelease` with its own state type):
1. Define `data FrontendReleaseState = ...`
2. Define `persistFrontendState :: FrontendReleaseState -> Flow ()`
3. Build `Stage FrontendReleaseState` values for each stage
4. Build `frontendBuildSpec :: WorkflowSpec FrontendReleaseState`
5. Dispatch via `runWorkflowSpec frontendBuildSpec :: ExceptT WorkFlowError (Recorded FrontendReleaseState Flow) ()`
6. The same engine, runner, RBAC, audit, sync, and notifications work without modification

The canonical six-step lifecycle (`skip-check → acquire-locks → pre-check → exec → validate → advance-and-persist`) runs every stage in every product. Same monad. Same checkpoint resumption. The only thing that varies between products is the state type `s`.

### Adding a New Top-Level Product

See `backend/PRODUCTS.md` "Adding a new top-level product" section for the full checklist.

## Code Style

### Haskell
- Formatter: fourmolu (run `sc-format` or `make format`)
- GHC options: -Wall -Wcompat -Wunused-imports
- All types use ADTs where possible (not Text)
- All permissions enforced at compile time
- Pattern matches must be exhaustive (-Wall catches this)

### TypeScript/React
- No class components — function components only
- React Query for all data fetching (no raw useEffect + fetch)
- sonner toast for all notifications
- All edit actions behind PermissionGate
- Shared UI from shared/ui/ (don't create duplicate components)

### CSS/Design
- Fira Sans for UI text, Fira Code for technical data
- No gradients, glassmorphism, or decorative effects
- Flat professional design (zinc palette)
- cursor-pointer on all clickable elements
- 150ms transitions for hover states
- Skeleton loaders for loading states (not spinners)
- Before any UI work, review the design constraints in `design-system/system-control-centre/MASTER.md` and follow them

## File Organization

- One concern per file
- Colocate related code (pages + api + hooks + types in same product folder)
- Shared code in shared/ (UI components, hooks)
- Core code in core/ (auth, admin, layout)
- Product code in products/ (self-contained per product)

## Testing

Backend:
```bash
sc-test-api    # Test all endpoints (server must be running)
cabal test     # Run Haskell test suite
```

Frontend:
```bash
npx tsc --noEmit   # TypeScript type check
npm run build       # Full production build
```
