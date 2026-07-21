import React, { useState, useEffect } from 'react';
import { Outlet, Link, useLocation, useNavigate } from 'react-router-dom';
import type { ProductDefinition, ProductNavItem } from '../../products/registry';
import {
  Rocket, FileText, Settings, Package, Layers,
  Plus, List, ChevronLeft,
  PanelLeftClose, PanelLeft, X,
  Activity, Flame, ExternalLink, Smartphone, Server, Gauge,
  CloudDownload, LayoutGrid, Link2,
  SlidersHorizontal, Users, Settings2, Bookmark,
} from 'lucide-react';
import { cn } from '../../lib/utils';
import TopBar from './TopBar';

const iconMap: Record<string, React.ReactNode> = {
  Rocket: <Rocket className="w-4 h-4" />,
  FileText: <FileText className="w-4 h-4" />,
  Settings: <Settings className="w-4 h-4" />,
  Package: <Package className="w-4 h-4" />,
  Layers: <Layers className="w-3.5 h-3.5" />,
  Plus: <Plus className="w-3.5 h-3.5" />,
  List: <List className="w-3.5 h-3.5" />,
  Activity: <Activity className="w-3.5 h-3.5" />,
  Flame: <Flame className="w-3.5 h-3.5" />,
  Smartphone: <Smartphone className="w-4 h-4" />,
  Server: <Server className="w-4 h-4" />,
  Gauge: <Gauge className="w-3.5 h-3.5" />,
  CloudDownload: <CloudDownload className="w-4 h-4" />,
  LayoutGrid: <LayoutGrid className="w-3.5 h-3.5" />,
  Link2: <Link2 className="w-3.5 h-3.5" />,
  SlidersHorizontal: <SlidersHorizontal className="w-3.5 h-3.5" />,
  Users: <Users className="w-3.5 h-3.5" />,
  Settings2: <Settings2 className="w-3.5 h-3.5" />,
  Bookmark: <Bookmark className="w-3.5 h-3.5" />,
};

interface SidebarBodyProps {
  navItems: ProductNavItem[];
  collapsed: boolean;
  isActive: (path: string) => boolean;
  onItemClick?: () => void;
  pill?: boolean;
}

// Two visual styles: default (left-border indicator, full-bleed rows) and
// pill (rounded — used by products with navPill: true). Pill mode matches the
// airborne dashboard: selected = #282931 surface, hover = brand purple.
const itemClasses = (pill: boolean, collapsed: boolean, active: boolean) =>
  pill
    ? cn(
        'flex items-center gap-2.5 mx-2 my-0.5 px-3 h-10 md:h-9 rounded-lg text-sm cursor-pointer transition-colors duration-150',
        collapsed && 'md:justify-center md:px-0 md:mx-1.5',
        active
          ? 'bg-airborne-nav text-white'
          : 'text-zinc-300 hover:bg-airborne hover:text-white'
      )
    : cn(
        'flex items-center gap-2.5 px-4 h-11 md:h-10 text-sm cursor-pointer transition-colors duration-150',
        collapsed && 'md:justify-center md:px-0',
        active
          ? 'text-zinc-50 bg-zinc-800 border-l-2 border-emerald-500'
          : 'text-zinc-400 hover:text-zinc-100 hover:bg-zinc-900 border-l-2 border-transparent'
      );

const SidebarBody: React.FC<SidebarBodyProps> = ({ navItems, collapsed, isActive, onItemClick, pill = false }) => (
  <nav className="flex-1 overflow-y-auto py-3">
    {navItems.map((item) => {
      if (item.external) {
        return (
          <a
            key={item.path}
            href={item.path}
            target="_blank"
            rel="noopener noreferrer"
            onClick={onItemClick}
            className={itemClasses(pill, collapsed, false)}
          >
            <span className="shrink-0">{iconMap[item.icon] || null}</span>
            {(!collapsed || onItemClick) && (
              <span className="truncate flex items-center gap-1.5">
                {item.label}
                <ExternalLink className="w-3 h-3 opacity-50" />
              </span>
            )}
          </a>
        );
      }

      const active = isActive(item.path);
      return (
        <Link
          key={item.path}
          to={item.path}
          onClick={onItemClick}
          className={itemClasses(pill, collapsed, active)}
        >
          <span className="shrink-0">{iconMap[item.icon] || null}</span>
          {(!collapsed || onItemClick) && <span className="truncate">{item.label}</span>}
        </Link>
      );
    })}
  </nav>
);

const ProductLayout: React.FC<{ product: ProductDefinition }> = ({ product }) => {
  const [collapsed, setCollapsed] = useState(false);
  const [mobileOpen, setMobileOpen] = useState(false);
  const location = useLocation();
  const navigate = useNavigate();

  // URL segments after basePath (e.g. '/airborne/ny-app/releases' → ['ny-app','releases']).
  // Products with getNavItems derive a location-aware sidebar from them.
  const parts = location.pathname.startsWith(product.basePath)
    ? location.pathname.slice(product.basePath.length).split('/').filter(Boolean)
    : [];
  const navItems = product.getNavItems?.(parts) ?? product.navItems;

  // Longest matching prefix wins, so '/x/:app' (Overview) stays inactive on
  // '/x/:app/releases' — the deeper Releases item out-lengths it.
  const activeNavPath = (() => {
    let best = '';
    for (const item of navItems) {
      if (item.external) continue;
      if (location.pathname === item.path || location.pathname.startsWith(item.path + '/')) {
        if (item.path.length > best.length) best = item.path;
      }
    }
    return best;
  })();
  const isActive = (path: string) => path === activeNavPath;

  useEffect(() => {
    setMobileOpen(false);
  }, [location.pathname]);

  useEffect(() => {
    if (mobileOpen) {
      document.body.style.overflow = 'hidden';
    } else {
      document.body.style.overflow = '';
    }
    return () => {
      document.body.style.overflow = '';
    };
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
          {!collapsed &&
            (product.logo ? (
              <img src={product.logo} alt={product.label} className="h-6 w-auto" />
            ) : (
              <span className="text-sm font-semibold text-white tracking-tight truncate">
                {product.label}
              </span>
            ))}
        </div>

        {!collapsed && product.SidebarHeader && <product.SidebarHeader />}
        <SidebarBody navItems={navItems} pill={product.navPill} collapsed={collapsed} isActive={isActive} />

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
            {product.logo ? (
              <img src={product.logo} alt={product.label} className="h-6 w-auto" />
            ) : (
              <span className="text-sm font-semibold text-white tracking-tight truncate">
                {product.label}
              </span>
            )}
          </div>
          <button
            onClick={() => setMobileOpen(false)}
            className="w-9 h-9 rounded-lg flex items-center justify-center text-zinc-500 hover:text-white hover:bg-zinc-900 cursor-pointer transition-colors duration-150"
            aria-label="Close menu"
          >
            <X className="w-4 h-4" />
          </button>
        </div>
        {product.SidebarHeader && <product.SidebarHeader />}
        <SidebarBody
          navItems={navItems}
          pill={product.navPill}
          collapsed={false}
          isActive={isActive}
          onItemClick={() => setMobileOpen(false)}
        />
      </aside>

      {/* Content — optionally wrapped in the product's ThemeWrapper so scoped
          theming (e.g. Airborne dark mode) covers TopBar + main only. */}
      <div className="flex-1 flex flex-col h-screen overflow-hidden min-w-0">
        {(() => {
          const content = (
            <>
              <TopBar
                onOpenMobileNav={() => setMobileOpen(true)}
                headerActions={product.HeaderActions ? <product.HeaderActions /> : null}
              />
              {product.Banner && <product.Banner />}
              <main className="flex-1 overflow-y-auto scroll-pb-28 px-4 py-4 sm:px-6 sm:py-5">
                <Outlet />
              </main>
            </>
          );
          return product.ThemeWrapper ? <product.ThemeWrapper>{content}</product.ThemeWrapper> : content;
        })()}
      </div>
    </div>
  );
};

export default ProductLayout;
