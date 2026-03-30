# System Control Centre

Unified platform for managing backend releases, configurations, and system operations with product-level RBAC.

## Architecture

```
┌─────────────────────────┐
│   Frontend (React)      │  ← One app, product-based folders
│   :5173                 │
└───────────┬─────────────┘
            │
┌───────────▼─────────────┐
│   Backend (Haskell)     │  ← One service, Core/ + Products/
│   :8012                 │
│                         │
│   Core/Auth     ← RBAC  │
│   Core/Admin    ← Users │
│   Products/Autopilot/   │  ← Backend Releases
│   Products/ConfigMgr/   │  ← Config Manager
└───────────┬─────────────┘
            │
┌───────────▼─────────────┐
│   PostgreSQL            │
│   system_control DB     │
└─────────────────────────┘
```

**Two layers only:**
- **Core/** — RBAC framework (auth, admin, server, config, DB). Never changes for new products.
- **Products/** — Each product is self-contained (routes, queries, K8s, workflows, types).

## Quick Start

### Prerequisites
- [Nix](https://nixos.org/download.html) (with flakes enabled)
- PostgreSQL running locally
- Node.js 20+ (for frontend)

### Backend

```bash
cd backend
nix develop --accept-flake-config

# All-in-one: creates DB + builds + starts server
sc-run
```

Or step by step:

```bash
sc-setup-db    # Create DB, schema, seed data
sc-build       # Compile
sc-server      # Start on :8012
```

### Frontend

```bash
cd frontend
npm install
npm run dev    # Starts on :5173
```

### Login

Open http://localhost:5173

- **Email:** admin@juspay.in
- **Password:** admin123
- This is the superadmin account with access to everything.

## Available Commands (in nix shell)

```
sc-setup-db    Setup local database (create + migrate + seed)
sc-build       Compile the backend
sc-run         Setup DB + build + start server (all-in-one)
sc-server      Start server only (assumes already built)
sc-hpack       Regenerate .cabal from package.yaml
sc-format      Format all Haskell source files (fourmolu)
sc-test        Run test suite
sc-migrate     Apply SQL migrations from dev/migrations/
sc-test-api    Test all APIs (server must be running)
sc-help        Show this help
```

## Without Nix (Makefile)

```bash
cd backend
make setup     # Create DB + schema + seed
make build     # cabal build
make run       # Setup + build + start
make format    # Format .hs files
make test      # Run tests
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SC_DB_NAME` | `system_control` | PostgreSQL database name |
| `SC_DB_USER` | `$(whoami)` | PostgreSQL user |
| `SC_DB_HOST` | `localhost` | PostgreSQL host |
| `SC_DB_PORT` | `5432` | PostgreSQL port |
| `PORT` | `8012` | Backend server port |

## API Overview

### Auth
```
POST /auth/login     → { token, person, products: [{ slug, role, permissions }] }
POST /auth/logout
GET  /auth/me        → current user + product access
POST /auth/verify    → { token, product, permission } → { authorized }
```

### Releases (RBAC-protected)
```
GET  /releases?from=&to=          → list releases
POST /releases/create             → create release
GET  /releases/:id                → release detail
GET  /releases/:id/events         → release events
POST /releases/:id/approve        → approve
POST /releases/:id/rollback       → rollback
POST /releases/:id/revert         → revert
POST /releases/:id/discard        → discard
POST /releases/:id/update         → update status (pause/resume/abort)
```

### Products & Services
```
GET  /products                    → list product configs
POST /products                    → upsert product
GET  /products/:prod/services     → list services
POST /services                    → upsert service
```

### Admin (superadmin only)
```
GET  /admin/products                          → list products (from ADT)
GET  /admin/products/:slug/permissions        → list permissions (from ADT)
GET  /admin/products/:slug/roles              → list roles + permissions
GET  /admin/users                             → list users
POST /admin/users                             → create user
GET  /admin/users/:id                         → user detail + access
POST /admin/users/:id/assign-role             → assign product role
DELETE /admin/users/:id/product-access/:slug  → revoke access
POST /admin/users/:id/permission-override     → add GRANT/DENY override
```

## RBAC Model

```
Products (from Haskell ADT — not DB)
  └── Roles (Admin, Manager, Viewer, Custom)
       └── Permissions (from ADT — not DB)

Person (DB)
  └── product_access: person + product_slug → role
       └── overrides: GRANT or DENY specific permissions

Effective = role_permissions + GRANTs - DENYs
Superadmins bypass all permission checks.
```

**System role defaults:**
| Role | Permissions |
|------|-------------|
| Admin | All 14 permissions |
| Manager | 12 permissions (all except config edit) |
| Viewer | 3 permissions (view only) |

## Type Safety

Everything is enforced at compile time:

- `ProductSlug` — ADT, not Text. Add a product without updating = compile error.
- `AutopilotPermission` — ADT with 14 values. Missing pattern match = compile warning.
- `Permission` — union type across all products.
- `SystemRole` — Admin/Manager/Viewer ADT.
- `OverrideType` — Grant/Deny ADT.
- Status transitions enforced by `validTransitions` function.

Products and permissions are **derived from code**, not stored in DB. The admin API returns them from `[minBound..maxBound]` on the ADTs.

## Adding a New Product

### Backend

1. Create `src/NammaAP/Products/MyProduct/Types/Permission.hs` — permission ADT
2. Add to `ProductSlug` in `Products/Types.hs`
3. Add to `Permission` union in `Products/Types.hs`
4. Add route-permission mapping in `Products/Registry.hs`
5. Create routes + handlers

### Frontend

1. Create `src/products/my-product/` folder with `pages/`, `api.ts`, `hooks.ts`, `types.ts`
2. Register in `src/products/registry.ts`
3. Routes + sidebar auto-wire from the registry.

### Database

```sql
INSERT INTO sc_role (product_slug, name, description, is_system_role) VALUES
  ('my-product', 'Admin', 'Full access', true),
  ('my-product', 'Manager', 'Standard access', true),
  ('my-product', 'Viewer', 'Read-only', true);
```

## Directory Structure

```
system-control-centre/
├── backend/
│   ├── src/NammaAP/
│   │   ├── Core/                    ← RBAC framework
│   │   │   ├── Auth/               ← Login, tokens, middleware
│   │   │   ├── Admin/              ← User/role management
│   │   │   ├── Server.hs           ← HTTP server
│   │   │   ├── Config.hs           ← Configuration
│   │   │   ├── Environment.hs      ← App state
│   │   │   └── DB/Connection.hs    ← PostgreSQL pool
│   │   └── Products/               ← Self-contained products
│   │       ├── Types.hs            ← ProductSlug, Permission ADTs
│   │       ├── Registry.hs         ← Route-permission mappings
│   │       ├── Autopilot/          ← Backend Releases product
│   │       │   ├── Routes.hs
│   │       │   ├── Runner.hs
│   │       │   ├── K8s/
│   │       │   ├── Workflow/
│   │       │   ├── Queries/
│   │       │   └── Types/
│   │       └── ConfigManager/      ← Config Manager product
│   ├── scripts/                    ← setup-db, run, format, migrate
│   ├── dev/
│   │   ├── sql-seed/               ← Schema + seed SQL
│   │   └── migrations/             ← Numbered migrations
│   ├── dhall-configs/              ← Typed configuration
│   ├── flake.nix                   ← Nix flake
│   ├── package.yaml                ← Haskell package config
│   └── .fourmolu.yaml              ← Formatter config
│
├── frontend/
│   └── src/
│       ├── app/                    ← App shell (routing, providers)
│       ├── core/                   ← Auth, admin, layout
│       ├── shared/ui/              ← Badge, Button, Card, etc.
│       ├── products/               ← Product modules
│       │   ├── registry.ts         ← Auto-wires routes + sidebar
│       │   └── releases/           ← Backend Releases UI
│       └── lib/                    ← Utilities
│
├── design-system/                  ← UI/UX design specs
│   └── system-control-centre/
│       ├── MASTER.md               ← Global design rules
│       └── pages/                  ← Per-page design specs
│
├── CLAUDE.md                       ← Project context for Claude
└── README.md                       ← This file
```

## Design System

Professional flat design — no gradients, no glassmorphism, no AI aesthetics.

- **Fonts:** Fira Sans (UI) + Fira Code (technical data)
- **Colors:** Zinc palette, blue accent, green/amber/red for statuses
- **Sidebar:** Dark (#0a0a0a), content light (#fafafa)
- **Cards:** border zinc-200, no shadow
- **Tables:** alternating rows, hover bg-zinc-100

Full specs in `design-system/system-control-centre/MASTER.md`.
