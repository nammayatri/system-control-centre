import React, { useState, useRef, useEffect } from 'react';
import { useLocation, Link } from 'react-router-dom';
import { useAuth } from '../auth/AuthContext';
import { ChevronRight, LogOut, User, Clock } from 'lucide-react';

function getBreadcrumbs(pathname: string): { label: string; to?: string }[] {
  const parts = pathname.split('/').filter(Boolean);
  const crumbs: { label: string; to?: string }[] = [];

  if (parts[0] === 'releases') {
    crumbs.push({ label: 'Releases', to: '/releases' });
    if (parts[1] === 'new') {
      crumbs.push({ label: 'Create Release' });
    } else if (parts.length >= 3) {
      crumbs.push({ label: parts[1], to: `/releases/${parts[1]}/${parts[2]}` });
      if (parts[3] === 'clone') {
        crumbs.push({ label: 'Clone' });
      } else {
        crumbs.push({ label: 'Release Summary' });
      }
    }
  } else if (parts[0] === 'configmap') {
    crumbs.push({ label: 'Config Map', to: '/configmap' });
    if (parts[1] === 'new') {
      crumbs.push({ label: 'Create ConfigMap' });
    } else if (parts.length >= 2) {
      crumbs.push({ label: 'ConfigMap Details' });
    }
  } else if (parts[0] === 'configurations') {
    crumbs.push({ label: 'Configurations' });
  } else if (parts[0] === 'admin') {
    crumbs.push({ label: 'Admin' });
    if (parts[1] === 'users') {
      crumbs.push({ label: 'Users', to: '/admin/users' });
      if (parts[2]) crumbs.push({ label: 'User Detail' });
    } else if (parts[1] === 'roles') {
      crumbs.push({ label: 'Roles', to: '/admin/roles' });
      if (parts[2]) crumbs.push({ label: 'Role Detail' });
    }
  }

  return crumbs;
}

const TopBar: React.FC = () => {
  const location = useLocation();
  const { user, logout } = useAuth();
  const [showMenu, setShowMenu] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);
  const [lastRefresh] = useState(new Date());

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
    <div className="h-12 bg-white border-b border-border flex items-center justify-between px-6 shrink-0">
      {/* Breadcrumbs */}
      <div className="flex items-center text-sm">
        {breadcrumbs.map((crumb, i) => (
          <React.Fragment key={i}>
            {i > 0 && <ChevronRight className="w-3.5 h-3.5 mx-1.5 text-zinc-300" />}
            {crumb.to ? (
              <Link to={crumb.to} className="text-zinc-500 hover:text-zinc-800 transition-colors">
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

      {/* Right side */}
      <div className="flex items-center gap-4">
        {/* Last refresh */}
        <div className="flex items-center gap-1.5 text-xs text-zinc-400">
          <Clock className="w-3 h-3" />
          <span className="font-mono">
            {lastRefresh.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' })}
          </span>
        </div>

        {/* User menu */}
        <div className="relative" ref={menuRef}>
          <button
            onClick={() => setShowMenu(!showMenu)}
            className="w-8 h-8 rounded-full bg-zinc-100 border border-zinc-200 flex items-center justify-center text-xs font-bold text-zinc-600 hover:bg-zinc-200 transition-colors uppercase"
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
                className="w-full flex items-center gap-2 px-3 py-2 text-sm text-red-600 hover:bg-red-50 transition-colors"
              >
                <LogOut className="w-3.5 h-3.5" />
                Sign out
              </button>
            </div>
          )}
        </div>
      </div>
    </div>
  );
};

export default TopBar;
