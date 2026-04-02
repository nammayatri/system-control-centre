# System Control Centre

## Architecture
- Two layers: Core/ (RBAC framework) + Products/ (self-contained product modules)
- One Haskell backend monolith + One React frontend
- Products + permissions derived from Haskell ADTs (not DB)
- Each product is fully self-contained -- owns its tables, types, queries, logic

## Local Setup

### Quick Start (one command)
```bash
cd backend
nix develop --accept-flake-config
# Inside nix shell:
bash scripts/run.sh   # creates DB + builds + starts server on :8012
```

### Step by Step
```bash
# Backend
cd backend
nix develop --accept-flake-config  # enter nix shell (GHC 9.2.7 + cabal + psql)
bash scripts/setup-db.sh           # create DB + schema + seed data
cabal build                        # compile
cabal run namma-ap-exe             # start server on :8012

# Frontend (separate terminal)
cd frontend
npm install
npm run dev                        # starts on :5173
```

### Environment Variables
| Variable | Default | Description |
|----------|---------|-------------|
| SC_DB_NAME | system_control | PostgreSQL database name |
| SC_DB_USER | $(whoami) | PostgreSQL user |
| SC_DB_HOST | localhost | PostgreSQL host |
| SC_DB_PORT | 5432 | PostgreSQL port |
| PORT | 8012 | Backend server port |

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
NammaAP_DATABASE_URL=postgres://<user>:<password>@<aiven-host>:<port>/defaultdb?sslmode=require

## Important
- NEVER add "Co-Authored-By: Claude" to commit messages
- All edit APIs are RBAC-controlled -- no open access
- Test with -Wall to catch missing pattern matches
