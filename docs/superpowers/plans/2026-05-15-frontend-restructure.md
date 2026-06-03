# Frontend Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the frontend URL tree into two disjoint tile roots (`/backend/*` and `/mobile/*`) using React Router v6 layout route nesting. Product is a prop to `ProductLayout` — the 46-line `findCurrentProduct` heuristic is deleted. Direct route replacement — no redirects, no transition period.

**Architecture:** Two `PRODUCT_REGISTRY` entries with disjoint `basePath`s. Each entry is a React Router layout route: `<Route path={basePath} element={<ProductLayout product={product} />}>`. Child routes are relative (e.g., `releases/:id`). Single `ReleaseSummary` component serves both `/backend/releases/:id` and `/mobile/releases/:id`. No DB schema changes. No new BE endpoints. No RBAC / role / permission-override changes.

**Tech Stack:** React + TypeScript + Vite + Tailwind, React Router v6, TanStack Query. Frontend-only — no backend work in this plan.

**Source spec:** `docs/superpowers/specs/2026-05-15-frontend-restructure-design.md`

**Branch:** TBD (suggested `feat/frontend-restructure` off `master` after mobile-release features land).

---

## Status

| Phase | Scope | Status |
|---|---|---|
| Phase 1 | Registry + App.tsx + ProductLayout restructure | ✅ done |
| Phase 2 | Internal link migration + dead code removal | ✅ done |
| Phase 3 | Server Config split (backend / mobile pages) | ✅ done |
| Phase 4 | Post-implementation fixes (breadcrumbs, data-driven nav) | ✅ done |

---

## Working agreement

- Direct route replacement. Old URLs stop existing. No `<Navigate>` redirects, no redirect table, no transition period.
- No phase touches the BE database schema. No phase adds new BE endpoints. No phase changes RBAC, roles, or permission overrides.
- Each phase is independently shippable — no half-migrated trees. After every phase, the app is usable end-to-end.
- Run `sc-dev` and manually click through each tile after every phase. Type-check is not enough — sidebar resolution and breadcrumbs only show breakage at runtime.
- Frequent commits at task boundaries. One task = one commit.
- Don't add new dependencies.

---

## Phase 1 — Registry + App.tsx + ProductLayout restructure

The structural change. Two layout routes, product as prop, relative child routes, disjoint basePaths.

### Task 1.1: Rewrite `ProductDefinition` type and registry entries

**Files:**
- Modify: `frontend/src/products/registry.ts`

- [ ] **Step 1: Update `ProductDefinition` interface**

Remove `defaultCategoryFilter` and `matchPaths` from `ProductNavItem`. Add `external?: boolean` (already present). Routes become relative paths (no leading slash, no basePath prefix).

```ts
interface ProductDefinition {
  slug: string;
  label: string;
  basePath: string;       // '/backend' or '/mobile'
  icon: string;
  viewPermission: string;
  navItems: ProductNavItem[];
  routes: ProductRoute[];
}

interface ProductRoute {
  path: string;           // relative: 'releases/:id', not '/backend/releases/:id'
  component: React.ComponentType;
  permission?: string;
}

interface ProductNavItem {
  label: string;
  path: string;           // absolute for <Link to>: '/backend/releases'
  icon: string;
  permission?: string;
  external?: boolean;
}
```

- [ ] **Step 2: Rewrite backend product entry**

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
```

- [ ] **Step 3: Rewrite mobile product entry**

```ts
const mobileProduct: ProductDefinition = {
  slug: 'autopilot',
  label: 'Mobile Releases',
  basePath: '/mobile',
  icon: 'Smartphone',
  viewPermission: 'RELEASE_VIEW',
  navItems: [
    { label: 'All Releases',   path: '/mobile/releases',      icon: 'List' },
    { label: 'Release Groups', path: '/mobile/groups',         icon: 'Layers' },
    { label: 'New Release',    path: '/mobile/releases/new',   icon: 'Plus' },
    { label: 'Live Releases',  path: '/mobile/releases/live',  icon: 'Activity' },
    { label: 'Apps',           path: '/mobile/apps',           icon: 'Package',
      permission: 'MOBILE_APP_MANAGE' },
    { label: 'Crashlytics',    path: 'https://console.firebase.google.com/project/_/crashlytics',
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

- [ ] **Step 4: Export `PRODUCT_REGISTRY` as `[backendProduct, mobileProduct]`**

### Task 1.2: Rewrite App.tsx routing to use layout route nesting

**Files:**
- Modify: `frontend/src/app/App.tsx`

- [ ] **Step 1: Replace flat route mapping with per-product layout routes**

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

React Router scopes child routes under parent's `path` — `/backend` + `releases/:id` = `/backend/releases/:id`.

- [ ] **Step 2: Remove any `findCurrentProduct` call from App.tsx.**

- [ ] **Step 3: Keep `/admin/*`, `/login`, `/` routes unchanged.**

### Task 1.3: Rewrite ProductLayout to accept product as prop

**Files:**
- Modify: `frontend/src/core/layout/ProductLayout.tsx`

- [ ] **Step 1: Change signature**

```tsx
const ProductLayout: React.FC<{ product: ProductDefinition }> = ({ product }) => {
```

- [ ] **Step 2: Delete `findCurrentProduct` entirely (lines 45–90)**

The product is now a prop. No heuristic, no `PRODUCT_REGISTRY.find()`, no query-string parsing.

- [ ] **Step 3: Simplify `isActive` check**

```tsx
const isActive = (path: string) =>
  location.pathname === path || location.pathname.startsWith(path + '/');
```

- [ ] **Step 4: Delete the query-string parsing block in SidebarBody**

Remove the `searchParams` / `queryMatches` logic (lines 136–145). Active check becomes `isActive(item.path)`.

- [ ] **Step 5: Replace content area with `<Outlet />`**

```tsx
<main className="flex-1 p-6"><Outlet /></main>
```

- [ ] **Step 6: Drop dead imports** (`useSearchParams`, etc.)

### Task 1.4: Delete `defaultCategoryFilter` and `matchPaths` from types

**Files:**
- Modify: `frontend/src/products/registry.ts`

- [ ] **Step 1: Remove `defaultCategoryFilter` from interface and both product entries.**
- [ ] **Step 2: Remove `matchPaths` from interface and any nav items.**
- [ ] **Step 3: Confirm no references remain:**

```bash
grep -r 'defaultCategoryFilter\|matchPaths\|findCurrentProduct' frontend/src
```

### Task 1.5: Validate Phase 1

- [ ] **Step 1: `npx tsc --noEmit` passes.**
- [ ] **Step 2: `sc-dev` runs, login works.**
- [ ] **Step 3: Click Backend tile from launcher → lands on `/backend/releases`.** Sidebar highlights "Releases".
- [ ] **Step 4: Click Mobile tile from launcher → lands on `/mobile/releases`.** Sidebar highlights "All Releases".
- [ ] **Step 5: Navigate to `/backend/releases/:id`** — ReleaseSummary renders with backend layout.
- [ ] **Step 6: Navigate to `/mobile/releases/:id`** — ReleaseSummary renders with mobile layout.
- [ ] **Step 7: Navigate to `/mobile/releases/:id/revert`** — MobileRevert page renders.
- [ ] **Step 8: Click every nav item in both tiles** — correct page, correct sidebar highlight.
- [ ] **Step 9: Crashlytics external link opens in new tab.**
- [ ] **Step 10: Confirm no multi-highlight** in sidebar on any URL.

**Risk:** High — changes every product route in one commit. Mitigation: TypeScript catches broken imports, manual click-through catches runtime behavior.

**Rollback:** Revert the Phase 1 commits.

---

## Phase 2 — Internal link migration + dead code removal

### Task 2.1: Replace hard-coded backend internal links

**Files:**
- Modify: all files under `frontend/src/products/` that reference old URLs

- [ ] **Step 1: Grep for old backend URLs**

```bash
grep -rn '"/(releases|configmap|vs-editor|deployment-config|configurations)' frontend/src --include="*.tsx" --include="*.ts"
```

- [ ] **Step 2: Replace each occurrence**

| Old pattern | New pattern |
|---|---|
| `navigate('/releases')` | `navigate('/backend/releases')` |
| `to="/releases"` | `to="/backend/releases"` |
| `` to={`/releases/${id}`} `` | `` to={`/backend/releases/${id}`} `` |
| `to="/configmap"` | `to="/backend/configmap"` |
| `to="/vs-editor"` | `to="/backend/vs-editor"` |
| `to="/deployment-config"` | `to="/backend/deployment-config"` |
| `to="/configurations"` | `to="/backend/server-config"` |

### Task 2.2: Replace hard-coded mobile internal links

**Files:**
- Modify: all files under `frontend/src/products/` that reference old mobile URLs

- [ ] **Step 1: Grep for old mobile URLs**

```bash
grep -rn 'category=mobile\|/release-groups\|/releases/mobile/new\|/releases/live' frontend/src --include="*.tsx" --include="*.ts"
```

- [ ] **Step 2: Replace each occurrence**

| Old pattern | New pattern |
|---|---|
| `` navigate(`/releases/${id}?category=mobile`) `` | `` navigate(`/mobile/releases/${id}`) `` |
| `to="/releases?category=mobile"` | `to="/mobile/releases"` |
| `to="/release-groups"` | `to="/mobile/groups"` |
| `navigate('/releases/mobile/new')` | `navigate('/mobile/releases/new')` |
| `` navigate(`/releases/${id}/revert?category=mobile`) `` | `` navigate(`/mobile/releases/${id}/revert`) `` |
| `to="/releases/live"` | `to="/mobile/releases/live"` |

### Task 2.3: Delete the `useEffect` hack in ReleaseSummary

**Files:**
- Modify: `frontend/src/products/releases/pages/ReleaseSummary.tsx`

- [ ] **Step 1: Delete lines 844–854** — the `useEffect` that appends `?category=mobile` to the URL. No longer needed because `/mobile/releases/:id` scopes the layout.

### Task 2.4: Centralize release-detail link generation

**Files:**
- Create: `frontend/src/products/releases/lib/release-urls.ts`
- Modify: every list/card that hand-builds a release detail URL

- [ ] **Step 1: Add helper**

```ts
import type { ReleaseRow } from '../types';

export function releaseDetailUrl(row: Pick<ReleaseRow, 'id' | 'category'>): string {
  const MOBILE_CATEGORIES = ['MobileApp', 'MobileBuild'];
  return MOBILE_CATEGORIES.includes(row.category)
    ? `/mobile/releases/${row.id}`
    : `/backend/releases/${row.id}`;
}
```

- [ ] **Step 2: Replace hand-built release detail URLs** across list pages with `releaseDetailUrl(row)`.

### Task 2.5: Validate Phase 2

- [ ] **Step 1: `npx tsc --noEmit` passes.**
- [ ] **Step 2: Zero hits for old URL patterns:**

```bash
grep -rE '"/(configmap|vs-editor|release-groups|configurations|deployment-config)(/|"|$)' frontend/src
grep -r 'category=mobile' frontend/src
grep -r 'findCurrentProduct\|defaultCategoryFilter\|matchPaths' frontend/src
```

- [ ] **Step 3: Click a backend release row → `/backend/releases/:id`.**
- [ ] **Step 4: Click a mobile release row → `/mobile/releases/:id`.**
- [ ] **Step 5: Navigate from release detail → back to list** — correct list page, correct sidebar state.
- [ ] **Step 6: Breadcrumbs show correct hierarchy on all pages.**

**Risk:** Medium — many scattered file edits. Mitigation: TypeScript + grep validation.

**Rollback:** Revert Phase 2 commits.

---

## Phase 3 — Server Config split

### Task 3.1: Define the mobile server-config name set

**Files:**
- Create: `frontend/src/products/server-config-filter.ts`

- [ ] **Step 1: Define the name set**

```ts
export const MOBILE_SERVER_CONFIG_NAMES = new Set([
  'mobile_dispatch_enabled',
  'mobile_run_poll_seconds',
  'github_app_id',
  'github_app_private_key',
  'github_app_installation_id',
  'play_console_service_account_json',
  'app_store_connect_issuer_id',
  'app_store_connect_key_id',
  'app_store_connect_private_key_p8',
]);

export const isMobileServerConfig = (name: string): boolean =>
  MOBILE_SERVER_CONFIG_NAMES.has(name);
```

- [ ] **Step 2: Cross-check against `0011-mobile-releases.sql` and `0001-seed-server-config.sql`.**

### Task 3.2: Parameterize the Configurations page

**Files:**
- Modify: `frontend/src/products/config/pages/Configurations.tsx`

- [ ] **Step 1: Accept a `filter` prop**

```tsx
interface ConfigurationsProps {
  filter: 'backend' | 'mobile';
}
```

- [ ] **Step 2: Apply client-side filter**

```ts
const filtered = rows?.filter(r =>
  props.filter === 'mobile'
    ? isMobileServerConfig(r.name)
    : !isMobileServerConfig(r.name)
);
```

- [ ] **Step 3: Update page title** — "Backend Server Config" vs "Mobile Server Config".

### Task 3.3: Wire routes

**Files:**
- Modify: `frontend/src/products/registry.ts`

- [ ] **Step 1: Backend route** already at `server-config` — pass `filter="backend"` prop.
- [ ] **Step 2: Add mobile route** `server-config` → `Configurations` with `filter="mobile"`.
- [ ] **Step 3: Add mobile nav item** `{ label: 'Server Config', path: '/mobile/server-config', icon: 'Settings' }`.

### Task 3.4: Validate Phase 3

- [ ] **Step 1: `/backend/server-config` lists rows excluding mobile keys.**
- [ ] **Step 2: `/mobile/server-config` lists exactly the mobile keys.**
- [ ] **Step 3: Edit a row on the mobile page — value persists after refresh.**

**Risk:** Low — pure client-side filter.

**Rollback:** Revert Phase 3 commits.

---

## Phase 4 — Post-implementation fixes

Bugs discovered during manual testing after Phases 1–3 shipped.

### Task 4.1: Data-driven navigation in ReleaseSummary

**Problem:** `ReleaseSummary` used `isMobileRoute` (checks URL prefix) to decide breadcrumb, delete-redirect, and back-button targets. When a mobile release is accessed from `/backend/releases/:id` (e.g. via "All" tab), all navigation pointed to `/backend/releases` instead of `/mobile/releases`.

**Files:**
- Modify: `frontend/src/products/releases/pages/ReleaseSummary.tsx`

- [x] **Step 1:** Replace `isMobileRoute` (URL-based) with `isMobile` (`release.tracker_type === 'MobileBuild'`, data-based) for breadcrumb link, delete redirect, and "Back to Releases" button.
- [x] **Step 2:** Guard edit button (`/backend/releases/:id/edit`) and clone button with `!isMobile` — those routes only exist in the backend product.
- [x] **Step 3:** Remove unused `isMobileRoute`, `useLocation`, and `location` declarations.

### Task 4.2: Guard clone button on list page

**Problem:** Clone button in `ListRelease` always navigated to `/backend/releases/:id/clone` even for mobile releases (clone route doesn't exist in mobile product).

**Files:**
- Modify: `frontend/src/products/releases/pages/ListRelease.tsx`

- [x] **Step 1:** Wrap clone button (desktop table and mobile card) with `{!isMobile && ...}` to hide it for mobile releases.

### Task 4.3: Fix `getBreadcrumbs` basePath guard

**Problem:** `getBreadcrumbs` in both products only checked `parts[1]` (the section) but not `parts[0]` (the basePath prefix). Since `backendProduct` is first in `PRODUCT_REGISTRY`, the TopBar breadcrumb for `/mobile/releases/:id` was generated by the backend product's `getBreadcrumbs`, producing `/backend/releases/:id` links.

**Files:**
- Modify: `frontend/src/products/registry.ts`

- [x] **Step 1:** Add `if (parts[0] !== 'backend') return [];` at the top of backend product's `getBreadcrumbs`.
- [x] **Step 2:** Add `if (parts[0] !== 'mobile') return [];` at the top of mobile product's `getBreadcrumbs`.

### Task 4.4: Validate Phase 4

- [x] **Step 1:** `npx tsc --noEmit` passes.
- [x] **Step 2:** On `/mobile/releases/:id`, TopBar breadcrumb UUID links to `/mobile/releases/:id` (not `/backend/`).
- [x] **Step 3:** On `/mobile/releases/:id`, inline breadcrumb "Releases" links to `/mobile/releases`.
- [x] **Step 4:** Clone/Edit buttons hidden on mobile release detail pages.
- [x] **Step 5:** Clone button hidden for mobile releases in list view.
- [x] **Step 6:** Delete and "Back to Releases" navigate to correct product list.

**Risk:** Low — targeted fixes, no structural changes.

**Rollback:** Revert Phase 4 commits.

---

## Migration map at a glance

```
Phase 1 → Registry + App.tsx + ProductLayout    structural change, layout route nesting
Phase 2 → Internal links + dead code            grep-and-replace, kill ?category= everywhere
Phase 3 → Server Config split                   one page → two filtered pages
Phase 4 → Post-impl fixes                       data-driven nav, breadcrumb basePath guard
```

## Ship order

- **Phase 1 first** — it establishes the layout route structure. Phase 2 and 3 depend on it.
- **Phase 2 after Phase 1** — internal links must point to routes that exist.
- **Phase 3 after Phase 1** — `/backend/server-config` and `/mobile/server-config` must exist as routes.
- Phases 2 and 3 are independent of each other and can run in parallel.
- This plan is frontend-only — no BE coordination needed.

## What gets deleted (across all phases)

| Code | Phase |
|---|---|
| `findCurrentProduct` (46 lines) | Phase 1 |
| `defaultCategoryFilter` on `ProductDefinition` | Phase 1 |
| `matchPaths` on `ProductNavItem` | Phase 1 |
| Query-string parsing in `SidebarBody` | Phase 1 |
| `?category=mobile` query-string routing | Phase 2 |
| `useEffect` in `ReleaseSummary` adding `?category=mobile` | Phase 2 |
| All `?category=` URL suffixes in internal links | Phase 2 |
| `isMobileRoute` / `useLocation` in `ReleaseSummary` | Phase 4 |
| Clone button on mobile release rows (list + detail) | Phase 4 |
| Edit button on mobile release detail pages | Phase 4 |
