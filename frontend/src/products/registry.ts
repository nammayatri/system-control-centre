/**
 * Product Registry — Single source of truth for all products.
 *
 * To add a new product:
 *   1. Create a folder: products/my-product/
 *   2. Register it here by adding to PRODUCT_REGISTRY
 *   3. That's it — routes, sidebar, permissions all auto-wire.
 */

import type { ComponentType } from 'react';

export interface ProductNavItem {
  label: string;
  path: string;
  icon: string;          // Lucide icon name
}

export interface ProductRoute {
  path: string;          // React Router path (relative to basePath)
  component: ComponentType;
  permission?: string;   // required permission (e.g., 'RELEASE_CREATE')
}

export interface ProductDefinition {
  slug: string;          // matches sc_product.slug in backend DB
  label: string;         // display name in sidebar
  icon: string;          // Lucide icon name for sidebar section
  basePath: string;      // URL base path (e.g., '/releases')
  navItems: ProductNavItem[];
  routes: ProductRoute[];
}

// ── Product: Releases ────────────────────────────────────────────

import ListRelease from './releases/pages/ListRelease';
import CreateRelease from './releases/pages/CreateRelease';
import ReleaseSummary from './releases/pages/ReleaseSummary';
import ListConfigMap from './configmap/pages/ListConfigMap';
import CreateConfigMap from './configmap/pages/CreateConfigMap';
import ConfigMapSummary from './configmap/pages/ConfigMapSummary';
import Configurations from './config/pages/Configurations';

const releasesProduct: ProductDefinition = {
  slug: 'autopilot',
  label: 'Backend Releases',
  icon: 'Rocket',
  basePath: '/releases',
  navItems: [
    { label: 'Releases', path: '/releases', icon: 'List' },
    { label: 'Create Release', path: '/releases/new', icon: 'Plus' },
    { label: 'Config Maps', path: '/configmap', icon: 'FileText' },
    { label: 'Server Config', path: '/configurations', icon: 'Settings' },
  ],
  routes: [
    // Releases
    { path: '/releases', component: ListRelease },
    { path: '/releases/new', component: CreateRelease, permission: 'RELEASE_CREATE' },
    { path: '/releases/:clusterId/:id', component: ReleaseSummary },
    { path: '/releases/:clusterId/:id/clone', component: CreateRelease, permission: 'RELEASE_CREATE' },
    // ConfigMap (under same product)
    { path: '/configmap', component: ListConfigMap },
    { path: '/configmap/new', component: CreateConfigMap, permission: 'RELEASE_CREATE' },
    { path: '/configmap/:clusterId', component: ConfigMapSummary },
    // Server Config
    { path: '/configurations', component: Configurations },
  ],
};

// ── Registry ─────────────────────────────────────────────────────
// Only two products for now: Backend Releases
// Admin Console is handled separately in App.tsx (not a product)

export const PRODUCT_REGISTRY: ProductDefinition[] = [
  releasesProduct,
  // ← Add new products here when ready
];

/**
 * TEMPLATE for adding a new product:
 *
 * 1. Create products/my-product/ folder with:
 *    - List.tsx (list view)
 *    - Create.tsx (create form)
 *    - Detail.tsx (detail/summary view)
 *
 * 2. Import and register here:
 *
 *    import MyList from '../my-product/List';
 *    import MyCreate from '../my-product/Create';
 *    import MyDetail from '../my-product/Detail';
 *
 *    const myProduct: ProductDefinition = {
 *      slug: 'my-product',        // must match DB sc_product.slug
 *      label: 'My Product',
 *      icon: 'Package',
 *      basePath: '/my-product',
 *      navItems: [
 *        { label: 'List', path: '/my-product', icon: 'List' },
 *        { label: 'Create', path: '/my-product/new', icon: 'Plus' },
 *      ],
 *      routes: [
 *        { path: '/my-product', component: MyList },
 *        { path: '/my-product/new', component: MyCreate, permission: 'MY_CREATE' },
 *        { path: '/my-product/:id', component: MyDetail },
 *      ],
 *    };
 *
 * 3. Add to PRODUCT_REGISTRY array above.
 *
 * That's it. Routes + sidebar + permissions auto-wire.
 */
