import { useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { putWatch } from '../api';
import { useQueryClient } from '@tanstack/react-query';
import { Eye, EyeOff, Pencil, Play, Plus, Shield, Trash2, Pause, RefreshCw } from 'lucide-react';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { Card, CardContent } from '../../../shared/ui/card';
import { Spinner } from '../../../shared/ui/spinner';
import { useConfirm } from '../../../shared/ui/confirm-dialog';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { useRefreshAnimation } from '../../../shared/hooks';
import { cn } from '../../../lib/utils';
import {
  useHistory, useScaleEvents, useScheduleAction, useSeries, useServiceDetail, useServiceEvents, useWatch,
} from '../hooks';
import { describeChange, describeKind, fmtTime, fmtTimeFull, relTime } from '../format';
import { ApplyStatusBadge, RoleBadge } from '../components/Badges';
import ApplyDialog, { Timeline } from '../components/ApplyDialog';
import DiffTable from '../components/DiffTable';
import GuardrailDialog from '../components/GuardrailDialog';
import HpaCard from '../components/HpaCard';
import ManualApplyDialog from '../components/ManualApplyDialog';
import ReplicaChart from '../components/ReplicaChart';
import ScheduleDialog from '../components/ScheduleDialog';
import type { Schedule, Snapshot } from '../types';

type Tab = 'performance' | 'hpas' | 'schedules' | 'history' | 'activity';
const TABS: { id: Tab; label: string }[] = [
  { id: 'performance', label: 'Performance' }, { id: 'hpas', label: 'HPAs' }, { id: 'schedules', label: 'Schedules' },
  { id: 'history', label: 'Config history' }, { id: 'activity', label: 'Activity' },
];
const RANGES = [{ id: '1h', label: '1 h', ms: 3600e3 }, { id: '6h', label: '6 h', ms: 6 * 3600e3 }, { id: '24h', label: '24 h', ms: 24 * 3600e3 }, { id: '3d', label: '3 d', ms: 3 * 86400e3 }, { id: '7d', label: '7 d', ms: 7 * 86400e3 }];

export default function HpaServiceDetail() {
  const { product = '', service = '' } = useParams();
  const { data: d, isLoading, isFetching, refetch, error } = useServiceDetail(product, service);
  const { spinning, onRefresh } = useRefreshAnimation(isFetching, refetch);
  const [tab, setTab] = useState<Tab>('performance');
  const [scheduleOpen, setScheduleOpen] = useState(false);
  const [editing, setEditing] = useState<Schedule | undefined>();
  const [manualOpen, setManualOpen] = useState(false);
  const [guardOpen, setGuardOpen] = useState(false);
  const [applyId, setApplyId] = useState<string | null>(null);
  const watch = useWatch(product, service);
  const qc = useQueryClient();
  // Start collecting chart data as soon as someone looks at a service. Quietly skipped if the person
  // may only view (the server refuses and nothing is shown).
  const [autoTried, setAutoTried] = useState(false);
  useEffect(() => {
    if (!d || d.watched || autoTried) return;
    setAutoTried(true);
    putWatch(product, service, true).then(() => qc.invalidateQueries({ queryKey: ['hpa'] })).catch(() => undefined);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [d?.watched]);

  const serving = useMemo(() => (d ? d.resolution.hpas.filter((h) => d.resolution.serving.includes(h.name)) : []), [d]);
  const reference = (serving[0] ?? d?.resolution.hpas[0])?.spec ?? null;

  if (isLoading) return <div className="p-6"><Spinner label="Loading…" /></div>;
  if (!d) return <div className="p-6 text-sm text-red-700">{(error as any)?.response?.data?.message ?? 'Failed to load this service.'}</div>;

  const live = d.applies.filter((a) => !['RESTORED', 'ROLLED_BACK', 'FAILED', 'SKIPPED'].includes(a.status));

  return (
    <div className="space-y-4 p-4 sm:p-6">
      <div className="flex flex-wrap items-start gap-3">
        <div>
          <div className="text-xs text-zinc-500"><Link to={`/backend/hpa?product=${encodeURIComponent(product)}`} className="text-sky-700 hover:underline">HPA Manager</Link> / {product}</div>
          <h1 className="text-lg font-semibold text-zinc-900">{service}</h1>
          <div className="mt-1 flex flex-wrap items-center gap-1.5">
            {d.guardrail.frozen && <Badge variant="danger">Frozen{d.guardrail.frozenReason ? `: ${d.guardrail.frozenReason}` : ''}</Badge>}
            {d.resolution.multipleHpas && <Badge variant="warning">{d.resolution.hpas.length} HPAs exist</Badge>}
            {live.map((a) => <ApplyStatusBadge key={a.id} status={a.status} />)}
          </div>
        </div>
        <div className="ml-auto flex flex-wrap items-center gap-2">
          <Button variant="secondary" size="icon" onClick={onRefresh} aria-label="Refresh"><RefreshCw className={cn('h-4 w-4', spinning && 'animate-spin')} /></Button>
          <PermissionGate product="autopilot" permission="HPA_SCHEDULE_EDIT" appGroup={product}>
            <Button variant="secondary" size="sm" loading={watch.isPending} onClick={() => watch.mutate(!d.watched)}>
              {d.watched ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}{d.watched ? 'Stop recording history' : 'Record history'}
            </Button>
          </PermissionGate>
          <PermissionGate product="autopilot" permission="HPA_GUARDRAIL_EDIT" appGroup={product}>
            <Button variant="secondary" size="sm" onClick={() => setGuardOpen(true)}><Shield className="h-4 w-4" />Guardrails</Button>
          </PermissionGate>
          <PermissionGate product="autopilot" permission="HPA_APPLY" appGroup={product}>
            <Button variant="secondary" size="sm" disabled={serving.length === 0} onClick={() => setManualOpen(true)}><Play className="h-4 w-4" />Change now</Button>
          </PermissionGate>
          <PermissionGate product="autopilot" permission="HPA_SCHEDULE_EDIT" appGroup={product}>
            <Button size="sm" disabled={serving.length === 0} onClick={() => { setEditing(undefined); setScheduleOpen(true); }}><Plus className="h-4 w-4" />New schedule</Button>
          </PermissionGate>
        </div>
      </div>

      {d.resolution.warnings.map((w) => <div key={w} className="rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-800">{w}</div>)}
      {serving.length === 0 && <div className="rounded-lg bg-zinc-100 px-3 py-2 text-xs text-zinc-700">{d.resolution.reason}. Schedules and changes need a serving HPA.</div>}

      <div role="tablist" className="flex gap-1 overflow-x-auto overflow-y-hidden border-b border-zinc-200">
        {TABS.map((t) => (
          <button key={t.id} role="tab" aria-selected={tab === t.id} onClick={() => setTab(t.id)}
            className={cn('-mb-px cursor-pointer whitespace-nowrap border-b-2 px-4 py-2 text-sm font-medium', tab === t.id ? 'border-zinc-900 text-zinc-900' : 'border-transparent text-zinc-500 hover:text-zinc-800')}>
            {t.label}{t.id === 'schedules' && d.schedules.length > 0 ? ` (${d.schedules.length})` : ''}
          </button>
        ))}
      </div>

      {tab === 'performance' && <PerformanceTab product={product} service={service} hpaNames={d.resolution.hpas.map((h) => h.name)} servingNames={d.resolution.serving} applies={d.applies} watched={d.watched} />}

      {tab === 'hpas' && (
        <div className="space-y-3">
          <div className="text-xs text-zinc-600">
            {d.resolution.reason}. Release baseline in deployment config: min {d.baseline.minReplicas}, max {d.baseline.maxReplicas} (what a brand-new HPA starts from).
          </div>
          {d.resolution.hpas.length === 0 ? <div className="text-sm text-zinc-500">No HPA found for this service.</div>
            : d.resolution.hpas.map((h) => <HpaCard key={h.name} hpa={h} />)}
        </div>
      )}

      {tab === 'schedules' && <SchedulesTab schedules={d.schedules} product={product} onEdit={(s) => { setEditing(s); setScheduleOpen(true); }} onOpenApply={setApplyId} />}
      {tab === 'history' && <HistoryTab product={product} service={service} />}
      {tab === 'activity' && <ActivityTab product={product} service={service} applies={d.applies} onOpen={setApplyId} />}

      <ScheduleDialog open={scheduleOpen} onOpenChange={setScheduleOpen} product={product} service={service} reference={reference} existing={editing} currentReplicas={serving[0]?.status.currentReplicas} />
      <ManualApplyDialog open={manualOpen} onOpenChange={setManualOpen} product={product} service={service} serving={serving} />
      <GuardrailDialog open={guardOpen} onOpenChange={setGuardOpen} product={product} service={service} value={d.guardrail} />
      <ApplyDialog id={applyId} onClose={() => setApplyId(null)} />
    </div>
  );
}

// ── Performance ─────────────────────────────────────────────────────────────

function PerformanceTab({ product, service, hpaNames, servingNames, applies, watched }: {
  product: string; service: string; hpaNames: string[]; servingNames: string[]; applies: import('../types').Apply[]; watched: boolean;
}) {
  const [range, setRange] = useState('6h');
  const [selected, setSelected] = useState('');
  // Re-anchor the window once a minute so the query key is stable between ticks.
  const [tick, setTick] = useState(() => Math.floor(Date.now() / 60000));
  useEffect(() => { const t = setInterval(() => setTick(Math.floor(Date.now() / 60000)), 60000); return () => clearInterval(t); }, []);
  const ms = RANGES.find((r) => r.id === range)?.ms ?? 6 * 3600e3;
  const to = useMemo(() => new Date(tick * 60000).toISOString(), [tick]);
  const from = useMemo(() => new Date(tick * 60000 - ms).toISOString(), [tick, ms]);
  const series = useSeries(product, service, from, to);
  const events = useScaleEvents(product, service, from, to);

  const names = useMemo(() => [...new Set([...hpaNames, ...(series.data?.points.map((p) => p.hpaName) ?? [])])], [hpaNames, series.data]);
  const current = selected && names.includes(selected) ? selected : servingNames[0] ?? names[0] ?? '';
  const points = (series.data?.points ?? []).filter((p) => p.hpaName === current);
  const last = points[points.length - 1];

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        {names.length > 1 && (
          <div className="flex gap-1">
            {names.map((n) => (
              <button key={n} onClick={() => setSelected(n)} className={cn('h-8 cursor-pointer rounded-lg border px-3 font-mono text-xs', n === current ? 'border-zinc-900 bg-zinc-900 text-white' : 'border-zinc-300 text-zinc-600 hover:bg-zinc-50')}>
                {n}{servingNames.includes(n) ? ' ●' : ''}
              </button>
            ))}
          </div>
        )}
        <div className="ml-auto inline-flex rounded-lg border border-zinc-300 p-0.5 text-xs">
          {RANGES.map((r) => (
            <button key={r.id} onClick={() => setRange(r.id)} className={cn('cursor-pointer rounded-md px-3 py-1.5 font-medium', range === r.id ? 'bg-zinc-900 text-white' : 'text-zinc-600 hover:bg-zinc-100')}>{r.label}</button>
          ))}
        </div>
      </div>

      {!watched && (series.data?.points.length ?? 0) === 0 && (
        <div className="rounded-lg bg-sky-50 px-3 py-2 text-xs text-sky-800">
          Collecting data for this service now. The chart fills in as samples arrive (one per minute), so check back in a minute or two.
        </div>
      )}

      {last && (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-5">
          <Kpi label="Current replicas" value={last.current} /><Kpi label="Desired" value={last.desired} />
          <Kpi label="Min – max" value={`${last.min} – ${last.max}`} /><Kpi label="CPU" value={last.cpuPct != null ? `${last.cpuPct.toFixed(0)}%` : '—'} />
          <Kpi label="Last sample" value={relTime(series.data?.latestSample)} />
        </div>
      )}

      <Card><CardContent>
        <ReplicaChart points={points} from={from} to={to} applies={applies.filter((a) => a.hpaName === current)} scaleEvents={(events.data ?? []).filter((e) => e.hpaName === current)} refreshing={series.isFetching} />
      </CardContent></Card>

      <Card><CardContent>
        <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-zinc-500">Scale events</div>
        {(events.data ?? []).length === 0 ? <div className="text-xs text-zinc-500">No Kubernetes scale events in this range.</div> : (
          <table className="w-full text-xs">
            <tbody>
              {(events.data ?? []).filter((e) => e.hpaName === current).slice(0, 50).map((e) => (
                <tr key={e.uid} className="border-t border-zinc-100 first:border-0">
                  <td className="w-36 py-1.5 pr-3 text-zinc-500">{fmtTimeFull(e.lastTs)}</td>
                  <td className="w-40 pr-3 font-medium text-zinc-800">{e.reason}{e.count > 1 ? ` ×${e.count}` : ''}</td>
                  <td className="w-20 pr-3 tabular-nums">{e.newSize != null ? `→ ${e.newSize}` : ''}</td>
                  <td className="text-zinc-600">{e.message}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </CardContent></Card>
    </div>
  );
}

function Kpi({ label, value }: { label: string; value: string | number }) {
  return <div className="rounded-xl border border-zinc-200 bg-white px-4 py-3"><div className="text-[11px] uppercase tracking-wide text-zinc-500">{label}</div><div className="text-xl font-semibold text-zinc-900">{value}</div></div>;
}

// ── Schedules ───────────────────────────────────────────────────────────────

function SchedulesTab({ schedules, product, onEdit, onOpenApply }: { schedules: Schedule[]; product: string; onEdit: (s: Schedule) => void; onOpenApply: (id: string) => void }) {
  const act = useScheduleAction();
  const confirm = useConfirm();
  if (schedules.length === 0) return <div className="rounded-lg border border-dashed border-zinc-300 px-4 py-10 text-center text-sm text-zinc-500">No schedules yet. Create one to raise or lower HPA limits automatically for a time window.</div>;
  return (
    <div className="space-y-3">
      {schedules.map((s) => (
        <Card key={s.id}><CardContent className="space-y-2">
          <div className="flex flex-wrap items-center gap-2">
            <span className="font-semibold text-zinc-900">{s.name}</span>
            <Badge variant={s.status === 'ACTIVE' ? 'success' : s.status === 'PAUSED' ? 'warning' : 'muted'} dot>{s.status.charAt(0) + s.status.slice(1).toLowerCase()}</Badge>
            {s.timing.windowOpen && <Badge variant="info">Window open now</Badge>}
            <PermissionGate product="autopilot" permission="HPA_SCHEDULE_EDIT" appGroup={product}>
              <div className="ml-auto flex gap-1">
                <Button size="icon-sm" variant="ghost" aria-label="Edit" onClick={() => onEdit(s)}><Pencil className="h-4 w-4" /></Button>
                {s.status === 'ACTIVE' && <Button size="icon-sm" variant="ghost" aria-label="Pause" onClick={() => act.mutate({ id: s.id, action: 'pause' })}><Pause className="h-4 w-4" /></Button>}
                {s.status === 'PAUSED' && <Button size="icon-sm" variant="ghost" aria-label="Resume" onClick={() => act.mutate({ id: s.id, action: 'resume' })}><Play className="h-4 w-4" /></Button>}
                <Button size="icon-sm" variant="ghost" aria-label="Delete" onClick={async () => {
                  if (await confirm({ title: 'Delete schedule', description: 'Any change it is holding is restored right away.', confirmLabel: 'Delete', variant: 'danger' })) act.mutate({ id: s.id, action: 'delete' });
                }}><Trash2 className="h-4 w-4 text-red-600" /></Button>
              </div>
            </PermissionGate>
          </div>
          <div className="text-xs text-zinc-600">{describeKind(s.kind)}</div>
          <div className="flex flex-wrap gap-1.5">{describeChange(s.change).map((c) => <Badge key={c} variant="blue">{c}</Badge>)}</div>
          <div className="text-xs text-zinc-500">
            {s.timing.currentWindow ? `Open until ${s.timing.currentWindow.end ? fmtTime(s.timing.currentWindow.end) : 'restored by hand'}` : s.timing.nextStart ? `Next window ${fmtTime(s.timing.nextStart)} (${relTime(s.timing.nextStart)})` : s.status === 'EXPIRED' ? 'Finished' : 'No upcoming window'}
            {' · '}created by {s.createdBy}
          </div>
          {(s.applies ?? []).length > 0 && (
            <div className="flex flex-wrap items-center gap-2 border-t border-zinc-100 pt-2 text-xs">
              <span className="text-zinc-500">Recent:</span>
              {(s.applies ?? []).slice(0, 4).map((a) => <button key={a.id} className="cursor-pointer" onClick={() => onOpenApply(a.id)}><ApplyStatusBadge status={a.status} /></button>)}
            </div>
          )}
        </CardContent></Card>
      ))}
    </div>
  );
}

// ── History ─────────────────────────────────────────────────────────────────

const SOURCE: Record<Snapshot['source'], { label: string; variant: 'default' | 'blue' | 'success' | 'warning' | 'muted' }> = {
  BEFORE: { label: 'Before a change', variant: 'muted' }, APPLY: { label: 'Change applied', variant: 'blue' },
  RESTORE: { label: 'Restored', variant: 'success' }, ROLLBACK: { label: 'Rolled back', variant: 'warning' },
  OBSERVED: { label: 'Seen changed (outside this tool)', variant: 'default' },
};

function HistoryTab({ product, service }: { product: string; service: string }) {
  const { data = [], isLoading } = useHistory(product, service);
  if (isLoading) return <Spinner label="Loading…" />;
  if (data.length === 0) return <div className="rounded-lg border border-dashed border-zinc-300 px-4 py-10 text-center text-sm text-zinc-500">No spec history yet. It starts with the first sample or change.</div>;
  return (
    <div className="space-y-3">
      {data.map((s) => (
        <Card key={s.id}><CardContent className="space-y-2">
          <div className="flex flex-wrap items-center gap-2 text-xs">
            <Badge variant={SOURCE[s.source].variant}>{SOURCE[s.source].label}</Badge>
            <span className="font-mono text-zinc-700">{s.hpaName}</span>
            <span className="text-zinc-500">{fmtTimeFull(s.ts)}</span>
            {s.managedBy && <span className="text-zinc-400">{s.managedBy === 'manual' ? 'manual apply' : `schedule ${s.managedBy.slice(0, 8)}`}</span>}
            <span className="ml-auto text-zinc-500">min {s.spec.minReplicas} · max {s.spec.maxReplicas}</span>
          </div>
          <DiffTable diff={s.diff} empty={s.previousSnapshot == null ? 'First recorded spec for this HPA' : 'No spec difference'} />
        </CardContent></Card>
      ))}
    </div>
  );
}

// ── Activity ────────────────────────────────────────────────────────────────

function ActivityTab({ product, service, applies, onOpen }: { product: string; service: string; applies: import('../types').Apply[]; onOpen: (id: string) => void }) {
  const events = useServiceEvents(product, service);
  return (
    <div className="grid gap-4 lg:grid-cols-2">
      <Card><CardContent>
        <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-zinc-500">Changes</div>
        {applies.length === 0 ? <div className="text-xs text-zinc-500">No changes yet.</div> : (
          <ul className="divide-y divide-zinc-100">
            {applies.map((a) => (
              <li key={a.id}>
                <button className="flex w-full cursor-pointer items-center gap-3 py-2 text-left hover:bg-zinc-50" onClick={() => onOpen(a.id)}>
                  <ApplyStatusBadge status={a.status} />
                  <div className="min-w-0 flex-1"><div className="truncate text-xs text-zinc-800">{describeChange(a.change).join(' · ')}</div><div className="font-mono text-[11px] text-zinc-400">{a.hpaName}</div></div>
                  <div className="text-right text-[11px] text-zinc-500">{fmtTime(a.createdAt)}<div>{a.trigger === 'MANUAL' ? 'manual' : 'schedule'}</div></div>
                </button>
              </li>
            ))}
          </ul>
        )}
      </CardContent></Card>
      <Card><CardContent>
        <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-zinc-500">Timeline</div>
        <Timeline events={events.data ?? []} />
      </CardContent></Card>
    </div>
  );
}

export { RoleBadge };
