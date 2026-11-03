import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { Pause, Pencil, Play, Plus, RefreshCw, Settings, Shield, Trash2 } from 'lucide-react';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { Card, CardContent } from '../../../shared/ui/card';
import { Spinner } from '../../../shared/ui/spinner';
import { useConfirm } from '../../../shared/ui/confirm-dialog';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { useRefreshAnimation } from '../../../shared/hooks';
import { cn } from '../../../lib/utils';
import { describeKind, fmtTime, relTime } from '../../hpa/format';
import { ApplyStatusBadge } from '../../hpa/components/Badges';
import { Timeline } from '../../hpa/components/ApplyDialog';
import { useDeleteTarget, useScheduleAction, useTarget } from '../hooks';
import { describeChange, kindLabel, modeLabel, stateLabel, stateVariant } from '../format';
import AutoscalerEditor from '../components/AutoscalerEditor';
import EditTargetDialog from '../components/EditTargetDialog';
import ScaleApplyDialog from '../components/ScaleApplyDialog';
import ScaleGuardrailDialog from '../components/ScaleGuardrailDialog';
import ScaleManualDialog from '../components/ScaleManualDialog';
import ScaleScheduleDialog from '../components/ScaleScheduleDialog';
import type { Schedule, TargetKind } from '../types';

type Tab = 'schedules' | 'autoscaler' | 'activity';
const TABS: { id: Tab; label: string }[] = [{ id: 'schedules', label: 'Schedules' }, { id: 'autoscaler', label: 'Autoscaler' }, { id: 'activity', label: 'Activity' }];

export default function ScalerTargetDetail() {
  const { kind = 'REDIS', id = '' } = useParams();
  const k = (kind === 'DB' ? 'DB' : 'REDIS') as TargetKind;
  const { data: d, isLoading, isFetching, refetch, error } = useTarget(k, id);
  const { spinning, onRefresh } = useRefreshAnimation(isFetching, refetch);
  const navigate = useNavigate();
  const confirm = useConfirm();
  const remove = useDeleteTarget(() => navigate('/backend/scaler'));
  const [tab, setTab] = useState<Tab>('schedules');
  const [scheduleOpen, setScheduleOpen] = useState(false);
  const [editing, setEditing] = useState<Schedule | undefined>();
  const [manualOpen, setManualOpen] = useState(false);
  const [guardOpen, setGuardOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [applyId, setApplyId] = useState<string | null>(null);

  if (isLoading) return <div className="p-6"><Spinner label="Loading…" /></div>;
  if (!d) return <div className="m-6 rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">{(error as { response?: { data?: { message?: string } } })?.response?.data?.message ?? 'Failed to load this target'}</div>;

  const t = d.target;
  const st = d.state;
  const live = d.applies.filter((a) => !['RESTORED', 'ROLLED_BACK', 'FAILED', 'SKIPPED'].includes(a.status));
  const units = st ? (st.mode === 'READ_POOL' ? 'node' : 'shard') : '';

  return (
    <div className="space-y-5 p-4 sm:p-6">
      <div className="flex flex-wrap items-start gap-3">
        <div>
          <Link to="/backend/scaler" className="text-xs text-sky-700 hover:underline">← All targets</Link>
          <h1 className="text-lg font-semibold text-zinc-900">{t.name}</h1>
          <div className="font-mono text-[11px] text-zinc-400">{t.parent ? `${t.parent} / ` : ''}{t.resource} · {t.project} · {t.location}</div>
          <div className="mt-1.5 flex flex-wrap items-center gap-2 text-xs text-zinc-600">
            <Badge variant={t.kind === 'REDIS' ? 'blue' : 'purple'}>{kindLabel(t.kind)}</Badge>
            {st && <Badge variant="muted">{modeLabel(st.mode)}</Badge>}
            {st && <Badge variant={stateVariant(st.state)} dot>{stateLabel(st.state)}</Badge>}
            {st && <span><b className="text-zinc-900">{st.units}</b> {units}{st.units === 1 ? '' : 's'}{st.mode !== 'READ_POOL' && <> · <b className="text-zinc-900">{st.replicas}</b> replica{st.replicas === 1 ? '' : 's'}</>}</span>}
            {d.guardrail.frozen && <Badge variant="danger">Frozen{d.guardrail.frozenReason ? `: ${d.guardrail.frozenReason}` : ''}</Badge>}
            {d.autoscaler.configured && d.autoscaler.state === 'PAUSED' && <Badge variant="warning">Autoscaler paused</Badge>}
            {live.map((a) => <ApplyStatusBadge key={a.id} status={a.status} />)}
          </div>
        </div>
        <div className="ml-auto flex flex-wrap items-center gap-2">
          <Button variant="secondary" size="icon" onClick={onRefresh} aria-label="Refresh"><RefreshCw className={cn('h-4 w-4', spinning && 'animate-spin')} /></Button>
          <PermissionGate product="autopilot" permission="HPA_GUARDRAIL_EDIT">
            <Button variant="secondary" size="sm" onClick={() => setSettingsOpen(true)}><Settings className="h-4 w-4" />Settings</Button>
            <Button variant="secondary" size="sm" onClick={() => setGuardOpen(true)}><Shield className="h-4 w-4" />Guardrails</Button>
          </PermissionGate>
          <PermissionGate product="autopilot" permission="HPA_APPLY">
            <Button variant="secondary" size="sm" disabled={!st} onClick={() => setManualOpen(true)}><Play className="h-4 w-4" />Scale now</Button>
          </PermissionGate>
          <PermissionGate product="autopilot" permission="HPA_SCHEDULE_EDIT">
            <Button size="sm" disabled={!st} onClick={() => { setEditing(undefined); setScheduleOpen(true); }}><Plus className="h-4 w-4" />New schedule</Button>
          </PermissionGate>
        </div>
      </div>

      {d.cloudError && (
        <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">
          Could not read this target from Google Cloud: {d.cloudError}
          {/permission|forbidden|403/i.test(d.cloudError) && <div className="mt-1 text-xs">The backend's Google service account needs read access to this resource (Memorystore or AlloyDB), plus update access to change anything.</div>}
        </div>
      )}

      <div role="tablist" className="flex gap-1 border-b border-zinc-200">
        {TABS.map((x) => (
          <button key={x.id} role="tab" aria-selected={tab === x.id} onClick={() => setTab(x.id)}
            className={cn('-mb-px cursor-pointer border-b-2 px-3 py-2 text-sm font-medium', tab === x.id ? 'border-zinc-900 text-zinc-900' : 'border-transparent text-zinc-500 hover:text-zinc-800')}>{x.label}</button>
        ))}
      </div>

      {tab === 'schedules' && <SchedulesList schedules={d.schedules} onEdit={(s) => { setEditing(s); setScheduleOpen(true); }} onOpenApply={setApplyId} />}
      {tab === 'autoscaler' && <AutoscalerEditor target={t} />}
      {tab === 'activity' && (
        <div className="space-y-4">
          <div className="grid gap-4 lg:grid-cols-2">
            <Card><CardContent>
              <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-zinc-500">Changes</div>
              {d.applies.length === 0 ? <div className="text-xs text-zinc-500">No changes yet.</div> : (
                <ul className="divide-y divide-zinc-100">
                  {d.applies.map((a) => (
                    <li key={a.id}>
                      <button className="flex w-full cursor-pointer items-center gap-3 py-2 text-left hover:bg-zinc-50" onClick={() => setApplyId(a.id)}>
                        <ApplyStatusBadge status={a.status} />
                        <div className="min-w-0 flex-1 truncate text-xs text-zinc-800">{describeChange(a.change, a.targetKind).join(' · ')}</div>
                        <div className="text-right text-[11px] text-zinc-500">{fmtTime(a.createdAt)}<div>{a.trigger === 'MANUAL' ? 'manual' : 'schedule'}</div></div>
                      </button>
                    </li>
                  ))}
                </ul>
              )}
            </CardContent></Card>
            <Card><CardContent>
              <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-zinc-500">Timeline</div>
              <Timeline events={d.events} />
            </CardContent></Card>
          </div>
          <PermissionGate product="autopilot" permission="HPA_GUARDRAIL_EDIT">
            <div className="flex justify-end">
              <Button variant="ghost" size="sm" loading={remove.isPending}
                onClick={async () => {
                  if (await confirm({ title: 'Remove this target', description: 'It stops being managed here. Nothing in Google Cloud is changed. A target with schedules or a change in flight cannot be removed.', confirmLabel: 'Remove', variant: 'danger' })) remove.mutate(t);
                }}>
                <Trash2 className="h-4 w-4 text-red-600" />Remove target
              </Button>
            </div>
          </PermissionGate>
        </div>
      )}

      <ScaleScheduleDialog open={scheduleOpen} onOpenChange={setScheduleOpen} target={t} state={st} existing={editing} />
      <ScaleManualDialog open={manualOpen} onOpenChange={setManualOpen} target={t} state={st} />
      <ScaleGuardrailDialog open={guardOpen} onOpenChange={setGuardOpen} target={t} value={d.guardrail} />
      <EditTargetDialog open={settingsOpen} onOpenChange={setSettingsOpen} target={t} />
      <ScaleApplyDialog id={applyId} onClose={() => setApplyId(null)} />
    </div>
  );
}

function SchedulesList({ schedules, onEdit, onOpenApply }: { schedules: Schedule[]; onEdit: (s: Schedule) => void; onOpenApply: (id: string) => void }) {
  const act = useScheduleAction();
  const confirm = useConfirm();
  if (schedules.length === 0) {
    return <div className="rounded-lg border border-dashed border-zinc-300 px-4 py-10 text-center text-sm text-zinc-500">No schedules yet. Create one to scale this up ahead of a busy period and keep its autoscaler from shrinking it.</div>;
  }
  return (
    <div className="space-y-3">
      {schedules.map((s) => (
        <Card key={s.id}><CardContent className="space-y-2">
          <div className="flex flex-wrap items-center gap-2">
            <span className="font-semibold text-zinc-900">{s.name}</span>
            <Badge variant={s.status === 'ACTIVE' ? 'success' : s.status === 'PAUSED' ? 'warning' : 'muted'} dot>{s.status.charAt(0) + s.status.slice(1).toLowerCase()}</Badge>
            {s.window.windowOpen && <Badge variant="info">Window open now</Badge>}
            <PermissionGate product="autopilot" permission="HPA_SCHEDULE_EDIT">
              <div className="ml-auto flex gap-1">
                <Button size="icon-sm" variant="ghost" aria-label="Edit" onClick={() => onEdit(s)}><Pencil className="h-4 w-4" /></Button>
                {s.status === 'ACTIVE' && <Button size="icon-sm" variant="ghost" aria-label="Pause" onClick={() => act.mutate({ id: s.id, action: 'pause' })}><Pause className="h-4 w-4" /></Button>}
                {s.status === 'PAUSED' && <Button size="icon-sm" variant="ghost" aria-label="Resume" onClick={() => act.mutate({ id: s.id, action: 'resume' })}><Play className="h-4 w-4" /></Button>}
                <Button size="icon-sm" variant="ghost" aria-label="Delete" onClick={async () => {
                  if (await confirm({ title: 'Delete schedule', description: "Any change it is holding is undone right away: the autoscaler's minimum is put back. Added capacity stays.", confirmLabel: 'Delete', variant: 'danger' })) act.mutate({ id: s.id, action: 'delete' });
                }}><Trash2 className="h-4 w-4 text-red-600" /></Button>
              </div>
            </PermissionGate>
          </div>
          <div className="text-xs text-zinc-600">{describeKind(s.timing)}</div>
          <div className="flex flex-wrap gap-1.5">{describeChange(s.change, s.targetKind).map((c) => <Badge key={c} variant="blue">{c}</Badge>)}</div>
          <div className="text-xs text-zinc-500">
            {s.window.windowOpen ? 'Window is open now' : s.window.nextStart ? `Next window ${fmtTime(s.window.nextStart)} (${relTime(s.window.nextStart)})` : s.status === 'EXPIRED' ? 'Finished' : 'No upcoming window'}
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
