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

import ListRelease from '../releases/ListRelease';
import CreateRelease from '../releases/CreateRelease';
import ReleaseSummary from '../releases/ReleaseSummary';

const releasesProduct: ProductDefinition = {
  slug: 'backend-releases',
  label: 'Releases',
  icon: 'Rocket',
  basePath: '/releases',
  navItems: [
    { label: 'List', path: '/releases', icon: 'List' },
    { label: 'Create', path: '/releases/new', icon: 'Plus' },
  ],
  routes: [
    { path: '/releases', component: ListRelease },
    { path: '/releases/new', component: CreateRelease, permission: 'RELEASE_CREATE' },
    { path: '/releases/:clusterId/:id', component: ReleaseSummary },
    { path: '/releases/:clusterId/:id/clone', component: CreateRelease, permission: 'RELEASE_CREATE' },
  ],
};

// ── Product: Config Map ──────────────────────────────────────────

import ListConfigMap from '../configmap/ListConfigMap';
import CreateConfigMap from '../configmap/CreateConfigMap';
import ConfigMapSummary from '../configmap/ConfigMapSummary';

const configMapProduct: ProductDefinition = {
  slug: 'config-manager',
  label: 'Config Map',
  icon: 'FileText',
  basePath: '/configmap',
  navItems: [
    { label: 'List', path: '/configmap', icon: 'List' },
    { label: 'Create', path: '/configmap/new', icon: 'Plus' },
  ],
  routes: [
    { path: '/configmap', component: ListConfigMap },
    { path: '/configmap/new', component: CreateConfigMap, permission: 'CONFIG_CREATE' },
    { path: '/configmap/:clusterId', component: ConfigMapSummary },
  ],
};

// ── Product: Server Config ───────────────────────────────────────

import Configurations from '../config/Configurations';

const configProduct: ProductDefinition = {
  slug: 'backend-releases',   // uses backend-releases permissions
  label: 'Configurations',
  icon: 'Settings',
  basePath: '/configurations',
  navItems: [
    { label: 'Server Config', path: '/configurations', icon: 'Layers' },
  ],
  routes: [
    { path: '/configurations', component: Configurations },
  ],
};

// ── Registry ─────────────────────────────────────────────────────
// Add new products here. Order determines sidebar order.

export const PRODUCT_REGISTRY: ProductDefinition[] = [
  releasesProduct,
  configMapProduct,
  configProduct,
  // ← Add new products here
  // myNewProduct,
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
