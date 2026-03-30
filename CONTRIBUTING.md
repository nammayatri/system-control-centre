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
1. Add route to `Products/Autopilot/Routes.hs`
2. Implement handler
3. Add permission mapping to `Products/Registry.hs`
4. If new permission needed: add to `Products/Autopilot/Types/Permission.hs` ADT

**Frontend:**
1. Add page component to `products/releases/pages/`
2. Add API function to `products/releases/api.ts`
3. Add React Query hook to `products/releases/hooks.ts`
4. Add route to product definition in `products/registry.ts`
5. Wrap edit actions in `<PermissionGate product="backend-releases" permission="PERM">`

### Adding a New Product

See README.md "Adding a New Product" section.

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
