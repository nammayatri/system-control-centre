import React, { useState, useRef, useEffect } from 'react';
import { useLocation, Link } from 'react-router-dom';
import { useAuth } from '../auth/AuthContext';
import { ChevronRight, LogOut, Menu } from 'lucide-react';
import { PRODUCT_REGISTRY, type Crumb } from '../../products/registry';
import { cn } from '../../lib/utils';

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

interface TopBarProps {
  onOpenMobileNav?: () => void;
}

const TopBar: React.FC<TopBarProps> = ({ onOpenMobileNav }) => {
  const location = useLocation();
  const { user, logout } = useAuth();
  const [showMenu, setShowMenu] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);

  const breadcrumbs = getBreadcrumbs(location.pathname);
  // The last crumb is the current page title for mobile display
  const lastCrumb = breadcrumbs[breadcrumbs.length - 1];

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
    <div className="h-14 bg-white border-b border-zinc-200 flex items-center justify-between px-3 sm:px-6 shrink-0 gap-3">
      {/* Mobile hamburger */}
      {onOpenMobileNav && (
        <button
          onClick={onOpenMobileNav}
          className="md:hidden h-10 w-10 -ml-1 flex items-center justify-center rounded-lg text-zinc-600 hover:bg-zinc-100 cursor-pointer transition-colors duration-150"
          aria-label="Open menu"
        >
          <Menu className="w-5 h-5" />
        </button>
      )}

      {/* Mobile: page title only */}
      <div className="md:hidden flex-1 min-w-0">
        <span className="text-sm font-semibold text-zinc-900 truncate block">
          {lastCrumb?.label || 'Dashboard'}
        </span>
      </div>

      {/* Desktop: full breadcrumbs */}
      <div className="hidden md:flex items-center text-sm flex-1 min-w-0 overflow-hidden">
        {breadcrumbs.map((crumb, i) => (
          <React.Fragment key={i}>
            {i > 0 && <ChevronRight className="w-3.5 h-3.5 mx-1.5 text-zinc-300 shrink-0" />}
            {crumb.to ? (
              <Link
                to={crumb.to}
                className="text-zinc-500 hover:text-zinc-800 transition-colors duration-150 cursor-pointer truncate"
              >
                {crumb.label}
              </Link>
            ) : (
              <span className="text-zinc-800 font-medium truncate">{crumb.label}</span>
            )}
          </React.Fragment>
        ))}
        {breadcrumbs.length === 0 && (
          <span className="text-zinc-800 font-medium">Dashboard</span>
        )}
      </div>

      {/* User menu */}
      <div className="relative shrink-0" ref={menuRef}>
        <button
          onClick={() => setShowMenu(!showMenu)}
          className={cn(
            'h-9 w-9 rounded-full bg-zinc-100 border border-zinc-200',
            'flex items-center justify-center text-xs font-bold text-zinc-600',
            'hover:bg-zinc-200 transition-colors duration-150 uppercase cursor-pointer',
            'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-zinc-400 focus-visible:ring-offset-1'
          )}
          aria-label="User menu"
        >
          {user?.name?.[0] || user?.email?.[0] || '?'}
        </button>
        {showMenu && (
          <div className="absolute right-0 top-full mt-2 w-56 bg-white border border-zinc-200 rounded-lg shadow-sm z-50 py-1">
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
