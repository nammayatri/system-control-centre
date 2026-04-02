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
import DeploymentConfig from './config/pages/DeploymentConfig';
import ListVSEdit from './vs-editor/pages/ListVSEdit';
import EditVS from './vs-editor/pages/EditVS';
import VSEditSummary from './vs-editor/pages/VSEditSummary';

const releasesProduct: ProductDefinition = {
  slug: 'autopilot',
  label: 'Backend Releases',
  icon: 'Rocket',
  basePath: '/releases',
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
};

// ── Registry ─────────────────────────────────────────────────────
// Only two products for now: Backend Releases
// Admin Console is handled separately in App.tsx (not a product)

export const PRODUCT_REGISTRY: ProductDefinition[] = [
  releasesProduct,
  // ← Add new products here when ready
];
