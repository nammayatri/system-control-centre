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
 *
 * Architecture: Each product is a React Router layout route. App.tsx
 * renders `<Route path={basePath} element={<ProductLayout product={product} />}>`
 * with relative child routes. Product is a prop — no heuristic resolution.
 */

import type { ComponentType } from 'react';

export interface ProductNavItem {
  label: string;
  path: string;            // absolute for <Link to>: '/backend/releases'
  icon: string;            // Lucide icon name
  permission?: string;     // optional: hide nav item unless caller has this permission
  external?: boolean;      // renders <a href target="_blank"> instead of <Link>
}

export interface ProductRoute {
  path: string;            // relative to basePath: 'releases/:id', NOT '/backend/releases/:id'
  component: ComponentType;
  permission?: string;     // required permission (e.g., 'RELEASE_CREATE')
}

export interface Crumb {
  label: string;
  to?: string;
}

export interface ProductDefinition {
  slug: string;            // matches sc_product.slug in backend DB
  label: string;           // display name in sidebar
  description: string;     // one-line description shown on launcher cards
  icon: string;            // Lucide icon name for sidebar section
  basePath: string;        // disjoint URL prefix: '/backend' or '/mobile'
  viewPermission: string;  // permission string required to see this product
  navItems: ProductNavItem[];
  routes: ProductRoute[];
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

// ── Product: Mobile Releases ──────────────────────────────────────
import CreateMobileRelease from './releases/pages/mobile/CreateMobileRelease';
import ReleaseGroupDetail from './releases/pages/mobile/ReleaseGroupDetail';
import ReleaseGroupsList from './releases/pages/mobile/ReleaseGroupsList';
import MobileAppsAdmin from './releases/pages/mobile/MobileAppsAdmin';
import MobileRevert from './releases/pages/mobile/MobileRevert';
import LiveReleases from './releases/pages/LiveReleases';

const backendProduct: ProductDefinition = {
  slug: 'autopilot',
  label: 'Backend Releases',
  description: 'Microservice rollouts, VS edits, config maps',
  icon: 'Server',
  basePath: '/backend',
  viewPermission: 'RELEASE_VIEW',
  navItems: [
    { label: 'Releases',          path: '/backend/releases',          icon: 'List' },
    { label: 'Create Release',    path: '/backend/releases/new',      icon: 'Plus' },
    { label: 'Live Releases',     path: '/backend/releases/live',     icon: 'Activity' },
    { label: 'Config Maps',       path: '/backend/configmap',         icon: 'FileText' },
    { label: 'Deployment Config', path: '/backend/deployment-config', icon: 'Layers' },
    { label: 'VS Editor',         path: '/backend/vs-editor',         icon: 'Settings' },
    { label: 'Server Config',     path: '/backend/server-config',     icon: 'Settings' },
  ],
  routes: [
    { path: 'releases',           component: ListRelease },
    { path: 'releases/new',       component: CreateRelease,  permission: 'RELEASE_CREATE' },
    { path: 'releases/live',      component: LiveReleases },
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
  getBreadcrumbs: (parts) => {
    if (parts[0] !== 'backend') return [];
    const crumbs: Crumb[] = [];
    if (parts[1] === 'releases') {
      crumbs.push({ label: 'Releases', to: '/backend/releases' });
      if (parts[2] === 'new') {
        crumbs.push({ label: 'Create Release' });
      } else if (parts.length >= 3) {
        crumbs.push({ label: parts[2], to: `/backend/releases/${parts[2]}` });
        if (parts[3] === 'clone') {
          crumbs.push({ label: 'Clone' });
        } else if (parts[3] === 'edit') {
          crumbs.push({ label: 'Edit' });
        } else {
          crumbs.push({ label: 'Release Summary' });
        }
      }
      return crumbs;
    }
    if (parts[1] === 'configmap') {
      crumbs.push({ label: 'Config Maps', to: '/backend/configmap' });
      if (parts[2] === 'new') {
        crumbs.push({ label: 'Create ConfigMap' });
      } else if (parts.length >= 3) {
        crumbs.push({ label: 'ConfigMap Details' });
      }
      return crumbs;
    }
    if (parts[1] === 'vs-editor') {
      crumbs.push({ label: 'VS Editor', to: '/backend/vs-editor' });
      if (parts[2] === 'new') {
        crumbs.push({ label: 'New VS Edit' });
      } else if (parts.length >= 3) {
        crumbs.push({ label: 'VS Edit Details' });
      }
      return crumbs;
    }
    if (parts[1] === 'server-config') {
      crumbs.push({ label: 'Server Config' });
      return crumbs;
    }
    if (parts[1] === 'deployment-config') {
      crumbs.push({ label: 'Deployment Config' });
      return crumbs;
    }
    return [];
  },
};

const mobileProduct: ProductDefinition = {
  slug: 'autopilot',
  label: 'Mobile Releases',
  description: 'React Native app releases via GitHub Actions',
  icon: 'Smartphone',
  basePath: '/mobile',
  viewPermission: 'RELEASE_VIEW',
  navItems: [
    { label: 'All Releases',   path: '/mobile/releases',      icon: 'List' },
    { label: 'Release Groups', path: '/mobile/groups',         icon: 'Layers' },
    { label: 'New Release',    path: '/mobile/releases/new',   icon: 'Plus' },
    { label: 'Live Releases',  path: '/mobile/releases/live',  icon: 'Activity' },
    { label: 'Apps',           path: '/mobile/apps',           icon: 'Package',
      permission: 'MOBILE_APP_MANAGE' },
    { label: 'Server Config', path: '/mobile/server-config',   icon: 'Settings' },
    { label: 'Crashlytics',   path: 'https://console.firebase.google.com/project/_/crashlytics',
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
    { path: 'server-config',       component: Configurations },
  ],
  getBreadcrumbs: (parts) => {
    if (parts[0] !== 'mobile') return [];
    const crumbs: Crumb[] = [];
    if (parts[1] === 'releases') {
      crumbs.push({ label: 'Releases', to: '/mobile/releases' });
      if (parts[2] === 'new') {
        crumbs.push({ label: 'New Release' });
      } else if (parts[2] === 'live') {
        crumbs.push({ label: 'Live Releases' });
      } else if (parts.length >= 3) {
        crumbs.push({ label: parts[2], to: `/mobile/releases/${parts[2]}` });
        if (parts[3] === 'revert') {
          crumbs.push({ label: 'Revert' });
        } else {
          crumbs.push({ label: 'Release Summary' });
        }
      }
      return crumbs;
    }
    if (parts[1] === 'groups') {
      crumbs.push({ label: 'Release Groups', to: '/mobile/groups' });
      if (parts.length >= 3) {
        crumbs.push({ label: 'Group Details' });
      }
      return crumbs;
    }
    if (parts[1] === 'apps') {
      crumbs.push({ label: 'Apps' });
      return crumbs;
    }
    if (parts[1] === 'server-config') {
      crumbs.push({ label: 'Server Config' });
      return crumbs;
    }
    return [];
  },
};

// ── Registry ─────────────────────────────────────────────────────
// Two tiles share slug='autopilot' so backend RBAC stays unified
// while the dashboard surfaces the backend and mobile flows separately.
// Admin Console is handled in App.tsx (not a product).

export const PRODUCT_REGISTRY: ProductDefinition[] = [
  backendProduct,
  mobileProduct,
];
