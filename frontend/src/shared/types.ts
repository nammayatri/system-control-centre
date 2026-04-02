/**
 * Common types shared across all products.
 * Every product should follow these patterns.
 */

/** Product registration config — used by Sidebar and routing */
export interface ProductConfig {
  slug: string;           // matches sc_product.slug in DB
  label: string;          // display name
  basePath: string;       // URL base path (e.g., '/releases')
  icon: string;           // Lucide icon name
  navItems: NavItem[];    // sidebar navigation items
}

export interface NavItem {
  label: string;
  path: string;
  icon: string;
}

/** Common list view props — all product list screens follow this */
export interface ListViewProps {
  product: string;        // product slug for permission checks
}

/** Common status type (PascalCase — canonical, matching Haskell ADT) */
export type BaseStatus = 'Created' | 'InProgress' | 'Completed' | 'Aborted' | 'Paused' | 'Discarded';

/** Date range filter — common across all list views */
export interface DateRange {
  from: string;           // ISO string
  to: string;             // ISO string
}

/** Pagination — common across all list views */
export interface PaginationState {
  page: number;
  pageSize: number;
  total: number;
}

/** Common API response wrapper */
export interface APIResponse {
  status: string;
  message: string;
}
