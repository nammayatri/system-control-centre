import React, { useState, useRef, useEffect } from 'react';
import { useLocation, Link } from 'react-router-dom';
import { useAuth } from '../auth/AuthContext';
import { ChevronRight, LogOut } from 'lucide-react';
import { PRODUCT_REGISTRY, type Crumb } from '../../products/registry';

function getAdminBreadcrumbs(parts: string[]): Crumb[] {
  const crumbs: Crumb[] = [{ label: 'Admin' }];
  if (parts[1] === 'users') {
    crumbs.push({ label: 'Users', to: '/admin/users' });
    if (parts[2]) crumbs.push({ label: 'User Detail' });
  } else if (parts[1] === 'roles') {
    crumbs.push({ label: 'Roles', to: '/admin/roles' });
    if (parts[2]) crumbs.push({ label: 'Role Detail' });
  }
  return crumbs;
}

function getBreadcrumbs(pathname: string): Crumb[] {
  const parts = pathname.split('/').filter(Boolean);
  if (parts.length === 0) return [];

  // Admin routes are a core concern, handled here.
  if (parts[0] === 'admin') return getAdminBreadcrumbs(parts);

  // Delegate to the first product that claims this path.
  for (const product of PRODUCT_REGISTRY) {
    const crumbs = product.getBreadcrumbs?.(parts);
    if (crumbs && crumbs.length > 0) return crumbs;
  }
  return [];
}

const TopBar: React.FC = () => {
  const location = useLocation();
  const { user, logout } = useAuth();
  const [showMenu, setShowMenu] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);

  const breadcrumbs = getBreadcrumbs(location.pathname);

  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        setShowMenu(false);
      }
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, []);

  return (
    <div className="h-14 bg-white border-b border-zinc-200 flex items-center justify-between px-6 shrink-0">
      {/* Breadcrumbs */}
      <div className="flex items-center text-sm">
        {breadcrumbs.map((crumb, i) => (
          <React.Fragment key={i}>
            {i > 0 && <ChevronRight className="w-3.5 h-3.5 mx-1.5 text-zinc-300" />}
            {crumb.to ? (
              <Link to={crumb.to} className="text-zinc-500 hover:text-zinc-800 transition-colors duration-150 cursor-pointer">
                {crumb.label}
              </Link>
            ) : (
              <span className="text-zinc-800 font-medium">{crumb.label}</span>
            )}
          </React.Fragment>
        ))}
        {breadcrumbs.length === 0 && (
          <span className="text-zinc-800 font-medium">Dashboard</span>
        )}
      </div>

      {/* User menu */}
      <div className="relative" ref={menuRef}>
        <button
          onClick={() => setShowMenu(!showMenu)}
          className="w-8 h-8 rounded-full bg-zinc-100 border border-zinc-200 flex items-center justify-center text-xs font-bold text-zinc-600 hover:bg-zinc-200 transition-colors duration-150 uppercase cursor-pointer focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-zinc-400 focus-visible:ring-offset-1"
        >
          {user?.name?.[0] || user?.email?.[0] || '?'}
        </button>
        {showMenu && (
          <div className="absolute right-0 top-full mt-1 w-48 bg-white border border-zinc-200 rounded-lg shadow-lg z-50 py-1">
            <div className="px-3 py-2 border-b border-zinc-100">
              <div className="text-sm font-medium text-zinc-800 truncate">{user?.name || 'User'}</div>
              <div className="text-xs text-zinc-500 truncate">{user?.email}</div>
            </div>
            <button
              onClick={logout}
              className="w-full flex items-center gap-2 px-3 py-2 text-sm text-red-600 hover:bg-red-50 transition-colors duration-150 cursor-pointer"
            >
              <LogOut className="w-3.5 h-3.5" />
              Sign out
            </button>
          </div>
        )}
      </div>
    </div>
  );
};

export default TopBar;
