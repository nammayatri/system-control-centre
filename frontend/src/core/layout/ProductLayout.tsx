import React, { useState, useEffect } from 'react';
import { Outlet, Link, useLocation, useNavigate } from 'react-router-dom';
import { PRODUCT_REGISTRY, type ProductDefinition } from '../../products/registry';
import {
  Rocket, FileText, Settings, Package, Layers,
  Plus, List, ChevronLeft,
  PanelLeftClose, PanelLeft, X,
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
};

/**
 * Resolve the current product entry from the URL.
 *
 * Two registry entries may share the same `slug` (Backend Releases and
 * Mobile Releases both back the `autopilot` slug). The naive `.find()`
 * picks whichever was registered first, which routes mobile-only paths
 * like `/releases/mobile/new` or `/releases/live` into the backend tile
 * — wrong sidebar, wrong product name. Two-step resolution:
 *
 *   1. If `?category=` is present, prefer the registry entry whose
 *      `defaultCategoryFilter` matches it. This handles the
 *      `/releases?category=mobile` (and `=backend`) case the list page
 *      uses to switch tiles without changing pathname.
 *   2. Otherwise rank candidates whose routes match the pathname, and
 *      pick the one with the longest matching route base. A mobile
 *      route `/releases/mobile/new` (base `/releases/mobile/new`) wins
 *      over the backend route `/releases/:id` (base `/releases`) for
 *      `/releases/mobile/new` even though both technically match.
 */
function findCurrentProduct(
  pathname: string,
  search: string,
): ProductDefinition | undefined {
  const params = new URLSearchParams(search);
  const category = params.get('category');

  const matchesPath = (p: ProductDefinition): { matched: boolean; bestLen: number } => {
    let bestLen = -1;
    for (const r of p.routes) {
      const routeBase = r.path.split('/:')[0];
      if (pathname === routeBase || pathname.startsWith(routeBase + '/')) {
        if (routeBase.length > bestLen) bestLen = routeBase.length;
      }
    }
    return { matched: bestLen >= 0, bestLen };
  };

  // 1. ?category= takes precedence when present. We accept either a route
  //    match OR a basePath match — the mobile entry's "All Mobile Releases"
  //    nav target is `/releases?category=mobile`, which lands on the
  //    backend tile's `/releases` route. The category param is the
  //    deliberate signal that the user wants the mobile tile.
  if (category) {
    const byCategory = PRODUCT_REGISTRY.find(
      p =>
        p.defaultCategoryFilter === category &&
        (matchesPath(p).matched ||
          pathname === p.basePath ||
          pathname.startsWith(p.basePath + '/')),
    );
    if (byCategory) return byCategory;
  }

  // 2. Longest-prefix wins. Stable order preserves first-registered as tie-breaker.
  let best: ProductDefinition | undefined;
  let bestLen = -1;
  for (const p of PRODUCT_REGISTRY) {
    const { matched, bestLen: len } = matchesPath(p);
    if (matched && len > bestLen) {
      best = p;
      bestLen = len;
    }
  }
  return best;
}

interface SidebarBodyProps {
  product: ProductDefinition | undefined;
  collapsed: boolean;
  isActive: (path: string) => boolean;
  onItemClick?: () => void;
}

const SidebarBody: React.FC<SidebarBodyProps> = ({ product, collapsed, isActive, onItemClick }) => (
  <nav className="flex-1 overflow-y-auto py-3">
    {product?.navItems.map((item) => (
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
        <span className="shrink-0">{iconMap[item.icon] || null}</span>
        {(!collapsed || onItemClick) && <span className="truncate">{item.label}</span>}
      </Link>
    ))}
  </nav>
);

const ProductLayout: React.FC = () => {
  const [collapsed, setCollapsed] = useState(false);
  const [mobileOpen, setMobileOpen] = useState(false);
  const location = useLocation();
  const navigate = useNavigate();

  const currentProduct = findCurrentProduct(location.pathname, location.search);
  const isActive = (path: string) => location.pathname === path || location.pathname.startsWith(path + '/');

  // Close mobile drawer on route change
  useEffect(() => {
    setMobileOpen(false);
  }, [location.pathname]);

  // Lock scroll when mobile drawer open
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
          {!collapsed && currentProduct && (
            <span className="text-sm font-semibold text-white tracking-tight truncate">
              {currentProduct.label}
            </span>
          )}
        </div>

        <SidebarBody product={currentProduct} collapsed={collapsed} isActive={isActive} />

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
            {currentProduct && (
              <span className="text-sm font-semibold text-white tracking-tight truncate">
                {currentProduct.label}
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
        <SidebarBody
          product={currentProduct}
          collapsed={false}
          isActive={isActive}
          onItemClick={() => setMobileOpen(false)}
        />
      </aside>

      {/* Content */}
      <div className="flex-1 flex flex-col h-screen overflow-hidden min-w-0">
        <TopBar onOpenMobileNav={() => setMobileOpen(true)} />
        <main className="flex-1 overflow-y-auto px-4 py-4 sm:px-6 sm:py-5">
          {/* Outlet is rendered directly — wrapping it in AnimatePresence with
              key={location.pathname} caused the destination page to mount
              twice during a route transition (once in the exiting motion.div,
              once in the entering one — both <Outlet /> resolve to the new
              route), firing every page-level useQuery twice. */}
          <Outlet />
        </main>
      </div>
    </div>
  );
};

export default ProductLayout;
