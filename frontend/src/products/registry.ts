/**
 * Product Registry — Single source of truth for all products.
 *
 * To add a new product:
 *   1. Create a folder: products/my-product/
 *   2. Register it here by adding to PRODUCT_REGISTRY
 *   3. That's it — routes, sidebar, permissions all auto-wire.
 *
 * Two entries may share the same `slug` to surface a single backend
 * product as multiple dashboard tiles (e.g. Backend Releases vs Mobile
 * Releases — both backed by the `autopilot` slug for unified RBAC).
 */

import type { ComponentType } from 'react';

export interface ProductNavItem {
  label: string;
  path: string;
  icon: string;          // Lucide icon name
  permission?: string;   // optional: hide nav item unless caller has this permission
  // Optional extra route prefixes that should also keep this nav item
  // highlighted as "active". Useful for routes that conceptually belong to
  // a nav item but aren't reachable directly from it (e.g.,
  // `/release-groups/:groupId` is part of the Mobile Releases flow but
  // sits at a different URL root than `/releases?category=mobile`).
  matchPaths?: string[];
}

export interface ProductRoute {
  path: string;          // React Router path (relative to basePath)
  component: ComponentType;
  permission?: string;   // required permission (e.g., 'RELEASE_CREATE')
}

export interface Crumb {
  label: string;
  to?: string;
}

export interface ProductDefinition {
  slug: string;          // matches sc_product.slug in backend DB
  label: string;         // display name in sidebar
  description: string;   // one-line description shown on launcher cards
  icon: string;          // Lucide icon name for sidebar section
  basePath: string;      // URL base path (e.g., '/releases')
  viewPermission: string; // permission string required to see this product (e.g., 'RELEASE_VIEW')
  navItems: ProductNavItem[];
  routes: ProductRoute[];
  // Optional: for products that share a slug, hint which release category
  // this tile is scoped to ('backend' | 'mobile' | 'all').
  defaultCategoryFilter?: 'backend' | 'mobile' | 'all';
  // Optional: build breadcrumbs for a path under this product.
  // Return an empty array if this product does not own the given path.
  getBreadcrumbs?: (parts: string[]) => Crumb[];
}

// ── Product: Backend Releases ─────────────────────────────────────

import ListRelease from './releases/pages/ListRelease';
import CreateRelease from './releases/pages/CreateRelease';
import ReleaseSummary from './releases/pages/ReleaseSummary';
import ListConfigMap from './configmap/pages/ListConfigMap';
import CreateConfigMap from './configmap/pages/CreateConfigMap';
import ConfigMapSummary from './configmap/pages/ConfigMapSummary';
import Configurations from './config/pages/Configurations';
import DeploymentConfig from './config/pages/DeploymentConfig';
import ListVSEdit from './vs-editor/pages/ListVSEdit';
import EditVS from './vs-editor/pages/EditVS';
import VSEditSummary from './vs-editor/pages/VSEditSummary';

// ── Product: Mobile Releases (stubs land in T23–T26) ──────────────
import CreateMobileRelease from './releases/pages/mobile/CreateMobileRelease';
import ReleaseGroupDetail from './releases/pages/mobile/ReleaseGroupDetail';
import ReleaseGroupsList from './releases/pages/mobile/ReleaseGroupsList';
import MobileAppsAdmin from './releases/pages/mobile/MobileAppsAdmin';
import LiveReleases from './releases/pages/LiveReleases';

const backendReleasesProduct: ProductDefinition = {
  slug: 'autopilot',
  label: 'Backend Releases',
  description: 'Microservice rollouts, VS edits, config maps',
  icon: 'Server',
  basePath: '/releases',
  defaultCategoryFilter: 'backend',
  viewPermission: 'RELEASE_VIEW',
  navItems: [
    { label: 'Releases', path: '/releases', icon: 'List' },
    { label: 'Create Release', path: '/releases/new', icon: 'Plus' },
    { label: 'Config Maps', path: '/configmap', icon: 'FileText' },
    { label: 'Deployment Config', path: '/deployment-config', icon: 'Layers' },
    { label: 'VS Editor', path: '/vs-editor', icon: 'Settings' },
    { label: 'Server Config', path: '/configurations', icon: 'Settings' },
  ],
  routes: [
    // Releases
    { path: '/releases', component: ListRelease },
    { path: '/releases/new', component: CreateRelease, permission: 'RELEASE_CREATE' },
    { path: '/releases/:id', component: ReleaseSummary },
    { path: '/releases/:id/edit', component: CreateRelease, permission: 'RELEASE_UPDATE' },
    { path: '/releases/:id/clone', component: CreateRelease, permission: 'RELEASE_CREATE' },
    // ConfigMap (under same product)
    { path: '/configmap', component: ListConfigMap },
    { path: '/configmap/new', component: CreateConfigMap, permission: 'RELEASE_CREATE' },
    { path: '/configmap/:id', component: ConfigMapSummary },
    // Deployment Config (groups + services)
    { path: '/deployment-config', component: DeploymentConfig },
    // VS Editor
    { path: '/vs-editor', component: ListVSEdit },
    { path: '/vs-editor/new', component: EditVS, permission: 'RELEASE_CREATE' },
    { path: '/vs-editor/:id', component: VSEditSummary },
    // Server Config
    { path: '/configurations', component: Configurations },
  ],
  getBreadcrumbs: (parts) => {
    const crumbs: Crumb[] = [];
    if (parts[0] === 'releases') {
      crumbs.push({ label: 'Releases', to: '/releases' });
      if (parts[1] === 'new') {
        crumbs.push({ label: 'Create Release' });
      } else if (parts.length >= 3) {
        crumbs.push({ label: parts[1], to: `/releases/${parts[1]}/${parts[2]}` });
        if (parts[3] === 'clone') {
          crumbs.push({ label: 'Clone' });
        } else {
          crumbs.push({ label: 'Release Summary' });
        }
      }
      return crumbs;
    }
    if (parts[0] === 'configmap') {
      crumbs.push({ label: 'Config Map', to: '/configmap' });
      if (parts[1] === 'new') {
        crumbs.push({ label: 'Create ConfigMap' });
      } else if (parts.length >= 2) {
        crumbs.push({ label: 'ConfigMap Details' });
      }
      return crumbs;
    }
    if (parts[0] === 'configurations') {
      crumbs.push({ label: 'Configurations' });
      return crumbs;
    }
    return [];
  },
};

const mobileReleasesProduct: ProductDefinition = {
  slug: 'autopilot',
  label: 'Mobile Releases',
  description: 'React Native app releases via GitHub Actions',
  icon: 'Smartphone',
  basePath: '/releases',
  defaultCategoryFilter: 'mobile',
  viewPermission: 'RELEASE_VIEW',
  navItems: [
    { label: 'All Mobile Releases', path: '/releases?category=mobile', icon: 'List' },
    {
      label: 'Release Groups',
      // List page; clicking a row deep-links to `/release-groups/<UUID>`.
      // matchPaths keeps this nav item highlighted on the detail page too,
      // even though the URL has a different prefix.
      path: '/release-groups',
      icon: 'Layers',
      matchPaths: ['/release-groups'],
    },
    { label: 'New Mobile Release', path: '/releases/mobile/new', icon: 'Plus' },
    { label: 'Live Releases', path: '/releases/live', icon: 'Activity' },
    { label: 'Mobile Apps', path: '/mobile/apps', icon: 'Package', permission: 'MOBILE_APP_MANAGE' },
  ],
  routes: [
    { path: '/releases/mobile/new', component: CreateMobileRelease, permission: 'RELEASE_CREATE' },
    { path: '/release-groups', component: ReleaseGroupsList },
    { path: '/release-groups/:groupId', component: ReleaseGroupDetail },
    { path: '/mobile/apps', component: MobileAppsAdmin, permission: 'MOBILE_APP_MANAGE' },
    { path: '/releases/live', component: LiveReleases },
  ],
};

// ── Registry ─────────────────────────────────────────────────────
// Two tiles share slug='autopilot' so backend RBAC stays unified
// while the dashboard surfaces the backend and mobile flows separately.
// Admin Console is handled in App.tsx (not a product).

export const PRODUCT_REGISTRY: ProductDefinition[] = [
  backendReleasesProduct,
  mobileReleasesProduct,
];
