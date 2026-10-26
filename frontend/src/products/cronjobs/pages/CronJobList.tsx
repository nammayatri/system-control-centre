import { useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { Plus, RefreshCw, Search } from 'lucide-react';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { Card } from '../../../shared/ui/card';
import { TableSkeleton } from '../../../shared/ui/skeleton';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { cn } from '../../../lib/utils';
import { useRefreshAnimation } from '../../../shared/hooks';
import { errorMessage } from '../api';
import { useCronJobs } from '../hooks';
import { fmtTime, relTime, shortImage } from '../format';
import { useNamespaceParam } from '../useNamespaceParam';

const select = 'h-9 rounded-lg border border-zinc-300 bg-white px-3 text-sm focus:border-zinc-500 focus:outline-none';

export default function CronJobList() {
  const { namespace, setNamespace, namespaces } = useNamespaceParam();
  const { data, isLoading, isFetching, refetch, error } = useCronJobs(namespace);
  const { spinning, onRefresh } = useRefreshAnimation(isFetching, refetch);
  const [search, setSearch] = useState('');
  const navigate = useNavigate();

  const rows = useMemo(() => (data ?? []).filter((c) => c.name.toLowerCase().includes(search.toLowerCase())), [data, search]);
  const open = (name: string) => navigate(`/backend/cronjobs/${encodeURIComponent(name)}?namespace=${encodeURIComponent(namespace)}`);

  return (
    <div className="space-y-4 p-4 sm:p-6">
      <div className="flex flex-wrap items-center gap-3">
        <div>
          <h1 className="text-lg font-semibold text-zinc-900">CronJobs</h1>
          <p className="text-xs text-zinc-500">Every CronJob in the namespace. Change a schedule, suspend, edit env vars, or create one from YAML.</p>
        </div>
        <div className="ml-auto flex flex-wrap items-center gap-2">
          <select className={select} value={namespace} onChange={(e) => setNamespace(e.target.value)} aria-label="Namespace">
            {namespaces.map((n) => <option key={n} value={n}>{n}</option>)}
          </select>
          <div className="relative">
            <Search className="pointer-events-none absolute left-2.5 top-2.5 h-4 w-4 text-zinc-400" />
            <input className={cn(select, 'w-48 pl-8')} placeholder="Find a CronJob" value={search} onChange={(e) => setSearch(e.target.value)} />
          </div>
          <Button variant="secondary" size="icon" onClick={onRefresh} aria-label="Refresh"><RefreshCw className={cn('h-4 w-4', spinning && 'animate-spin')} /></Button>
          <PermissionGate product="autopilot" permission="CRONJOB_CREATE">
            <Link to={`/backend/cronjobs/new?namespace=${encodeURIComponent(namespace)}`}>
              <Button size="sm"><Plus className="h-4 w-4" />New CronJob</Button>
            </Link>
          </PermissionGate>
        </div>
      </div>

      {error && (
        <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">
          Could not read CronJobs from namespace “{namespace}”: {errorMessage(error)}
        </div>
      )}

      <Card className="overflow-hidden">
        {isLoading ? <TableSkeleton rows={6} cols={5} /> : rows.length === 0 ? (
          <div className="px-4 py-12 text-center text-sm text-zinc-500">{namespace ? 'No CronJobs here.' : 'Pick a namespace.'}</div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="bg-zinc-50 text-left text-xs uppercase tracking-wide text-zinc-500">
                <tr><th className="px-4 py-2.5">Name</th><th className="px-3">Schedule</th><th className="px-3">State</th><th className="px-3">Last run</th><th className="px-4">Image</th></tr>
              </thead>
              <tbody>
                {rows.map((c) => (
                  <tr key={c.name} tabIndex={0} onClick={() => open(c.name)} onKeyDown={(e) => e.key === 'Enter' && open(c.name)}
                    className="cursor-pointer border-t border-zinc-100 hover:bg-zinc-50 focus:bg-zinc-50 focus:outline-none">
                    <td className="px-4 py-3 font-medium text-zinc-900">{c.name}</td>
                    <td className="px-3 font-mono text-xs">{c.schedule}{c.timeZone && <span className="ml-1.5 font-sans text-zinc-400">{c.timeZone}</span>}</td>
                    <td className="px-3">
                      <div className="flex flex-wrap items-center gap-1.5">
                        {c.suspend ? <Badge variant="warning">Suspended</Badge> : <Badge variant="success">Scheduled</Badge>}
                        {c.active > 0 && <Badge variant="info">{c.active} running</Badge>}
                      </div>
                    </td>
                    <td className="px-3 text-xs text-zinc-600">
                      {c.lastScheduleTime ? <>{fmtTime(c.lastScheduleTime)}<span className="text-zinc-400"> · {relTime(c.lastScheduleTime)}</span></> : <span className="text-zinc-400">never</span>}
                    </td>
                    <td className="max-w-[260px] truncate px-4 font-mono text-xs text-zinc-600" title={c.images.join(', ')}>{c.images.map(shortImage).join(', ')}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </div>
  );
}
