import { BrowserRouter as Router, Routes, Route, Navigate } from 'react-router-dom';
import Layout from './components/layout/Layout';
import { ProtectedRoute } from './components/auth/ProtectedRoute';
import LoginPage from './screens/LoginPage';
// Products
import ListRelease from './products/releases/ListRelease';
import CreateRelease from './products/releases/CreateRelease';
import ReleaseSummary from './products/releases/ReleaseSummary';
import ListConfigMap from './products/configmap/ListConfigMap';
import CreateConfigMap from './products/configmap/CreateConfigMap';
import ConfigMapSummary from './products/configmap/ConfigMapSummary';
import Configurations from './products/config/Configurations';
// Admin (core)
import UserList from './screens/admin/UserList';
import UserDetail from './screens/admin/UserDetail';
import RoleList from './screens/admin/RoleList';
import RoleDetail from './screens/admin/RoleDetail';

function App() {
  return (
    <Router>
      <Routes>
        <Route path="/login" element={<LoginPage />} />

        <Route element={<Layout />}>
          {/* Releases */}
          <Route path="/" element={<Navigate to="/releases" replace />} />
          <Route path="/releases" element={<ProtectedRoute product="backend-releases"><ListRelease /></ProtectedRoute>} />
          <Route path="/releases/new" element={<ProtectedRoute product="backend-releases"><CreateRelease /></ProtectedRoute>} />
          <Route path="/releases/:clusterId/:id" element={<ProtectedRoute product="backend-releases"><ReleaseSummary /></ProtectedRoute>} />
          <Route path="/releases/:clusterId/:id/clone" element={<ProtectedRoute product="backend-releases"><CreateRelease /></ProtectedRoute>} />

          {/* ConfigMap */}
          <Route path="/configmap" element={<ProtectedRoute product="config-manager"><ListConfigMap /></ProtectedRoute>} />
          <Route path="/configmap/new" element={<ProtectedRoute product="config-manager"><CreateConfigMap /></ProtectedRoute>} />
          <Route path="/configmap/:clusterId" element={<ProtectedRoute product="config-manager"><ConfigMapSummary /></ProtectedRoute>} />

          {/* Configurations */}
          <Route path="/configurations" element={<ProtectedRoute product="backend-releases"><Configurations /></ProtectedRoute>} />

          {/* Admin */}
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
