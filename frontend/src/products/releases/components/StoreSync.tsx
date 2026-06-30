import { useCallback } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { RefreshCw, AlertTriangle, Clock } from 'lucide-react';
import { mobileApi } from '../api';
import type { StoreMonitorApp, StoreMonitorResult } from '../api';
import { cn } from '../../../lib/utils';
import { relativeAge } from '../utils';

// Fallback freshness threshold (seconds) until the backend value loads — matches
// the server default of `store_refresh_cooldown_seconds`.
const DEFAULT_STALE_SECONDS = 300;

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

/**
 * Store freshness + on-demand refresh, shared by the monitor, the releases list,
 * and the create page. Reads the `store_status` cache (one GET) and exposes the
 * global last-synced time. `refreshAll` fans out the per-app refresh
 * (cooldown-gated server-side, so rapid mounts / clicks serve cache instead of
 * spending edits). With `auto`, it triggers ONE refresh on mount when the cache is
 * cold (never synced) or stale, so the data populates and stays current on its own.
 */
export function useStoreSync(_opts?: { auto?: boolean }) {
  const qc = useQueryClient();
  const { data } = useQuery<StoreMonitorResult>({
    queryKey: ['store-monitor'],
    queryFn: () => mobileApi.storeMonitor(),
    // The backend self-refreshes on read (a stale cache kicks a detached, coalesced
    // sweep). Poll faster while a sweep is in progress so fresh cells land quickly.
    refetchInterval: (q) => (q.state.data?.refreshing ? 4_000 : 60_000),
  });
  const apps = data?.apps ?? [];
  const available = data?.available ?? false;
  const lastSyncedAt = maxSyncedAt(apps);
  const staleMs = (data?.staleThresholdSeconds ?? DEFAULT_STALE_SECONDS) * 1000;
  const cold = available && apps.length > 0 && lastSyncedAt === null;
  const stale = lastSyncedAt !== null && Date.now() - new Date(lastSyncedAt).getTime() > staleMs;
  // Driven by the backend now — no FE fan-out. A sweep is running (or was just kicked
  // by our read) when this is true.
  const refreshing = data?.refreshing ?? false;

  // ↻ just re-reads (a stale cache re-kicks the sweep server-side) and invalidates the
  // dependent views; the store-monitor poll renders fresh cells as the sweep lands them.
  const refreshAll = useCallback(() => {
    void qc.invalidateQueries({ queryKey: ['store-monitor'] });
    void qc.invalidateQueries({ queryKey: ['releases'] });
    void qc.invalidateQueries({ queryKey: ['mobile', 'apps'] });
  }, [qc]);

  return { available, hasApps: apps.length > 0, lastSyncedAt, cold, stale, refreshing, refreshAll };
}

/**
 * "Store data synced X ago" strip with a Refresh button. With `auto` (default) it
 * refreshes on mount when the cache is cold or stale; pass `auto={false}` to make it
 * display-only with a manual Refresh button (no fetch on open). Renders nothing on a
 * deployment where the monitor is unavailable (e.g. debug builds) or before any apps
 * are known.
 */
export function StoreSyncBanner({ className, auto = true }: { className?: string; auto?: boolean }) {
  const { available, hasApps, lastSyncedAt, cold, stale, refreshing, refreshAll } = useStoreSync({
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
          ? 'Refreshing store data…'
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
