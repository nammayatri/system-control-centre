import { useMemo, useState } from 'react';
import { ChevronDown } from 'lucide-react';
import type { APRelease } from '../../api';
import type { AppCatalogEntry, LatestBuild } from '../../types';
import { BrandLogo } from '../../components/BrandLogo';
import { MEMBER_PHASE_CHIP } from '../../components/GroupStageChip';
import { PlatformBadge } from '../../components/PlatformBadge';
import { TableSkeleton } from '../../../../shared/ui/skeleton';
import { formatBuildCode } from '../../utils';
import { cn, formatDate } from '../../../../lib/utils';

// App-first release view styled like the group list: ONE collapsed row per
// app showing its PRIMARY slot (live > in review/approved > internal), with a
// chevron expanding to the three slot rows. The slot-convergence rules
// guarantee at most one active row per slot — this is a pure regroup of the
// releases payload the groups view already fetches.

const SURFACE_LABEL: Record<string, string> = { customer: 'consumer', driver: 'provider' };

type SlotKey = 'live' | 'incoming' | 'internal';

// Precedence order: live > approved/in-review > internal.
const SLOT_DEFS: { key: SlotKey; label: string; phases: string[] }[] = [
  { key: 'live', label: 'Live', phases: ['live', 'rolling_out', 'halted'] },
  { key: 'incoming', label: 'In review', phases: ['in_review', 'approved'] },
  { key: 'internal', label: 'Internal', phases: ['internal_held'] },
];

const phaseOf = (r: APRelease): string => r.release_context?.display_phase ?? '';

const newestFirst = (a: APRelease, b: APRelease) =>
  (b.date_created || '').localeCompare(a.date_created || '');

function slotChip(r: APRelease) {
  const ph = phaseOf(r);
  const base = MEMBER_PHASE_CHIP[ph] ?? { label: ph || '—', cls: 'bg-zinc-100 text-zinc-600 border-zinc-200' };
  // The canonical label carries the live % for a ramp ("Rolling out · 50%").
  const label =
    ['rolling_out', 'halted'].includes(ph) && r.release_context?.display_label
      ? r.release_context.display_label
      : base.label;
  return { label, cls: base.cls };
}

// Chip for the store-truth live fallback — same look as the Live chip, marked
// as store-sourced so it can't be mistaken for an SCC-managed release.
function StoreLiveChip() {
  const base = MEMBER_PHASE_CHIP['live'] ?? { label: 'Live', cls: 'bg-zinc-100 text-zinc-600 border-zinc-200' };
  return (
    <span
      className={cn(
        'inline-flex items-center gap-1.5 text-[10px] sm:text-[11px] font-medium uppercase tracking-wide border rounded-md px-2 py-0.5',
        base.cls,
      )}
    >
      <span className="w-1.5 h-1.5 rounded-full bg-current opacity-70" />
      Live · store
    </span>
  );
}

function PhaseChip({ release, pulsing }: { release: APRelease; pulsing?: boolean }) {
  const chip = slotChip(release);
  return (
    <span
      className={cn(
        'inline-flex items-center gap-1.5 text-[10px] sm:text-[11px] font-medium uppercase tracking-wide border rounded-md px-2 py-0.5',
        chip.cls,
      )}
    >
      <span className={cn('w-1.5 h-1.5 rounded-full bg-current opacity-70', pulsing && 'status-pulse')} />
      {chip.label}
    </span>
  );
}

interface AppSlots {
  app: AppCatalogEntry;
  slots: Record<SlotKey, APRelease | null>;
  primary: APRelease | null; // highest-precedence occupied slot
  count: number;
  // Store-truth fallback for the live slot: what the store cache says is live
  // when no tracker row exists (versions shipped before SCC tracked the app).
  // Display-only — there is no release row/page behind it.
  storeLive: LatestBuild | null;
}

const SLOT_STATUS_BUCKET: Record<string, string> = {
  live: 'completed',
  rolling_out: 'rollout',
  halted: 'rollout',
  in_review: 'review',
  approved: 'approved',
  internal_held: 'promote',
};

export interface AppSlotViewProps {
  apps: AppCatalogEntry[];
  releases: APRelease[];
  loading: boolean;
  filters: { search: string; app: string; surface: string; platform: string; status: string };
  onOpen: (r: APRelease) => void;
}

export function AppSlotView({ apps, releases, loading, filters, onOpen }: AppSlotViewProps) {
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const toggle = (key: string) =>
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });

  const perApp: AppSlots[] = useMemo(() => {
    const byApp = new Map<string, APRelease[]>();
    for (const r of releases) {
      const key = `${r.appGroup}|${r.service}|${r.env}`;
      const arr = byApp.get(key) ?? [];
      arr.push(r);
      byApp.set(key, arr);
    }
    const q = filters.search.trim().toLowerCase();
    const out: AppSlots[] = [];
    for (const app of apps) {
      if (!app.enabled) continue;
      if (filters.app && app.name !== filters.app) continue;
      if (filters.surface && app.surface !== filters.surface) continue;
      if (filters.platform && app.platform !== filters.platform) continue;
      const rows = (byApp.get(`${app.name}|${app.surface}|${app.platform}`) ?? []).sort(newestFirst);
      const slots = Object.fromEntries(
        SLOT_DEFS.map((def) => [def.key, rows.find((r) => def.phases.includes(phaseOf(r))) ?? null]),
      ) as Record<SlotKey, APRelease | null>;
      const occupied = SLOT_DEFS.map((d) => slots[d.key]).filter(Boolean) as APRelease[];
      const storeLive =
        !slots.live && app.latestProdBuild?.version ? app.latestProdBuild : null;
      if (q) {
        const hay = [
          app.name,
          app.displayLabel ?? '',
          storeLive?.version ?? '',
          ...occupied.map((r) => r.new_version ?? ''),
        ]
          .join(' ')
          .toLowerCase();
        if (!hay.includes(q)) continue;
      }
      if (
        filters.status &&
        !occupied.some((r) => SLOT_STATUS_BUCKET[phaseOf(r)] === filters.status) &&
        !(filters.status === 'completed' && storeLive)
      )
        continue;
      out.push({ app, slots, primary: occupied[0] ?? null, count: occupied.length, storeLive });
    }
    const rank = (x: AppSlots) => (x.primary ? 2 : x.storeLive ? 1 : 0);
    return out.sort((a, b) => rank(b) - rank(a) || a.app.name.localeCompare(b.app.name));
  }, [apps, releases, filters]);

  if (loading) {
    return (
      <div className="bg-white rounded-xl border border-zinc-200">
        <TableSkeleton rows={8} cols={6} />
      </div>
    );
  }

  if (perApp.length === 0) {
    return (
      <div className="bg-white rounded-xl border border-zinc-200 py-16 text-center text-sm text-zinc-500">
        No apps match the current filters.
      </div>
    );
  }

  return (
    <div className="bg-white rounded-xl border border-zinc-200 overflow-x-auto">
      <table className="w-full text-left" aria-label="Releases by app">
        <thead>
          <tr className="bg-zinc-50 border-b border-zinc-200 text-[11px] text-zinc-500 font-medium uppercase tracking-wider">
            <th className="py-3 px-4 hidden lg:table-cell w-10">#</th>
            <th className="py-3 px-4">App</th>
            <th className="py-3 px-4 hidden md:table-cell">Surface</th>
            <th className="py-3 px-4">Platform</th>
            <th className="py-3 px-4">Version</th>
            <th className="py-3 px-4">Status</th>
            <th className="py-3 px-4 hidden md:table-cell">Created</th>
            <th className="py-3 px-4 w-16">Actions</th>
          </tr>
        </thead>
        <tbody className="text-sm">
          {perApp.map((row, i) => (
            <AppRow
              key={`${row.app.name}-${row.app.surface}-${row.app.platform}`}
              index={i + 1}
              row={row}
              zebra={i % 2 === 1}
              expanded={expanded.has(`${row.app.name}-${row.app.surface}-${row.app.platform}`)}
              onToggle={() => toggle(`${row.app.name}-${row.app.surface}-${row.app.platform}`)}
              onOpen={onOpen}
            />
          ))}
        </tbody>
      </table>
    </div>
  );
}

function AppRow({
  index,
  row,
  zebra,
  expanded,
  onToggle,
  onOpen,
}: {
  index: number;
  row: AppSlots;
  zebra: boolean;
  expanded: boolean;
  onToggle: () => void;
  onOpen: (r: APRelease) => void;
}) {
  const { app, slots, primary, count, storeLive } = row;
  const panelId = `app-slots-${app.name}-${app.surface}-${app.platform}`.replace(/\s+/g, '-');
  const pulsing = primary != null && ['rolling_out', 'in_review'].includes(phaseOf(primary));
  const expandable = count > 0 || storeLive != null;
  return (
    <>
      <tr
        onClick={() => (expandable ? onToggle() : undefined)}
        className={cn(
          'transition-colors',
          expandable && 'cursor-pointer',
          expanded
            ? 'bg-emerald-50/40 hover:bg-emerald-50/60'
            : cn('border-b border-zinc-100 hover:bg-zinc-50', zebra ? 'bg-zinc-50/50' : 'bg-white'),
        )}
      >
        <td className="py-3 px-4 text-xs text-zinc-400 hidden lg:table-cell">{index}</td>
        <td className="py-3 px-4">
          <span className="inline-flex items-center gap-2 font-medium text-zinc-800">
            {expandable ? (
              <button
                onClick={(e) => {
                  e.stopPropagation();
                  onToggle();
                }}
                aria-expanded={expanded}
                aria-controls={panelId}
                aria-label={expanded ? 'Collapse release slots' : 'Expand release slots'}
                className={cn(
                  'h-6 w-6 -ml-1 flex items-center justify-center rounded-md transition-all',
                  expanded
                    ? 'bg-emerald-100 text-emerald-700 hover:bg-emerald-200'
                    : 'text-zinc-400 hover:bg-zinc-200/60 hover:text-zinc-700',
                )}
              >
                <ChevronDown
                  className={cn('w-4 h-4 transition-transform duration-200', !expanded && '-rotate-90')}
                />
              </button>
            ) : (
              <span className="h-6 w-5 -ml-1" aria-hidden />
            )}
            <BrandLogo brand={app.name} surface={app.surface === 'driver' ? 'driver' : undefined} size="sm" />
            <span className="min-w-0">
              <span className="block truncate">{app.displayLabel || app.name}</span>
            </span>
          </span>
        </td>
        <td className="py-3 px-4 text-xs text-zinc-600 hidden md:table-cell">
          {SURFACE_LABEL[app.surface] ?? app.surface}
        </td>
        <td className="py-3 px-4">
          <PlatformBadge platform={app.platform} isMobile />
        </td>
        <td className="py-3 px-4 font-mono text-xs text-zinc-600 whitespace-nowrap">
          {primary ? (
            <>
              {primary.new_version} {formatBuildCode(primary.release_context?.version_code)}
            </>
          ) : storeLive ? (
            <>
              {storeLive.version} {formatBuildCode(storeLive.versionCode)}
            </>
          ) : (
            '—'
          )}
        </td>
        <td className="py-3 px-4">
          {primary ? (
            <PhaseChip release={primary} pulsing={pulsing} />
          ) : storeLive ? (
            <StoreLiveChip />
          ) : (
            <span className="text-xs text-zinc-400">no active builds</span>
          )}
        </td>
        <td className="py-3 px-4 font-mono text-xs text-zinc-500 whitespace-nowrap hidden md:table-cell">
          {primary ? formatDate(primary.date_created) : '—'}
        </td>
        <td className="py-3 px-4">
          {primary && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                onOpen(primary);
              }}
              className="text-xs text-zinc-600 hover:text-zinc-900 underline"
            >
              Open
            </button>
          )}
        </td>
      </tr>

      {/* Slot sub-rows — same inset-panel pattern as the group expansion. */}
      {expandable && (
        <tr aria-hidden={!expanded} className={cn(!expanded && 'border-0')}>
          <td colSpan={8} className="p-0">
            <div id={panelId} className={cn('expand-panel', expanded && 'open')}>
              <div>
                <div className="mx-4 sm:mx-6 mb-3 mt-1 ml-12 sm:ml-14 rounded-xl border border-zinc-200 bg-white shadow-sm overflow-hidden border-l-[3px] border-l-emerald-300">
                  <div className="px-4 py-2 bg-zinc-50/80 border-b border-zinc-100 flex items-center justify-between">
                    <span className="text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
                      Release slots · live → in review → internal
                    </span>
                    <span className="text-[10px] text-zinc-400">click a slot for its release page</span>
                  </div>
                  <div key={String(expanded)} className="divide-y divide-zinc-100">
                    {SLOT_DEFS.map((def, i) => {
                      const r = slots[def.key];
                      if (!r && def.key === 'live' && storeLive) {
                        // Store-truth fallback: live on the store, but shipped
                        // before SCC tracked this app — no release page behind it.
                        return (
                          <div
                            key={def.key}
                            className={cn(
                              'flex items-center gap-3 px-4 py-2.5',
                              expanded && `animate-fadeInUp stagger-${Math.min(i + 1, 5)}`,
                            )}
                          >
                            <span className="w-20 text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
                              {def.label}
                            </span>
                            <span className="font-mono text-xs text-zinc-600 bg-zinc-100 rounded-md px-2 py-1">
                              {storeLive.version} {formatBuildCode(storeLive.versionCode)}
                            </span>
                            <StoreLiveChip />
                            <span className="ml-auto text-[11px] text-zinc-400 whitespace-nowrap">
                              observed on store · pre-SCC release
                            </span>
                          </div>
                        );
                      }
                      if (!r) {
                        return (
                          <div
                            key={def.key}
                            className="flex items-center gap-3 px-4 py-2.5 text-zinc-300"
                          >
                            <span className="w-20 text-[10px] font-semibold uppercase tracking-wider">
                              {def.label}
                            </span>
                            <span className="text-xs">—</span>
                          </div>
                        );
                      }
                      return (
                        <button
                          key={def.key}
                          type="button"
                          onClick={(e) => {
                            e.stopPropagation();
                            onOpen(r);
                          }}
                          aria-label={`Open ${app.name} ${def.label} release`}
                          className={cn(
                            'group/slot w-full text-left flex items-center gap-3 px-4 py-2.5 cursor-pointer transition-colors hover:bg-emerald-50/40',
                            'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-emerald-400',
                            expanded && `animate-fadeInUp stagger-${Math.min(i + 1, 5)}`,
                          )}
                        >
                          <span className="w-20 text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
                            {def.label}
                          </span>
                          <span className="font-mono text-xs text-zinc-600 bg-zinc-100 rounded-md px-2 py-1">
                            {r.new_version} {formatBuildCode(r.release_context?.version_code)}
                          </span>
                          <PhaseChip release={r} />
                          <span className="ml-auto inline-flex items-center gap-3">
                            <span className="font-mono text-[11px] text-zinc-400 whitespace-nowrap hidden sm:inline">
                              {formatDate(r.date_created)}
                            </span>
                            <span className="text-xs text-zinc-400 group-hover/slot:text-emerald-700 transition-colors whitespace-nowrap">
                              Open →
                            </span>
                          </span>
                        </button>
                      );
                    })}
                  </div>
                </div>
              </div>
            </div>
          </td>
        </tr>
      )}
    </>
  );
}
