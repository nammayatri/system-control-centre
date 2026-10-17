import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { ChevronLeft, ChevronRight, Plus, Search } from 'lucide-react';
import { useAuth } from '../../../core/auth/AuthContext';
import { usePermissions } from '../../../core/auth/PermissionsContext';
import { Button } from '../../../shared/ui/button';
import { TableSkeleton } from '../../../shared/ui/skeleton';
import { cn, timeAgo } from '../../../lib/utils';
import { DevboxStatusBadge, stageLabel } from '../components/DevboxStatus';
import { useDevboxReleases } from '../hooks';
import { ACTIVE_STATUSES, type StatusFilter } from '../types';

const PAGE_SIZE = 20;
const FILTER_KEY = 'devbox-filter';

const CHIPS: { key: StatusFilter; label: string; count: 'all' | 'running' | 'inProgress' | 'stopped' }[] = [
  { key: 'all', label: 'All', count: 'all' },
  { key: 'running', label: 'Running', count: 'running' },
  { key: 'in_progress', label: 'In progress', count: 'inProgress' },
  { key: 'stopped', label: 'Stopped', count: 'stopped' },
];

function savedFilter(): StatusFilter {
  try {
    const v = localStorage.getItem(FILTER_KEY);
    if (v && CHIPS.some((c) => c.key === v)) return v as StatusFilter;
  } catch {}
  return 'all';
}

function timeLeft(iso: string): string {
  const m = Math.round((new Date(iso).getTime() - Date.now()) / 60_000);
  if (m <= 0) return 'due now';
  const d = Math.floor(m / 1440);
  const h = Math.floor((m % 1440) / 60);
  return `${d ? `${d}d ` : ''}${h}h left`;
}

export default function DevboxReleasesList() {
  const navigate = useNavigate();
  const { user } = useAuth();
  const { hasPermission } = usePermissions();
  const canCreate = hasPermission('devbox', 'DEVBOX_RELEASE_CREATE');
  const [filter, setFilter] = useState<StatusFilter>(savedFilter);
  const [q, setQ] = useState('');
  const [page, setPage] = useState(1);
  const { data, isLoading } = useDevboxReleases(filter, q.trim(), page, PAGE_SIZE);

  const pickFilter = (f: StatusFilter) => {
    setFilter(f);
    setPage(1);
    try {
      localStorage.setItem(FILTER_KEY, f);
    } catch {}
  };

  const email = user?.email;
  const mineActive = (data?.releases ?? []).filter((r) => r.createdBy === email && ACTIVE_STATUSES.includes(r.status)).length;
  const pages = data ? Math.max(1, Math.ceil(data.total / PAGE_SIZE)) : 1;

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-3">
        <div className="min-w-0">
          <h1 className="text-xl font-bold tracking-tight text-zinc-900 dark:text-zinc-100">Devbox Releases</h1>
          <p className="text-sm text-zinc-500">
            Feature branches built and running on a dev-box, with their data, control centre and app builds.
          </p>
        </div>
        <div className="flex-1" />
        {canCreate && (
          <Button onClick={() => navigate('/devbox/releases/new')}>
            <Plus className="h-4 w-4" /> New release
          </Button>
        )}
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <div className="flex flex-wrap gap-1.5" role="group" aria-label="Filter by status">
          {CHIPS.map((c) => (
            <button
              key={c.key}
              type="button"
              aria-pressed={filter === c.key}
              onClick={() => pickFilter(c.key)}
              className={cn(
                'inline-flex items-center gap-2 rounded-full border px-3 py-1 text-sm font-semibold transition-colors cursor-pointer',
                filter === c.key
                  ? 'border-zinc-900 bg-zinc-900 text-white dark:border-zinc-100 dark:bg-zinc-100 dark:text-zinc-900'
                  : 'border-zinc-200 bg-white text-zinc-700 hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300',
              )}
            >
              {c.label}
              <span className="tabular-nums opacity-70">{data?.counts[c.count] ?? '·'}</span>
            </button>
          ))}
        </div>
        <div className="flex-1" />
        {email && canCreate && <span className="text-xs text-zinc-500">Your active releases on this page: {mineActive}</span>}
        <label className="relative">
          <Search className="pointer-events-none absolute left-2.5 top-2.5 h-4 w-4 text-zinc-400" />
          <input
            id="devbox-search"
            type="search"
            value={q}
            onChange={(e) => {
              setQ(e.target.value);
              setPage(1);
            }}
            placeholder="Search branch, name, owner"
            aria-label="Search"
            className="w-60 rounded-lg border border-zinc-200 bg-white py-2 pl-8 pr-3 text-sm dark:border-zinc-700 dark:bg-zinc-900"
          />
        </label>
      </div>

      <div className="overflow-x-auto rounded-xl border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-950">
        {isLoading ? (
          <TableSkeleton rows={6} cols={8} />
        ) : (
          <table className="w-full text-sm">
            <thead className="bg-zinc-50 text-left text-[11px] uppercase tracking-wider text-zinc-500 dark:bg-zinc-900">
              <tr>
                {['Name', 'Backend branch', 'Owner', 'Status', 'Stage', 'Data', 'Dev-box', 'Created', 'Auto-stop'].map((h) => (
                  <th key={h} className="whitespace-nowrap px-3 py-2.5 font-semibold">{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {(data?.releases ?? []).map((r) => (
                <tr
                  key={r.id}
                  onClick={() => navigate(`/devbox/releases/${r.id}`)}
                  className="cursor-pointer border-t border-zinc-100 hover:bg-zinc-50 dark:border-zinc-800 dark:hover:bg-zinc-900"
                >
                  <td className="whitespace-nowrap px-3 py-2.5 font-mono text-xs">{r.workspace}</td>
                  <td className="whitespace-nowrap px-3 py-2.5 font-mono text-xs">{r.backendBranch}</td>
                  <td className="whitespace-nowrap px-3 py-2.5">{r.createdBy.split('@')[0]}</td>
                  <td className="whitespace-nowrap px-3 py-2.5"><DevboxStatusBadge status={r.status} /></td>
                  <td className="whitespace-nowrap px-3 py-2.5 text-zinc-600 dark:text-zinc-400">
                    {r.status === 'STOPPED' ? '—' : r.status === 'FAILED' ? `failed at ${stageLabel(r.stage)}` : stageLabel(r.stage)}
                  </td>
                  <td className="whitespace-nowrap px-3 py-2.5 font-mono text-xs">{r.dataSource} {r.dataVersion ?? ''}</td>
                  <td className="whitespace-nowrap px-3 py-2.5">{r.devboxName?.split('-MS')[0] ?? '—'}</td>
                  <td className="whitespace-nowrap px-3 py-2.5 text-zinc-500">{timeAgo(r.createdAt)}</td>
                  <td className="whitespace-nowrap px-3 py-2.5 text-zinc-500">
                    {ACTIVE_STATUSES.includes(r.status) ? timeLeft(r.expiresAt) : '—'}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        {!isLoading && (data?.releases.length ?? 0) === 0 && (
          <div className="p-8 text-center text-sm text-zinc-500">No devbox releases match this filter.</div>
        )}
      </div>

      {pages > 1 && (
        <div className="flex items-center justify-end gap-2 text-sm text-zinc-500">
          <Button variant="outline" size="sm" disabled={page <= 1} onClick={() => setPage((p) => p - 1)}>
            <ChevronLeft className="h-4 w-4" />
          </Button>
          Page {page} of {pages}
          <Button variant="outline" size="sm" disabled={page >= pages} onClick={() => setPage((p) => p + 1)}>
            <ChevronRight className="h-4 w-4" />
          </Button>
        </div>
      )}
    </div>
  );
}
