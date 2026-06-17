import React from 'react';
import { ChevronDown } from 'lucide-react';
import type { AppCatalogEntry } from '../types';
import { cn } from '../../../lib/utils';

// Apps are grouped by `surface` into Consumer / Provider sections on both the
// create-release picker and the /mobile/apps admin. Surface is the raw DB value
// ('customer' | 'driver'); we relabel it for display only.
export type SurfaceKey = AppCatalogEntry['surface'];

export const SURFACE_LABEL: Record<SurfaceKey, string> = {
  customer: 'Consumer',
  driver: 'Provider',
};

const SURFACE_ORDER: SurfaceKey[] = ['customer', 'driver'];

export type AppSurfaceGroup = {
  key: SurfaceKey;
  label: string;
  apps: AppCatalogEntry[];
};

/** Partition apps into ordered Consumer→Provider groups, dropping empty ones.
 *  Preserves the incoming order within each group (callers pre-sort). */
export function groupAppsBySurface(apps: AppCatalogEntry[]): AppSurfaceGroup[] {
  return SURFACE_ORDER.map((key) => ({
    key,
    label: SURFACE_LABEL[key],
    apps: apps.filter((a) => a.surface === key),
  })).filter((g) => g.apps.length > 0);
}

/** Collapse-state hook: every group open by default, toggle by surface key. */
export function useGroupCollapse() {
  const [closed, setClosed] = React.useState<Partial<Record<SurfaceKey, boolean>>>({});
  const isOpen = (key: SurfaceKey) => !closed[key];
  const toggle = (key: SurfaceKey) =>
    setClosed((s) => ({ ...s, [key]: !s[key] }));
  return { isOpen, toggle };
}

/** A chevron that points down when open, right when collapsed. */
export const GroupChevron = ({ open }: { open: boolean }) => (
  <ChevronDown
    className={cn('w-4 h-4 text-zinc-400 transition-transform', !open && '-rotate-90')}
  />
);

/** Collapsible section with a clickable header — used by the create-release
 *  picker and the admin mobile cards (the admin desktop table uses a native
 *  header row instead). */
export function CollapsibleGroup({
  label,
  count,
  badge,
  open,
  onToggle,
  children,
}: {
  label: string;
  count: number;
  badge?: React.ReactNode;
  open: boolean;
  onToggle: () => void;
  children: React.ReactNode;
}) {
  return (
    <div className="rounded-lg border border-zinc-200 overflow-hidden">
      <button
        type="button"
        onClick={onToggle}
        className="w-full flex items-center gap-2 px-3 py-2 bg-zinc-50 hover:bg-zinc-100 transition-colors"
      >
        <GroupChevron open={open} />
        <span className="text-xs font-semibold uppercase tracking-wider text-zinc-600">
          {label}
        </span>
        <span className="text-xs text-zinc-400">{count}</span>
        {badge && <span className="ml-auto">{badge}</span>}
      </button>
      {open && <div className="p-2 sm:p-3 bg-white">{children}</div>}
    </div>
  );
}
