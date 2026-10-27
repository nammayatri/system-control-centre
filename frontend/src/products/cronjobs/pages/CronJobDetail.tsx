import { useEffect, useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { Pause, Pencil, Play, Plus, RefreshCw, Tag, Trash2 } from 'lucide-react';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { Card } from '../../../shared/ui/card';
import { Input } from '../../../shared/ui/input';
import { useConfirm } from '../../../shared/ui/confirm-dialog';
import { Spinner } from '../../../shared/ui/spinner';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { cn } from '../../../lib/utils';
import { useRefreshAnimation } from '../../../shared/hooks';
import { errorMessage } from '../api';
import { useCronJob, useDelete, useSuspend, useUpdateEnv, useUpdateImage, useUpdateSchedule } from '../hooks';
import { ImageDialog } from '../ImageDialog';
import { EnvDialog } from '../EnvDialog';
import { fmtTime, relTime } from '../format';
import type { ContainerDetail, EnvEntry } from '../types';

function EnvValue({ e }: { e: EnvEntry }) {
  const ref = e.valueFrom?.secretKeyRef ?? e.valueFrom?.configMapKeyRef;
  if (ref) {
    return (
      <span className="font-mono text-xs">
        <Badge variant={e.valueFrom?.secretKeyRef ? 'purple' : 'blue'} className="mr-1.5">{e.valueFrom?.secretKeyRef ? 'Secret' : 'ConfigMap'}</Badge>
        {ref.name}<span className="text-zinc-400"> : </span>{ref.key}
      </span>
    );
  }
  if (e.valueFrom?.fieldRef) return <span className="font-mono text-xs text-zinc-500">field {e.valueFrom.fieldRef.fieldPath}</span>;
  if (e.valueFrom?.resourceFieldRef) return <span className="font-mono text-xs text-zinc-500">resource {e.valueFrom.resourceFieldRef.resource}</span>;
  if (e.masked) return <span className="text-xs italic text-zinc-400">hidden (looks like a credential)</span>;
  return <span className="break-all font-mono text-xs">{e.value === '' ? <span className="text-zinc-400">(empty)</span> : e.value}</span>;
}

export default function CronJobDetail() {
  const { name = '' } = useParams();
  const [params] = useSearchParams();
  const namespace = params.get('namespace') ?? '';
  const navigate = useNavigate();
  const confirm = useConfirm();
  const { data, isLoading, isFetching, refetch, error } = useCronJob(namespace, name);
  const { spinning, onRefresh } = useRefreshAnimation(isFetching, refetch);

  const [editingSchedule, setEditingSchedule] = useState(false);
  const [schedule, setSchedule] = useState('');
  const [timeZone, setTimeZone] = useState('');
  const [envDialog, setEnvDialog] = useState<{ container: string; entry?: EnvEntry } | null>(null);
  const [imageDialog, setImageDialog] = useState<ContainerDetail | null>(null);

  const saveSchedule = useUpdateSchedule(namespace, name, () => setEditingSchedule(false));
  const suspend = useSuspend(namespace, name);
  const env = useUpdateEnv(namespace, name, () => setEnvDialog(null));
  const image = useUpdateImage(namespace, name, () => setImageDialog(null));
  const del = useDelete(namespace, name, () => navigate(`/backend/cronjobs?namespace=${encodeURIComponent(namespace)}`));

  const s = data?.summary;
  useEffect(() => {
    if (s && !editingSchedule) { setSchedule(s.schedule); setTimeZone(s.timeZone ?? ''); }
  }, [s, editingSchedule]);

  if (isLoading) return <div className="flex justify-center p-12"><Spinner /></div>;
  if (error || !data || !s) {
    return (
      <div className="space-y-3 p-6">
        <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">Could not load {name} in “{namespace}”: {errorMessage(error)}</div>
        <Link to={`/backend/cronjobs?namespace=${encodeURIComponent(namespace)}`} className="text-sm text-sky-700 hover:underline">← Back to CronJobs</Link>
      </div>
    );
  }

  const onDelete = async () => {
    const running = data.activeJobs.length;
    const ok = await confirm({
      title: `Delete ${name}?`,
      description: running > 0
        ? `${running} job(s) are running right now. Deleting the CronJob terminates them. Suspending it instead would let them finish.`
        : `This removes the CronJob from “${namespace}”. Its schedule will no longer fire.`,
      confirmLabel: 'Delete',
      variant: 'danger',
    });
    if (ok) del.mutate(running > 0);
  };

  const onRemoveEnv = async (c: ContainerDetail, e: EnvEntry) => {
    const ok = await confirm({ title: `Remove ${e.name}?`, description: `Removes it from container ${c.name}. Runs that start after this will not see it.`, confirmLabel: 'Remove', variant: 'danger' });
    if (ok) env.mutate({ container: c.name, remove: [e.name] });
  };

  return (
    <div className="space-y-4 p-4 sm:p-6">
      <div className="flex flex-wrap items-center gap-3">
        <div className="min-w-0">
          <Link to={`/backend/cronjobs?namespace=${encodeURIComponent(namespace)}`} className="text-xs text-sky-700 hover:underline">← CronJobs</Link>
          <h1 className="flex flex-wrap items-center gap-2 text-lg font-semibold text-zinc-900">
            {name}
            {s.suspend ? <Badge variant="warning">Suspended</Badge> : <Badge variant="success">Scheduled</Badge>}
            {s.active > 0 && <Badge variant="info">{s.active} running</Badge>}
          </h1>
          <p className="text-xs text-zinc-500">Namespace {namespace} · last run {s.lastScheduleTime ? `${fmtTime(s.lastScheduleTime)} (${relTime(s.lastScheduleTime)})` : 'never'}</p>
        </div>
        <div className="ml-auto flex flex-wrap items-center gap-2">
          <Button variant="secondary" size="icon" onClick={onRefresh} aria-label="Refresh"><RefreshCw className={cn('h-4 w-4', spinning && 'animate-spin')} /></Button>
          <PermissionGate product="autopilot" permission="CRONJOB_EDIT">
            <Button variant="secondary" size="sm" loading={suspend.isPending} onClick={() => suspend.mutate(!s.suspend)}>
              {s.suspend ? <><Play className="h-4 w-4" />Resume</> : <><Pause className="h-4 w-4" />Suspend</>}
            </Button>
          </PermissionGate>
          <PermissionGate product="autopilot" permission="CRONJOB_DELETE">
            <Button variant="danger" size="sm" loading={del.isPending} onClick={onDelete}><Trash2 className="h-4 w-4" />Delete</Button>
          </PermissionGate>
        </div>
      </div>

      <Card className="space-y-3 p-4">
        <div className="flex items-center justify-between">
          <h2 className="text-sm font-semibold text-zinc-900">Schedule</h2>
          <PermissionGate product="autopilot" permission="CRONJOB_EDIT">
            {!editingSchedule && <Button variant="ghost" size="sm" onClick={() => setEditingSchedule(true)}><Pencil className="h-4 w-4" />Edit</Button>}
          </PermissionGate>
        </div>
        {editingSchedule ? (
          <form className="space-y-3" onSubmit={(e) => { e.preventDefault(); saveSchedule.mutate({ schedule, timeZone }); }}>
            <div className="grid gap-3 sm:grid-cols-2">
              <Input label="Cron expression" value={schedule} onChange={(e) => setSchedule(e.target.value)} className="font-mono" hint="minute hour day-of-month month day-of-week, or @daily, @hourly …" />
              <Input label="Time zone" value={timeZone} onChange={(e) => setTimeZone(e.target.value)} placeholder="Asia/Kolkata" hint="Empty uses the cluster's zone (usually UTC)." />
            </div>
            <div className="flex gap-2">
              <Button type="submit" size="sm" loading={saveSchedule.isPending} disabled={!schedule.trim()}>Save</Button>
              <Button type="button" variant="secondary" size="sm" onClick={() => setEditingSchedule(false)}>Cancel</Button>
            </div>
          </form>
        ) : (
          <div className="flex flex-wrap items-baseline gap-x-6 gap-y-1 text-sm">
            <span className="font-mono text-base text-zinc-900">{s.schedule}</span>
            <span className="text-zinc-500">{s.timeZone ?? 'cluster default zone'}</span>
            <span className="text-zinc-500">concurrency {s.concurrencyPolicy ?? 'Allow'}</span>
          </div>
        )}
      </Card>

      {data.containers.map((c) => (
        <Card key={c.name} className="overflow-hidden">
          <div className="flex flex-wrap items-center gap-2 border-b border-zinc-100 px-4 py-3">
            <div className="min-w-0">
              <div className="text-sm font-semibold text-zinc-900">Container {c.name}</div>
              <div className="break-all font-mono text-xs text-zinc-500">{c.image}</div>
            </div>
            <PermissionGate product="autopilot" permission="CRONJOB_EDIT">
              <Button className="ml-auto" size="sm" variant="secondary" onClick={() => setImageDialog(c)}><Tag className="h-4 w-4" />Change version</Button>
              <Button size="sm" variant="secondary" onClick={() => setEnvDialog({ container: c.name })}><Plus className="h-4 w-4" />Add variable</Button>
            </PermissionGate>
          </div>
          {c.envFrom.length > 0 && (
            <div className="flex flex-wrap items-center gap-1.5 border-b border-zinc-100 px-4 py-2 text-xs text-zinc-500">
              All keys from:
              {c.envFrom.map((f) => <Badge key={f.kind + f.name} variant={f.kind === 'Secret' ? 'purple' : 'blue'}>{f.kind} {f.name}</Badge>)}
            </div>
          )}
          {c.env.length === 0 ? (
            <div className="px-4 py-6 text-center text-sm text-zinc-500">No environment variables.</div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead className="bg-zinc-50 text-left text-xs uppercase tracking-wide text-zinc-500">
                  <tr><th className="px-4 py-2">Name</th><th className="px-3">Value</th><th className="w-24 px-4" /></tr>
                </thead>
                <tbody>
                  {c.env.map((e) => (
                    <tr key={e.name} className="border-t border-zinc-100">
                      <td className="px-4 py-2.5 font-mono text-xs font-medium text-zinc-900">{e.name}</td>
                      <td className="px-3"><EnvValue e={e} /></td>
                      <td className="px-4">
                        <PermissionGate product="autopilot" permission="CRONJOB_EDIT">
                          <div className="flex justify-end gap-1">
                            <Button variant="ghost" size="icon-sm" aria-label={`Edit ${e.name}`} onClick={() => setEnvDialog({ container: c.name, entry: e })}><Pencil className="h-4 w-4" /></Button>
                            <Button variant="ghost" size="icon-sm" aria-label={`Remove ${e.name}`} onClick={() => onRemoveEnv(c, e)}><Trash2 className="h-4 w-4 text-red-600" /></Button>
                          </div>
                        </PermissionGate>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </Card>
      ))}

      <ImageDialog
        open={!!imageDialog}
        onOpenChange={(o) => !o && setImageDialog(null)}
        container={imageDialog?.name ?? ''}
        image={imageDialog?.image ?? ''}
        saving={image.isPending}
        onSave={(img) => imageDialog && image.mutate({ container: imageDialog.name, image: img })}
      />
      <EnvDialog
        open={!!envDialog}
        onOpenChange={(o) => !o && setEnvDialog(null)}
        container={envDialog?.container ?? ''}
        entry={envDialog?.entry}
        saving={env.isPending}
        onSave={(entry) => envDialog && env.mutate({ container: envDialog.container, set: [entry] })}
      />
    </div>
  );
}
