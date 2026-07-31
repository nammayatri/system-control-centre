import { Link, useNavigate, useParams } from 'react-router-dom';
import { ArrowRight, Calendar, Rocket, Smartphone } from 'lucide-react';
import type { ReactNode } from 'react';
import { useOtaReleases } from '../hooks';
import { OtaAppHeader } from '../components/OtaAppHeader';
import { OtaStatusBadge } from '../components/OtaStatusBadge';
import { Skeleton } from '../../../shared/ui/skeleton';
import { formatDate } from '../../../lib/utils';
import { usePermissions } from '../../../core/auth/PermissionsContext';
import { OtaErrorState } from '../components/OtaErrorState';

const RECENT_COUNT = 5;

// DD/MM/YYYY, matching the live airborne dashboard's "Last Deploy" format.
const formatDay = (dateStr: string | undefined): string => {
  if (!dateStr) return '—';
  const d = new Date(dateStr);
  if (isNaN(d.getTime())) return '—';
  return d.toLocaleDateString('en-GB', {
    timeZone: 'Asia/Kolkata',
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
  });
};

function StatCard({ icon, label, value }: { icon: ReactNode; label: string; value: ReactNode }) {
  return (
    <div className="bg-white border border-zinc-200 dark:bg-zinc-900 dark:border-zinc-800 rounded-xl p-4 sm:p-5">
      <div className="flex items-center justify-between gap-2">
        <span className="text-sm text-zinc-500 dark:text-zinc-400">{label}</span>
        <span className="text-zinc-400 dark:text-zinc-500">{icon}</span>
      </div>
      <div className="text-2xl font-semibold text-zinc-900 dark:text-zinc-100 mt-2">{value}</div>
    </div>
  );
}

export default function OtaAppOverview() {
  const { app } = useParams<{ app: string }>();
  const navigate = useNavigate();
  const { userPermissions, hasAnyDeploymentAccess } = usePermissions();

  const { data, isLoading, error } = useOtaReleases(app, { page: 1, count: RECENT_COUNT });
  const rows = data?.data ?? [];
  const newest = rows[0];
  const totalReleases = data?.total_items ?? rows.length;

  // OTA bundles ride on the app's native store build — offer a bridge to the
  // Mobile Releases console when the caller can see it. There is no reliable
  // per-app join (the airborne↔mobile slug alignment is convention, not a
  // stored FK), so this links to the console, not a pre-filtered app.
  const canSeeMobile =
    (userPermissions['mobile']?.length ?? 0) > 0 || hasAnyDeploymentAccess('mobile');

  return (
    <div className="flex flex-col flex-1 w-full pb-12 space-y-4">
      <OtaAppHeader app={app!} />

      {canSeeMobile && (
        <Link
          to="/mobile/releases"
          className="inline-flex items-center gap-2 self-start text-xs text-zinc-500 hover:text-airborne dark:text-zinc-400 dark:hover:text-airborne transition-colors"
        >
          <Smartphone className="w-3.5 h-3.5" />
          Manage this app's native store releases in Mobile Releases
          <ArrowRight className="w-3.5 h-3.5" />
        </Link>
      )}

      {error && !data ? (
        <OtaErrorState error={error} what="this app" />
      ) : (
        <>
          {/* Stat cards */}
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 sm:gap-4">
            {isLoading ? (
              <>
                <Skeleton className="h-24 w-full dark:invert" />
                <Skeleton className="h-24 w-full dark:invert" />
              </>
            ) : (
              <>
                <StatCard
                  icon={<Rocket className="w-4 h-4" />}
                  label="Total Releases"
                  value={totalReleases}
                />
                <StatCard
                  icon={<Calendar className="w-4 h-4" />}
                  label="Last Deploy"
                  value={formatDay(newest?.created_at)}
                />
              </>
            )}
          </div>

          {/* Recent releases */}
          <div className="bg-white border border-zinc-200 dark:bg-zinc-900 dark:border-zinc-800 rounded-xl">
            <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100 dark:border-zinc-800">
              <h2 className="text-sm font-semibold text-zinc-900 dark:text-zinc-100">
                Recent Releases
              </h2>
              <p className="text-xs text-zinc-500 dark:text-zinc-400 mt-0.5">
                Latest deployments and their status
              </p>
            </header>

            {isLoading ? (
              <div className="p-4 space-y-2 dark:invert">
                {Array.from({ length: 4 }).map((_, i) => (
                  <Skeleton key={i} className="h-9 w-full" />
                ))}
              </div>
            ) : rows.length === 0 ? (
              <div className="py-16 text-center text-zinc-400 dark:text-zinc-500 text-sm">
                No releases yet for this app.
              </div>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-left">
                  <thead>
                    <tr className="bg-zinc-50 border-b border-zinc-200 dark:bg-zinc-800/50 dark:border-zinc-800 text-[11px] text-zinc-500 dark:text-zinc-500 font-medium uppercase tracking-wider">
                      <th className="py-3 px-4">ID</th>
                      <th className="py-3 px-4">Package</th>
                      <th className="py-3 px-4">Status</th>
                      <th className="py-3 px-4">Created</th>
                    </tr>
                  </thead>
                  <tbody className="text-sm">
                    {rows.slice(0, RECENT_COUNT).map((r, i) => {
                      const id = r.id ? String(r.id) : '';
                      const pkg = r.experiment?.package_version ?? r.package?.version;
                      return (
                        <tr
                          key={id || i}
                          className="border-b border-zinc-100 dark:border-zinc-800 cursor-pointer hover:bg-zinc-50 dark:hover:bg-airborne-nav"
                          onClick={() =>
                            id &&
                            navigate(
                              `/airborne/${encodeURIComponent(app!)}/releases/${encodeURIComponent(id)}`,
                            )
                          }
                        >
                          <td className="py-3 px-4">
                            <span
                              className="font-mono text-xs text-zinc-700 dark:text-zinc-300 truncate block max-w-[180px]"
                              title={id}
                            >
                              {id || '—'}
                            </span>
                          </td>
                          <td className="py-3 px-4 font-mono text-xs text-zinc-700 dark:text-zinc-300">
                            {pkg != null ? String(pkg) : '—'}
                          </td>
                          <td className="py-3 px-4">
                            <OtaStatusBadge status={r.experiment?.status} />
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
          </div>

          {/* Activity panel (SCC audit trail) hidden for now — re-enable by
              restoring <OtaActivityPanel app={app!} /> from components/. */}
        </>
      )}
    </div>
  );
}
