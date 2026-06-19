import { createContext, memo, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import {
  Apple,
  Smartphone,
  Search,
  RefreshCw,
  AlertTriangle,
  ChevronRight,
  MonitorSmartphone,
  Zap,
  Info,
} from 'lucide-react';
import { useStoreMonitor } from '../../hooks';
import type { PlatformBlock, StoreMonitorApp, TrackCell } from '../../api';
import { Button } from '../../../../shared/ui/button';
import { TableSkeleton } from '../../../../shared/ui/skeleton';
import { Badge } from '../../../../shared/ui/badge';
import { cn } from '../../../../lib/utils';
import { deriveStoreBadge, activeRolloutOf } from '../../components/storeBadge';
import { RolloutBar } from '../../components/RolloutBar';
import { AppTrackModal } from '../../components/AppTrackModal';
import { MobileBulkPanel } from '../../components/MobileBulkPanel';
import { SURFACE_META, SURFACE_ORDER, surfaceKeyOf, type SurfaceKey } from '../../components/surfaces';
import { useRepollMonitor } from '../../components/useRepollMonitor';

type PlatformName = 'android' | 'ios';

// ── Grouping helpers ───────────────────────────────────────────────

// Brand = the card label minus the "(Surface Platform)" suffix and any trailing
// Partner/Driver — so "Namma Yatri (Customer Android)" and the NammaYatriPartner
// card "Namma Yatri (Driver Android)" both collapse to "Namma Yatri", letting the
// consumer + driver variants sit together under one brand card.
function brandOf(appLabel: string): string {
  const base = appLabel.split(' (')[0].trim();
  return base.replace(/\s*(Partner|Driver)$/i, '').trim() || appLabel;
}

interface BrandGroup {
  brand: string;
  cards: StoreMonitorApp[]; // one per surface (consumer, driver…), surface-ordered
}

function groupByBrand(apps: StoreMonitorApp[]): BrandGroup[] {
  const map = new Map<string, StoreMonitorApp[]>();
  for (const a of apps) {
    const b = brandOf(a.app);
    (map.get(b) ?? map.set(b, []).get(b)!).push(a);
  }
  return [...map.entries()]
    .map(([brand, cards]) => ({
      brand,
      cards: [...cards].sort(
        (x, y) => SURFACE_ORDER.indexOf(surfaceKeyOf(x.surface)) - SURFACE_ORDER.indexOf(surfaceKeyOf(y.surface)),
      ),
    }))
    .sort((a, b) => a.brand.localeCompare(b.brand));
}

interface ActiveRolloutItem {
  brand: string;
  surfaceKey: SurfaceKey;
  platform: PlatformName;
  cell: TrackCell;
  block: PlatformBlock;
  pct: number;
  halted: boolean;
}

// Every production track currently ramping or halted mid-ramp — the headline of
// the page, surfaced in the band up top. Halted first (needs a human), then by
// descending %.
function collectActiveRollouts(apps: StoreMonitorApp[]): ActiveRolloutItem[] {
  const out: ActiveRolloutItem[] = [];
  for (const a of apps) {
    const brand = brandOf(a.app);
    const surfaceKey = surfaceKeyOf(a.surface);
    (['android', 'ios'] as PlatformName[]).forEach((platform) => {
      const block = a.platforms[platform];
      const prod = block?.production ?? null;
      const ar = activeRolloutOf(prod);
      if (block && prod && ar) out.push({ brand, surfaceKey, platform, cell: prod, block, pct: ar.pct, halted: ar.halted });
    });
  }
  return out.sort((x, y) => Number(y.halted) - Number(x.halted) || y.pct - x.pct);
}

const isEmptyCell = (cell: TrackCell | null): boolean => !cell || cell.status === 'none';

const anyRolling = (card: StoreMonitorApp): boolean =>
  (['android', 'ios'] as PlatformName[]).some((p) => activeRolloutOf(card.platforms[p]?.production ?? null) != null);

// ── Freshness ──────────────────────────────────────────────────────

// Single freshness threshold (ms), sourced from the backend's
// `store_refresh_cooldown_seconds` via the store-monitor response and shared down
// the tree by context. Default until the value loads — matches the server default.
const DEFAULT_STALE_MS = 300 * 1000;
const StaleMsContext = createContext(DEFAULT_STALE_MS);

function freshness(syncedAt: string | null, staleMs: number): { label: string; stale: boolean } | null {
  if (!syncedAt) return null;
  const t = new Date(syncedAt).getTime();
  if (isNaN(t)) return null;
  const ageMs = Date.now() - t;
  const mins = Math.max(0, Math.round(ageMs / 60000));
  let label: string;
  if (mins < 1) label = 'just now';
  else if (mins < 60) label = `${mins}m ago`;
  else {
    const hrs = Math.round(mins / 60);
    label = hrs < 24 ? `${hrs}h ago` : `${Math.round(hrs / 24)}d ago`;
  }
  return { label, stale: ageMs > staleMs };
}

function platformSyncedAt(block: PlatformBlock): string | null {
  const stamps = [block.production?.syncedAt, block.internal?.syncedAt, block.testflight?.syncedAt]
    .filter((s): s is string => !!s)
    .map((s) => new Date(s).getTime())
    .filter((n) => !isNaN(n));
  return stamps.length ? new Date(Math.max(...stamps)).toISOString() : null;
}

// ── Small presentational bits ──────────────────────────────────────

function PlatformIcon({ platform }: { platform: PlatformName }) {
  return platform === 'ios'
    ? <Apple className="w-4 h-4 text-zinc-500" />
    : <Smartphone className="w-4 h-4 text-emerald-600" />;
}

function RollingChip() {
  return (
    <span className="inline-flex items-center gap-0.5 rounded-full border border-indigo-200 bg-indigo-50 px-1.5 py-0.5 text-[9px] font-semibold uppercase tracking-wide text-indigo-700">
      <Zap className="w-2.5 h-2.5" /> rolling out
    </span>
  );
}

function DriftChip() {
  return (
    <span
      className="inline-flex items-center gap-0.5 rounded border border-amber-200 bg-amber-50 px-1 py-0.5 text-[9px] font-semibold uppercase tracking-wide text-amber-700"
      title="Store version differs from the last version SCC shipped"
    >
      <AlertTriangle className="w-2.5 h-2.5" /> drift
    </span>
  );
}

function EmptyState({ children }: { children: ReactNode }) {
  return (
    <div className="rounded-xl border border-zinc-200 bg-white py-16 text-center text-sm text-zinc-400">{children}</div>
  );
}

// Shown when the API reports the monitor is off for this deployment (e.g. a debug
// build — no live production store data).
function UnavailableNotice({ reason }: { reason?: string | null }) {
  return (
    <div className="rounded-xl border border-amber-200 bg-amber-50/40 px-6 py-14 text-center">
      <div className="mx-auto mb-3 flex h-10 w-10 items-center justify-center rounded-full bg-amber-100">
        <Info className="h-5 w-5 text-amber-600" />
      </div>
      <p className="text-sm font-semibold text-zinc-800">App Release Monitoring isn’t available here</p>
      <p className="mx-auto mt-1.5 max-w-md text-xs leading-relaxed text-zinc-500">
        {reason ??
          'This deployment is a debug build; the monitor tracks live production store releases, which a debug build does not have.'}
      </p>
    </div>
  );
}

// ── Track / platform / surface / brand ─────────────────────────────

function TrackLine({ label, cell }: { label: string; cell: TrackCell | null }) {
  const empty = isEmptyCell(cell);
  const badge = deriveStoreBadge(empty ? null : cell);
  const ar = empty ? null : activeRolloutOf(cell);

  return (
    <div className="py-2">
      <div className="flex items-center justify-between gap-2">
        <div className="flex min-w-0 items-center gap-2">
          <span className="w-20 shrink-0 truncate text-[10px] font-semibold uppercase tracking-wide text-zinc-400">{label}</span>
          {empty ? (
            <span className="text-sm text-zinc-300">—</span>
          ) : (
            <span className="flex min-w-0 items-center gap-1.5 font-mono text-sm text-zinc-800">
              <span className="truncate">{cell?.version ?? '—'}</span>
              {cell?.buildCode != null && <span className="text-zinc-400">+{cell.buildCode}</span>}
              {cell?.drift === true && <DriftChip />}
            </span>
          )}
        </div>
        <Badge variant={badge.variant}>{badge.label}</Badge>
      </div>
      {ar && <RolloutBar pct={ar.pct} halted={ar.halted} className="mt-1.5" />}
    </div>
  );
}

function PlatformPanel({
  platform,
  block,
  onOpen,
}: {
  platform: PlatformName;
  block: PlatformBlock | null;
  onOpen: () => void;
}) {
  if (!block) {
    return (
      <div className="flex min-h-[92px] flex-1 items-center justify-center rounded-lg border border-dashed border-zinc-200 p-3">
        <span className="text-xs text-zinc-400">No {platform === 'ios' ? 'iOS' : 'Android'}</span>
      </div>
    );
  }

  const secondaryLabel = platform === 'ios' ? 'TestFlight' : 'Internal';
  const secondaryCell = platform === 'ios' ? block.testflight : block.internal;
  const rolling = activeRolloutOf(block.production) != null;
  const fresh = freshness(platformSyncedAt(block), useContext(StaleMsContext));

  return (
    <button
      type="button"
      onClick={onOpen}
      className={cn(
        'group flex-1 rounded-lg border bg-white p-3 text-left transition-all duration-150 hover:shadow-sm',
        rolling ? 'border-indigo-300 ring-1 ring-indigo-100' : 'border-zinc-200 hover:border-zinc-300',
      )}
    >
      <div className="mb-1 flex items-center justify-between gap-2">
        <div className="flex items-center gap-1.5 text-xs font-semibold text-zinc-700">
          <PlatformIcon platform={platform} />
          <span>{platform === 'ios' ? 'iOS' : 'Android'}</span>
        </div>
        <ChevronRight className="h-4 w-4 text-zinc-300 transition-colors group-hover:text-zinc-500" />
      </div>
      <div className="divide-y divide-zinc-100">
        <TrackLine label="Prod" cell={block.production} />
        <TrackLine label={secondaryLabel} cell={secondaryCell} />
      </div>
      {fresh && (
        <div className={cn('mt-2 text-[10px]', fresh.stale ? 'font-medium text-amber-600' : 'text-zinc-400')}>
          synced {fresh.label}
          {fresh.stale ? ' · stale' : ''}
        </div>
      )}
    </button>
  );
}

function SurfaceSection({
  card,
  onOpen,
}: {
  card: StoreMonitorApp;
  onOpen: (platform: PlatformName, block: PlatformBlock) => void;
}) {
  const meta = SURFACE_META[surfaceKeyOf(card.surface)];
  const Icon = meta.Icon;
  return (
    <div>
      <div className="mb-2 flex items-center gap-1.5">
        <Icon className={cn('h-3.5 w-3.5', meta.tint)} />
        <span className="text-xs font-semibold text-zinc-600">{meta.label}</span>
        {anyRolling(card) && <RollingChip />}
      </div>
      <div className="flex flex-col gap-2.5 sm:flex-row">
        <PlatformPanel
          platform="android"
          block={card.platforms.android}
          onOpen={() => card.platforms.android && onOpen('android', card.platforms.android)}
        />
        <PlatformPanel
          platform="ios"
          block={card.platforms.ios}
          onOpen={() => card.platforms.ios && onOpen('ios', card.platforms.ios)}
        />
      </div>
    </div>
  );
}

// Memoised: a full-tree refresh patches the cache per app, and the page re-renders
// on every refresh-progress tick — memo keeps untouched brand cards from re-rendering
// (`onOpen` is stabilised with useCallback at the page, so the props stay equal).
const BrandCard = memo(function BrandCard({
  group,
  onOpen,
}: {
  group: BrandGroup;
  onOpen: (brand: string, surface: SurfaceKey, platform: PlatformName, block: PlatformBlock) => void;
}) {
  const repoll = useRepollMonitor();
  const [refreshing, setRefreshing] = useState(false);
  const rolling = group.cards.some(anyRolling);

  // ↻ → live re-poll every catalog id across this brand's variants (shared bounded
  // re-poll: each fresh card is patched into the ['store-monitor'] cache as it returns).
  const onRefresh = async () => {
    const ids = group.cards
      .flatMap((c) => [c.platforms.android?.appCatalogId, c.platforms.ios?.appCatalogId])
      .filter((id): id is number => id != null);
    if (!ids.length) return;
    setRefreshing(true);
    try {
      const { failed } = await repoll(ids);
      if (failed) toast.error(`Failed to refresh ${failed} variant${failed > 1 ? 's' : ''}`);
    } finally {
      setRefreshing(false);
    }
  };

  return (
    <div className={cn('flex flex-col rounded-xl border bg-white', rolling ? 'border-indigo-200 shadow-sm' : 'border-zinc-200')}>
      <header className="flex items-center justify-between gap-3 border-b border-zinc-100 px-4 py-3">
        <div className="flex min-w-0 items-center gap-2">
          <h3 className="truncate text-sm font-semibold text-zinc-900">{group.brand}</h3>
          {rolling && <RollingChip />}
        </div>
        <Button
          variant="secondary"
          size="icon-sm"
          onClick={onRefresh}
          loading={refreshing}
          aria-label={`Refresh ${group.brand}`}
          title="Live re-poll this app"
        >
          {!refreshing && <RefreshCw className="h-4 w-4" />}
        </Button>
      </header>
      <div className="p-3">
        {group.cards.map((card, i) => (
          <div
            key={`${card.app}-${card.surface}`}
            className={cn(i > 0 && 'mt-3 border-t border-zinc-100 pt-3')}
          >
            <SurfaceSection
              card={card}
              onOpen={(platform, block) => onOpen(group.brand, surfaceKeyOf(card.surface), platform, block)}
            />
          </div>
        ))}
      </div>
    </div>
  );
});

function ActiveRolloutsPanel({
  items,
  onOpen,
}: {
  items: ActiveRolloutItem[];
  onOpen: (brand: string, surface: SurfaceKey, platform: PlatformName, block: PlatformBlock) => void;
}) {
  if (!items.length) return null;
  return (
    <section className="rounded-xl border border-indigo-200 bg-gradient-to-br from-indigo-50/70 to-white p-4">
      <header className="mb-3 flex items-center gap-2">
        <span className="flex h-6 w-6 items-center justify-center rounded-lg bg-indigo-100">
          <Zap className="h-3.5 w-3.5 text-indigo-600" />
        </span>
        <h2 className="text-sm font-semibold text-indigo-900">Active rollouts</h2>
        <Badge variant="info">{items.length}</Badge>
      </header>
      <div className="grid grid-cols-1 gap-2 lg:grid-cols-2">
        {items.map((it, i) => (
          <button
            key={`${it.brand}-${it.surfaceKey}-${it.platform}-${i}`}
            type="button"
            onClick={() => onOpen(it.brand, it.surfaceKey, it.platform, it.block)}
            className="flex items-center gap-3 rounded-lg border border-zinc-200 bg-white px-3 py-2 text-left transition-all hover:border-indigo-300 hover:shadow-sm"
          >
            <PlatformIcon platform={it.platform} />
            <div className="min-w-0 flex-1">
              <div className="truncate text-sm font-medium text-zinc-800">
                {it.brand}
                <span className="mx-1 text-zinc-300">·</span>
                <span className="text-zinc-500">{SURFACE_META[it.surfaceKey].label}</span>
              </div>
              <div className="truncate font-mono text-[11px] text-zinc-500">
                {it.cell.version}
                {it.cell.buildCode != null ? ` +${it.cell.buildCode}` : ''}
              </div>
            </div>
            <RolloutBar pct={it.pct} halted={it.halted} className="w-28 shrink-0 sm:w-36" />
            {it.halted && <Badge variant="warning">Halted</Badge>}
          </button>
        ))}
      </div>
    </section>
  );
}

// ── Page ───────────────────────────────────────────────────────────

export default function StoreMonitor() {
  const { data, isLoading } = useStoreMonitor();
  const apps = useMemo(() => data?.apps ?? [], [data]);
  const unavailable = !!data && !data.available;
  // Single freshness threshold from the backend (store_refresh_cooldown_seconds):
  // drives the cold-start auto-refresh and, via context, the per-card "stale" amber.
  const staleMs = (data?.staleThresholdSeconds ?? 300) * 1000;
  const qc = useQueryClient();
  const repoll = useRepollMonitor();
  const [search, setSearch] = useState('');
  const [refreshingAll, setRefreshingAll] = useState(false);
  const [refreshProgress, setRefreshProgress] = useState<{ done: number; total: number } | null>(null);
  const [modal, setModal] = useState<
    { brand: string; surface: SurfaceKey; platform: PlatformName; block: PlatformBlock } | null
  >(null);

  const groups = useMemo(() => groupByBrand(apps), [apps]);
  const rollouts = useMemo(() => collectActiveRollouts(apps), [apps]);
  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return groups;
    return groups.filter(
      (g) =>
        g.brand.toLowerCase().includes(q) ||
        g.cards.some((c) => c.surface.toLowerCase().includes(q) || c.app.toLowerCase().includes(q)),
    );
  }, [groups, search]);

  // Stable so the memoised BrandCards don't re-render on every page state change
  // (search keystroke, refresh-progress tick, etc.).
  const open = useCallback(
    (brand: string, surface: SurfaceKey, platform: PlatformName, block: PlatformBlock) =>
      setModal({ brand, surface, platform, block }),
    [],
  );

  // Top-right Refresh → LIVE re-poll every app (not just re-read the cache, which is
  // what a plain refetch does) via the shared bounded re-poll, surfacing per-app
  // progress, then reconciling with one authoritative GET.
  const refreshAll = async () => {
    const ids = apps
      .flatMap((a) => [a.platforms.android?.appCatalogId, a.platforms.ios?.appCatalogId])
      .filter((id): id is number => id != null);
    if (!ids.length || refreshingAll) return;
    setRefreshingAll(true);
    setRefreshProgress({ done: 0, total: ids.length });
    try {
      await repoll(ids, (done, total) => setRefreshProgress({ done, total }));
      toast.success('Store data refreshed');
    } finally {
      setRefreshingAll(false);
      setRefreshProgress(null);
      void qc.invalidateQueries({ queryKey: ['store-monitor'] });
    }
  };

  // Cold-start: on first open auto-fire one full refresh ONLY when the cached data
  // is stale (older than the cooldown). Fresh data is shown as-is — a quick re-open
  // serves cache instead of spending Play/ASC edits. Fires once per mount.
  const autoFired = useRef(false);
  useEffect(() => {
    if (autoFired.current || refreshingAll || apps.length === 0) return;
    let latest: string | null = null;
    for (const a of apps)
      for (const blk of [a.platforms.android, a.platforms.ios])
        if (blk)
          for (const cell of [blk.production, blk.internal, blk.testflight])
            if (cell?.syncedAt && (latest === null || cell.syncedAt > latest)) latest = cell.syncedAt;
    if (latest === null || Date.now() - new Date(latest).getTime() > staleMs) {
      autoFired.current = true;
      void refreshAll();
    }
  }, [apps, refreshingAll, staleMs]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <StaleMsContext.Provider value={staleMs}>
    <div className="flex w-full flex-1 flex-col space-y-4 pb-12">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex min-w-0 items-center gap-2">
          <MonitorSmartphone className="h-4 w-4 text-violet-600" />
          <h1 className="text-base font-semibold text-zinc-900 sm:text-lg">App Release Monitoring</h1>
          {!unavailable && (
            <span className="text-xs text-zinc-500">
              {groups.length} {groups.length === 1 ? 'app' : 'apps'} · {apps.length} variants
            </span>
          )}
        </div>
        {!unavailable && (
          <div className="flex items-center gap-2">
            <div className="relative">
              <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-zinc-400" />
              <input
                type="text"
                value={search}
                onChange={(e) => setSearch(e.target.value)}
                placeholder="Search app or surface…"
                className="h-9 w-48 rounded-lg border border-zinc-300 bg-white pl-9 pr-3 text-sm text-zinc-900 transition-shadow placeholder:text-zinc-400 focus:border-transparent focus:outline-none focus:ring-2 focus:ring-zinc-400 sm:w-56"
              />
            </div>
            <Button
              variant="secondary"
              size="sm"
              onClick={() => void refreshAll()}
              loading={refreshingAll}
              title="Live re-poll every app from the stores"
            >
              {!refreshingAll && <RefreshCw className="h-4 w-4" />}
              {refreshingAll && refreshProgress ? `Refreshing ${refreshProgress.done}/${refreshProgress.total}` : 'Refresh'}
            </Button>
          </div>
        )}
      </div>

      {isLoading ? (
        <div className="rounded-xl border border-zinc-200 bg-white">
          <TableSkeleton rows={4} cols={4} />
        </div>
      ) : unavailable ? (
        <UnavailableNotice reason={data?.reason} />
      ) : apps.length === 0 ? (
        <EmptyState>No apps to monitor yet.</EmptyState>
      ) : (
        <>
          <ActiveRolloutsPanel items={rollouts} onOpen={open} />
          <MobileBulkPanel />
          {filtered.length === 0 ? (
            <EmptyState>No apps match “{search}”.</EmptyState>
          ) : (
            <div className="grid grid-cols-1 gap-4 2xl:grid-cols-2">
              {filtered.map((g) => (
                <BrandCard key={g.brand} group={g} onOpen={open} />
              ))}
            </div>
          )}
        </>
      )}

      {modal && (
        <AppTrackModal
          open
          onClose={() => setModal(null)}
          appLabel={modal.brand}
          surface={SURFACE_META[modal.surface].label}
          platform={modal.platform}
          block={modal.block}
        />
      )}
    </div>
    </StaleMsContext.Provider>
  );
}
