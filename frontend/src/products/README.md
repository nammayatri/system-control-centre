# Products

Each product is a self-contained folder under `src/products/`. Routes and sidebar
entries are auto-wired from a single source of truth: `registry.ts`. There is no
need to edit `App.tsx` or `Sidebar.tsx` when adding pages.

## Folder layout

A product folder typically looks like:

```
src/products/<product>/
  pages/           UI screens (List / Create / Detail / Summary, etc.)
  api.ts           fetch helpers for this product's endpoints
  hooks.ts         react-query hooks wrapping api.ts
  types.ts         TypeScript types for this product (optional)
```

`pages/` is the only required subfolder. `api.ts` / `hooks.ts` / `types.ts` are
conventional but optional — add them when you need them. Note: a single product
slug can own several route groups (see below), in which case each group can live
in its own top-level folder (e.g. `releases/`, `configmap/`, `vs-editor/`,
`config/`) and all of them get registered under the same `ProductDefinition`.

## Registering a product

Open `src/products/registry.ts` and add an entry to `PRODUCT_REGISTRY`. Every
product is described by a `ProductDefinition`:

```ts
export interface ProductDefinition {
  slug: string;          // matches sc_role.product_slug in backend DB
  label: string;         // display name in sidebar
  icon: string;          // Lucide icon name for sidebar section
  basePath: string;      // URL base path (e.g., '/releases')
  navItems: ProductNavItem[];
  routes: ProductRoute[];
}
```

Each route may carry an optional `permission` string that gets enforced by
`ProtectedRoute` at render time:

```ts
export interface ProductRoute {
  path: string;          // React Router path
  component: ComponentType;
  permission?: string;   // e.g. 'RELEASE_CREATE'
}
```

A real example, abridged from the current registry:

```ts
import ListRelease from './releases/pages/ListRelease';
import CreateRelease from './releases/pages/CreateRelease';
import ReleaseSummary from './releases/pages/ReleaseSummary';
import ListConfigMap from './configmap/pages/ListConfigMap';
// ... more imports

const releasesProduct: ProductDefinition = {
  slug: 'autopilot',
  label: 'Backend Releases',
  icon: 'Rocket',
  basePath: '/releases',
  navItems: [
    { label: 'Releases',          path: '/releases',          icon: 'List' },
    { label: 'Create Release',    path: '/releases/new',      icon: 'Plus' },
    { label: 'Config Maps',       path: '/configmap',         icon: 'FileText' },
    { label: 'Deployment Config', path: '/deployment-config', icon: 'Layers' },
    { label: 'VS Editor',         path: '/vs-editor',         icon: 'Settings' },
    { label: 'Server Config',     path: '/configurations',    icon: 'Settings' },
  ],
  routes: [
    { path: '/releases',           component: ListRelease },
    { path: '/releases/new',       component: CreateRelease, permission: 'RELEASE_CREATE' },
    { path: '/releases/:id',       component: ReleaseSummary },
    { path: '/releases/:id/edit',  component: CreateRelease, permission: 'RELEASE_UPDATE' },
    { path: '/configmap',          component: ListConfigMap },
    // ... etc
  ],
};

export const PRODUCT_REGISTRY: ProductDefinition[] = [
  releasesProduct,
  // ← add new products here
];
```

That's it. `app/App.tsx` consumes `PRODUCT_REGISTRY.flatMap(...)` to mount every
route under `ProductLayout` + `ProtectedRoute`, and `core/layout/Sidebar.tsx`
iterates the same registry to render the nav. Don't hand-edit either file.

Note that one product slug can own several distinct URL groups — the `autopilot`
product currently exposes `/releases`, `/configmap`, `/deployment-config`,
`/vs-editor`, and `/configurations` all under the same backend slug.

## Currently registered products

- `autopilot` — Backend Releases. Owns the route groups: `/releases`,
  `/configmap`, `/deployment-config`, `/vs-editor`, `/configurations`.

The Admin console (`/admin/...`) is not a product — it lives directly in
`app/App.tsx` with its own `AdminLayout`.

## Backend coupling

The frontend `slug` must match a `product_slug` known to the backend RBAC layer
(`sc_role` rows are seeded per product slug, and `ProtectedRoute` calls
`hasPermission(slug, permission)`). When you add a new product slug here, also:

1. Add the corresponding `ProductSlug` constructor and permission ADT in the
   Haskell backend (`Products/Types.hs` + `Products/Registry.hs`).
2. Seed system roles into `sc_role` for that slug so users can be granted access.

Without the backend side in place, the sidebar will hide the product (the
`hasPermission` check in `Sidebar.tsx` filters it out) and routes will 403.
