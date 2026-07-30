// Fleet Activity — every operation across every app, one day-grouped feed
// (docs/design/fleet-activity-mockup-v1.html). Data: GET /mobile/activity,
// a merged stream of release workflow events + OTA pushes + airborne verbs.
// Category/sentence mapping lives HERE; the endpoint returns raw labels.
import { useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import {
  AndroidLogoIcon,
  AppleLogoIcon,
  ArrowUUpLeftIcon,
  ArrowUpRightIcon,
  BroadcastIcon,
  ChartLineUpIcon,
  CheckCircleIcon,
  CircleNotchIcon,
  DetectiveIcon,
  FlagCheckeredIcon,
  HammerIcon,
  MagnifyingGlassIcon,
  PaperPlaneTiltIcon,
  PulseIcon,
  RobotIcon,
  RocketLaunchIcon,
  StorefrontIcon,
  TagIcon,
  XCircleIcon,
  XIcon,
} from '@phosphor-icons/react';
import { cn } from '../../../../lib/utils';
import { fetchFleetActivity, type FleetActivityRow } from '../../api';
import { useMobileApps } from '../../hooks';
import { fullStamp } from './summary/dates';

type Category = 'build' | 'store' | 'ota' | 'recovery' | 'system';

const CATEGORY_META: Record<Category, { tile: string; icon: React.ReactNode }> = {
  build: { tile: 'bg-amber-50 border-amber-100', icon: <HammerIcon size={13} weight="bold" className="text-amber-600" aria-hidden="true" /> },
  store: { tile: 'bg-emerald-50 border-emerald-100', icon: <StorefrontIcon size={13} weight="bold" className="text-emerald-600" aria-hidden="true" /> },
  ota: { tile: 'bg-violet-50 border-violet-100', icon: <RocketLaunchIcon size={13} weight="fill" className="text-violet-600" aria-hidden="true" /> },
  recovery: { tile: 'bg-red-50 border-red-100', icon: <ArrowUUpLeftIcon size={13} weight="bold" className="text-red-500" aria-hidden="true" /> },
  system: { tile: 'bg-zinc-50 border-zinc-200', icon: <StorefrontIcon size={13} weight="bold" className="text-zinc-500" aria-hidden="true" /> },
};

interface Decoded {
  category: Category;
  sentence: string;
  failed: boolean;
  system: boolean;
  icon?: React.ReactNode;
}

const prettify = (label: string) =>
  label.toLowerCase().replace(/^ota_/, '').replace(/_/g, ' ');

// Raw label → operator sentence + category. Unknown labels degrade to a
// prettified label with a source-derived category — never dropped.
function decode(r: FleetActivityRow): Decoded {
  const a = r.action;
  const d = (r.detail ?? {}) as Record<string, unknown>;
  const failedish = /FAILED|ABORT|CANCEL|REJECT/i.test(a) || !!d.error;

  // OTA pushes
  if (a === 'OTA_PUSH_DISPATCHED' || a === 'OTA_PUSH_RUNNING')
    return { category: 'ota', sentence: `dispatched an OTA bundle push (${d.bump ?? 'patch'})`, failed: false, system: false };
  if (a === 'OTA_PUSH_BUNDLE_PUSHED')
    return {
      category: 'ota',
      sentence: `OTA bundle pushed${r.version ? ` — ${r.version}` : ''}${d.packageVersion != null ? ` (pkg v${d.packageVersion})` : ''}`,
      failed: false,
      system: false,
      icon: <TagIcon size={13} weight="bold" className="text-violet-600" aria-hidden="true" />,
    };
  if (a === 'OTA_PUSH_FAILED')
    return {
      category: 'ota',
      sentence: `OTA bundle push failed${d.error ? ` · ${String(d.error).slice(0, 60)}` : ''}`,
      failed: true,
      system: false,
      icon: <XCircleIcon size={13} weight="fill" className="text-red-500" aria-hidden="true" />,
    };

  // Airborne verbs
  if (a === 'OTA_RAMP') {
    const req = (d.request ?? {}) as Record<string, unknown>;
    const pct = req.trafficPercentage ?? req.traffic_percentage;
    return {
      category: 'ota',
      sentence: pct != null ? `ramped the OTA release to ${pct}%` : 'ramped the OTA release',
      failed: typeof d.status === 'number' && (d.status as number) >= 400,
      system: false,
      icon: <ChartLineUpIcon size={13} weight="bold" className="text-violet-600" aria-hidden="true" />,
    };
  }
  if (a === 'OTA_CONCLUDE')
    return {
      category: 'ota',
      sentence: 'concluded the OTA release to 100%',
      failed: typeof d.status === 'number' && (d.status as number) >= 400,
      system: false,
      icon: <FlagCheckeredIcon size={13} weight="fill" className="text-violet-600" aria-hidden="true" />,
    };
  if (a === 'OTA_DISCARD')
    return { category: 'ota', sentence: 'discarded an OTA release', failed: false, system: false };
  if (a.startsWith('OTA_'))
    return { category: 'ota', sentence: prettify(a), failed: failedish, system: false };

  // Release workflow events
  switch (a) {
    case 'TRACKER_CREATED':
      return { category: 'build', sentence: `created the release draft${r.version ? ` v${r.version}` : ''}`, failed: false, system: false };
    case 'TRACKER_APPROVED':
      return { category: 'build', sentence: 'approved the draft', failed: false, system: false, icon: <CheckCircleIcon size={13} weight="fill" className="text-emerald-600" aria-hidden="true" /> };
    case 'TRACKER_TRIGGERED':
    case 'GH_DISPATCHED':
      return { category: 'build', sentence: 'dispatched the build to CI', failed: false, system: false, icon: <PaperPlaneTiltIcon size={13} weight="bold" className="text-amber-600" aria-hidden="true" /> };
    case 'BUILD_STARTED':
      return { category: 'build', sentence: 'CI build started', failed: false, system: true };
    case 'BUILD_COMPLETED':
      return { category: 'build', sentence: 'CI build completed', failed: false, system: true };
    case 'TAG_PUSHED':
      return { category: 'build', sentence: 'build landed — tag pushed', failed: false, system: true, icon: <TagIcon size={13} weight="bold" className="text-amber-600" aria-hidden="true" /> };
    case 'GH_RUN_CANCELLED':
      return { category: 'recovery', sentence: 'cancelled the CI run', failed: true, system: false };
    case 'STORE_SUBMITTED':
      return { category: 'store', sentence: 'submitted to store review', failed: false, system: false, icon: <PaperPlaneTiltIcon size={13} weight="bold" className="text-emerald-600" aria-hidden="true" /> };
    case 'EXTERNAL_REVIEW_DETECTED':
      return { category: 'store', sentence: 'store review detected out-of-band', failed: false, system: true };
    case 'TRAFFIC_UPDATED':
      return { category: 'store', sentence: 'updated the staged rollout', failed: false, system: false, icon: <ChartLineUpIcon size={13} weight="bold" className="text-emerald-600" aria-hidden="true" /> };
    case 'STORE_BUILD_ADOPTED':
      return { category: 'system', sentence: 'store sync adopted a build uploaded outside SCC', failed: false, system: true };
    case 'CHANGELOG_SLACK_SENT':
      return { category: 'system', sentence: 'changelog posted to Slack', failed: false, system: true };
    case 'CHANGELOG_SLACK_FAILED':
      return { category: 'system', sentence: 'changelog → Slack failed', failed: true, system: true };
    case 'REVERT_TRACKER_CREATED':
    case 'ROLLBACK_REQUESTED':
      return { category: 'recovery', sentence: 'created a revert release', failed: true, system: false };
    case 'ABORT_HANDLED':
      return { category: 'recovery', sentence: 'aborted the release', failed: true, system: false };
    case 'FAILED':
      return { category: 'build', sentence: 'build failed', failed: true, system: true, icon: <XCircleIcon size={13} weight="fill" className="text-red-500" aria-hidden="true" /> };
    case 'COMPLETED':
    case 'SUCCESS':
      return { category: 'store', sentence: 'release completed', failed: false, system: true };
    default:
      return { category: r.source === 'release' ? 'build' : 'ota', sentence: prettify(a), failed: failedish, system: !r.actor };
  }
}

const initialsOf = (email?: string | null) =>
  (email ?? '')
    .split('@')[0]
    .split(/[._-]+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0]?.toUpperCase())
    .join('') || '?';

// Machine attribution for actor-less rows: which subsystem wrote the event —
// the store-sync reconciler (rollout/store heals) or the CI workflow.
const MACHINE_ACTORS = new Set(['store-sync', 'ci', 'system']);
const machineOf = (r: FleetActivityRow): string => {
  const a = r.action.toUpperCase();
  if (
    a.startsWith('ROLLOUT') ||
    a.startsWith('STORE') ||
    a.startsWith('TRAFFIC') ||
    a.startsWith('EXTERNAL_REVIEW') ||
    a === 'COMPLETED' ||
    a === 'SUCCESS'
  )
    return 'store-sync';
  if (a.startsWith('BUILD') || a.startsWith('GH_') || a.startsWith('TAG_') || a.startsWith('OTA_PUSH') || a === 'FAILED')
    return 'ci';
  return 'system';
};

const timeOf = (iso: string) =>
  new Date(iso).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit', hour12: false });

const dayKeyOf = (iso: string) => new Date(iso).toDateString();

const dayLabelOf = (iso: string) => {
  const d = new Date(iso);
  const today = new Date();
  const yesterday = new Date(Date.now() - 86_400_000);
  if (d.toDateString() === today.toDateString()) return `Today · ${d.toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric' })}`;
  if (d.toDateString() === yesterday.toDateString()) return `Yesterday · ${d.toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric' })}`;
  return d.toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric' });
};

const CATEGORY_TABS: { v: '' | Category; label: string; icon: React.ReactNode | null }[] = [
  { v: '', label: 'All', icon: null },
  { v: 'build', label: 'Builds', icon: <HammerIcon size={13} weight="bold" className="text-amber-600" aria-hidden="true" /> },
  { v: 'store', label: 'Store', icon: <StorefrontIcon size={13} weight="bold" className="text-emerald-600" aria-hidden="true" /> },
  { v: 'ota', label: 'OTA', icon: <RocketLaunchIcon size={13} weight="fill" className="text-violet-600" aria-hidden="true" /> },
  { v: 'recovery', label: 'Recovery', icon: <ArrowUUpLeftIcon size={13} weight="bold" className="text-red-500" aria-hidden="true" /> },
];

export default function FleetActivity() {
  const navigate = useNavigate();
  const [search, setSearch] = useState('');
  const [appFilter, setAppFilter] = useState('');
  const [actorFilter, setActorFilter] = useState('');
  const [category, setCategory] = useState<'' | Category>('');
  const [days, setDays] = useState(7);
  const [failuresOnly, setFailuresOnly] = useState(false);
  const [extraRows, setExtraRows] = useState<FleetActivityRow[]>([]);
  // Paging cursor: null = untouched (use page 1's), '' = exhausted.
  const [cursor, setCursor] = useState<string | null>(null);
  const [loadingMore, setLoadingMore] = useState(false);
  const searchRef = useRef<HTMLInputElement>(null);
  const sentinelRef = useRef<HTMLDivElement>(null);
  const loadMoreRef = useRef<() => void>(() => {});
  const { data: apps = [] } = useMobileApps();

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        searchRef.current?.focus();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  const q = useQuery({
    queryKey: ['fleet-activity', days, appFilter, actorFilter, search],
    queryFn: () => fetchFleetActivity({ days, app: appFilter || undefined, actor: actorFilter || undefined, q: search || undefined, limit: 60 }),
    staleTime: 15_000,
    refetchInterval: 60_000,
  });
  // New filterset → drop the accumulated pages.
  useEffect(() => {
    setExtraRows([]);
    setCursor(null);
  }, [days, appFilter, actorFilter, search]);

  const allRows = useMemo(() => [...(q.data?.rows ?? []), ...extraRows], [q.data, extraRows]);
  const decoded = useMemo(() => allRows.map((r) => ({ r, d: decode(r) })), [allRows]);

  const visible = decoded.filter(
    ({ d }) => (!category || d.category === category) && (!failuresOnly || d.failed),
  );

  // Day grouping preserves feed order (already newest-first).
  const dayGroups = useMemo(() => {
    const groups: { key: string; label: string; rows: typeof visible }[] = [];
    for (const item of visible) {
      const key = dayKeyOf(item.r.at);
      const last = groups[groups.length - 1];
      if (last && last.key === key) last.rows.push(item);
      else groups.push({ key, label: dayLabelOf(item.r.at), rows: [item] });
    }
    return groups;
  }, [visible]);

  // Right rail: computed over the LOADED window (honest label below).
  const actorStats = useMemo(() => {
    const counts = new Map<string, number>();
    for (const { r } of decoded) {
      const key = r.actor ?? machineOf(r);
      counts.set(key, (counts.get(key) ?? 0) + 1);
    }
    return [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 5);
  }, [decoded]);
  const categoryStats = useMemo(() => {
    const counts: Record<Category, number> = { build: 0, store: 0, ota: 0, recovery: 0, system: 0 };
    for (const { d } of decoded) counts[d.category]++;
    return counts;
  }, [decoded]);
  const failureCount = decoded.filter(({ d }) => d.failed).length;
  const maxActor = Math.max(1, ...actorStats.map(([, n]) => n));
  const maxCat = Math.max(1, ...Object.values(categoryStats));

  const effectiveCursor = cursor ?? q.data?.nextBefore ?? null;
  const canLoadMore = effectiveCursor !== null && effectiveCursor !== '';
  const loadMore = async () => {
    if (!canLoadMore || loadingMore) return;
    setLoadingMore(true);
    try {
      const page = await fetchFleetActivity({
        days,
        app: appFilter || undefined,
        actor: actorFilter || undefined,
        q: search || undefined,
        before: effectiveCursor,
        limit: 60,
      });
      setExtraRows((prev) => [...prev, ...page.rows]);
      setCursor(page.nextBefore ?? '');
    } finally {
      setLoadingMore(false);
    }
  };

  loadMoreRef.current = () => void loadMore();

  // Older pages load as the sentinel scrolls into view; the button stays as a
  // manual fallback. Observed via a ref so the observer binds once.
  useEffect(() => {
    const el = sentinelRef.current;
    if (!el) return;
    const obs = new IntersectionObserver(
      (entries) => {
        if (entries[0]?.isIntersecting) loadMoreRef.current();
      },
      { rootMargin: '400px' },
    );
    obs.observe(el);
    return () => obs.disconnect();
  }, []);

  const openTarget = (r: FleetActivityRow) => {
    if (r.releaseId) navigate(`/mobile/releases/${r.releaseId}`);
    else if (r.groupId) navigate(`/mobile/groups/${r.groupId}`);
  };

  const todayCount = decoded.filter(({ r }) => dayKeyOf(r.at) === new Date().toDateString()).length;

  return (
    <div className="flex flex-col flex-1 w-full pb-12 gap-5">
      {/* Header */}
      <header className="flex items-start justify-between gap-4 flex-wrap">
        <div>
          <h1 className="text-lg sm:text-xl font-bold tracking-tight text-zinc-900">Fleet Activity</h1>
          <p className="text-xs text-zinc-500 mt-1.5">
            Every operation across every app — who did what, when, and to which build.
          </p>
        </div>
        <span className="hidden sm:flex items-center gap-1.5 text-xs text-zinc-400 mt-1">
          <BroadcastIcon size={14} className="text-emerald-500" aria-hidden="true" /> live · {todayCount} action{todayCount === 1 ? '' : 's'} today
        </span>
      </header>

      {/* Filter toolbar — one row */}
      <section className="card-surface px-3 py-2.5 flex items-center gap-2 flex-nowrap overflow-x-auto stagger-item" style={{ ['--index' as string]: 0 }}>
        <div className="relative">
          <MagnifyingGlassIcon size={15} className="absolute left-3 top-1/2 -translate-y-1/2 text-zinc-400" aria-hidden="true" />
          <input
            ref={searchRef}
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search actions / apps / versions…"
            className="pl-9 pr-12 py-1.5 text-sm border border-zinc-200 rounded-lg w-52 min-w-36 bg-white focus:outline-none focus:ring-2 focus:ring-violet-200 focus:border-violet-400 transition-all"
          />
          <span className="absolute right-2.5 top-1/2 -translate-y-1/2 text-[9px] font-mono text-zinc-400 bg-zinc-100 border border-zinc-200 rounded px-1 py-0.5 pointer-events-none">
            ⌘K
          </span>
        </div>
        <select
          value={appFilter}
          onChange={(e) => setAppFilter(e.target.value)}
          className="text-sm border border-zinc-200 rounded-lg px-2.5 py-1.5 bg-white text-zinc-700 shrink-0 cursor-pointer"
        >
          <option value="">All Apps</option>
          {[...new Set(apps.map((a) => a.name))].map((n) => (
            <option key={n} value={n}>
              {n}
            </option>
          ))}
        </select>
        <div className="rounded-lg border border-zinc-200 bg-zinc-50 p-0.5 inline-flex shrink-0" role="tablist" aria-label="Action category">
          {CATEGORY_TABS.map((o) => (
            <button
              key={o.v}
              role="tab"
              aria-selected={category === o.v}
              onClick={() => setCategory(o.v)}
              className={cn(
                'px-2 py-1 text-xs rounded-md cursor-pointer transition-colors whitespace-nowrap flex items-center gap-1',
                category === o.v
                  ? 'bg-white shadow-sm text-zinc-900 border border-zinc-200 font-bold'
                  : 'text-zinc-500 hover:text-zinc-800 font-medium',
              )}
            >
              {o.icon}
              {o.label}
            </button>
          ))}
        </div>
        <select
          value={days}
          onChange={(e) => setDays(Number(e.target.value))}
          className="text-sm border border-zinc-200 rounded-lg px-2.5 py-1.5 bg-white text-zinc-700 shrink-0 cursor-pointer"
        >
          <option value={1}>Last 24 hours</option>
          <option value={7}>Last 7 days</option>
          <option value={30}>Last 30 days</option>
          <option value={90}>Last 90 days</option>
        </select>
        <label className="inline-flex items-center gap-1.5 text-xs text-zinc-600 font-medium cursor-pointer shrink-0 pl-1">
          <input
            type="checkbox"
            checked={failuresOnly}
            onChange={(e) => setFailuresOnly(e.target.checked)}
            className="rounded border-zinc-300 accent-red-600 w-3.5 h-3.5"
          />{' '}
          Failures only
        </label>
        {q.isFetching && (
          <span className="ml-auto shrink-0 inline-flex items-center gap-1.5 text-[11px] text-violet-600 font-medium">
            <CircleNotchIcon size={13} weight="bold" className="animate-spin" aria-hidden="true" /> syncing…
          </span>
        )}
      </section>

      {/* Active actor filter */}
      {actorFilter && (
        <div className="flex items-center gap-2 text-xs px-1">
          <span className="bg-violet-600 text-white font-bold px-2.5 py-1 rounded-full flex items-center gap-1.5">
            <span className="w-4 h-4 rounded-full bg-white/25 flex items-center justify-center text-[8px] font-bold">
              {initialsOf(actorFilter)}
            </span>
            {actorFilter}
            <button onClick={() => setActorFilter('')} aria-label="Clear actor filter" className="opacity-80 hover:opacity-100 cursor-pointer">
              <XIcon size={11} weight="bold" aria-hidden="true" />
            </button>
          </span>
        </div>
      )}

      <div className="grid grid-cols-1 lg:grid-cols-12 gap-6 items-start">
        {/* Feed */}
        <div className="col-span-1 lg:col-span-7 xl:col-span-8 flex flex-col gap-5">
          {q.isLoading ? (
            <div className="card-surface flex items-center justify-center gap-2 py-16 text-xs text-zinc-500 font-medium">
              <CircleNotchIcon size={16} weight="bold" className="animate-spin text-violet-500" aria-hidden="true" />
              Loading fleet activity…
            </div>
          ) : dayGroups.length === 0 ? (
            <div className="card-surface p-12 text-center stagger-item">
              <DetectiveIcon size={36} weight="duotone" className="text-zinc-300 mx-auto" aria-hidden="true" />
              <p className="text-sm font-bold text-zinc-700 mt-3">Nothing matches these filters</p>
              <p className="text-xs text-zinc-500 mt-1">Try a wider time range, or clear the actor / category filters.</p>
              <button
                onClick={() => {
                  setSearch('');
                  setAppFilter('');
                  setActorFilter('');
                  setCategory('');
                  setFailuresOnly(false);
                }}
                className="mt-4 px-3 py-1.5 text-xs font-bold rounded-lg border border-zinc-200 bg-white text-zinc-700 shadow-sm hover:bg-zinc-50 cursor-pointer"
              >
                Clear filters
              </button>
            </div>
          ) : (
            dayGroups.map((g, gi) => (
              <div key={g.key} className="stagger-item" style={{ ['--index' as string]: Math.min(gi + 1, 5) }}>
                <div className="flex items-center gap-3 mb-2 px-1">
                  <span className="eyebrow">{g.label}</span>
                  <span className="flex-1 h-px bg-zinc-200" />
                  <span className="text-[10px] font-mono text-zinc-400">
                    {g.rows.length} action{g.rows.length === 1 ? '' : 's'}
                  </span>
                </div>
                <div className="card-surface overflow-hidden divide-y divide-zinc-50">
                  {g.rows.map(({ r, d }) => {
                    const meta = CATEGORY_META[d.category];
                    return (
                      <button
                        key={r.id}
                        type="button"
                        onClick={() => openTarget(r)}
                        className={cn(
                          'w-full text-left flex items-center gap-3 px-4 py-2.5 text-xs transition-colors cursor-pointer',
                          d.failed ? 'bg-red-50/30 hover:bg-red-50/50' : 'hover:bg-zinc-50',
                          d.system && !d.failed && 'opacity-70',
                        )}
                        style={d.failed ? { boxShadow: 'inset 3px 0 0 #ef4444' } : undefined}
                        title={fullStamp(r.at)}
                      >
                        <span className="font-mono text-[10px] text-zinc-400 w-10 shrink-0">{timeOf(r.at)}</span>
                        {r.actor ? (
                          <span
                            className="w-6 h-6 rounded-full bg-zinc-100 border border-zinc-200 flex items-center justify-center text-[9px] font-bold text-zinc-600 shrink-0"
                            title={r.actor}
                          >
                            {initialsOf(r.actor)}
                          </span>
                        ) : (
                          <span
                            className="w-6 h-6 rounded-full bg-zinc-50 border border-dashed border-zinc-300 flex items-center justify-center shrink-0"
                            title="System"
                          >
                            <RobotIcon size={12} className="text-zinc-400" aria-hidden="true" />
                          </span>
                        )}
                        <span
                          className={cn(
                            'shrink-0 font-medium truncate max-w-48 hidden sm:inline',
                            r.actor ? 'text-zinc-600' : 'text-zinc-400',
                          )}
                          title={r.actor ?? `Automated — written by ${machineOf(r)}`}
                        >
                          {r.actor ?? machineOf(r)}
                        </span>
                        <span className={cn('w-6 h-6 rounded-lg border flex items-center justify-center shrink-0', meta.tile)}>
                          {d.icon ?? meta.icon}
                        </span>
                        <span className={cn('min-w-0 truncate', d.failed ? 'text-zinc-700' : 'text-zinc-700')}>
                          {d.sentence}
                        </span>
                        <span className="ml-auto flex items-center gap-2 shrink-0">
                          {r.app && (
                            <span className="bg-zinc-100 border border-zinc-200 text-zinc-700 font-mono text-[9px] font-semibold px-1.5 py-px rounded inline-flex items-center gap-1">
                              {r.platform === 'ios' ? (
                                <AppleLogoIcon size={9} weight="fill" aria-hidden="true" />
                              ) : r.platform === 'android' ? (
                                <AndroidLogoIcon size={9} weight="fill" className="text-emerald-600" aria-hidden="true" />
                              ) : null}
                              {r.app}
                            </span>
                          )}
                          {r.version && <span className="font-mono text-[10px] text-zinc-400">v{r.version}</span>}
                          {(r.releaseId || r.groupId) && (
                            <ArrowUpRightIcon size={13} weight="bold" className="text-zinc-300" aria-hidden="true" />
                          )}
                        </span>
                      </button>
                    );
                  })}
                </div>
              </div>
            ))
          )}

          {/* Scroll sentinel — crossing it (400px early) pulls the next page. */}
          <div ref={sentinelRef} className="h-px" aria-hidden="true" />
          {canLoadMore && dayGroups.length > 0 ? (
            <button
              onClick={() => void loadMore()}
              disabled={loadingMore}
              className="mx-auto px-4 py-2 text-xs font-bold rounded-lg border border-zinc-200 bg-white text-zinc-600 shadow-sm hover:bg-zinc-50 transition-colors cursor-pointer disabled:opacity-50 inline-flex items-center gap-1.5"
            >
              {loadingMore && <CircleNotchIcon size={13} weight="bold" className="animate-spin" aria-hidden="true" />}
              {loadingMore ? 'Loading older activity…' : 'Load older activity'}
            </button>
          ) : dayGroups.length > 0 ? (
            <p className="mx-auto text-[10px] text-zinc-400 font-medium">
              You&apos;re all caught up — end of the {days === 1 ? '24-hour' : `${days}-day`} window.
            </p>
          ) : null}
        </div>

        {/* Right rail */}
        <div className="col-span-1 lg:col-span-5 xl:col-span-4 flex flex-col gap-5">
          <div className="card-surface p-4 stagger-item" style={{ ['--index' as string]: 2 }}>
            <span className="eyebrow">Most active · loaded window</span>
            <div className="flex flex-col divide-y divide-zinc-50 mt-2">
              {actorStats.map(([actor, n]) => {
                const machine = MACHINE_ACTORS.has(actor);
                return (
                  <button
                    key={actor}
                    onClick={() => !machine && setActorFilter(actorFilter === actor ? '' : actor)}
                    className={cn(
                      'flex items-center gap-2.5 py-2 text-xs rounded-md px-1 transition-colors',
                      machine ? 'opacity-70 cursor-default' : 'hover:bg-zinc-50 cursor-pointer',
                      actorFilter === actor && 'bg-violet-50/70',
                    )}
                  >
                    {machine ? (
                      <span className="w-6 h-6 rounded-full bg-zinc-50 border border-dashed border-zinc-300 flex items-center justify-center">
                        <RobotIcon size={12} className="text-zinc-400" aria-hidden="true" />
                      </span>
                    ) : (
                      <span className="w-6 h-6 rounded-full bg-zinc-100 border border-zinc-200 flex items-center justify-center text-[9px] font-bold text-zinc-600">
                        {initialsOf(actor)}
                      </span>
                    )}
                    <span className="text-zinc-700 font-medium truncate">{actor === 'ci' ? 'ci · workflow' : actor}</span>
                    <span className="ml-auto flex items-center gap-2">
                      <span className="w-20 h-1.5 rounded-full bg-zinc-100 overflow-hidden">
                        <span
                          className={cn('block h-full rounded-full', machine ? 'bg-zinc-300' : 'bg-violet-500')}
                          style={{ width: `${Math.max(6, (n / maxActor) * 100)}%` }}
                        />
                      </span>
                      <span className="font-mono text-[10px] text-zinc-500 w-6 text-right">{n}</span>
                    </span>
                  </button>
                );
              })}
              {actorStats.length === 0 && <p className="py-2 text-xs text-zinc-400">No activity in this window.</p>}
            </div>
            <p className="text-[9px] text-zinc-400 mt-2">click an actor to filter the feed</p>
          </div>

          <div className="card-surface p-4 stagger-item" style={{ ['--index' as string]: 3 }}>
            <span className="eyebrow">Action mix · loaded window</span>
            <div className="flex flex-col gap-2 mt-2.5 text-xs">
              {(
                [
                  ['ota', 'OTA', 'bg-violet-500'],
                  ['store', 'Store', 'bg-emerald-500'],
                  ['build', 'Builds', 'bg-amber-500'],
                  ['recovery', 'Recovery', 'bg-red-500'],
                  ['system', 'System', 'bg-zinc-300'],
                ] as [Category, string, string][]
              ).map(([key, label, bar]) => (
                <div key={key} className="flex items-center gap-2">
                  <span className="w-4 flex justify-center">{CATEGORY_META[key].icon}</span>
                  <span className="text-zinc-600 w-16">{label}</span>
                  <span className="flex-1 h-1.5 rounded-full bg-zinc-100 overflow-hidden">
                    <span className={cn('block h-full rounded-full', bar)} style={{ width: `${Math.max(2, (categoryStats[key] / maxCat) * 100)}%` }} />
                  </span>
                  <span className="font-mono text-[10px] text-zinc-500 w-6 text-right">{categoryStats[key]}</span>
                </div>
              ))}
            </div>
            <div className="mt-3 pt-2.5 border-t border-zinc-100 flex items-center justify-between text-[10px]">
              <span className="text-zinc-500 font-medium">Failures</span>
              <span className={cn('font-mono font-bold', failureCount > 0 ? 'text-red-600' : 'text-zinc-700')}>
                {failureCount} <span className="text-zinc-400 font-medium font-sans">of {decoded.length} loaded</span>
              </span>
            </div>
          </div>

          <p className="text-[10px] text-zinc-400 px-1 leading-relaxed stagger-item" style={{ ['--index' as string]: 4 }}>
            <PulseIcon size={11} className="inline mr-1 text-violet-400" aria-hidden="true" />
            Sourced from release workflow events, OTA pushes and airborne mutations. System rows
            (CI, store sync) are shown muted; rail stats cover the loaded window only.
          </p>
        </div>
      </div>
    </div>
  );
}
