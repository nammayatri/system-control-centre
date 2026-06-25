import React, { useMemo, useState } from 'react';
import { useQueryClient, useMutation } from '@tanstack/react-query';
import { Apple, Package } from 'lucide-react';
import { useMobileApps } from '../../hooks';
import { mobileApi } from '../../api';
import type { AppCatalogEntry, LatestBuild } from '../../types';
import { TableSkeleton } from '../../../../shared/ui/skeleton';
import { cn } from '../../../../lib/utils';
import { groupAppsBySurface, useGroupCollapse, GroupChevron } from '../../components/appGroups';
import { AddAppButton } from '../../components/AddAppModal';
import { toast } from 'sonner';

const AndroidIcon = ({ className }: { className?: string }) => (
  <svg viewBox="0 0 24 24" fill="currentColor" className={className}>
    <path d="M17.6 9.48l1.84-3.18c.16-.31.04-.69-.27-.85a.637.637 0 00-.83.22l-1.88 3.24a11.463 11.463 0 00-8.92 0L5.66 5.67c-.19-.29-.58-.38-.87-.2-.28.18-.37.54-.19.83L6.4 9.48A10.78 10.78 0 003 16h18a10.78 10.78 0 00-3.4-6.52zM8.86 13a.98.98 0 110-1.96.98.98 0 010 1.96zm6.28 0a.98.98 0 110-1.96.98.98 0 010 1.96z"/>
  </svg>
);

const PlatformBadge = ({ platform }: { platform: string }) => {
  if (platform === 'ios') {
    return (
      <span className="inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-zinc-100 text-zinc-700 border border-zinc-300">
        <Apple className="w-3 h-3" />
        iOS
      </span>
    );
  }
  return (
    <span className="inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-[#3DDC84]/15 text-[#1B8A4F] border border-[#3DDC84]/30">
      <AndroidIcon className="w-3 h-3" />
      Android
    </span>
  );
};

const wfShort = (path: string) => {
  const parts = path.split('/');
  return parts[parts.length - 1] || path;
};

// Local toggle — small enough not to deserve its own shared component yet.
function Toggle({
  checked, onChange, disabled,
}: { checked: boolean; onChange: () => void; disabled?: boolean }) {
  return (
    <button
      type="button"
      onClick={onChange}
      disabled={disabled}
      className={cn(
        'relative inline-flex h-6 w-10 items-center rounded-full transition-colors duration-150 cursor-pointer',
        disabled ? 'bg-zinc-200 cursor-not-allowed opacity-60'
          : checked ? 'bg-zinc-900' : 'bg-zinc-300',
      )}
      aria-pressed={checked}
    >
      <span
        className={cn(
          'inline-block h-4 w-4 transform rounded-full bg-white transition-transform duration-150',
          checked ? 'translate-x-5' : 'translate-x-1',
        )}
      />
    </button>
  );
}

const formatShortDate = (d: string) => {
  const date = new Date(d);
  if (isNaN(date.getTime())) return '';
  return date.toLocaleDateString('en-IN', { month: 'short', day: '2-digit', year: '2-digit' });
};

const BuildCell = ({ build, label }: { build?: LatestBuild | null; label: string }) => {
  if (!build) return <span className="text-zinc-300">—</span>;
  return (
    <div className="space-y-0.5">
      <span className={cn(
        'inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium',
        label === 'debug'
          ? 'bg-amber-50 text-amber-700 border border-amber-200'
          : 'bg-emerald-50 text-emerald-700 border border-emerald-200',
      )}>
        <span className="font-mono">v{build.version}</span>
        {build.versionCode != null && <span className="opacity-70">+{build.versionCode}</span>}
      </span>
      {build.completedAt && (
        <div className="text-[10px] text-zinc-400">{formatShortDate(build.completedAt)}</div>
      )}
    </div>
  );
};

export default function MobileAppsAdmin() {
  const { data: rawApps = [], isLoading, error } = useMobileApps();
  const qc = useQueryClient();

  const apps = useMemo(
    () => [...rawApps].sort((a, b) => {
      if (a.enabled !== b.enabled) return a.enabled ? -1 : 1;
      return (a.displayLabel || a.name).localeCompare(b.displayLabel || b.name);
    }),
    [rawApps],
  );

  // Consumer/Provider collapsible groups (shared with the create-release picker).
  const groups = useMemo(() => groupAppsBySurface(apps), [apps]);
  const { isOpen, toggle } = useGroupCollapse();

  const [pendingId, setPendingId] = useState<number | null>(null);

  const patchMutation = useMutation({
    mutationFn: ({ id, body }: { id: number; body: Partial<AppCatalogEntry> }) =>
      mobileApi.patchApp(id, body),
    onMutate: async ({ id }) => setPendingId(id),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['mobile', 'apps'] });
    },
    onError: (err: any) => {
      toast.error(err?.response?.data?.message || err.message || 'Failed to update app');
    },
    onSettled: () => setPendingId(null),
  });

  const onToggle = (app: AppCatalogEntry) => {
    patchMutation.mutate({ id: app.id, body: { enabled: !app.enabled } });
  };

  return (
    <div className="flex flex-col flex-1 w-full pb-12">
      <div className="bg-white rounded-xl border border-zinc-200">
        <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100 flex items-center justify-between gap-3">
          <div className="flex items-center gap-2 min-w-0">
            <Package className="w-4 h-4 text-zinc-500" />
            <h1 className="text-base sm:text-lg font-semibold text-zinc-900">
              Mobile apps
            </h1>
            <span className="text-xs text-zinc-500">{apps.length}</span>
          </div>
          <AddAppButton />
        </header>

        {error ? (
          <div className="px-4 py-6 text-sm text-red-600">
            Failed to load apps. Refresh to retry.
          </div>
        ) : isLoading ? (
          <TableSkeleton rows={5} cols={6} />
        ) : apps.length === 0 ? (
          <div className="py-16 text-center text-zinc-400 text-sm">
            No mobile apps registered yet.
          </div>
        ) : (
          <>
            <div className="hidden md:block">
              <table className="w-full text-left">
                <thead>
                  <tr className="bg-zinc-50 border-b border-zinc-200 text-[11px] text-zinc-500 font-medium uppercase tracking-wider">
                    <th className="py-3 px-4 w-10 text-center">On</th>
                    <th className="py-3 px-4">App</th>
                    <th className="py-3 px-4">Platform</th>
                    <th className="py-3 px-4">Workflows</th>
                    <th className="py-3 px-4">Package</th>
                    <th className="py-3 px-4">Latest Release</th>
                  </tr>
                </thead>
                <tbody className="text-sm">
                  {groups.map((g) => (
                    <React.Fragment key={g.key}>
                      <tr
                        className="bg-zinc-100/70 border-y border-zinc-200 cursor-pointer hover:bg-zinc-100"
                        onClick={() => toggle(g.key)}
                      >
                        <td colSpan={6} className="py-2 px-4">
                          <div className="flex items-center gap-2 text-xs font-semibold uppercase tracking-wider text-zinc-600">
                            <GroupChevron open={isOpen(g.key)} />
                            {g.label}
                            <span className="font-normal normal-case tracking-normal text-zinc-400">
                              {g.apps.length} app{g.apps.length === 1 ? '' : 's'}
                            </span>
                          </div>
                        </td>
                      </tr>
                      {isOpen(g.key) &&
                        g.apps.map((app, i) => (
                          <tr
                            key={app.id}
                            className={cn(
                              'border-b border-zinc-100',
                              !app.enabled && 'opacity-50',
                              i % 2 === 1 ? 'bg-zinc-50' : 'bg-white',
                            )}
                          >
                            <td className="py-3 px-4 text-center">
                              <Toggle
                                checked={app.enabled}
                                onChange={() => onToggle(app)}
                                disabled={pendingId === app.id}
                              />
                            </td>
                            <td className="py-3 px-4">
                              <div className="font-medium text-zinc-800">{app.displayLabel || app.name}</div>
                              <div className="text-[11px] text-zinc-500 mt-0.5">{app.surface}</div>
                            </td>
                            <td className="py-3 px-4">
                              <PlatformBadge platform={app.platform} />
                            </td>
                            <td className="py-3 px-4">
                              <div className="font-mono text-[11px] text-zinc-600" title={app.workflowPath}>
                                {wfShort(app.workflowPath)}
                              </div>
                            </td>
                            <td className="py-3 px-4 font-mono text-[11px] text-zinc-500 max-w-[140px] truncate" title={app.packageName ?? undefined}>
                              {app.packageName ?? '—'}
                            </td>
                            <td className="py-3 px-4"><BuildCell build={app.latestReleaseBuild} label="release" /></td>
                          </tr>
                        ))}
                    </React.Fragment>
                  ))}
                </tbody>
              </table>
            </div>

            <div className="md:hidden">
              {groups.map((g) => (
                <div key={g.key}>
                  <button
                    type="button"
                    onClick={() => toggle(g.key)}
                    className="w-full flex items-center gap-2 px-4 py-2 bg-zinc-100/70 border-y border-zinc-200"
                  >
                    <GroupChevron open={isOpen(g.key)} />
                    <span className="text-xs font-semibold uppercase tracking-wider text-zinc-600">{g.label}</span>
                    <span className="text-xs text-zinc-400">{g.apps.length}</span>
                  </button>
                  {isOpen(g.key) && (
                    <div className="divide-y divide-zinc-100">
                      {g.apps.map((app) => (
                        <div key={app.id} className={cn('p-4 flex items-start justify-between gap-3', !app.enabled && 'opacity-50')}>
                          <div className="min-w-0 flex-1">
                            <div className="text-sm font-medium text-zinc-900 truncate">
                              {app.displayLabel || app.name}
                            </div>
                            <div className="text-xs text-zinc-500 mt-1 flex items-center gap-1.5 flex-wrap">
                              <span>{app.surface}</span>
                              <PlatformBadge platform={app.platform} />
                            </div>
                            <div className="text-[11px] font-mono text-zinc-400 mt-1 truncate" title={app.workflowPath}>
                              {wfShort(app.workflowPath)}
                            </div>
                            {app.packageName && (
                              <div className="text-[11px] font-mono text-zinc-400 truncate">{app.packageName}</div>
                            )}
                            {(app.latestReleaseBuild || app.latestDebugBuild) && (
                              <div className="flex flex-wrap gap-1.5 mt-1.5">
                                {app.latestReleaseBuild && <BuildCell build={app.latestReleaseBuild} label="release" />}
                                {app.latestDebugBuild && <BuildCell build={app.latestDebugBuild} label="debug" />}
                              </div>
                            )}
                          </div>
                          <Toggle
                            checked={app.enabled}
                            onChange={() => onToggle(app)}
                            disabled={pendingId === app.id}
                          />
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              ))}
            </div>
          </>
        )}
      </div>
              <p className="text-xs text-zinc-400 mt-3">
        Toggle <strong>Enabled</strong> to control whether an app shows up on
        the Create Mobile Release page.
      </p>
    </div>
  );
}
