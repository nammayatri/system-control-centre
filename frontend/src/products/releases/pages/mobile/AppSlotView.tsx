import { useEffect, useMemo, useState } from 'react';
import { ChevronDown } from 'lucide-react';
import { AndroidLogoIcon, AppleLogoIcon, ArrowUpRightIcon } from '@phosphor-icons/react';
import type { APRelease } from '../../api';
import type { AppCatalogEntry, LatestBuild } from '../../types';
import { BrandLogo } from '../../components/BrandLogo';
import { MEMBER_PHASE_CHIP } from '../../components/GroupStageChip';
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

// Dead rows keep their stale display_phase (an aborted promote still says
// 'internal_held') — they must never claim a store lane.
const DEAD_STATUS = new Set(['ABORTED', 'USER_ABORTED', 'GCLT_ABORTED', 'DISCARDED', 'REVERTED']);

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
        'inline-flex items-center gap-1.5 text-[10px] font-bold uppercase tracking-wide border rounded-full px-2 py-0.5',
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
        'inline-flex items-center gap-1.5 text-[10px] font-bold uppercase tracking-wide border rounded-full px-2 py-0.5',
        chip.cls,
      )}
    >
      <span className={cn('w-1.5 h-1.5 rounded-full bg-current opacity-70', pulsing && 'animate-pulse motion-reduce:animate-none')} />
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
        SLOT_DEFS.map((def) => [
          def.key,
          rows.find((r) => !DEAD_STATUS.has(r.status) && def.phases.includes(phaseOf(r))) ?? null,
        ]),
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

  // Status filtering targets SLOTS: auto-expand the matching apps so the
  // matching lanes (and their "matches filter" tag) are visible, not hidden
  // behind a chevron — same behavior as the groups view.
  useEffect(() => {
    // Filter cleared → collapse what the filter opened.
    if (!filters.status) {
      setExpanded(new Set());
      return;
    }
    setExpanded(
      new Set(
        perApp
          .filter((row) =>
            SLOT_DEFS.some((def) => {
              const r = row.slots[def.key];
              return r != null && SLOT_STATUS_BUCKET[phaseOf(r)] === filters.status;
            }),
          )
          .map((row) => `${row.app.name}-${row.app.surface}-${row.app.platform}`),
      ),
    );
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [filters.status, filters.app, filters.surface, filters.platform, apps, releases]);

  if (loading) {
    return (
      <div className="card-surface overflow-hidden">
        <TableSkeleton rows={8} cols={6} />
      </div>
    );
  }

  if (perApp.length === 0) {
    return (
      <div className="card-surface py-16 text-center text-sm text-zinc-500">
        No apps match the current filters.
      </div>
    );
  }

  return (
    <div className="card-surface overflow-hidden">
      <div className="overflow-x-auto">
      <table className="w-full text-left" aria-label="Releases by app">
        <thead>
          <tr className="bg-zinc-50 border-b border-zinc-200 text-[10px] text-zinc-500 font-bold uppercase tracking-widest">
            <th className="py-3 pl-4 w-8" />
            <th className="py-3 px-4">App</th>
            <th className="py-3 px-4">Status</th>
            <th className="py-3 px-4">Version</th>
            <th className="py-3 px-4 hidden md:table-cell">Created</th>
            <th className="py-3 px-4 text-right">Open</th>
          </tr>
        </thead>
        <tbody className="text-sm">
          {perApp.map((row, i) => (
            <AppRow
              key={`${row.app.name}-${row.app.surface}-${row.app.platform}`}
              index={i + 1}
              row={row}
              zebra={i % 2 === 1}
              filtersStatus={filters.status}
              expanded={expanded.has(`${row.app.name}-${row.app.surface}-${row.app.platform}`)}
              onToggle={() => toggle(`${row.app.name}-${row.app.surface}-${row.app.platform}`)}
              onOpen={onOpen}
            />
          ))}
        </tbody>
      </table>
      </div>
    </div>
  );
}

function AppRow({
  index,
  row,
  zebra,
  expanded,
  filtersStatus = '',
  onToggle,
  onOpen,
}: {
  index: number;
  row: AppSlots;
  zebra: boolean;
  expanded: boolean;
  filtersStatus?: string;
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
            ? 'bg-violet-50/40 hover:bg-violet-50/60'
            : cn('border-b border-zinc-100 hover:bg-zinc-50', zebra ? 'bg-zinc-50/50' : 'bg-white'),
        )}
      >
        <td className="py-3 pl-4">
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
                'h-6 w-6 -ml-1 flex items-center justify-center rounded-md transition-all cursor-pointer',
                expanded
                  ? 'bg-violet-100 text-violet-700 hover:bg-violet-200'
                  : 'text-zinc-400 hover:bg-zinc-200/60 hover:text-zinc-700',
              )}
            >
              <ChevronDown
                className={cn('w-4 h-4 transition-transform duration-200', !expanded && '-rotate-90')}
              />
            </button>
          ) : (
            <span className="h-6 w-5 -ml-1 inline-block" aria-hidden />
          )}
        </td>
        <td className="py-3 px-4">
          <span className="inline-flex items-center gap-2.5">
            <BrandLogo brand={app.name} surface={app.surface === 'driver' ? 'driver' : undefined} size="sm" />
            <span className="flex flex-col leading-tight min-w-0">
              <span className="font-medium text-zinc-800 truncate">{app.displayLabel || app.name}</span>
              <span className="text-[10px] text-zinc-400 font-medium flex items-center gap-1">
                {SURFACE_LABEL[app.surface] ?? app.surface} ·{' '}
                {app.platform === 'ios' ? (
                  <AppleLogoIcon size={11} weight="fill" className="text-zinc-600" aria-hidden="true" />
                ) : (
                  <AndroidLogoIcon size={11} weight="fill" className="text-emerald-600" aria-hidden="true" />
                )}{' '}
                {app.platform}
              </span>
            </span>
          </span>
        </td>
        <td className="py-3 px-4">
          <span className="inline-flex flex-col gap-1 leading-none">
            <span className="inline-flex items-center gap-1.5 flex-wrap">
              {primary ? (
                <PhaseChip release={primary} pulsing={pulsing} />
              ) : storeLive ? (
                <StoreLiveChip />
              ) : (
                <span className="text-xs text-zinc-400">no active builds</span>
              )}
              {!slots.live && storeLive && primary && (
                <span
                  className="text-[9px] font-mono text-zinc-400 border border-zinc-200 rounded px-1.5 py-0.5"
                  title="Store cache: version live on production"
                >
                  store: v{storeLive.version} live
                </span>
              )}
            </span>
            {primary &&
              primary.env === 'ios' &&
              ['rolling_out', 'halted'].includes(phaseOf(primary)) &&
              primary.release_context?.rollout_percent != null && (
                (() => {
                  const pct = Number(primary.release_context.rollout_percent);
                  const ladder = [1, 2, 5, 10, 20, 50, 100];
                  const idx = ladder.findIndex((p) => p >= pct);
                  const day = idx === -1 ? 7 : idx + 1;
                  return (
                    <span className="inline-flex items-center gap-0.5 pl-1" title={`Apple 7-day phased release — day ${day} of 7 (${pct}%)`}>
                      {ladder.map((p, i) => (
                        <span key={p} className={cn('w-1.5 h-1.5 rounded-full', i < day ? 'bg-sky-500' : 'bg-zinc-200')} />
                      ))}
                      <span className="text-[9px] font-mono text-sky-600 ml-1">{pct}%</span>
                    </span>
                  );
                })()
              )}
            {primary && primary.env !== 'ios' && ['rolling_out', 'halted'].includes(phaseOf(primary)) && primary.release_context?.rollout_percent != null && (
              <span
                className="inline-flex items-center gap-1.5 pl-0.5"
                title={`Staged rollout — ${+Number(primary.release_context.rollout_percent).toFixed(2)}% of users`}
              >
                <span className="w-24 h-1.5 rounded-full bg-zinc-100 overflow-hidden">
                  <span
                    className={cn('block h-full rounded-full', phaseOf(primary) === 'halted' ? 'bg-amber-500' : 'bg-emerald-500')}
                    style={{ width: `${Math.max(2, Math.min(100, Number(primary.release_context.rollout_percent)))}%` }}
                  />
                </span>
                <span className={cn('text-[9px] font-mono', phaseOf(primary) === 'halted' ? 'text-amber-600' : 'text-emerald-600')}>
                  {+Number(primary.release_context.rollout_percent).toFixed(2)}%
                </span>
              </span>
            )}
          </span>
        </td>
        <td className="py-3 px-4 font-mono text-xs font-bold text-zinc-800 whitespace-nowrap">
          {primary ? (
            <>
              {primary.new_version}{' '}
              <span className="text-zinc-400 font-medium">{formatBuildCode(primary.release_context?.version_code)}</span>
            </>
          ) : storeLive ? (
            <>
              {storeLive.version}{' '}
              <span className="text-zinc-400 font-medium">{formatBuildCode(storeLive.versionCode)}</span>
            </>
          ) : (
            '—'
          )}
        </td>
        <td className="py-3 px-4 font-mono text-[11px] text-zinc-500 whitespace-nowrap hidden md:table-cell">
          {primary ? formatDate(primary.date_created) : '—'}
        </td>
        <td className="py-3 px-4 text-right">
          {primary && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                onOpen(primary);
              }}
              title="Open"
              aria-label={`Open ${app.name}`}
              className="text-zinc-400 hover:text-zinc-900 cursor-pointer"
            >
              <ArrowUpRightIcon size={16} weight="bold" aria-hidden="true" />
            </button>
          )}
        </td>
      </tr>

      {/* Slot sub-rows — mockup lane list (violet-edged inset). */}
      {expandable && (
        <tr aria-hidden={!expanded} className={cn(!expanded && 'border-0', expanded && 'bg-zinc-50/60 border-b border-zinc-100')}>
          <td colSpan={6} className="p-0">
            <div id={panelId} className={cn('expand-panel', expanded && 'open')}>
              <div>
                <div className="flex flex-col gap-1.5 pl-1 border-l-2 border-violet-200 ml-6 my-2 mr-4">
                  {SLOT_DEFS.map((def) => {
                    const r = slots[def.key];
                    const laneCls =
                      def.key === 'live'
                        ? 'text-emerald-600'
                        : def.key === 'incoming'
                          ? 'text-violet-600'
                          : 'text-blue-600';
                    const laneLabel = def.key === 'incoming' ? 'Review' : def.label;
                    if (!r && def.key === 'live' && storeLive) {
                      return (
                        <div key={def.key} className="flex items-center gap-3 pl-3 py-1 text-xs">
                          <span className={cn('w-14 text-[9px] font-bold uppercase tracking-wider', laneCls)}>{laneLabel}</span>
                          <span className="font-mono font-medium text-zinc-800">
                            {storeLive.version} {formatBuildCode(storeLive.versionCode)}
                          </span>
                          <StoreLiveChip />
                          <span className="ml-auto text-[10px] text-zinc-400 whitespace-nowrap">
                            observed on store · pre-SCC release
                          </span>
                        </div>
                      );
                    }
                    if (!r) {
                      return (
                        <div key={def.key} className="flex items-center gap-3 pl-3 py-1 text-xs text-zinc-300">
                          <span className="w-14 text-[9px] font-bold uppercase tracking-wider">{laneLabel}</span>
                          <span>—</span>
                        </div>
                      );
                    }
                    const matches = !!filtersStatus && SLOT_STATUS_BUCKET[phaseOf(r)] === filtersStatus;
                    return (
                      <button
                        key={def.key}
                        type="button"
                        onClick={(e) => {
                          e.stopPropagation();
                          onOpen(r);
                        }}
                        aria-label={`Open ${app.name} ${laneLabel} release`}
                        className={cn(
                          'w-full text-left flex items-center gap-3 pl-3 pr-2 py-1 text-xs cursor-pointer transition-colors rounded-md',
                          'hover:bg-violet-50/40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-violet-400',
                          matches && 'bg-violet-50/60',
                        )}
                      >
                        <span className={cn('w-14 text-[9px] font-bold uppercase tracking-wider', laneCls)}>{laneLabel}</span>
                        <span className="font-mono font-medium text-zinc-800">
                          {r.new_version} {formatBuildCode(r.release_context?.version_code)}
                        </span>
                        <PhaseChip release={r} />
                        {matches && <span className="text-[9px] text-violet-600 font-bold uppercase">← matches filter</span>}
                        <span className="ml-auto font-mono text-[10px] text-zinc-400 whitespace-nowrap">
                          {formatDate(r.date_created)}
                        </span>
                        <ArrowUpRightIcon size={13} weight="bold" className="text-zinc-400 shrink-0" aria-hidden="true" />
                      </button>
                    );
                  })}
                </div>
              </div>
            </div>
          </td>
        </tr>
      )}
    </>
  );
}
