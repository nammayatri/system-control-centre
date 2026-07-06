import { useCallback } from 'react';
import { useQueryClient, type QueryClient } from '@tanstack/react-query';
import { mobileApi, type StoreMonitorApp, type StoreMonitorResult } from '../api';

// Live-re-poll concurrency cap — keep store reads bounded so a wide fan-out doesn't
// trip Play / ASC rate limits.
const REPOLL_CONCURRENCY = 4;

// Run async `worker` over `items` with at most `limit` in flight.
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

// Patch fresh cards into the single ['store-monitor'] cache entry, matched by
// (app, surface). The one place that knows the cache shape — used by every re-poll.
function patchMonitorCards(qc: QueryClient, cards: StoreMonitorApp[]): void {
  if (!cards.length) return;
  qc.setQueryData<StoreMonitorResult>(['store-monitor'], (prev) => {
    if (!prev) return prev;
    const byKey = new Map(cards.map((c) => [`${c.app}|${c.surface}`, c]));
    return { ...prev, apps: prev.apps.map((row) => byKey.get(`${row.app}|${row.surface}`) ?? row) };
  });
}

export interface RepollResult {
  ok: number;
  failed: number;
}

/**
 * One shared "live re-poll a set of app_catalog ids → patch each fresh card into
 * the ['store-monitor'] cache" routine, with a single bounded-concurrency + error
 * policy. Per-app errors are isolated (counted, not thrown) so one bad store read
 * never aborts the batch; each fresh card is patched in as it returns. Drives both
 * the page-level "Refresh" and the per-brand ↻.
 */
export function useRepollMonitor() {
  const qc = useQueryClient();
  return useCallback(
    async (ids: number[], onProgress?: (done: number, total: number) => void): Promise<RepollResult> => {
      let done = 0;
      let ok = 0;
      let failed = 0;
      await runPool(ids, REPOLL_CONCURRENCY, async (id) => {
        try {
          const card = await mobileApi.refreshStoreApp(id);
          patchMonitorCards(qc, [card]);
          ok += 1;
        } catch {
          failed += 1;
        } finally {
          done += 1;
          onProgress?.(done, ids.length);
        }
      });
      return { ok, failed };
    },
    [qc],
  );
}
