import React, { useState, useEffect } from 'react';
import { Outlet, Link, useLocation, useNavigate } from 'react-router-dom';
import { motion, AnimatePresence } from 'framer-motion';
import {
  Users, Shield, ChevronLeft,
  PanelLeftClose, PanelLeft, X,
} from 'lucide-react';
import { cn } from '../../lib/utils';
import TopBar from './TopBar';

const adminNavItems = [
  { label: 'Users', path: '/admin/users', icon: <Users className="w-4 h-4" /> },
  { label: 'Roles', path: '/admin/roles', icon: <Shield className="w-4 h-4" /> },
];

interface NavBodyProps {
  collapsed: boolean;
  isActive: (path: string) => boolean;
  onItemClick?: () => void;
}

const NavBody: React.FC<NavBodyProps> = ({ collapsed, isActive, onItemClick }) => (
  <nav className="flex-1 overflow-y-auto py-3">
    {adminNavItems.map((item) => (
      <Link
        key={item.path}
        to={item.path}
        onClick={onItemClick}
        className={cn(
          'flex items-center gap-2.5 px-4 h-11 md:h-10 text-sm cursor-pointer transition-colors duration-150',
          collapsed && 'md:justify-center md:px-0',
          isActive(item.path)
            ? 'text-zinc-50 bg-zinc-800 border-l-2 border-emerald-500'
            : 'text-zinc-400 hover:text-zinc-100 hover:bg-zinc-900 border-l-2 border-transparent'
        )}
      >
        <span className="shrink-0">{item.icon}</span>
        {(!collapsed || onItemClick) && <span className="truncate">{item.label}</span>}
      </Link>
    ))}
  </nav>
);

const AdminLayout: React.FC = () => {
  const [collapsed, setCollapsed] = useState(false);
  const [mobileOpen, setMobileOpen] = useState(false);
  const location = useLocation();
  const navigate = useNavigate();

  const isActive = (path: string) => location.pathname === path || location.pathname.startsWith(path + '/');

  useEffect(() => { setMobileOpen(false); }, [location.pathname]);

  useEffect(() => {
    if (mobileOpen) document.body.style.overflow = 'hidden';
    else document.body.style.overflow = '';
    return () => { document.body.style.overflow = ''; };
  }, [mobileOpen]);

  return (
    <div className="min-h-screen bg-zinc-50 flex font-sans">
      {/* Desktop sidebar */}
      <aside
        className={cn(
          'hidden md:flex bg-zinc-950 flex-shrink-0 flex-col h-screen transition-all duration-200 border-r border-zinc-800',
          collapsed ? 'w-[60px]' : 'w-[240px] lg:w-[260px]'
        )}
      >
        <div className={cn(
          'h-14 flex items-center border-b border-zinc-800 shrink-0',
          collapsed ? 'justify-center px-2' : 'px-3 gap-2'
        )}>
          <button
            onClick={() => navigate('/')}
            className="w-8 h-8 rounded-lg flex items-center justify-center text-zinc-500 hover:text-white hover:bg-zinc-900 cursor-pointer transition-colors duration-150"
            aria-label="Back to launcher"
          >
            <ChevronLeft className="w-4 h-4" />
          </button>
          {!collapsed && (
            <span className="text-sm font-semibold text-white tracking-tight">Admin Console</span>
          )}
        </div>

        <NavBody collapsed={collapsed} isActive={isActive} />

        <div className="shrink-0 border-t border-zinc-800">
          <button
            onClick={() => setCollapsed(!collapsed)}
            className="w-full flex items-center justify-center py-3 text-zinc-600 hover:text-zinc-400 cursor-pointer transition-colors duration-150"
            aria-label={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
          >
            {collapsed ? <PanelLeft className="w-4 h-4" /> : <PanelLeftClose className="w-4 h-4" />}
          </button>
        </div>
      </aside>

      {/* Mobile drawer overlay */}
      {mobileOpen && (
        <div
          className="md:hidden fixed inset-0 z-40 bg-black/50 animate-in fade-in-0 duration-200"
          onClick={() => setMobileOpen(false)}
        />
      )}

      {/* Mobile drawer */}
      <aside
        className={cn(
          'md:hidden fixed inset-y-0 left-0 z-50 w-[280px] max-w-[85vw] bg-zinc-950 border-r border-zinc-800 flex flex-col',
          'transition-transform duration-200 ease-out',
          mobileOpen ? 'translate-x-0' : '-translate-x-full'
        )}
      >
        <div className="h-14 flex items-center justify-between border-b border-zinc-800 shrink-0 px-3 gap-2">
          <div className="flex items-center gap-2 min-w-0">
            <button
              onClick={() => { setMobileOpen(false); navigate('/'); }}
              className="w-9 h-9 rounded-lg flex items-center justify-center text-zinc-500 hover:text-white hover:bg-zinc-900 cursor-pointer transition-colors duration-150"
              aria-label="Back to launcher"
            >
              <ChevronLeft className="w-4 h-4" />
            </button>
            <span className="text-sm font-semibold text-white tracking-tight">Admin Console</span>
          </div>
          <button
            onClick={() => setMobileOpen(false)}
            className="w-9 h-9 rounded-lg flex items-center justify-center text-zinc-500 hover:text-white hover:bg-zinc-900 cursor-pointer transition-colors duration-150"
            aria-label="Close menu"
          >
            <X className="w-4 h-4" />
          </button>
        </div>
        <NavBody collapsed={false} isActive={isActive} onItemClick={() => setMobileOpen(false)} />
      </aside>

      {/* Content */}
      <div className="flex-1 flex flex-col h-screen overflow-hidden min-w-0">
        <TopBar onOpenMobileNav={() => setMobileOpen(true)} />
        <main className="flex-1 overflow-y-auto px-4 py-4 sm:px-6 sm:py-5 lg:px-8 lg:py-6">
          <AnimatePresence mode="wait">
            <motion.div
              key={location.pathname}
              initial={{ opacity: 0, y: 4 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0 }}
              transition={{ duration: 0.2, ease: 'easeOut' }}
            >
              <Outlet />
            </motion.div>
          </AnimatePresence>
        </main>
      </div>
    </div>
  );
};

export default AdminLayout;
