import React, { useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { useAuth } from '../auth/AuthContext';
import { usePermissions } from '../auth/PermissionsContext';
import {
  Rocket,
  FileText,
  Settings,
  ChevronDown,
  ChevronRight,
  PanelLeftClose,
  PanelLeft,
  Users,
  Shield,
  Package,
  Layers,
  Plus,
  List,
} from 'lucide-react';
import nyLogo from '../../assets/ny-logo.svg';
import { cn } from '../../lib/utils';
import { PRODUCT_REGISTRY, type ProductDefinition } from '../../products/registry';

const iconMap: Record<string, React.ReactNode> = {
  Rocket: <Rocket className="w-4 h-4" />,
  FileText: <FileText className="w-4 h-4" />,
  Settings: <Settings className="w-4 h-4" />,
  Package: <Package className="w-4 h-4" />,
  Shield: <Shield className="w-4 h-4" />,
  Users: <Users className="w-4 h-4" />,
  Layers: <Layers className="w-3.5 h-3.5" />,
  Plus: <Plus className="w-3.5 h-3.5" />,
  List: <List className="w-3.5 h-3.5" />,
};

interface SidebarProps {
  collapsed: boolean;
  onToggle: () => void;
}

const Sidebar: React.FC<SidebarProps> = ({ collapsed, onToggle }) => {
  const location = useLocation();
  const { user } = useAuth();
  const { isAdmin, hasPermission } = usePermissions();

  const [openSections, setOpenSections] = useState<Record<string, boolean>>(() => {
    const initial: Record<string, boolean> = {};
    PRODUCT_REGISTRY.forEach((p) => {
      initial[p.slug] = location.pathname.startsWith(p.basePath);
    });
    return initial;
  });

  const isActive = (path: string) => location.pathname === path || location.pathname.startsWith(path + '/');

  const toggleSection = (key: string) => {
    setOpenSections((prev) => ({ ...prev, [key]: !prev[key] }));
  };

  const visibleProducts = PRODUCT_REGISTRY.filter((p) =>
    hasPermission(p.slug, `${p.slug === 'config-manager' ? 'CONFIG' : 'RELEASE'}_VIEW`)
  );

  const renderProductSection = (product: ProductDefinition) => {
    const key = product.slug + product.basePath;
    const isOpen = openSections[key] ?? false;

    return (
      <div key={key} className="mb-1">
        <button
          onClick={() => !collapsed && toggleSection(key)}
          className={cn(
            'w-full flex items-center gap-3 px-4 h-10 text-sm cursor-pointer transition-colors duration-150',
            'text-[#a1a1aa] hover:text-white hover:bg-[#171717]',
            collapsed && 'justify-center px-0'
          )}
        >
          <span className="text-zinc-500">{iconMap[product.icon] || <Package className="w-4 h-4" />}</span>
          {!collapsed && (
            <>
              <span className="flex-1 text-left font-medium">{product.label}</span>
              {isOpen ? (
                <ChevronDown className="w-3.5 h-3.5 text-zinc-600" />
              ) : (
                <ChevronRight className="w-3.5 h-3.5 text-zinc-600" />
              )}
            </>
          )}
        </button>
        {!collapsed && isOpen && (
          <div className="mt-0.5 space-y-0.5">
            {product.navItems.map((item) => (
              <Link
                key={item.path}
                to={item.path}
                className={cn(
                  'flex items-center gap-2.5 pl-11 pr-4 h-9 text-sm cursor-pointer transition-colors duration-150',
                  isActive(item.path)
                    ? 'text-[#fafafa] bg-[#262626] border-l-2 border-emerald-500'
                    : 'text-zinc-500 hover:text-zinc-300 hover:bg-[#171717] border-l-2 border-transparent'
                )}
              >
                {iconMap[item.icon] || null}
                <span>{item.label}</span>
              </Link>
            ))}
          </div>
        )}
      </div>
    );
  };

  return (
    <aside
      className={cn(
        'bg-[#0a0a0a] flex-shrink-0 flex flex-col h-screen transition-all duration-200 border-r border-zinc-800',
        collapsed ? 'w-[60px]' : 'w-[260px]'
      )}
    >
      {/* Logo */}
      <div className={cn(
        'h-14 flex items-center border-b border-zinc-800 shrink-0',
        collapsed ? 'justify-center px-2' : 'px-4 gap-3'
      )}>
        <img src={nyLogo} alt="Logo" className="h-7 w-auto" />
        {!collapsed && (
          <span className="text-sm font-semibold text-white tracking-tight">System Control</span>
        )}
      </div>

      {/* Product sections */}
      <nav className="flex-1 overflow-y-auto sidebar-scroll py-3">
        {visibleProducts.map(renderProductSection)}

        {/* Admin section */}
        {isAdmin && (
          <>
            <div className="mx-4 my-3 border-t border-zinc-800" />
            <div className="mb-1">
              <button
                onClick={() => !collapsed && toggleSection('admin')}
                className={cn(
                  'w-full flex items-center gap-3 px-4 h-10 text-sm cursor-pointer transition-colors duration-150',
                  'text-[#a1a1aa] hover:text-white hover:bg-[#171717]',
                  collapsed && 'justify-center px-0'
                )}
              >
                <span className="text-zinc-500"><Shield className="w-4 h-4" /></span>
                {!collapsed && (
                  <>
                    <span className="flex-1 text-left font-medium">Admin</span>
                    {openSections['admin'] ? (
                      <ChevronDown className="w-3.5 h-3.5 text-zinc-600" />
                    ) : (
                      <ChevronRight className="w-3.5 h-3.5 text-zinc-600" />
                    )}
                  </>
                )}
              </button>
              {!collapsed && openSections['admin'] && (
                <div className="mt-0.5 space-y-0.5">
                  {[
                    { label: 'Users', path: '/admin/users', icon: 'Users' },
                    { label: 'Roles', path: '/admin/roles', icon: 'Shield' },
                  ].map((item) => (
                    <Link
                      key={item.path}
                      to={item.path}
                      className={cn(
                        'flex items-center gap-2.5 pl-11 pr-4 h-9 text-sm cursor-pointer transition-colors duration-150',
                        isActive(item.path)
                          ? 'text-[#fafafa] bg-[#262626] border-l-2 border-emerald-500'
                          : 'text-zinc-500 hover:text-zinc-300 hover:bg-[#171717] border-l-2 border-transparent'
                      )}
                    >
                      {iconMap[item.icon] || null}
                      <span>{item.label}</span>
                    </Link>
                  ))}
                </div>
              )}
            </div>
          </>
        )}
      </nav>

      {/* Bottom */}
      <div className="shrink-0 border-t border-zinc-800">
        {!collapsed && user && (
          <div className="px-4 py-3 flex items-center gap-3">
            <div className="w-7 h-7 rounded-full bg-zinc-700 flex items-center justify-center text-xs font-bold text-white uppercase">
              {user.name?.[0] || user.email?.[0] || '?'}
            </div>
            <div className="flex-1 min-w-0">
              <div className="text-sm text-zinc-300 font-medium truncate">{user.name || user.email}</div>
              <div className="text-xs text-zinc-600 truncate">{user.email}</div>
            </div>
          </div>
        )}

        <button
          onClick={onToggle}
          className="w-full flex items-center justify-center py-3 text-zinc-600 hover:text-zinc-400 cursor-pointer transition-colors duration-150"
        >
          {collapsed ? <PanelLeft className="w-4 h-4" /> : <PanelLeftClose className="w-4 h-4" />}
        </button>
      </div>
    </aside>
  );
};

export default Sidebar;
