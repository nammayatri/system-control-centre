import { useState } from 'react';
import { Link } from 'react-router-dom';
import { CloudDownload, Plus, Rocket, Search } from 'lucide-react';
import { toast } from 'sonner';
import { useCreateOtaApp, useOtaAccess, useOtaHealth } from '../hooks';
import { useOtaTheme } from '../theme';
import { resolveOrg, useOtaOrg } from '../orgStore';
import { usePermissions } from '../../../core/auth/PermissionsContext';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { Input } from '../../../shared/ui/input';
import {
  Dialog,
  DialogBody,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '../../../shared/ui/dialog';
import { CardSkeleton } from '../../../shared/ui/skeleton';
import { cn } from '../../../lib/utils';
import logoDark from '../assets/airborne-logo-dark.svg';
import logoLight from '../assets/airborne-logo-light.svg';

// Organization Overview — landing page mirroring airborne.juspay.in:
// searchable application cards (selected org only) with an Open action.
export default function OtaAppsHome() {
  const { data, isLoading, error } = useOtaAccess();
  const health = useOtaHealth();
  const { isDark } = useOtaTheme();
  const storedOrg = useOtaOrg();
  const [query, setQuery] = useState('');
  const { userPermissions } = usePermissions();
  const createApp = useCreateOtaApp();
  const [createOpen, setCreateOpen] = useState(false);
  const [newAppName, setNewAppName] = useState('');

  // Upstream is org-scoped and the backend enforces a PRODUCT-level check, so
  // gate on the product-level permission list only — hasPermission() would be
  // looser (it ORs in per-app grants and any-product admin).
  const canCreateApp = (userPermissions?.['airborne-ota'] ?? []).includes('OTA_APP_MANAGE');

  const apps = data?.apps ?? [];
  const orgs = [...new Set(apps.map((a) => a.org).filter(Boolean))].sort();
  const org = resolveOrg(storedOrg, orgs);
  const orgApps = apps.filter((a) => a.org === org);

  const q = query.trim().toLowerCase();
  const filtered = q
    ? orgApps.filter((a) =>
        [a.app, a.org].filter(Boolean).some((v) => String(v).toLowerCase().includes(q)),
      )
    : orgApps;

  return (
    <div className="flex flex-col flex-1 w-full pb-12">
      <div className="mb-5 flex items-start justify-between gap-3">
        <div>
          <img
            src={isDark ? logoDark : logoLight}
            alt="Airborne"
            className="h-7 w-auto mb-3"
          />
          <h1 className="text-xl sm:text-2xl font-bold text-zinc-900 dark:text-zinc-100">
            Organization Overview
          </h1>
          <p className="text-sm text-zinc-500 dark:text-zinc-400 mt-1">
            {org ? (
              <>
                Applications in <span className="font-medium text-zinc-700 dark:text-zinc-300">{org}</span>
                {' — '}switch organisation from the sidebar
              </>
            ) : (
              "Manage your organization's applications and OTA releases"
            )}
          </p>
        </div>
        {(health.data || health.isError) &&
          (() => {
            // Health never throws upstream now — `status` is the signal, so
            // isError alone would read "reachable" during a real outage.
            const status = health.isError ? 'down' : health.data?.status;
            const label =
              status === 'ok'
                ? 'Airborne reachable'
                : status === 'not-configured'
                  ? 'Airborne not configured'
                  : status === 'degraded'
                    ? 'Airborne degraded'
                    : 'Airborne unreachable';
            const ok = status === 'ok';
            return (
              <Badge
                variant={ok ? 'success' : status === 'not-configured' ? 'warning' : 'danger'}
                dot
                className={
                  ok
                    ? 'dark:bg-transparent dark:border-emerald-700 dark:text-emerald-300'
                    : status === 'not-configured'
                      ? 'dark:bg-transparent dark:border-amber-700 dark:text-amber-300'
                      : 'dark:bg-transparent dark:border-red-700 dark:text-red-300'
                }
              >
                {label}
              </Badge>
            );
          })()}
      </div>

      <div className="rounded-xl border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900 p-3 sm:p-4 mb-4 flex items-center gap-3">
        <div className="flex-1 min-w-0">
          <Input
            placeholder="Search applications…"
            icon={<Search className="w-4 h-4" />}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            className="dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-100"
          />
        </div>
        {canCreateApp && (
          <Button
            size="sm"
            className="bg-airborne border-airborne text-white hover:bg-airborne-hover shrink-0"
            onClick={() => {
              setNewAppName('');
              setCreateOpen(true);
            }}
          >
            <Plus className="w-4 h-4" />
            New Application
          </Button>
        )}
      </div>

      {error ? (
        <div className="rounded-xl border border-red-200 bg-red-50 dark:border-red-900 dark:bg-red-950/40 px-4 py-3 text-sm text-red-700 dark:text-red-300">
          Failed to load OTA apps. Refresh to retry.
        </div>
      ) : isLoading ? (
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 sm:gap-4 dark:invert">
          {Array.from({ length: 4 }).map((_, i) => (
            <CardSkeleton key={i} />
          ))}
        </div>
      ) : apps.length === 0 ? (
        <div className="rounded-xl border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900 py-16 px-6 text-center">
          <CloudDownload className="w-10 h-10 text-zinc-300 dark:text-zinc-600 mx-auto mb-3" />
          {data?.upstreamReachable === false ? (
            <>
              <h2 className="text-sm font-semibold text-zinc-700 dark:text-zinc-300">
                Airborne is unreachable
              </h2>
              <p className="text-sm text-zinc-500 dark:text-zinc-400 mt-1 max-w-md mx-auto">
                This is a service outage, not a permissions issue — the app list couldn't be
                loaded. Try again shortly.
              </p>
            </>
          ) : (
            <>
              <h2 className="text-sm font-semibold text-zinc-700 dark:text-zinc-300">No OTA apps available</h2>
              <p className="text-sm text-zinc-500 dark:text-zinc-400 mt-1 max-w-md mx-auto">
                An admin must grant you access to an Airborne app before anything shows up here.
              </p>
            </>
          )}
        </div>
      ) : filtered.length === 0 ? (
        <div className="rounded-xl border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900 py-16 px-6 text-center text-sm text-zinc-500 dark:text-zinc-400">
          No applications match “{query.trim()}”.
        </div>
      ) : (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3 sm:gap-4">
          {filtered.map((a) => (
            <div
              key={a.appRef}
              className="bg-white border border-zinc-200 hover:bg-zinc-100 hover:border-airborne dark:bg-zinc-900 dark:border-zinc-800 dark:hover:bg-airborne-nav dark:hover:border-airborne rounded-xl p-4 sm:p-5 transition-colors duration-150"
            >
              <h3 className="text-base font-semibold text-zinc-900 dark:text-zinc-100 truncate">
                {a.app}
              </h3>
              <p className="text-sm text-zinc-500 dark:text-zinc-400 mt-0.5 truncate">{a.org}</p>
              <div className="flex items-center justify-between mt-6">
                <span className="inline-flex items-center gap-1.5 text-sm text-zinc-500 dark:text-zinc-400">
                  <Rocket className="w-4 h-4" />
                  Releases
                </span>
                <Link
                  to={`/airborne/${encodeURIComponent(a.appRef)}`}
                  className="px-4 h-9 inline-flex items-center rounded-lg bg-airborne hover:bg-airborne-hover text-white text-sm font-medium transition-colors duration-150"
                >
                  Open
                </Link>
              </div>
            </div>
          ))}
        </div>
      )}

      {/* Create application — org-scoped upstream, so the org is the one the
          sidebar has selected. Dialogs portal outside the theme wrapper, so
          re-enter dark scope explicitly. */}
      <Dialog open={createOpen} onOpenChange={setCreateOpen}>
        <DialogContent
          size="md"
          className={cn(isDark && 'dark bg-zinc-900 border-zinc-800 sm:border-zinc-800')}
        >
          <DialogHeader>
            <DialogTitle className="dark:text-zinc-100">New application</DialogTitle>
            <DialogDescription className="dark:text-zinc-400">
              Creates an airborne application in <b>{org || '—'}</b>. Applications cannot be renamed
              or deleted once created.
            </DialogDescription>
          </DialogHeader>
          <DialogBody className="space-y-3">
            <Input
              label="Application name"
              placeholder="myapp"
              value={newAppName}
              onChange={(e) => setNewAppName(e.target.value)}
              required
              className="dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-100"
            />
            <p className="text-xs text-zinc-500 dark:text-zinc-400">
              Lowercase letters, digits, <code>-</code>, <code>_</code> and <code>.</code> only, max
              50 characters. Existing apps may not follow this rule — airborne added the
              restriction later.
            </p>
          </DialogBody>
          <DialogFooter className="dark:bg-zinc-900 dark:border-zinc-800">
            <Button
              variant="secondary"
              className="dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
              onClick={() => setCreateOpen(false)}
            >
              Cancel
            </Button>
            <Button
              variant="primary"
              className="bg-airborne border-airborne text-white hover:bg-airborne-hover"
              loading={createApp.isPending}
              onClick={() => {
                const name = newAppName.trim();
                if (!name) {
                  toast.error('Application name is required');
                  return;
                }
                if (!org) {
                  toast.error('Select an organisation in the sidebar first');
                  return;
                }
                createApp.mutate(
                  { org, app: name },
                  { onSuccess: () => setCreateOpen(false) },
                );
              }}
            >
              Create
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
