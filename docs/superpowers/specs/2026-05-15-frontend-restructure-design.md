# Frontend Restructure — Disjoint URL Trees + Layout Route Nesting — Design

| | |
|---|---|
| **Date** | 2026-05-15 (revised 2026-05-26) |
| **Author** | shivendra02shah@gmail.com (with assistant) |
| **Status** | Implemented (all 4 phases complete) |
| **Scope** | Frontend routing and navigation only. No DB schema changes. No new BE endpoints. No changes to RBAC, roles, or permission overrides. |
| **Source plan** | `docs/superpowers/plans/2026-05-15-frontend-restructure.md` |

## 1. Problem

Both tiles share `basePath: '/releases'`. This single overlap forces:

| Workaround | Where | Lines |
|---|---|---|
| `findCurrentProduct` heuristic (46 lines) | `ProductLayout.tsx:45–90` | Longest-prefix + query-param resolution to guess which tile owns the URL |
| `defaultCategoryFilter` | `registry.ts` | `'mobile'` / `'backend'` hint for `?category=` disambiguation |
| `matchPaths` | `registry.ts` | Extra prefixes to keep sidebar highlighted (`/release-groups` → mobile tile) |
| `?category=mobile` query-string routing | `registry.ts`, `SidebarBody` | Nav item `/releases?category=mobile` requires query-param matching in sidebar active check |
| `useEffect` self-correction in `ReleaseSummary` | `ReleaseSummary.tsx:844–854` | Adds `?category=mobile` to URL after data loads to fix sidebar |
| Query-string parsing in `SidebarBody` | `ProductLayout.tsx:136–145` | Splits nav item paths on `?`, compares URLSearchParams |

**Current URL tree — scattered across roots:**

```
Backend tile routes:       Mobile tile routes:
/releases                  /releases?category=mobile    (query-param routing)
/releases/new              /releases/mobile/new
/releases/:id              /releases/:id/revert
/releases/:id/edit         /releases/live
/releases/:id/clone        /release-groups              (different root)
/configmap                 /release-groups/:groupId
/configmap/new             /mobile/apps                 (different root)
/configmap/:id
/vs-editor
/vs-editor/new
/vs-editor/:id
/deployment-config
/configurations
```

Mobile pages span 4 roots (`/releases/*`, `/release-groups/*`, `/mobile/*`, plus `?category=`). Backend pages span 5 roots (`/releases/*`, `/configmap/*`, `/vs-editor/*`, `/deployment-config`, `/configurations`). No single prefix identifies either tile.

**Goal.** Two disjoint URL trees (`/backend/*` and `/mobile/*`). Product resolved by React Router layout route nesting, not by heuristic. Direct route replacement — no redirect table, no transition period.

## 2. Decisions

| # | Question | Decision |
|---|---|---|
| 1 | One tile or two? | **Two tiles** (Backend Releases + Mobile Releases). Both share `slug='autopilot'` so RBAC stays unified. |
| 2 | Where does each tile live? | **Disjoint basePaths.** Backend → `/backend/*`, Mobile → `/mobile/*`. |
| 3 | How does the sidebar know which tile? | **Product is a prop to `ProductLayout`**, passed by React Router layout route nesting. `findCurrentProduct` is deleted entirely. |
| 4 | Are routes absolute or relative? | **Relative.** Route paths in the registry are relative to basePath (e.g., `releases/:id`). React Router scopes them under the parent layout route's path. NavItem paths remain absolute for `<Link to>`. |
| 5 | Redirects from old URLs? | **No.** Direct replacement. Old URLs stop existing. Internal links (`<Link to>`, `navigate()`) are updated in the same commit. No redirect helper, no transition period. |
| 6 | Are ConfigMap and VS Editor "releases"? | **Yes** — `release_tracker` rows with different categories. Live at `/backend/configmap`, `/backend/vs-editor`. |
| 7 | Where does Deployment Config live? | **`/backend/deployment-config`.** Only k8s columns; zero mobile rows. |
| 8 | Where does App Catalog live? | **`/mobile/apps`.** Only mobile columns; zero backend rows. |
| 9 | One detail component or two? | **One component, two routes.** `ReleaseSummary` mounts at both `/backend/releases/:id` and `/mobile/releases/:id`. The URL prefix tells React Router which layout to render — no runtime detection needed. |
| 10 | Where do live releases live? | **`/mobile/releases/live`.** |
| 11 | Where do release groups live? | **`/mobile/groups/*`.** |
| 12 | Where does Server Config live? | **`/backend/server-config`** (filtered to exclude mobile keys) and **`/mobile/server-config`** (filtered to mobile keys only). Client-side name-set filter. |
| 13 | Where do external links go? | **`external: true` on `ProductNavItem`** — sidebar renders `<a target="_blank">`. Already implemented for Crashlytics. |

## 3. Architecture overview

### URL tree (after)

```
/login                                    public

/                                         launcher

/admin/                                   ── CoreDb (RBAC, unchanged)
   users, users/:id
   roles, roles/:id

/backend/                                 ── layout route: <ProductLayout product={backend} />
   releases                               release_tracker WHERE category IN backend set
   releases/new
   releases/:id                           shared ReleaseSummary
   releases/:id/edit
   releases/:id/clone
   configmap                              release_tracker WHERE category='BackendConfig'
   configmap/new
   configmap/:id
   vs-editor                              release_tracker WHERE category IS NULL
   vs-editor/new
   vs-editor/:id
   deployment-config                      deployment_config table
   server-config                          server_config WHERE name NOT IN mobile set

/mobile/                                  ── layout route: <ProductLayout product={mobile} />
   releases                               release_tracker WHERE category='MobileBuild'
   releases/new
   releases/:id                           shared ReleaseSummary
   releases/:id/revert
   releases/live
   groups                                 release_tracker GROUP BY release_group_id
   groups/:groupId
   apps                                   app_catalog table
   server-config                          server_config WHERE name IN mobile set
```

### App.tsx (after)

```tsx
{PRODUCT_REGISTRY.map((product) => (
  <Route
    key={product.basePath}
    path={product.basePath}
    element={<ProductLayout product={product} />}
  >
    <Route index element={<Navigate to={product.navItems[0].path} replace />} />
    {product.routes.map((route) => (
      <Route
        key={route.path}
        path={route.path}
        element={
          <ProtectedRoute product={product.slug} permission={route.permission}>
            <route.component />
          </ProtectedRoute>
        }
      />
    ))}
  </Route>
))}
```

React Router scopes child routes under the parent's `path` — `/backend` + `releases/:id` = `/backend/releases/:id`. The parent layout route passes the product as a prop. No heuristic needed.

### Registry shape (after)

```ts
const backendProduct: ProductDefinition = {
  slug: 'autopilot',
  label: 'Backend Releases',
  basePath: '/backend',
  icon: 'Server',
  viewPermission: 'RELEASE_VIEW',
  navItems: [
    { label: 'Releases',          path: '/backend/releases',          icon: 'List' },
    { label: 'Create Release',    path: '/backend/releases/new',      icon: 'Plus' },
    { label: 'Config Maps',       path: '/backend/configmap',         icon: 'FileText' },
    { label: 'Deployment Config', path: '/backend/deployment-config', icon: 'Layers' },
    { label: 'VS Editor',         path: '/backend/vs-editor',         icon: 'Settings' },
    { label: 'Server Config',     path: '/backend/server-config',     icon: 'Settings' },
  ],
  routes: [
    { path: 'releases',           component: ListRelease },
    { path: 'releases/new',       component: CreateRelease,  permission: 'RELEASE_CREATE' },
    { path: 'releases/:id',       component: ReleaseSummary },
    { path: 'releases/:id/edit',  component: CreateRelease,  permission: 'RELEASE_UPDATE' },
    { path: 'releases/:id/clone', component: CreateRelease,  permission: 'RELEASE_CREATE' },
    { path: 'configmap',          component: ListConfigMap },
    { path: 'configmap/new',      component: CreateConfigMap, permission: 'RELEASE_CREATE' },
    { path: 'configmap/:id',      component: ConfigMapSummary },
    { path: 'deployment-config',  component: DeploymentConfig },
    { path: 'vs-editor',          component: ListVSEdit },
    { path: 'vs-editor/new',      component: EditVS,         permission: 'RELEASE_CREATE' },
    { path: 'vs-editor/:id',      component: VSEditSummary },
    { path: 'server-config',      component: Configurations },
  ],
};

const mobileProduct: ProductDefinition = {
  slug: 'autopilot',
  label: 'Mobile Releases',
  basePath: '/mobile',
  icon: 'Smartphone',
  viewPermission: 'RELEASE_VIEW',
  navItems: [
    { label: 'All Releases',   path: '/mobile/releases',      icon: 'List' },
    { label: 'Release Groups',  path: '/mobile/groups',        icon: 'Layers' },
    { label: 'New Release',     path: '/mobile/releases/new',  icon: 'Plus' },
    { label: 'Live Releases',   path: '/mobile/releases/live', icon: 'Activity' },
    { label: 'Apps',            path: '/mobile/apps',          icon: 'Package',
      permission: 'MOBILE_APP_MANAGE' },
    { label: 'Crashlytics',     path: 'https://console.firebase.google.com/project/_/crashlytics',
      icon: 'Flame', external: true },
  ],
  routes: [
    { path: 'releases',            component: ListRelease },
    { path: 'releases/new',        component: CreateMobileRelease, permission: 'RELEASE_CREATE' },
    { path: 'releases/:id',        component: ReleaseSummary },
    { path: 'releases/:id/revert', component: MobileRevert,        permission: 'RELEASE_REVERT' },
    { path: 'releases/live',       component: LiveReleases },
    { path: 'groups',              component: ReleaseGroupsList },
    { path: 'groups/:groupId',     component: ReleaseGroupDetail },
    { path: 'apps',                component: MobileAppsAdmin,     permission: 'MOBILE_APP_MANAGE' },
  ],
};
```

### ProductLayout (after)

```tsx
const ProductLayout: React.FC<{ product: ProductDefinition }> = ({ product }) => {
  const location = useLocation();
  const isActive = (path: string) =>
    location.pathname === path || location.pathname.startsWith(path + '/');

  // product is a prop — React Router already resolved it.
  // No findCurrentProduct. No query-string parsing. No defaultCategoryFilter.
  return (
    <div className="min-h-screen bg-zinc-50 flex font-sans">
      <Sidebar product={product} isActive={isActive} />
      <main><Outlet /></main>
    </div>
  );
};
```

### SidebarBody (after)

```tsx
// Active check collapses to a single startsWith.
// No query-string parsing. No matchPaths fallback.
const active = isActive(item.path);
```

### getBreadcrumbs basePath guard

Each product's `getBreadcrumbs` must check `parts[0]` matches its own basePath prefix before returning crumbs. Without this, `PRODUCT_REGISTRY` iteration order determines which product claims the breadcrumb — `backendProduct` (listed first) would claim `/mobile/releases/:id` because it only checked `parts[1] === 'releases'`.

```tsx
// backend product
getBreadcrumbs: (parts) => {
  if (parts[0] !== 'backend') return [];   // guard — don't claim /mobile/* URLs
  ...
}
// mobile product
getBreadcrumbs: (parts) => {
  if (parts[0] !== 'mobile') return [];
  ...
}
```

### Data-driven navigation in shared components

Shared components (`ReleaseSummary`, `ListRelease`) that serve both `/backend/` and `/mobile/` routes must use the **release's data** (`release.tracker_type === 'MobileBuild'`) — not the **URL prefix** — to decide navigation targets (breadcrumb links, delete redirects, back buttons). The URL prefix only tells you which layout route is active, not which product the release belongs to. This matters when the "All" tab shows cross-product releases under one layout.

## 4. What gets deleted

| Code | Why it existed | Why it dies |
|---|---|---|
| `findCurrentProduct` (46 lines) | Two tiles share `/releases` | Disjoint basePaths, product is a prop |
| `defaultCategoryFilter` on `ProductDefinition` | `?category=mobile` routing signal | URL prefix is the signal |
| `matchPaths` on `ProductNavItem` | `/release-groups` needed to highlight mobile sidebar | All mobile URLs start with `/mobile` |
| `?category=mobile` query-string routing | Disambiguate `/releases` list page | `/mobile/releases` is unambiguous |
| Query-string parsing in `SidebarBody` | Nav items like `/releases?category=mobile` | Nav items are plain paths |
| `useEffect` in `ReleaseSummary` adding `?category=mobile` | Self-correct sidebar for mobile releases at `/releases/:id` | `/mobile/releases/:id` scopes the layout |
| `isMobileRoute` in `ReleaseSummary` | URL-based mobile detection for breadcrumb/nav links | Replaced by data-driven `isMobile` (`release.tracker_type`) |
| Clone/Edit buttons on mobile releases | Backend-only routes shown to all releases | Guarded with `!isMobile` — those routes don't exist in mobile product |

## 5. What stays

- **`external` on `ProductNavItem`** — still needed for Crashlytics sidebar link
- **Shared `ReleaseSummary`** — mounted at both `/backend/releases/:id` and `/mobile/releases/:id`
- **RBAC** — both tiles keep `slug: 'autopilot'`, same permissions
- **Registry-driven routing** — `App.tsx` still maps over `PRODUCT_REGISTRY`
- **`ProductNavItem.permission`** — per-item visibility gating

## 6. Rationale

| Concern | How this shape addresses it |
|---|---|
| URL prefix should be predictive | `/backend/*` is always Backend, `/mobile/*` is always Mobile |
| Sidebar resolution should be trivial | Product is a prop from the layout route — zero runtime computation |
| Routes should compose with React Router | Layout route nesting is idiomatic React Router v6 |
| No redirect debt | Direct replacement means no cleanup phase, no stale redirect table |
| Future tiles scale linearly | Add a new layout route (e.g., `/infra/*`). No collisions. |
| Permission model doesn't change | Same slug, same view permission, same per-route gates |

**What this shape rejects:**

- A single `/releases/*` tree with both backend and mobile sub-flows. Reason: forces heuristic resolution, nests unrelated admin tables under "releases".
- Redirect-based migration (`<Navigate replace>` from old to new URLs). Reason: adds a cleanup phase, doubles the route count during transition, and stale redirects become invisible tech debt.

## 7. Current frontend state (as of 2026-05-25)

Features built since the original proposal that this restructure must account for:

| Feature | Files | Notes |
|---|---|---|
| Mobile revert flow | `pages/mobile/MobileRevert.tsx` (40KB) | Full-page UI at `/releases/:id/revert` → becomes `releases/:id/revert` under `/mobile` |
| Mobile apps admin | `pages/mobile/MobileAppsAdmin.tsx` | At `/mobile/apps` — already under correct prefix |
| Release groups | `pages/mobile/ReleaseGroupsList.tsx`, `ReleaseGroupDetail.tsx` | At `/release-groups/*` → becomes `groups/*` under `/mobile` |
| Live releases | `pages/LiveReleases.tsx` | At `/releases/live` → becomes `releases/live` under `/mobile` |
| Crashlytics deep-link | Sidebar `external` nav item + per-release button in `ReleaseSummary` | External link, no route change needed |
| `firebase_project_id` on app_catalog | Backend + frontend types | Used by Crashlytics URL builder in `ReleaseSummary` |
| `mobileApi` namespace | `api.ts` (8 methods) | No URL dependency |
| Mobile hooks | `hooks.ts` (6 mobile-specific hooks) | No URL dependency |
| `types.ts` | Mobile-only type definitions | No URL dependency |
| External link rendering in sidebar | `ProductLayout.tsx`, `ProductNavItem.external` | Already implemented, keeps working |

## 8. Internal links to update

Hard-coded URLs in components that must change:

```bash
# Backend links — grep targets:
navigate('/releases')           → navigate('/backend/releases')
to="/releases"                  → to="/backend/releases"
to={`/releases/${id}`}          → to={`/backend/releases/${id}`}
to="/configmap"                 → to="/backend/configmap"
to="/vs-editor"                 → to="/backend/vs-editor"

# Mobile links — grep targets:
navigate(`/releases/${id}?category=mobile`)  → navigate(`/mobile/releases/${id}`)
to="/releases?category=mobile"               → to="/mobile/releases"
to="/release-groups"                         → to="/mobile/groups"
navigate('/releases/mobile/new')             → navigate('/mobile/releases/new')
navigate(`/releases/${id}/revert?category=mobile`) → navigate(`/mobile/releases/${id}/revert`)
```

The `?category=mobile` suffix on all mobile links disappears entirely.

## 9. Future scope

1. **Universal release detail URL.** A `/releases/:id` catch-all that reads the row's `category` and redirects to `/backend/releases/:id` or `/mobile/releases/:id`. Useful for Slack/PR links.
2. **Server Config category column.** If the BE adds a `tier` column to `server_config`, the client-side name-set filter becomes server-side.
3. **Cross-tile dashboard.** `/dashboard` aggregating release activity across both tiles.

## 10. References

- Source plan: `docs/superpowers/plans/2026-05-15-frontend-restructure.md`
- Post-MVP spec: `docs/superpowers/specs/2026-05-18-mobile-releases-post-mvp-design.md`
- BE autopilot schema: `backend/src/Products/Autopilot/Types/Storage/Schema.hs`
- FE registry: `frontend/src/products/registry.ts`
- FE layout: `frontend/src/core/layout/ProductLayout.tsx`
- FE app entry: `frontend/src/app/App.tsx`
