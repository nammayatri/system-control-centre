import React, { useState } from 'react';
import { Outlet, Link, useLocation, useNavigate } from 'react-router-dom';
import { motion, AnimatePresence } from 'framer-motion';
import {
  Users, Shield, ChevronLeft,
  PanelLeftClose, PanelLeft,
} from 'lucide-react';
import { cn } from '../../lib/utils';
import TopBar from './TopBar';

const adminNavItems = [
  { label: 'Users', path: '/admin/users', icon: <Users className="w-4 h-4" /> },
  { label: 'Roles', path: '/admin/roles', icon: <Shield className="w-4 h-4" /> },
];

const AdminLayout: React.FC = () => {
  const [collapsed, setCollapsed] = useState(false);
  const location = useLocation();
  const navigate = useNavigate();

  const isActive = (path: string) => location.pathname === path || location.pathname.startsWith(path + '/');

  return (
    <div className="min-h-screen bg-[#fafafa] flex font-sans">
      {/* Admin sidebar */}
      <aside
        className={cn(
          'bg-[#0a0a0a] flex-shrink-0 flex flex-col h-screen transition-all duration-200 border-r border-zinc-800',
          collapsed ? 'w-[60px]' : 'w-[260px]'
        )}
      >
        {/* Back to launcher + title */}
        <div className={cn(
          'h-14 flex items-center border-b border-zinc-800 shrink-0',
          collapsed ? 'justify-center px-2' : 'px-3 gap-2'
        )}>
          <button
            onClick={() => navigate('/')}
            className="w-8 h-8 rounded-lg flex items-center justify-center text-zinc-500 hover:text-white hover:bg-[#171717] cursor-pointer transition-colors duration-150"
          >
            <ChevronLeft className="w-4 h-4" />
          </button>
          {!collapsed && (
            <span className="text-sm font-semibold text-white tracking-tight">Admin Console</span>
          )}
        </div>

        {/* Admin nav items */}
        <nav className="flex-1 overflow-y-auto py-3">
          {adminNavItems.map((item) => (
            <Link
              key={item.path}
              to={item.path}
              className={cn(
                'flex items-center gap-2.5 px-4 h-10 text-[13px] cursor-pointer transition-all duration-150',
                collapsed && 'justify-center px-0',
                isActive(item.path)
                  ? 'text-[#fafafa] bg-[#262626] border-l-2 border-emerald-500'
                  : 'text-zinc-500 hover:text-zinc-300 hover:bg-[#171717] border-l-2 border-transparent'
              )}
            >
              {item.icon}
              {!collapsed && <span>{item.label}</span>}
            </Link>
          ))}
        </nav>

        {/* Collapse toggle */}
        <div className="shrink-0 border-t border-zinc-800">
          <button
            onClick={() => setCollapsed(!collapsed)}
            className="w-full flex items-center justify-center py-3 text-zinc-600 hover:text-zinc-400 cursor-pointer transition-colors duration-150"
          >
            {collapsed ? <PanelLeft className="w-4 h-4" /> : <PanelLeftClose className="w-4 h-4" />}
          </button>
        </div>
      </aside>

      {/* Content */}
      <div className="flex-1 flex flex-col h-screen overflow-hidden">
        <TopBar />
        <main className="flex-1 overflow-y-auto px-8 py-6">
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
