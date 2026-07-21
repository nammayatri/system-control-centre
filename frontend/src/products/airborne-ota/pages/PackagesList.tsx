import { useEffect, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { ChevronLeft, ChevronRight, Plug, Plus, Rocket, Search } from 'lucide-react';
import type { ReactNode } from 'react';
import { useOtaAccess, useOtaPackages } from '../hooks';
import { OtaAppHeader } from '../components/OtaAppHeader';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { Input } from '../../../shared/ui/input';
import { TableSkeleton } from '../../../shared/ui/skeleton';
import { useSearch } from '../../../shared/hooks';

const PAGE_SIZE = 15;

const fieldDark = 'dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-100';
const primaryBtnDark = 'bg-airborne border-airborne text-white hover:bg-airborne-hover';
const secondaryBtnDark =
  'dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800';

// Airborne-dashboard style summary tile: label + icon, big accent number, note.
function StatTile({
  label,
  value,
  note,
  icon,
}: {
  label: string;
  value: ReactNode;
  note?: string;
  icon: ReactNode;
}) {
  return (
    <div className="bg-white border border-zinc-200 dark:bg-zinc-900 dark:border-zinc-800 rounded-xl p-4 sm:p-5">
      <div className="flex items-start justify-between gap-2">
        <span className="text-sm text-zinc-500 dark:text-zinc-400">{label}</span>
        <span className="text-zinc-400 dark:text-zinc-500 shrink-0">{icon}</span>
      </div>
      <div className="text-2xl font-bold text-airborne mt-2 tabular-nums">{value}</div>
      {note && <div className="text-xs text-zinc-500 dark:text-zinc-400 mt-1">{note}</div>}
    </div>
  );
}

export default function PackagesList() {
  const { app } = useParams<{ app: string }>();
  const navigate = useNavigate();
  const [page, setPage] = useState(1);
  const { search, debouncedSearch, setSearch } = useSearch();

  useEffect(() => {
    setPage(1);
  }, [debouncedSearch]);

  const { data, isLoading, isFetching, error } = useOtaPackages(app, {
    page,
    count: PAGE_SIZE,
    search: debouncedSearch || undefined,
  });

  const { data: access } = useOtaAccess();
  const perms = access?.apps.find((a) => a.appRef === app)?.permissions ?? [];
  const canManage = perms.includes('OTA_PACKAGE_MANAGE');

  const rows = data?.data ?? [];
  const totalPages = data?.total_pages ?? 1;

  // Tiles mirror the airborne dashboard exactly, including its quirks: all
  // three are computed from the CURRENT PAGE only, and "Release Usage" is the
  // sum of version numbers (airborne packages/page.tsx:198,211). Kept
  // identical deliberately — do not "fix" these without checking upstream.
  const totalPackageVersions = rows.length;
  const totalFiles = rows.reduce((sum, p) => sum + (p.files?.length ?? 0), 0);
  const releaseUsage = rows.reduce(
    (sum, p) => sum + (typeof p.version === 'number' ? p.version : 0),
    0,
  );

  return (
    <div className="flex flex-col flex-1 w-full pb-12 space-y-4">
      <OtaAppHeader app={app!} title="Packages" />

      {/* Page heading + primary action */}
      <div className="flex items-start justify-between gap-3 flex-wrap">
        <div>
          <h1 className="text-xl sm:text-2xl font-bold text-zinc-900 dark:text-zinc-100">Packages</h1>
          <p className="text-sm text-zinc-500 dark:text-zinc-400 mt-1">
            Bundle files together with properties and metadata
          </p>
        </div>
        {canManage && (
          <Button
            size="sm"
            className={primaryBtnDark}
            onClick={() => navigate(`/airborne/${encodeURIComponent(app!)}/packages/new`)}
          >
            <Plus className="w-4 h-4" />
            Create Package
          </Button>
        )}
      </div>

      {/* Summary tiles */}
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-3 sm:gap-4">
        <StatTile
          label="Total Packages Versions"
          value={isLoading ? '…' : totalPackageVersions.toLocaleString()}
          icon={<Plug className="w-5 h-5" />}
        />
        <StatTile
          label="Total Files"
          value={isLoading ? '…' : totalFiles.toLocaleString()}
          note="across all packages"
          icon={<Plug className="w-5 h-5" />}
        />
        <StatTile
          label="Release Usage"
          value={isLoading ? '…' : releaseUsage.toLocaleString()}
          note="total deployments"
          icon={<Rocket className="w-5 h-5" />}
        />
      </div>

      {/* Search */}
      <div className="rounded-xl border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900 p-3 sm:p-4">
        <Input
          placeholder="Search packages by index file name…"
          icon={<Search className="w-4 h-4" />}
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          className={fieldDark}
        />
      </div>

      {/* Packages table */}
      <div className="bg-white border-zinc-200 dark:bg-zinc-900 dark:border-zinc-800 rounded-xl border">
        <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100 dark:border-zinc-800">
          <h2 className="text-sm font-semibold text-zinc-900 dark:text-zinc-100">
            Packages ({isLoading ? '…' : totalPackageVersions})
          </h2>
          <p className="text-xs text-zinc-500 dark:text-zinc-400 mt-0.5">
            All packages with bundled file identifiers
          </p>
        </header>

        {error && !data ? (
          <div className="px-4 py-6 text-sm text-red-600 dark:text-red-400">
            Failed to load packages. Refresh to retry.
          </div>
        ) : isLoading ? (
          <div className="dark:invert">
            <TableSkeleton rows={6} cols={4} />
          </div>
        ) : rows.length === 0 ? (
          <div className="py-16 text-center text-zinc-400 dark:text-zinc-500 text-sm">
            No packages{debouncedSearch ? ' match the current search' : ' for this app'}.
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left">
              <thead>
                <tr className="bg-zinc-50 border-b border-zinc-200 dark:bg-zinc-800/50 dark:border-zinc-800 text-[11px] text-zinc-500 dark:text-zinc-500 font-medium uppercase tracking-wider">
                  <th className="py-3 px-4 w-32">Tag</th>
                  <th className="py-3 px-4">Index</th>
                  <th className="py-3 px-4 w-24">Version</th>
                  <th className="py-3 px-4 w-28">Files</th>
                </tr>
              </thead>
              <tbody className="text-sm">
                {rows.map((p, i) => (
                  <tr key={i} className="border-b border-zinc-100 dark:border-zinc-800">
                    <td className="py-3 px-4">
                      {p.tag ? (
                        <Badge className="font-mono dark:bg-zinc-800 dark:border-zinc-700 dark:text-zinc-300">
                          {p.tag}
                        </Badge>
                      ) : (
                        <span className="text-xs text-zinc-400 dark:text-zinc-500">—</span>
                      )}
                    </td>
                    <td className="py-3 px-4">
                      <span
                        className="font-mono text-xs text-zinc-700 dark:text-zinc-300 truncate block max-w-[560px]"
                        title={p.index != null ? String(p.index) : undefined}
                      >
                        {p.index != null ? String(p.index) : '—'}
                      </span>
                    </td>
                    <td className="py-3 px-4 font-mono text-xs text-zinc-700 dark:text-zinc-300">
                      {p.version != null ? String(p.version) : '—'}
                    </td>
                    <td className="py-3 px-4 text-zinc-500 dark:text-zinc-400 text-xs whitespace-nowrap">
                      {p.files?.length ?? 0} files
                    </td>
                  </tr>
                ))}
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
