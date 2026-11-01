import type { Crumb, ProductDefinition } from '../registry';
import { Mr2ThemeToggle, Mr2ThemeWrapper } from './theme';
import Home from './pages/Home';
import Releases from './pages/Releases';
import Apps from './pages/Apps';
import Log from './pages/Log';
import NewRelease from './pages/NewRelease';

// Mobile Releases v2 — a separate section over the same backend + RBAC as v1
// (slug 'mobile'). v1 pages are untouched; v2 lives entirely under /mobile-v2.
export const mobileV2Product: ProductDefinition = {
  slug: 'mobile',
  label: 'Mobile Releases v2',
  description: 'Release many apps at once: pinned apps, stage matrix, review before every store action',
  icon: 'Smartphone',
  basePath: '/mobile-v2',
  viewPermission: 'MB_RELEASE_VIEW',
  navItems: [
    { label: 'Home', path: '/mobile-v2/home', icon: 'Gauge' },
    { label: 'Releases', path: '/mobile-v2/releases', icon: 'List' },
    { label: 'Apps', path: '/mobile-v2/apps', icon: 'LayoutGrid' },
    { label: 'Log', path: '/mobile-v2/log', icon: 'Activity' },
  ],
  routes: [
    { path: 'home', component: Home },
    { path: 'releases', component: Releases },
    { path: 'releases/:groupId', component: Releases },
    { path: 'new', component: NewRelease, permission: 'MB_RELEASE_CREATE' },
    { path: 'apps', component: Apps },
    { path: 'log', component: Log },
  ],
  getBreadcrumbs: (parts) => {
    if (parts[0] !== 'mobile-v2') return [];
    const crumbs: Crumb[] = [{ label: 'Mobile Releases v2', to: '/mobile-v2/home' }];
    const page = { releases: 'Releases', new: 'New release', apps: 'Apps', log: 'Log' }[parts[1] as string];
    if (page) crumbs.push({ label: page });
    return crumbs;
  },
  ThemeWrapper: Mr2ThemeWrapper,
  HeaderActions: Mr2ThemeToggle,
};
