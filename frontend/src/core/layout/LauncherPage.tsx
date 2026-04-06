import { useNavigate } from 'react-router-dom';
import { useAuth } from '../auth/AuthContext';
import { usePermissions } from '../auth/PermissionsContext';
import { PRODUCT_REGISTRY } from '../../products/registry';
import { motion } from 'framer-motion';
import {
  Rocket, FileText, Settings, Shield, LogOut, Package,
  ChevronRight, Globe, Layers,
} from 'lucide-react';

const iconMap: Record<string, React.ReactNode> = {
  Rocket: <Rocket className="w-7 h-7" />,
  FileText: <FileText className="w-7 h-7" />,
  Settings: <Settings className="w-7 h-7" />,
  Package: <Package className="w-7 h-7" />,
  Globe: <Globe className="w-7 h-7" />,
  Layers: <Layers className="w-7 h-7" />,
};

export default function LauncherPage() {
  const navigate = useNavigate();
  const { user, logout } = useAuth();
  const { isAdmin, hasPermission } = usePermissions();

  // Filter products user has access to via each product's declared viewPermission
  const accessibleProducts = PRODUCT_REGISTRY.filter((p) =>
    hasPermission(p.slug, p.viewPermission)
  );

  return (
    <div className="min-h-screen bg-zinc-50 font-sans">
      {/* Top bar */}
      <header className="h-14 bg-white border-b border-zinc-200 flex items-center justify-between px-6">
        <div className="flex items-center gap-3">
          <div className="w-8 h-8 bg-zinc-900 rounded-lg flex items-center justify-center">
            <span className="text-white text-sm font-bold">SC</span>
          </div>
          <span className="text-base font-semibold text-zinc-900 tracking-tight">System Control Centre</span>
        </div>
        <div className="flex items-center gap-4">
          <span className="text-sm text-zinc-500">{user?.email}</span>
          <button
            onClick={logout}
            className="flex items-center gap-1.5 text-sm text-zinc-500 hover:text-zinc-700 cursor-pointer transition-colors duration-150"
          >
            <LogOut className="w-4 h-4" />
            Logout
          </button>
        </div>
      </header>

      {/* Main content */}
      <main className="max-w-4xl mx-auto px-6 py-12">
        <div className="mb-8">
          <h1 className="text-lg font-semibold text-zinc-900">
            Welcome{user?.name ? `, ${user.name.split(' ')[0]}` : ''}
          </h1>
          <p className="text-sm text-zinc-500 mt-1">Select a product to get started</p>
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
          {/* Admin Console — only for admins */}
          {isAdmin && (
            <motion.button
              initial={{ opacity: 0, y: 6 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.2, ease: 'easeOut', delay: 0 }}
              onClick={() => navigate('/admin')}
              className="group bg-white border border-zinc-200 rounded-xl p-5 text-left cursor-pointer transition-all duration-150 hover:bg-zinc-50 hover:shadow-sm"
            >
              <div className="flex items-start justify-between">
                <div className="w-12 h-12 rounded-lg bg-zinc-100 flex items-center justify-center text-zinc-600 group-hover:text-zinc-900 transition-colors duration-150">
                  <Shield className="w-7 h-7" />
                </div>
                <ChevronRight className="w-4 h-4 text-zinc-300 group-hover:text-zinc-500 transition-colors duration-150 mt-1" />
              </div>
              <h3 className="text-sm font-semibold text-zinc-900 mt-4">Admin Console</h3>
              <p className="text-xs text-zinc-500 mt-1 leading-relaxed">
                Manage users, roles, and product access
              </p>
            </motion.button>
          )}

          {/* Product cards */}
          {accessibleProducts.map((product, i) => (
            <motion.button
              key={product.slug}
              initial={{ opacity: 0, y: 6 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.2, ease: 'easeOut', delay: (isAdmin ? i + 1 : i) * 0.05 }}
              onClick={() => navigate(product.navItems[0]?.path || product.basePath)}
              className="group bg-white border border-zinc-200 rounded-xl p-5 text-left cursor-pointer transition-all duration-150 hover:bg-zinc-50 hover:shadow-sm"
            >
              <div className="flex items-start justify-between">
                <div className="w-12 h-12 rounded-lg bg-zinc-100 flex items-center justify-center text-zinc-600 group-hover:text-zinc-900 transition-colors duration-150">
                  {iconMap[product.icon] || <Package className="w-7 h-7" />}
                </div>
                <ChevronRight className="w-4 h-4 text-zinc-300 group-hover:text-zinc-500 transition-colors duration-150 mt-1" />
              </div>
              <h3 className="text-sm font-semibold text-zinc-900 mt-4">{product.label}</h3>
              <p className="text-xs text-zinc-500 mt-1 leading-relaxed">
                {product.description}
              </p>
            </motion.button>
          ))}
        </div>
      </main>
    </div>
  );
}

