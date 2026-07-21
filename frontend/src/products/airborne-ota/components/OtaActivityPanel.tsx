import { useState } from 'react';
import { ChevronLeft, ChevronRight } from 'lucide-react';
import { useOtaEvents } from '../hooks';
import type { OtaEvent } from '../types';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { TableSkeleton } from '../../../shared/ui/skeleton';
import { formatDate } from '../../../lib/utils';

const PAGE_SIZE = 10;
const secondaryBtnDark =
  'dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800';

// airborne accepts a change_reason on only four endpoints and hardcodes its
// own everywhere else, so for most mutations this table is the ONLY record of
// who acted. Outcome "unknown" = the upstream call threw mid-flight (an intent
// row): the change may or may not have applied — never render it as a failure.
function OutcomeBadge({ outcome }: { outcome: OtaEvent['outcome'] }) {
  if (outcome === 'ok') {
    return (
      <Badge variant="success" className="dark:bg-transparent dark:border-emerald-700 dark:text-emerald-300">
        ok
      </Badge>
    );
  }
  if (outcome === 'failed') {
    return (
      <Badge variant="danger" className="dark:bg-transparent dark:border-red-700 dark:text-red-300">
        failed
      </Badge>
    );
  }
  return (
    <span title="The upstream call did not complete cleanly — this change may or may not have applied.">
      <Badge variant="warning" className="dark:bg-transparent dark:border-amber-700 dark:text-amber-300">
        unknown
      </Badge>
    </span>
  );
}

export function OtaActivityPanel({ app }: { app: string }) {
  const [page, setPage] = useState(1);
  const { data, isLoading, isFetching, error } = useOtaEvents(app, { page, count: PAGE_SIZE });

  const rows = data?.data ?? [];
  const totalPages = data?.total_pages ?? 1;
  const totalItems = data?.total_items;

  return (
    <div className="bg-white border-zinc-200 dark:bg-zinc-900 dark:border-zinc-800 rounded-xl border">
      <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100 dark:border-zinc-800 flex items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <h2 className="text-sm font-semibold text-zinc-900 dark:text-zinc-100">Activity</h2>
          {totalItems != null && (
            <span className="text-xs text-zinc-500 dark:text-zinc-400">{totalItems}</span>
          )}
        </div>
        <span className="text-xs text-zinc-400 dark:text-zinc-500">
          Changes made through SCC
        </span>
      </header>

      {error ? (
        <div className="px-4 py-6 text-sm text-red-600 dark:text-red-400">
          Failed to load activity. Refresh to retry.
        </div>
      ) : isLoading ? (
        <div className="dark:invert">
          <TableSkeleton rows={4} cols={4} />
        </div>
      ) : rows.length === 0 ? (
        <div className="py-12 text-center text-zinc-400 dark:text-zinc-500 text-sm">
          No changes recorded for this app yet.
        </div>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-left">
            <thead>
              <tr className="bg-zinc-50 border-b border-zinc-200 dark:bg-zinc-800/50 dark:border-zinc-800 text-[11px] text-zinc-500 dark:text-zinc-500 font-medium uppercase tracking-wider">
                <th className="py-3 px-4">When</th>
                <th className="py-3 px-4">Who</th>
                <th className="py-3 px-4">Action</th>
                <th className="py-3 px-4">Result</th>
              </tr>
            </thead>
            <tbody className="text-sm">
              {rows.map((e) => (
                <tr key={e.id} className="border-b border-zinc-100 dark:border-zinc-800">
                  <td className="py-3 px-4 text-zinc-500 dark:text-zinc-400 text-xs whitespace-nowrap">
                    {formatDate(e.createdAt)}
                  </td>
                  <td className="py-3 px-4 text-zinc-700 dark:text-zinc-300 truncate max-w-[16rem]" title={e.actor}>
                    {e.actor}
                  </td>
                  <td className="py-3 px-4">
                    <span className="font-mono text-xs text-zinc-700 dark:text-zinc-300">{e.action}</span>
                    <div
                      className="font-mono text-[11px] text-zinc-400 dark:text-zinc-500 truncate max-w-[22rem]"
                      title={e.endpoint}
                    >
                      {e.endpoint}
                    </div>
                  </td>
                  <td className="py-3 px-4">
                    <OutcomeBadge outcome={e.outcome} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {rows.length > 0 && (
        <footer className="px-4 py-3 sm:px-6 border-t border-zinc-100 dark:border-zinc-800 flex items-center justify-between gap-3">
          <span className="text-xs text-zinc-500 dark:text-zinc-400">
            Page {page} of {Math.max(totalPages, 1)}
            {isFetching && <span className="ml-2 text-zinc-400 dark:text-zinc-500">refreshing…</span>}
          </span>
          <div className="flex items-center gap-2">
            <Button
              variant="secondary"
              size="icon-sm"
              className={secondaryBtnDark}
              disabled={page <= 1}
              onClick={() => setPage((p) => Math.max(1, p - 1))}
              aria-label="Previous page"
            >
              <ChevronLeft className="w-4 h-4" />
            </Button>
            <Button
              variant="secondary"
              size="icon-sm"
              className={secondaryBtnDark}
              disabled={page >= totalPages}
              onClick={() => setPage((p) => p + 1)}
              aria-label="Next page"
            >
              <ChevronRight className="w-4 h-4" />
            </Button>
          </div>
        </footer>
      )}
    </div>
  );
}
