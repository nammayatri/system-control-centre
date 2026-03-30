import { BrowserRouter as Router, Routes, Route, Navigate } from 'react-router-dom';
import { ProtectedRoute } from '../core/auth/ProtectedRoute';
import LoginPage from '../core/auth/LoginPage';
import LauncherPage from '../core/layout/LauncherPage';
import ProductLayout from '../core/layout/ProductLayout';
import AdminLayout from '../core/layout/AdminLayout';
// Admin pages
import UserList from '../core/admin/pages/UserList';
import UserDetail from '../core/admin/pages/UserDetail';
import RoleList from '../core/admin/pages/RoleList';
import RoleDetail from '../core/admin/pages/RoleDetail';
// Product registry
import { PRODUCT_REGISTRY } from '../products/registry';

function App() {
  return (
    <Router>
      <Routes>
        {/* Public */}
        <Route path="/login" element={<LoginPage />} />

        {/* Launcher — product selection page */}
        <Route
          path="/"
          element={
            <ProtectedRoute>
              <LauncherPage />
            </ProtectedRoute>
          }
        />

        {/* Admin Console — own layout with admin sidebar */}
        <Route element={<ProtectedRoute requireAdmin><AdminLayout /></ProtectedRoute>}>
          <Route path="/admin" element={<Navigate to="/admin/users" replace />} />
          <Route path="/admin/users" element={<UserList />} />
          <Route path="/admin/users/:id" element={<UserDetail />} />
          <Route path="/admin/roles" element={<RoleList />} />
          <Route path="/admin/roles/:id" element={<RoleDetail />} />
        </Route>

        {/* Product workspaces — each uses ProductLayout with product-specific sidebar */}
        <Route element={<ProductLayout />}>
          {PRODUCT_REGISTRY.flatMap((product) =>
            product.routes.map((route) => (
              <Route
                key={route.path}
                path={route.path}
                element={
                  <ProtectedRoute product={product.slug} permission={route.permission}>
                    <route.component />
                  </ProtectedRoute>
                }
              />
            ))
          )}
        </Route>
      </Routes>
    </Router>
  );
}

export default App;
