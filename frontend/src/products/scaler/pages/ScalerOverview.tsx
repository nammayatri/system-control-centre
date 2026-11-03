import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Plus, RefreshCw, Search } from 'lucide-react';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { Card } from '../../../shared/ui/card';
import { TableSkeleton } from '../../../shared/ui/skeleton';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { cn } from '../../../lib/utils';
import { useRefreshAnimation } from '../../../shared/hooks';
import { ApplyStatusBadge } from '../../hpa/components/Badges';
import { useTargets } from '../hooks';
import { kindLabel, modeLabel, stateLabel, stateVariant } from '../format';
import AddTargetDialog from '../components/AddTargetDialog';
import type { TargetKind, TargetRow } from '../types';

const field = 'h-9 rounded-lg border border-zinc-300 bg-white px-3 text-sm focus:border-zinc-500 focus:outline-none';
const TABS: { id: TargetKind | 'ALL'; label: string }[] = [{ id: 'ALL', label: 'All' }, { id: 'REDIS', label: 'Valkey' }, { id: 'DB', label: 'AlloyDB read pools' }];

export default function ScalerOverview() {
  const [tab, setTab] = useState<TargetKind | 'ALL'>('ALL');
  const { data, isLoading, isFetching, refetch, error } = useTargets(tab === 'ALL' ? undefined : tab);
  const { spinning, onRefresh } = useRefreshAnimation(isFetching, refetch);
  const [search, setSearch] = useState('');
  const [addOpen, setAddOpen] = useState(false);
  const navigate = useNavigate();

  const rows = useMemo(
    () => (data ?? []).filter((r) => `${r.target.name} ${r.target.resource} ${r.target.parent ?? ''}`.toLowerCase().includes(search.toLowerCase())),
    [data, search],
  );
  const open = (r: TargetRow) => navigate(`/backend/scaler/${r.target.kind}/${encodeURIComponent(r.target.id)}`);

  return (
    <div className="space-y-4 p-4 sm:p-6">
      <div className="flex flex-wrap items-center gap-3">
        <div>
          <h1 className="text-lg font-semibold text-zinc-900">Capacity Scaler</h1>
          <p className="text-xs text-zinc-500">Scheduled capacity and autoscaler settings for Valkey instances (shards or replicas) and AlloyDB read pools (nodes).</p>
        </div>
        <div className="ml-auto flex flex-wrap items-center gap-2">
          <div className="relative">
            <Search className="pointer-events-none absolute left-2.5 top-2.5 h-4 w-4 text-zinc-400" />
            <input className={cn(field, 'w-48 pl-8')} placeholder="Find a target" value={search} onChange={(e) => setSearch(e.target.value)} />
          </div>
          <Button variant="secondary" size="icon" onClick={onRefresh} aria-label="Refresh"><RefreshCw className={cn('h-4 w-4', spinning && 'animate-spin')} /></Button>
          <PermissionGate product="autopilot" permission="HPA_GUARDRAIL_EDIT">
            <Button size="sm" onClick={() => setAddOpen(true)}><Plus className="h-4 w-4" />Add target</Button>
          </PermissionGate>
        </div>
      </div>

      <div role="tablist" className="flex gap-1 border-b border-zinc-200">
        {TABS.map((t) => (
          <button key={t.id} role="tab" aria-selected={tab === t.id} onClick={() => setTab(t.id)}
            className={cn('-mb-px cursor-pointer border-b-2 px-3 py-2 text-sm font-medium', tab === t.id ? 'border-zinc-900 text-zinc-900' : 'border-transparent text-zinc-500 hover:text-zinc-800')}>{t.label}</button>
        ))}
      </div>

      {error && !data && <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">{(error as { response?: { data?: { message?: string } } })?.response?.data?.message ?? 'Failed to load'}</div>}

      <Card className="overflow-hidden">
        {isLoading ? <TableSkeleton rows={4} cols={7} /> : rows.length === 0 ? (
          <div className="px-4 py-12 text-center text-sm text-zinc-500">
            {(data ?? []).length === 0 ? 'No targets yet. Add a Valkey instance or an AlloyDB read pool to start.' : 'No targets match.'}
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="bg-zinc-50 text-left text-xs uppercase tracking-wide text-zinc-500">
                <tr>
                  <th className="px-4 py-2.5">Target</th><th className="px-3">Kind</th><th className="px-3">State</th>
                  <th className="px-3">Capacity</th><th className="px-3">Autoscaler</th><th className="px-3">Schedules</th><th className="px-4">Changes</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => {
                  const t = r.target; const s = r.state;
                  return (
                    <tr key={`${t.kind}/${t.id}`} tabIndex={0} onClick={() => open(r)} onKeyDown={(e) => e.key === 'Enter' && open(r)}
                      className="cursor-pointer border-t border-zinc-100 hover:bg-zinc-50 focus:bg-zinc-50 focus:outline-none">
                      <td className="px-4 py-3">
                        <div className="font-medium text-zinc-900">{t.name}</div>
                        <div className="font-mono text-[11px] text-zinc-400">{t.parent ? `${t.parent} / ` : ''}{t.resource}</div>
                      </td>
                      <td className="px-3 text-xs"><Badge variant={t.kind === 'REDIS' ? 'blue' : 'purple'}>{kindLabel(t.kind)}</Badge>{s && <div className="mt-0.5 text-zinc-400">{modeLabel(s.mode)}</div>}</td>
                      <td className="px-3">{s ? <Badge variant={stateVariant(s.state)} dot>{stateLabel(s.state)}</Badge> : <span className="text-xs text-red-700" title={r.cloudError ?? ''}>Unreachable</span>}</td>
                      <td className="px-3 tabular-nums">{s ? `${s.units} ${s.mode === 'READ_POOL' ? 'nodes' : s.mode === 'CLUSTER' ? 'shards' : 'shard'}${s.mode !== 'READ_POOL' ? ` · ${s.replicas} repl.` : ''}` : '—'}</td>
                      <td className="px-3 text-xs text-zinc-600">{t.autoscalerJob ? <span className="font-mono">{t.autoscalerJob}</span> : <span className="text-zinc-400">none</span>}</td>
                      <td className="px-3 text-xs text-zinc-600">
                        {r.activeSchedules > 0 ? <span>{r.activeSchedules} active{r.windowOpen && <Badge variant="info" className="ml-1.5">window open</Badge>}</span>
                          : r.schedules > 0 ? <span className="text-zinc-400">none active</span> : <span className="text-zinc-400">none</span>}
                      </td>
                      <td className="px-4"><div className="flex flex-wrap items-center gap-1.5">{r.inflight.map((a) => <ApplyStatusBadge key={a.id} status={a.status} />)}</div></td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      <AddTargetDialog open={addOpen} onOpenChange={setAddOpen} onAdded={(kind, id) => navigate(`/backend/scaler/${kind}/${encodeURIComponent(id)}`)} />
    </div>
  );
}
