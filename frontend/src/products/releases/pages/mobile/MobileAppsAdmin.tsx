import { useState } from 'react';
import { useQueryClient, useMutation } from '@tanstack/react-query';
import { Apple, Cpu, Package } from 'lucide-react';
import { useMobileApps } from '../../hooks';
import { mobileApi } from '../../api';
import type { AppCatalogEntry } from '../../types';
import { TableSkeleton } from '../../../../shared/ui/skeleton';
import { cn } from '../../../../lib/utils';
import { toast } from 'sonner';

const PlatformIcon = ({ platform }: { platform: string }) =>
  platform === 'ios'
    ? <Apple className="w-4 h-4 text-zinc-500" />
    : <Cpu className="w-4 h-4 text-emerald-600" />;

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

export default function MobileAppsAdmin() {
  const { data: apps = [], isLoading, error } = useMobileApps();
  const qc = useQueryClient();

  // Track per-row in-flight state so multiple rapid toggles don't race; the
  // server is the source of truth, we just optimistically reflect the new
  // value while the patch is in flight.
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
          {/* Add-app modal deferred — entries can be seeded via SQL or a
              future modal hooked to mobileApi.createApp. */}
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
            <div className="hidden md:block overflow-x-auto">
              <table className="w-full text-left whitespace-nowrap">
                <thead>
                  <tr className="bg-zinc-50 border-b border-zinc-200 text-[11px] text-zinc-500 font-medium uppercase tracking-wider">
                    <th className="py-3 px-4">Name</th>
                    <th className="py-3 px-4">Surface</th>
                    <th className="py-3 px-4">Platform</th>
                    <th className="py-3 px-4">Repo</th>
                    <th className="py-3 px-4">Workflow</th>
                    <th className="py-3 px-4">Package</th>
                    <th className="py-3 px-4 w-24 text-center">Enabled</th>
                  </tr>
                </thead>
                <tbody className="text-sm">
                  {apps.map((app, i) => (
                    <tr
                      key={app.id}
                      className={cn(
                        'border-b border-zinc-100',
                        i % 2 === 1 ? 'bg-zinc-50' : 'bg-white',
                      )}
                    >
                      <td className="py-3 px-4 font-medium text-zinc-800">
                        {app.displayLabel || app.name}
                      </td>
                      <td className="py-3 px-4 text-xs text-zinc-600">{app.surface}</td>
                      <td className="py-3 px-4">
                        <span className="inline-flex items-center gap-1.5 text-xs text-zinc-600">
                          <PlatformIcon platform={app.platform} /> {app.platform}
                        </span>
                      </td>
                      <td className="py-3 px-4 font-mono text-xs text-zinc-600">{app.githubRepo}</td>
                      <td className="py-3 px-4 font-mono text-xs text-zinc-500">{app.workflowPath}</td>
                      <td className="py-3 px-4 font-mono text-xs text-zinc-500">{app.packageName ?? '—'}</td>
                      <td className="py-3 px-4 text-center">
                        <Toggle
                          checked={app.enabled}
                          onChange={() => onToggle(app)}
                          disabled={pendingId === app.id}
                        />
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            <div className="md:hidden divide-y divide-zinc-100">
              {apps.map((app) => (
                <div key={app.id} className="p-4 flex items-start justify-between gap-3">
                  <div className="min-w-0 flex-1">
                    <div className="text-sm font-medium text-zinc-900 truncate">
                      {app.displayLabel || app.name}
                    </div>
                    <div className="text-xs text-zinc-500 mt-0.5 flex items-center gap-1.5 flex-wrap">
                      <span>{app.surface}</span>
                      <span className="inline-flex items-center gap-1">
                        <PlatformIcon platform={app.platform} /> {app.platform}
                      </span>
                    </div>
                    <div className="text-[11px] font-mono text-zinc-500 mt-1 truncate">{app.githubRepo}</div>
                    <div className="text-[11px] font-mono text-zinc-400 truncate">{app.workflowPath}</div>
                    {app.packageName && (
                      <div className="text-[11px] font-mono text-zinc-400 truncate">{app.packageName}</div>
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
