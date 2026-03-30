# Adding a New Product

Follow these steps to add a new product to System Control Centre.

## 1. Create product folder

```
src/products/my-new-product/
  index.ts          ← route registration + exports
  api.ts            ← API calls for this product
  types.ts          ← TypeScript types for this product
  screens/
    List.tsx         ← list/table view
    Create.tsx       ← creation form
    Detail.tsx       ← detail/summary view
```

## 2. Define the product config

In `index.ts`:

```tsx
import { ProductConfig } from '../_shared/types';

export const config: ProductConfig = {
  slug: 'my-new-product',
  label: 'My New Product',
  basePath: '/my-new-product',
  icon: 'Package',           // Lucide icon name
  navItems: [
    { label: 'List', path: '/my-new-product', icon: 'List' },
    { label: 'Create', path: '/my-new-product/new', icon: 'Plus' },
  ],
};
```

## 3. Register routes in App.tsx

```tsx
import MyList from './products/my-new-product/screens/List';
import MyCreate from './products/my-new-product/screens/Create';
import MyDetail from './products/my-new-product/screens/Detail';

// Inside <Route element={<Layout />}>:
<Route path="/my-new-product" element={<ProtectedRoute product="my-new-product"><MyList /></ProtectedRoute>} />
<Route path="/my-new-product/new" element={<ProtectedRoute product="my-new-product"><MyCreate /></ProtectedRoute>} />
<Route path="/my-new-product/:id" element={<ProtectedRoute product="my-new-product"><MyDetail /></ProtectedRoute>} />
```

## 4. Add to sidebar navigation

In `components/layout/Sidebar.tsx`, add to the `sections` array:

```tsx
{
  label: 'My New Product',
  icon: <Package className="w-4 h-4" />,
  items: [
    { label: 'List', to: '/my-new-product', icon: <List className="w-3.5 h-3.5" /> },
    { label: 'Create', to: '/my-new-product/new', icon: <Plus className="w-3.5 h-3.5" /> },
  ],
},
```

## 5. Backend: Seed permissions

```sql
-- Add product
INSERT INTO sc_product (slug, name) VALUES ('my-new-product', 'My New Product');

-- Add permissions
INSERT INTO sc_permission (product_id, action) VALUES
  ((SELECT id FROM sc_product WHERE slug = 'my-new-product'), 'MY_VIEW'),
  ((SELECT id FROM sc_product WHERE slug = 'my-new-product'), 'MY_CREATE'),
  ((SELECT id FROM sc_product WHERE slug = 'my-new-product'), 'MY_UPDATE');

-- Create roles + assign permissions
-- (follow pattern in scripts/rbac_seed.sql)
```

## 6. Backend: Add route-permission mapping

In `Auth/Middleware.hs`, add to `routePermissions`:

```haskell
, RoutePermission "GET"  ["my-new-product"]        "MY_VIEW"   "my-new-product"
, RoutePermission "POST" ["my-new-product", "create"] "MY_CREATE" "my-new-product"
```

## Common utilities available

- `PermissionGate` — wrap buttons/actions that need specific permissions
- `useAuth()` / `usePermissions()` — auth + permission hooks
- `Badge`, `StatusBadge` — status indicators
- `Button`, `Card`, `Input`, `SelectInput`, `Dialog` — UI components
- `Skeleton`, `TableSkeleton` — loading states
- `toast` from sonner — notifications
- React Query hooks — data fetching with caching
