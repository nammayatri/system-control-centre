import { useCallback, useEffect, useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { RefreshCw, AlertTriangle, Clock } from 'lucide-react';
import { mobileApi } from '../api';
import type { StoreMonitorApp, StoreMonitorResult } from '../api';
import { cn } from '../../../lib/utils';

// Fallback freshness threshold (seconds) until the backend value loads — matches
// the server default of `store_refresh_cooldown_seconds`.
const DEFAULT_STALE_SECONDS = 300;

// Run `worker` over `items` with at most `limit` in flight — bounded so a cold
// start doesn't fire N parallel store reads at once (Play / ASC rate limits).
async function runPool<T>(items: T[], limit: number, worker: (item: T) => Promise<void>): Promise<void> {
  let cursor = 0;
  const runners = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (cursor < items.length) {
      const i = cursor++;
      await worker(items[i]);
    }
  });
  await Promise.all(runners);
}

// The latest sync time across every track cell of every app — the global
// "store data last synced" timestamp.
function maxSyncedAt(apps: StoreMonitorApp[]): string | null {
  let max: string | null = null;
  for (const a of apps) {
    for (const blk of [a.platforms.android, a.platforms.ios]) {
      if (!blk) continue;
      for (const cell of [blk.production, blk.internal, blk.testflight]) {
        if (cell?.syncedAt && (max === null || cell.syncedAt > max)) max = cell.syncedAt;
      }
    }
  }
  return max;
}

function appIds(apps: StoreMonitorApp[]): number[] {
  return apps
    .flatMap((a) => [a.platforms.android?.appCatalogId, a.platforms.ios?.appCatalogId])
    .filter((x): x is number => x != null);
}

export function relativeAge(iso: string | null): string {
  if (!iso) return 'never';
  const s = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
  if (s < 60) return `${s}s ago`;
  const m = Math.round(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h}h ago`;
  return `${Math.round(h / 24)}d ago`;
}

/**
 * Store freshness + on-demand refresh, shared by the monitor, the releases list,
 * and the create page. Reads the `store_status` cache (one GET) and exposes the
 * global last-synced time. `refreshAll` fans out the per-app refresh
 * (cooldown-gated server-side, so rapid mounts / clicks serve cache instead of
 * spending edits). With `auto`, it triggers ONE refresh on mount when the cache is
 * cold (never synced) or stale, so the data populates and stays current on its own.
 */
export function useStoreSync(opts?: { auto?: boolean }) {
  const qc = useQueryClient();
  const { data } = useQuery<StoreMonitorResult>({
    queryKey: ['store-monitor'],
    queryFn: () => mobileApi.storeMonitor(),
    refetchInterval: 60_000,
  });
  const apps = data?.apps ?? [];
  const available = data?.available ?? false;
  const lastSyncedAt = maxSyncedAt(apps);
  const staleMs = (data?.staleThresholdSeconds ?? DEFAULT_STALE_SECONDS) * 1000;
  const cold = available && apps.length > 0 && lastSyncedAt === null;
  const stale = lastSyncedAt !== null && Date.now() - new Date(lastSyncedAt).getTime() > staleMs;

  const [refreshing, setRefreshing] = useState(false);
  const [progress, setProgress] = useState<{ done: number; total: number } | null>(null);

  const refreshAll = useCallback(async () => {
    const ids = appIds(apps);
    if (!ids.length || refreshing) return;
    setRefreshing(true);
    let done = 0;
    setProgress({ done, total: ids.length });
    try {
      await runPool(ids, 4, async (id) => {
        try {
          await mobileApi.refreshStoreApp(id);
        } catch {
          // one app's store error shouldn't abort the rest
        } finally {
          done += 1;
          setProgress({ done, total: ids.length });
        }
      });
    } finally {
      setRefreshing(false);
      setProgress(null);
      // A refresh updates store_status + the release_tracker synthetic rows + the
      // create-page track metadata — refresh all three readers.
      void qc.invalidateQueries({ queryKey: ['store-monitor'] });
      void qc.invalidateQueries({ queryKey: ['releases'] });
      void qc.invalidateQueries({ queryKey: ['mobile', 'apps'] });
    }
  }, [apps, refreshing, qc]);

  // Cold-start: fire ONCE per mount when the cache is empty or stale.
  const fired = useRef(false);
  useEffect(() => {
    if (opts?.auto && !fired.current && available && apps.length > 0 && (cold || stale) && !refreshing) {
      fired.current = true;
      void refreshAll();
    }
  }, [opts?.auto, available, apps.length, cold, stale, refreshing, refreshAll]);

  return { available, hasApps: apps.length > 0, lastSyncedAt, cold, stale, refreshing, progress, refreshAll };
}

/**
 * "Store data synced X ago" strip with a Refresh button. With `auto` (default) it
 * refreshes on mount when the cache is cold or stale; pass `auto={false}` to make it
 * display-only with a manual Refresh button (no fetch on open). Renders nothing on a
 * deployment where the monitor is unavailable (e.g. debug builds) or before any apps
 * are known.
 */
export function StoreSyncBanner({ className, auto = true }: { className?: string; auto?: boolean }) {
  const { available, hasApps, lastSyncedAt, cold, stale, refreshing, progress, refreshAll } = useStoreSync({
    auto,
  });
  if (!available || !hasApps) return null;
  const amber = cold || stale;
  return (
    <div
      className={cn(
        'flex items-center justify-between gap-3 rounded-lg border px-3 py-2 text-xs',
        amber ? 'border-amber-200 bg-amber-50 text-amber-800' : 'border-zinc-200 bg-zinc-50 text-zinc-600',
        className,
      )}
    >
      <span className="flex items-center gap-1.5">
        {amber ? <AlertTriangle className="h-3.5 w-3.5 shrink-0" /> : <Clock className="h-3.5 w-3.5 shrink-0" />}
        {refreshing
          ? `Refreshing store data${progress ? ` ${progress.done}/${progress.total}` : ''}…`
          : cold
            ? 'Store data not synced yet — fetching the latest from the stores'
            : `Store data synced ${relativeAge(lastSyncedAt)}${stale ? ' — may be outdated' : ''}`}
      </span>
      <button
        type="button"
        onClick={() => void refreshAll()}
        disabled={refreshing}
        className="flex shrink-0 items-center gap-1 rounded-md border border-current/30 px-2 py-1 font-medium hover:bg-white/60 disabled:opacity-50"
      >
        <RefreshCw className={cn('h-3.5 w-3.5', refreshing && 'animate-spin')} />
        Refresh
      </button>
    </div>
  );
}
