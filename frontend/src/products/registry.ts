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

import type { ComponentType, ReactNode } from 'react';

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
  // Optional: location-aware sidebar. `parts` are the URL segments after
  // basePath (e.g. ['ny-consumer','releases']). Falls back to navItems.
  getNavItems?: (parts: string[]) => ProductNavItem[];
  // Optional: wraps the content column (TopBar + main) — used for scoped
  // theming. Products without it render exactly as before.
  ThemeWrapper?: ComponentType<{ children: ReactNode }>;
  // Optional: render sidebar active item as a rounded accent pill instead of
  // the default left-border style.
  navPill?: boolean;
  // Optional: rendered in the TopBar's right cluster (before the user menu),
  // once per product — e.g. the Airborne theme toggle. Must be usable inside
  // the product's ThemeWrapper (TopBar is wrapped by it).
  HeaderActions?: ComponentType;
  // Optional: image URL replacing the text label in the sidebar header.
  // The sidebar is always dark — supply a dark-surface variant.
  logo?: string;
  // Optional: rendered at the top of the sidebar, above the nav items
  // (e.g. the Airborne app switcher). Lives OUTSIDE the ThemeWrapper —
  // style for the always-dark sidebar, don't rely on theme context.
  SidebarHeader?: ComponentType;
  // Optional: full-width strip rendered between the TopBar and the scrolling
  // content, inside the ThemeWrapper (e.g. the Airborne upstream-health
  // banner). Renders null when there's nothing to show.
  Banner?: ComponentType;
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

// ── Product: Airborne OTA ─────────────────────────────────────────
import OtaAppsHome from './airborne-ota/pages/OtaAppsHome';
import OtaAppOverview from './airborne-ota/pages/OtaAppOverview';
import OtaReleasesList from './airborne-ota/pages/ReleasesList';
import OtaReleaseDetail from './airborne-ota/pages/ReleaseDetail';
import OtaReleaseWizardCreate, {
  OtaReleaseWizardClone,
  OtaReleaseWizardEdit,
} from './airborne-ota/pages/ReleaseWizard';
import OtaPackagesList from './airborne-ota/pages/PackagesList';
import OtaPackageCreate from './airborne-ota/pages/PackageCreate';
import OtaFilesList from './airborne-ota/pages/FilesList';
import OtaDimensionsPage from './airborne-ota/pages/DimensionsPage';
import OtaCohortsPage from './airborne-ota/pages/CohortsPage';
import OtaRemoteConfigPage from './airborne-ota/pages/RemoteConfigPage';
import OtaViewsPage from './airborne-ota/pages/ViewsPage';
import { OtaThemeWrapper, OtaThemeToggle } from './airborne-ota/theme';
import { OtaSidebarSwitcher } from './airborne-ota/components/OtaSidebarSwitcher';
import { OtaStatusBanner } from './airborne-ota/components/OtaStatusBanner';
import airborneLogoDark from './airborne-ota/assets/airborne-logo-dark.svg';

// ── Product: Mobile Releases ──────────────────────────────────────
import CreateMobileRelease from './releases/pages/mobile/CreateMobileRelease';
import GroupsHome, { GroupsHomeRedirect, MobileReleaseHistory } from './releases/pages/mobile/GroupsHome';
import ReleaseGroupDetail from './releases/pages/mobile/ReleaseGroupDetail';
import MobileAppsAdmin from './releases/pages/mobile/MobileAppsAdmin';
import MobileRevert from './releases/pages/mobile/MobileRevert';
import MobileReleaseSummary from './releases/pages/mobile/summary/MobileReleaseSummary';
import StoreMonitor from './releases/pages/mobile/StoreMonitor';
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
    { label: 'Releases',       path: '/mobile/releases',      icon: 'List' },
    { label: 'New Release',    path: '/mobile/releases/new',   icon: 'Plus' },
    { label: 'App Release Monitor',  path: '/mobile/releases/monitor', icon: 'Gauge' },
    { label: 'Apps',           path: '/mobile/apps',           icon: 'Package',
      permission: 'MOBILE_APP_MANAGE' },
    { label: 'Server Config', path: '/mobile/server-config',   icon: 'Settings' },
    { label: 'Crashlytics',   path: 'https://console.firebase.google.com/project/_/crashlytics',
      icon: 'Flame', external: true },
  ],
  routes: [
    { path: 'releases',            component: GroupsHome },
    { path: 'releases/history',    component: MobileReleaseHistory },
    { path: 'releases/new',        component: CreateMobileRelease, permission: 'RELEASE_CREATE' },
    { path: 'releases/:id',        component: MobileReleaseSummary },
    { path: 'releases/:id/revert', component: MobileRevert,        permission: 'RELEASE_REVERT' },
    { path: 'releases/live',       component: LiveReleases },
    { path: 'releases/monitor',    component: StoreMonitor },
    // Old groups list retired — the home page IS groups now; bookmarks survive.
    { path: 'groups',              component: GroupsHomeRedirect },
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
      } else if (parts[2] === 'monitor') {
        crumbs.push({ label: 'App Release Monitor' });
      } else if (parts[2] === 'history') {
        crumbs.push({ label: 'History' });
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
      crumbs.push({ label: 'Releases', to: '/mobile/releases' });
      if (parts.length >= 3) {
        crumbs.push({ label: 'Release Group' });
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

const AIRBORNE_ROOT_NAV: ProductNavItem[] = [
  { label: 'Apps',        path: '/airborne',          icon: 'LayoutGrid' },
];

const airborneOtaProduct: ProductDefinition = {
  slug: 'airborne-ota',
  label: 'Airborne OTA',
  description: 'OTA bundle releases (Airborne)',
  icon: 'CloudDownload',
  basePath: '/airborne',
  viewPermission: 'OTA_VIEW',
  navItems: AIRBORNE_ROOT_NAV,
  navPill: true,
  ThemeWrapper: OtaThemeWrapper,
  HeaderActions: OtaThemeToggle,
  logo: airborneLogoDark,
  SidebarHeader: OtaSidebarSwitcher,
  Banner: OtaStatusBanner,
  // App-scoped sidebar once inside an app (airborne.juspay.in layout).
  // Paths reuse the raw URL segment so active-prefix matching stays exact.
  getNavItems: (parts) => {
    const app = parts[0];
    if (!app || app === 'apps') return AIRBORNE_ROOT_NAV;
    const base = `/airborne/${app}`;
    return [
      { label: 'Overview',   path: base,               icon: 'Activity' },
      { label: 'Files',      path: `${base}/files`,    icon: 'FileText' },
      { label: 'Packages',   path: `${base}/packages`, icon: 'Package' },
      { label: 'Releases',   path: `${base}/releases`, icon: 'Rocket' },
      { label: 'Dimensions', path: `${base}/dimensions`, icon: 'SlidersHorizontal' },
      { label: 'Cohorts',    path: `${base}/cohorts`,  icon: 'Users' },
      { label: 'Remote Config', path: `${base}/remote-config`, icon: 'Settings2' },
      { label: 'Views',      path: `${base}/views`,    icon: 'Bookmark' },
    ];
  },
  routes: [
    { path: '',                         component: OtaAppsHome },
    { path: ':app',                     component: OtaAppOverview },
    { path: ':app/releases',            component: OtaReleasesList },
    // Static 'new' outranks ':releaseId' in React Router route ranking.
    { path: ':app/releases/new',        component: OtaReleaseWizardCreate, permission: 'OTA_RELEASE_CREATE' },
    { path: ':app/releases/:releaseId', component: OtaReleaseDetail },
    { path: ':app/releases/:releaseId/edit',  component: OtaReleaseWizardEdit,  permission: 'OTA_RELEASE_CREATE' },
    { path: ':app/releases/:releaseId/clone', component: OtaReleaseWizardClone, permission: 'OTA_RELEASE_CREATE' },
    { path: ':app/packages',            component: OtaPackagesList },
    { path: ':app/packages/new',        component: OtaPackageCreate, permission: 'OTA_PACKAGE_MANAGE' },
    { path: ':app/files',               component: OtaFilesList },
    { path: ':app/dimensions',          component: OtaDimensionsPage },
    { path: ':app/cohorts',             component: OtaCohortsPage },
    { path: ':app/remote-config',       component: OtaRemoteConfigPage },
    { path: ':app/views',               component: OtaViewsPage },
  ],
  getBreadcrumbs: (parts) => {
    if (parts[0] !== 'airborne') return [];
    const crumbs: Crumb[] = [{ label: 'Apps', to: '/airborne' }];
    if (parts.length < 2) return crumbs;
    const app = parts[1];
    crumbs.push({ label: app, to: `/airborne/${app}` });
    if (parts[2] === 'releases') {
      crumbs.push({ label: 'Releases', to: `/airborne/${app}/releases` });
      if (parts[3] === 'new') {
        crumbs.push({ label: 'New Release' });
      } else if (parts.length >= 4) {
        if (parts[4] === 'edit' || parts[4] === 'clone') {
          crumbs.push({ label: parts[3], to: `/airborne/${app}/releases/${parts[3]}` });
          crumbs.push({ label: parts[4] === 'edit' ? 'Edit' : 'Clone' });
        } else {
          crumbs.push({ label: parts[3] });
        }
      }
    } else if (parts[2] === 'packages') {
      if (parts[3] === 'new') {
        crumbs.push({ label: 'Packages', to: `/airborne/${app}/packages` });
        crumbs.push({ label: 'Create Package' });
      } else {
        crumbs.push({ label: 'Packages' });
      }
    } else if (parts[2] === 'files') {
      crumbs.push({ label: 'Files' });
    } else if (parts[2] === 'dimensions') {
      crumbs.push({ label: 'Dimensions' });
    } else if (parts[2] === 'cohorts') {
      crumbs.push({ label: 'Cohorts' });
    } else if (parts[2] === 'remote-config') {
      crumbs.push({ label: 'Remote Config' });
    } else if (parts[2] === 'views') {
      crumbs.push({ label: 'Views' });
    }
    return crumbs;
  },
};

// ── Registry ─────────────────────────────────────────────────────
// Two tiles share slug='autopilot' so backend RBAC stays unified
// while the dashboard surfaces the backend and mobile flows separately.
// Admin Console is handled in App.tsx (not a product).

export const PRODUCT_REGISTRY: ProductDefinition[] = [
  backendProduct,
  mobileProduct,
  airborneOtaProduct,
];
