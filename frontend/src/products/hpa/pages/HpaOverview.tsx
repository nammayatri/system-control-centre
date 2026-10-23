import { useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { RefreshCw, Search } from 'lucide-react';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { Card } from '../../../shared/ui/card';
import { TableSkeleton } from '../../../shared/ui/skeleton';
import { cn } from '../../../lib/utils';
import { useRefreshAnimation } from '../../../shared/hooks';
import { useOverview } from '../hooks';
import { fmtTime, relTime } from '../format';
import { useProductParam } from '../useProductParam';
import { ApplyStatusBadge } from '../components/Badges';
import type { OverviewService } from '../types';

const select = 'h-9 rounded-lg border border-zinc-300 bg-white px-3 text-sm focus:border-zinc-500 focus:outline-none';

export default function HpaOverview() {
  const { product, setProduct, products } = useProductParam();
  const { data, isLoading, isFetching, refetch, error } = useOverview(product);
  const { spinning, onRefresh } = useRefreshAnimation(isFetching, refetch);
  const [search, setSearch] = useState('');
  const navigate = useNavigate();

  const rows = useMemo(
    () => (data?.services ?? []).filter((s) => s.service.toLowerCase().includes(search.toLowerCase())),
    [data, search],
  );
  const open = (s: OverviewService) => navigate(`/backend/hpa/${encodeURIComponent(product)}/${encodeURIComponent(s.service)}`);

  return (
    <div className="space-y-4 p-4 sm:p-6">
      <div className="flex flex-wrap items-center gap-3">
        <div>
          <h1 className="text-lg font-semibold text-zinc-900">HPA Manager</h1>
          <p className="text-xs text-zinc-500">Time-based HPA changes with automatic restore and rollback, plus live scaling behaviour.</p>
        </div>
        <div className="ml-auto flex flex-wrap items-center gap-2">
          <Link to={`/backend/hpa/applies?product=${encodeURIComponent(product)}`} className="text-xs font-medium text-sky-700 hover:underline">Activity log →</Link>
          <select className={select} value={product} onChange={(e) => setProduct(e.target.value)} aria-label="Product">
            {products.map((p) => <option key={p} value={p}>{p}</option>)}
          </select>
          <div className="relative">
            <Search className="pointer-events-none absolute left-2.5 top-2.5 h-4 w-4 text-zinc-400" />
            <input className={cn(select, 'w-48 pl-8')} placeholder="Find a service" value={search} onChange={(e) => setSearch(e.target.value)} />
          </div>
          <Button variant="secondary" size="icon" onClick={onRefresh} aria-label="Refresh"><RefreshCw className={cn('h-4 w-4', spinning && 'animate-spin')} /></Button>
        </div>
      </div>

      {data?.clusterError && (
        <div className="space-y-1 rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">
          <div className="font-medium">Could not read HPAs from namespace “{data.namespace || '(none set)'}” for {data.product}.</div>
          {/forbidden/i.test(data.clusterError) && (
            <div className="text-xs">
              The backend's service account has no access there. Usually the namespace in this product's Deployment Config does not exist
              in this cluster (stale or copied configuration); otherwise grant the service account a Role with
              get/list/watch/update/patch on <code>horizontalpodautoscalers</code>.
            </div>
          )}
          {/not.?found/i.test(data.clusterError) && !/forbidden/i.test(data.clusterError) && (
            <div className="text-xs">That namespace was not found. Check the namespace in this product's Deployment Config.</div>
          )}
          <details className="text-xs text-red-700"><summary className="cursor-pointer">Details</summary><pre className="mt-1 whitespace-pre-wrap">{data.clusterError}</pre></details>
        </div>
      )}
      {error && !data && <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">{(error as any)?.response?.data?.message ?? 'Failed to load'}</div>}

      <Card className="overflow-hidden">
        {isLoading ? <TableSkeleton rows={6} cols={6} /> : rows.length === 0 ? (
          <div className="px-4 py-12 text-center text-sm text-zinc-500">{product ? 'No services match.' : 'Pick a product.'}</div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="bg-zinc-50 text-left text-xs uppercase tracking-wide text-zinc-500">
                <tr>
                  <th className="px-4 py-2.5">Service</th><th className="px-3">Serving HPA</th><th className="px-3">Replicas</th>
                  <th className="px-3">Min – Max</th><th className="px-3">Scales on</th><th className="px-3">Schedules</th><th className="px-4">Status</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((s) => {
                  const h = s.serving[0];
                  return (
                    <tr key={s.service} tabIndex={0} onClick={() => open(s)} onKeyDown={(e) => e.key === 'Enter' && open(s)}
                      className="cursor-pointer border-t border-zinc-100 hover:bg-zinc-50 focus:bg-zinc-50 focus:outline-none">
                      <td className="px-4 py-3 font-medium text-zinc-900">{s.service}</td>
                      <td className="px-3">
                        {h ? <><span className="font-mono text-xs">{h.name}</span>{s.serving.length > 1 && <Badge variant="warning" className="ml-1.5">+{s.serving.length - 1}</Badge>}</>
                          : <span className="text-xs text-zinc-400" title={s.reason}>{s.hpaCount === 0 ? 'No HPA' : 'Unknown'}</span>}
                      </td>
                      <td className="px-3 tabular-nums">{h ? <><span className="font-semibold">{h.currentReplicas}</span><span className="text-zinc-400"> → {h.desiredReplicas}</span></> : '—'}</td>
                      <td className="px-3 tabular-nums">{h ? `${h.minReplicas} – ${h.maxReplicas}` : '—'}</td>
                      <td className="max-w-[220px] truncate px-3 text-xs text-zinc-600" title={h?.metrics.join(', ')}>{h?.metrics.join(' · ') ?? '—'}</td>
                      <td className="px-3 text-xs text-zinc-600">
                        {s.activeSchedules > 0 ? (
                          <span>{s.activeSchedules} active{s.windowOpen ? <Badge variant="info" className="ml-1.5">window open</Badge> : s.nextWindowStart && <span className="text-zinc-400"> · next {relTime(s.nextWindowStart)}</span>}</span>
                        ) : s.schedules > 0 ? <span className="text-zinc-400">none active</span> : <span className="text-zinc-400">none</span>}
                        {s.nextWindowStart && !s.windowOpen && <div className="text-zinc-400">{fmtTime(s.nextWindowStart)}</div>}
                      </td>
                      <td className="px-4">
                        <div className="flex flex-wrap items-center gap-1.5">
                          {s.inflight.map((a) => <ApplyStatusBadge key={a.id} status={a.status} />)}
                          {s.frozen && <Badge variant="danger">Frozen</Badge>}
                          {s.hpaCount > 1 && <Badge variant="warning">{s.hpaCount} HPAs</Badge>}
                          {h && !h.editable && <Badge variant="danger" >Not editable</Badge>}
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </div>
  );
}
