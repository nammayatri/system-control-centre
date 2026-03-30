import { BrowserRouter as Router, Routes, Route, Navigate } from 'react-router-dom';
import Layout from './components/layout/Layout';
import { ProtectedRoute } from './components/auth/ProtectedRoute';
import LoginPage from './screens/LoginPage';
// Admin (core — not a product)
import UserList from './screens/admin/UserList';
import UserDetail from './screens/admin/UserDetail';
import RoleList from './screens/admin/RoleList';
import RoleDetail from './screens/admin/RoleDetail';
// Product registry — auto-generates routes
import { PRODUCT_REGISTRY } from './products/_shared/ProductRegistry';

function App() {
  return (
    <Router>
      <Routes>
        <Route path="/login" element={<LoginPage />} />

        <Route element={<Layout />}>
          {/* Default redirect */}
          <Route path="/" element={<Navigate to={PRODUCT_REGISTRY[0]?.basePath || '/releases'} replace />} />

          {/* Auto-generate routes from product registry */}
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

          {/* Admin routes (core — always available for superadmin) */}
          <Route path="/admin/users" element={<ProtectedRoute requireAdmin><UserList /></ProtectedRoute>} />
          <Route path="/admin/users/:id" element={<ProtectedRoute requireAdmin><UserDetail /></ProtectedRoute>} />
          <Route path="/admin/roles" element={<ProtectedRoute requireAdmin><RoleList /></ProtectedRoute>} />
          <Route path="/admin/roles/:id" element={<ProtectedRoute requireAdmin><RoleDetail /></ProtectedRoute>} />
        </Route>
      </Routes>
    </Router>
  );
}

export default App;
