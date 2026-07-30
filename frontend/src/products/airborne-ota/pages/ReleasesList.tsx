import { useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { ChevronLeft, ChevronRight, Copy, Plus } from 'lucide-react';
import { toast } from 'sonner';
import { useOtaAccess, useOtaReleases } from '../hooks';
import { OtaAppHeader } from '../components/OtaAppHeader';
import { OtaStatusBadge } from '../components/OtaStatusBadge';
import { Button } from '../../../shared/ui/button';
import { SelectInput } from '../../../shared/ui/input';
import { TableSkeleton } from '../../../shared/ui/skeleton';
import { cn, copyToClipboard, formatDate } from '../../../lib/utils';

const STATUS_OPTIONS = [
  { value: '', label: 'All statuses' },
  { value: 'CREATED', label: 'Created' },
  { value: 'INPROGRESS', label: 'In progress' },
  { value: 'CONCLUDED', label: 'Concluded' },
  { value: 'DISCARDED', label: 'Discarded' },
];

const PAGE_SIZE = 15;

const primaryBtnDark = 'bg-airborne border-airborne text-white hover:bg-airborne-hover';
const secondaryBtnDark =
  'dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800';

function CopyableId({ id }: { id: string }) {
  return (
    <span className="inline-flex items-center gap-1.5 min-w-0">
      <span className="font-mono text-xs text-zinc-700 dark:text-zinc-300 truncate max-w-[140px]" title={id}>
        {id.length > 14 ? `${id.slice(0, 14)}…` : id}
      </span>
      <button
        type="button"
        className="p-1 rounded text-zinc-400 hover:text-zinc-700 hover:bg-zinc-100 dark:text-zinc-500 dark:hover:text-zinc-200 dark:hover:bg-zinc-800 cursor-pointer shrink-0"
        onClick={(e) => {
          e.stopPropagation();
          copyToClipboard(id);
          toast.success('Release id copied');
        }}
        aria-label="Copy release id"
      >
        <Copy className="w-3.5 h-3.5" />
      </button>
    </span>
  );
}

export default function ReleasesList() {
  const { app } = useParams<{ app: string }>();
  const navigate = useNavigate();
  const [status, setStatus] = useState('');
  const [page, setPage] = useState(1);

  const { data, isLoading, isFetching, error } = useOtaReleases(app, {
    page,
    count: PAGE_SIZE,
    status: status || undefined,
  });

  const { data: access } = useOtaAccess();
  const perms = access?.apps.find((a) => a.appRef === app)?.permissions ?? [];
  const canCreate = perms.includes('OTA_RELEASE_CREATE');

  const rows = data?.data ?? [];
  const totalPages = data?.total_pages ?? 1;
  const totalItems = data?.total_items;

  return (
    <div className="flex flex-col flex-1 w-full pb-12 space-y-4">
      <OtaAppHeader app={app!} title="Releases" />

      <div className="bg-white border-zinc-200 dark:bg-zinc-900 dark:border-zinc-800 rounded-xl border">
        <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100 dark:border-zinc-800 flex items-center justify-between gap-3">
          <div className="flex items-center gap-2">
            <h2 className="text-sm font-semibold text-zinc-900 dark:text-zinc-100">Releases</h2>
            {totalItems != null && <span className="text-xs text-zinc-500 dark:text-zinc-400">{totalItems}</span>}
          </div>
          <div className="flex items-center gap-2">
            <div className="w-44">
              <SelectInput
                aria-label="Filter by status"
                options={STATUS_OPTIONS}
                value={status}
                onChange={(e) => {
                  setStatus(e.target.value);
                  setPage(1);
                }}
                className="dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-100"
              />
            </div>
            {canCreate && (
              <Button
                size="sm"
                className={primaryBtnDark}
                onClick={() => navigate(`/airborne/${encodeURIComponent(app!)}/releases/new`)}
              >
                <Plus className="w-4 h-4" />
                New Release
              </Button>
            )}
          </div>
        </header>

        {error && !data ? (
          <div className="px-4 py-6 text-sm text-red-600 dark:text-red-400">
            Failed to load releases. Refresh to retry.
          </div>
        ) : isLoading ? (
          <div className="dark:invert">
            <TableSkeleton rows={6} cols={4} />
          </div>
        ) : rows.length === 0 ? (
          <div className="py-16 text-center text-zinc-400 dark:text-zinc-500 text-sm">
            No releases{status ? ` with status ${status}` : ''} for this app.
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left">
              <thead>
                <tr className="bg-zinc-50 border-b border-zinc-200 dark:bg-zinc-800/50 dark:border-zinc-800 text-[11px] text-zinc-500 dark:text-zinc-500 font-medium uppercase tracking-wider">
                  <th className="py-3 px-4">Release ID</th>
                  <th className="py-3 px-4">Status</th>
                  <th className="py-3 px-4">Traffic</th>
                  <th className="py-3 px-4">Package Version</th>
                  <th className="py-3 px-4">Created</th>
                </tr>
              </thead>
              <tbody className="text-sm">
                {rows.map((r, i) => {
                  const id = r.id ? String(r.id) : '';
                  // A concluded release rolls out to 100%; every other state
                  // shows the raw ramp (matches the airborne dashboard).
                  const st = r.experiment?.status
                    ? String(r.experiment.status).toUpperCase()
                    : undefined;
                  const rawTraffic = r.experiment?.traffic_percentage;
                  const traffic =
                    st === 'CONCLUDED'
                      ? 100
                      : typeof rawTraffic === 'number'
                        ? rawTraffic
                        : undefined;
                  const pkgVersion = r.experiment?.package_version ?? r.package?.version;
                  return (
                    <tr
                      key={id || i}
                      className={cn(
                        'border-b border-zinc-100 dark:border-zinc-800 cursor-pointer hover:bg-zinc-50 dark:hover:bg-airborne-nav',
                      )}
                      onClick={() =>
                        id &&
                        navigate(
                          `/airborne/${encodeURIComponent(app!)}/releases/${encodeURIComponent(id)}`,
                        )
                      }
                    >
                      <td className="py-3 px-4">{id ? <CopyableId id={id} /> : '—'}</td>
                      <td className="py-3 px-4">
                        <OtaStatusBadge status={r.experiment?.status} />
                      </td>
                      <td className="py-3 px-4 text-zinc-700 dark:text-zinc-300">
                        {typeof traffic === 'number' ? `${traffic}%` : '—'}
                      </td>
                      <td className="py-3 px-4 font-mono text-xs text-zinc-700 dark:text-zinc-300">
                        {pkgVersion != null ? String(pkgVersion) : '—'}
                      </td>
                      <td className="py-3 px-4 text-zinc-500 dark:text-zinc-400 text-xs whitespace-nowrap">
                        {formatDate(r.created_at)}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}

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
              disabled={data?.total_pages != null ? page >= totalPages : rows.length < PAGE_SIZE}
              onClick={() => setPage((p) => p + 1)}
              aria-label="Next page"
            >
              <ChevronRight className="w-4 h-4" />
            </Button>
          </div>
        </footer>
      </div>
    </div>
  );
}
