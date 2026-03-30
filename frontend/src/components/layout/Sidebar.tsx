import React, { useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { useAuth } from '../../context/AuthContext';
import { usePermissions } from '../../context/PermissionsContext';
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

interface SidebarProps {
  collapsed: boolean;
  onToggle: () => void;
}

interface NavSection {
  label: string;
  icon: React.ReactNode;
  defaultOpen?: boolean;
  items: { label: string; to: string; icon?: React.ReactNode }[];
}

const Sidebar: React.FC<SidebarProps> = ({ collapsed, onToggle }) => {
  const location = useLocation();
  const { user } = useAuth();
  const { isAdmin } = usePermissions();

  const [openSections, setOpenSections] = useState<Record<string, boolean>>({
    releases: true,
    configmap: true,
  });

  const isActive = (path: string) => location.pathname === path || location.pathname.startsWith(path + '/');

  const toggleSection = (key: string) => {
    setOpenSections((prev) => ({ ...prev, [key]: !prev[key] }));
  };

  const sections: NavSection[] = [
    {
      label: 'Releases',
      icon: <Rocket className="w-4 h-4" />,
      defaultOpen: true,
      items: [
        { label: 'List', to: '/releases', icon: <List className="w-3.5 h-3.5" /> },
        { label: 'Create', to: '/releases/new', icon: <Plus className="w-3.5 h-3.5" /> },
      ],
    },
    {
      label: 'Config Map',
      icon: <FileText className="w-4 h-4" />,
      items: [
        { label: 'List', to: '/configmap', icon: <List className="w-3.5 h-3.5" /> },
        { label: 'Create', to: '/configmap/new', icon: <Plus className="w-3.5 h-3.5" /> },
      ],
    },
    {
      label: 'Configurations',
      icon: <Settings className="w-4 h-4" />,
      items: [
        { label: 'Server Config', to: '/configurations', icon: <Layers className="w-3.5 h-3.5" /> },
      ],
    },
  ];

  const adminSection: NavSection = {
    label: 'Admin',
    icon: <Shield className="w-4 h-4" />,
    items: [
      { label: 'Users', to: '/admin/users', icon: <Users className="w-3.5 h-3.5" /> },
      { label: 'Roles', to: '/admin/roles', icon: <Shield className="w-3.5 h-3.5" /> },
      { label: 'Products', to: '/admin/products', icon: <Package className="w-3.5 h-3.5" /> },
    ],
  };

  const renderSection = (section: NavSection, key: string) => {
    const isOpen = openSections[key] ?? section.defaultOpen ?? false;

    return (
      <div key={key} className="mb-1">
        <button
          onClick={() => !collapsed && toggleSection(key)}
          className={cn(
            'w-full flex items-center gap-3 px-4 py-2.5 text-sm transition-colors',
            'text-zinc-400 hover:text-white hover:bg-sidebar-hover',
            collapsed && 'justify-center px-0'
          )}
        >
          <span className="text-zinc-500">{section.icon}</span>
          {!collapsed && (
            <>
              <span className="flex-1 text-left font-medium">{section.label}</span>
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
            {section.items.map((item) => (
              <Link
                key={item.to}
                to={item.to}
                className={cn(
                  'flex items-center gap-2.5 pl-11 pr-4 py-2 text-sm transition-all',
                  isActive(item.to)
                    ? 'text-white bg-sidebar-active border-l-2 border-blue-500'
                    : 'text-zinc-500 hover:text-zinc-300 hover:bg-sidebar-hover border-l-2 border-transparent'
                )}
              >
                {item.icon}
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
        'bg-sidebar flex-shrink-0 flex flex-col h-screen transition-all duration-200 border-r border-zinc-800',
        collapsed ? 'w-[60px]' : 'w-[260px]'
      )}
    >
      {/* Logo */}
      <div className={cn(
        'h-14 flex items-center border-b border-zinc-800 shrink-0',
        collapsed ? 'justify-center px-2' : 'px-4 gap-3'
      )}>
        <img src={nyLogo} alt="NY" className="h-7 w-auto" />
        {!collapsed && (
          <span className="text-sm font-semibold text-white tracking-tight">System Control</span>
        )}
      </div>

      {/* Nav */}
      <nav className="flex-1 overflow-y-auto sidebar-scroll py-3">
        {sections.map((s, i) => renderSection(s, s.label.toLowerCase().replace(/\s/g, '')))}

        {isAdmin && (
          <>
            <div className="mx-4 my-3 border-t border-zinc-800" />
            {renderSection(adminSection, 'admin')}
          </>
        )}
      </nav>

      {/* Bottom */}
      <div className="shrink-0 border-t border-zinc-800">
        {/* User */}
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

        {/* Collapse toggle */}
        <button
          onClick={onToggle}
          className="w-full flex items-center justify-center py-3 text-zinc-600 hover:text-zinc-400 transition-colors"
        >
          {collapsed ? <PanelLeft className="w-4 h-4" /> : <PanelLeftClose className="w-4 h-4" />}
        </button>
      </div>
    </aside>
  );
};

export default Sidebar;
