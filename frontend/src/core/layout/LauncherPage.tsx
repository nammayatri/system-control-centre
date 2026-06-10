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
  Rocket: <Rocket className="w-6 h-6" />,
  FileText: <FileText className="w-6 h-6" />,
  Settings: <Settings className="w-6 h-6" />,
  Package: <Package className="w-6 h-6" />,
  Globe: <Globe className="w-6 h-6" />,
  Layers: <Layers className="w-6 h-6" />,
};

export default function LauncherPage() {
  const navigate = useNavigate();
  const { user, logout } = useAuth();
  const { isAdmin, hasPermission } = usePermissions();

  const accessibleProducts = PRODUCT_REGISTRY.filter((p) =>
    hasPermission(p.slug, p.viewPermission)
  );

  return (
    <div className="min-h-screen bg-zinc-50 font-sans">
      {/* Top bar */}
      <header className="h-14 bg-white border-b border-zinc-200 flex items-center justify-between px-4 sm:px-6">
        <div className="flex items-center gap-2.5 min-w-0">
          <div className="w-8 h-8 bg-zinc-900 rounded-lg flex items-center justify-center shrink-0">
            <span className="text-white text-xs font-bold">SC</span>
          </div>
          <span className="text-sm sm:text-base font-semibold text-zinc-900 tracking-tight truncate">
            <span className="hidden sm:inline">System Control Centre</span>
            <span className="sm:hidden">System Control</span>
          </span>
        </div>
        <div className="flex items-center gap-3 sm:gap-4 shrink-0">
          <span className="hidden md:inline text-sm text-zinc-500 truncate max-w-[200px]">{user?.email}</span>
          <button
            onClick={logout}
            className="flex items-center gap-1.5 text-sm text-zinc-500 hover:text-zinc-700 cursor-pointer transition-colors duration-150 h-9 px-2 rounded-md hover:bg-zinc-100"
            aria-label="Logout"
          >
            <LogOut className="w-4 h-4" />
            <span className="hidden sm:inline">Logout</span>
          </button>
        </div>
      </header>

      {/* Main content */}
      <main className="max-w-5xl mx-auto px-4 sm:px-6 py-8 sm:py-12">
        <div className="mb-6 sm:mb-8">
          <h1 className="text-lg sm:text-xl font-semibold text-zinc-900">
            Welcome{user?.name ? `, ${user.name.split(' ')[0]}` : ''}
          </h1>
          <p className="text-sm text-zinc-500 mt-1">Select a product to get started</p>
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3 sm:gap-4">
          {/* Admin Console — only for admins */}
          {isAdmin && (
            <motion.button
              initial={{ opacity: 0, y: 6 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.2, ease: 'easeOut', delay: 0 }}
              onClick={() => navigate('/admin')}
              className="group bg-white border border-zinc-200 rounded-xl p-4 sm:p-5 text-left cursor-pointer transition-colors duration-150 hover:bg-zinc-50 hover:border-zinc-300"
            >
              <div className="flex items-start justify-between">
                <div className="w-11 h-11 sm:w-12 sm:h-12 rounded-lg bg-zinc-100 flex items-center justify-center text-zinc-600 group-hover:text-zinc-900 transition-colors duration-150">
                  <Shield className="w-6 h-6" />
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
          {/* Two registry entries may share `slug` (e.g. Backend Releases +
              Mobile Releases both back the `autopilot` product), so the
              react key must combine slug + label to stay unique. */}
          {accessibleProducts.map((product, i) => (
            <motion.button
              key={`${product.slug}:${product.label}`}
              initial={{ opacity: 0, y: 6 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.2, ease: 'easeOut', delay: (isAdmin ? i + 1 : i) * 0.05 }}
              onClick={() => navigate(product.navItems[0]?.path || product.basePath)}
              className="group bg-white border border-zinc-200 rounded-xl p-4 sm:p-5 text-left cursor-pointer transition-colors duration-150 hover:bg-zinc-50 hover:border-zinc-300"
            >
              <div className="flex items-start justify-between">
                <div className="w-11 h-11 sm:w-12 sm:h-12 rounded-lg bg-zinc-100 flex items-center justify-center text-zinc-600 group-hover:text-zinc-900 transition-colors duration-150">
                  {iconMap[product.icon] || <Package className="w-6 h-6" />}
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
