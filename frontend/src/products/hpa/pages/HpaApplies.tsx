import { useState } from 'react';
import { Link } from 'react-router-dom';
import { RefreshCw } from 'lucide-react';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { Card } from '../../../shared/ui/card';
import { TableSkeleton } from '../../../shared/ui/skeleton';
import { cn } from '../../../lib/utils';
import { useRefreshAnimation } from '../../../shared/hooks';
import { useApplies } from '../hooks';
import { describeChange, fmtTime } from '../format';
import { useProductParam } from '../useProductParam';
import { ApplyStatusBadge } from '../components/Badges';
import ApplyDialog from '../components/ApplyDialog';
import { STATUS_LABEL } from '../format';
import type { ApplyStatus } from '../types';

const select = 'h-9 rounded-lg border border-zinc-300 bg-white px-3 text-sm focus:border-zinc-500 focus:outline-none';

/** Every change the scheduler or a person has made to an HPA in this product, newest first. */
export default function HpaApplies() {
  const { product, setProduct, products } = useProductParam();
  const [status, setStatus] = useState('');
  const [open, setOpen] = useState<string | null>(null);
  const { data = [], isLoading, isFetching, refetch } = useApplies(product, { status: status || undefined });
  const { spinning, onRefresh } = useRefreshAnimation(isFetching, refetch);

  return (
    <div className="space-y-4 p-4 sm:p-6">
      <div className="flex flex-wrap items-center gap-3">
        <div>
          <h1 className="text-lg font-semibold text-zinc-900">HPA activity</h1>
          <p className="text-xs text-zinc-500"><Link to={`/backend/hpa?product=${encodeURIComponent(product)}`} className="text-sky-700 hover:underline">← Services</Link> · every change, who made it, and how it ended.</p>
        </div>
        <div className="ml-auto flex items-center gap-2">
          <select className={select} value={product} onChange={(e) => setProduct(e.target.value)} aria-label="Product">{products.map((p) => <option key={p}>{p}</option>)}</select>
          <select className={select} value={status} onChange={(e) => setStatus(e.target.value)} aria-label="Status">
            <option value="">All statuses</option>
            {(Object.keys(STATUS_LABEL) as ApplyStatus[]).map((s) => <option key={s} value={s}>{STATUS_LABEL[s]}</option>)}
          </select>
          <Button variant="secondary" size="icon" onClick={onRefresh} aria-label="Refresh"><RefreshCw className={cn('h-4 w-4', spinning && 'animate-spin')} /></Button>
        </div>
      </div>
      <Card className="overflow-hidden">
        {isLoading ? <TableSkeleton rows={6} cols={6} /> : data.length === 0 ? (
          <div className="px-4 py-12 text-center text-sm text-zinc-500">Nothing yet.</div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="bg-zinc-50 text-left text-xs uppercase tracking-wide text-zinc-500">
                <tr><th className="px-4 py-2.5">Service / HPA</th><th className="px-3">Change</th><th className="px-3">Status</th><th className="px-3">Source</th><th className="px-3">Window</th><th className="px-4">Created</th></tr>
              </thead>
              <tbody>
                {data.map((a) => (
                  <tr key={a.id} tabIndex={0} onClick={() => setOpen(a.id)} onKeyDown={(e) => e.key === 'Enter' && setOpen(a.id)} className="cursor-pointer border-t border-zinc-100 hover:bg-zinc-50 focus:bg-zinc-50 focus:outline-none">
                    <td className="px-4 py-3"><div className="font-medium text-zinc-900">{a.service}</div><div className="font-mono text-[11px] text-zinc-500">{a.hpaName}</div></td>
                    <td className="px-3"><div className="flex flex-wrap gap-1">{describeChange(a.change).map((c) => <Badge key={c} variant="blue">{c}</Badge>)}</div></td>
                    <td className="px-3"><ApplyStatusBadge status={a.status} /></td>
                    <td className="px-3 text-xs text-zinc-600">{a.trigger === 'MANUAL' ? 'Manual' : 'Schedule'}<div className="text-zinc-400">{a.createdBy.replace('scheduler:', '').slice(0, 24)}</div></td>
                    <td className="px-3 text-xs text-zinc-600">{a.windowEnd ? `until ${fmtTime(a.windowEnd)}` : 'until restored'}</td>
                    <td className="px-4 text-xs text-zinc-600">{fmtTime(a.createdAt)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>
      <ApplyDialog id={open} onClose={() => setOpen(null)} />
    </div>
  );
}
