import { useMemo, useState, type ReactNode } from 'react';
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
  User,
  Car,
  Zap,
  Info,
} from 'lucide-react';
import { useStoreMonitor } from '../../hooks';
import { mobileApi } from '../../api';
import type { PlatformBlock, StoreMonitorApp, StoreMonitorResult, TrackCell } from '../../api';
import { Button } from '../../../../shared/ui/button';
import { TableSkeleton } from '../../../../shared/ui/skeleton';
import { Badge } from '../../../../shared/ui/badge';
import { cn } from '../../../../lib/utils';
import { deriveStoreBadge, activeRolloutOf } from '../../components/storeBadge';
import { RolloutBar } from '../../components/RolloutBar';
import { AppTrackModal } from '../../components/AppTrackModal';

type PlatformName = 'android' | 'ios';
type SurfaceKey = 'consumer' | 'driver' | 'other';

// ── Grouping helpers ───────────────────────────────────────────────

// Brand = the card label minus the "(Surface Platform)" suffix and any trailing
// Partner/Driver — so "Namma Yatri (Customer Android)" and the NammaYatriPartner
// card "Namma Yatri (Driver Android)" both collapse to "Namma Yatri", letting the
// consumer + driver variants sit together under one brand card.
function brandOf(appLabel: string): string {
  const base = appLabel.split(' (')[0].trim();
  return base.replace(/\s*(Partner|Driver)$/i, '').trim() || appLabel;
}

function surfaceKeyOf(surface: string): SurfaceKey {
  const s = surface.toLowerCase();
  if (s === 'customer' || s === 'consumer') return 'consumer';
  if (s === 'driver' || s === 'provider' || s === 'partner') return 'driver';
  return 'other';
}

const SURFACE_META: Record<SurfaceKey, { label: string; Icon: typeof User; tint: string }> = {
  consumer: { label: 'Consumer', Icon: User, tint: 'text-sky-600' },
  driver: { label: 'Driver', Icon: Car, tint: 'text-emerald-600' },
  other: { label: 'Other', Icon: User, tint: 'text-zinc-500' },
};

const SURFACE_ORDER: SurfaceKey[] = ['consumer', 'driver', 'other'];

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

// Run async `worker` over `items` with at most `limit` in flight. The "refresh
// all" button uses this to live re-poll every app without firing N parallel
// store reads at once (Play / ASC rate limits).
async function runPool<T>(items: T[], limit: number, worker: (item: T) => Promise<void>): Promise<void> {
  let cursor = 0;
  const runners = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (cursor < items.length) {
      const idx = cursor++;
      await worker(items[idx]);
    }
  });
  await Promise.all(runners);
}

// ── Freshness ──────────────────────────────────────────────────────

const STALE_MS = 30 * 60 * 1000; // amber once older than the default poll cadence

function freshness(syncedAt: string | null): { label: string; stale: boolean } | null {
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
  return { label, stale: ageMs > STALE_MS };
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
          <span className="w-10 shrink-0 text-[10px] font-semibold uppercase tracking-wider text-zinc-400">{label}</span>
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
  const fresh = freshness(platformSyncedAt(block));

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

function BrandCard({
  group,
  onOpen,
}: {
  group: BrandGroup;
  onOpen: (brand: string, surface: SurfaceKey, platform: PlatformName, block: PlatformBlock) => void;
}) {
  const qc = useQueryClient();
  const [refreshing, setRefreshing] = useState(false);
  const rolling = group.cards.some(anyRolling);

  // ↻ → live re-poll every catalog id across this brand's variants, then patch
  // each returned card back into the single ['store-monitor'] cache entry.
  const onRefresh = async () => {
    const ids = group.cards
      .flatMap((c) => [c.platforms.android?.appCatalogId, c.platforms.ios?.appCatalogId])
      .filter((id): id is number => id != null);
    if (!ids.length) return;
    setRefreshing(true);
    try {
      const fresh = await Promise.all(ids.map((id) => mobileApi.refreshStoreApp(id)));
      qc.setQueryData<StoreMonitorResult>(['store-monitor'], (prev) => {
        if (!prev) return prev;
        const byKey = new Map(fresh.map((f) => [`${f.app}|${f.surface}`, f]));
        return { ...prev, apps: prev.apps.map((row) => byKey.get(`${row.app}|${row.surface}`) ?? row) };
      });
    } catch (err: any) {
      toast.error(err?.response?.data?.message || err.message || 'Failed to refresh app');
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
}

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
  const qc = useQueryClient();
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

  const open = (brand: string, surface: SurfaceKey, platform: PlatformName, block: PlatformBlock) =>
    setModal({ brand, surface, platform, block });

  // Top-right Refresh → LIVE re-poll every app (not just re-read the cache, which
  // is what a plain refetch does). Fans out the per-app refresh endpoint with
  // bounded concurrency, patching each fresh card into the grid as it returns,
  // then reconciles with one authoritative GET. One app's store error is skipped,
  // not fatal.
  const refreshAll = async () => {
    const ids = apps
      .flatMap((a) => [a.platforms.android?.appCatalogId, a.platforms.ios?.appCatalogId])
      .filter((id): id is number => id != null);
    if (!ids.length || refreshingAll) return;
    setRefreshingAll(true);
    let done = 0;
    setRefreshProgress({ done, total: ids.length });
    try {
      await runPool(ids, 4, async (id) => {
        try {
          const card = await mobileApi.refreshStoreApp(id);
          qc.setQueryData<StoreMonitorResult>(['store-monitor'], (prev) =>
            prev
              ? {
                  ...prev,
                  apps: prev.apps.map((row) =>
                    row.app === card.app && row.surface === card.surface ? card : row,
                  ),
                }
              : prev,
          );
        } catch {
          // skip this app — a single store read failing shouldn't abort the rest
        } finally {
          done += 1;
          setRefreshProgress({ done, total: ids.length });
        }
      });
      toast.success('Store data refreshed');
    } finally {
      setRefreshingAll(false);
      setRefreshProgress(null);
      void qc.invalidateQueries({ queryKey: ['store-monitor'] });
    }
  };

  return (
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
  );
}
