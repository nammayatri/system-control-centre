import { Dialog, DialogBody, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '../../../shared/ui/dialog';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { Spinner } from '../../../shared/ui/spinner';
import { useConfirm } from '../../../shared/ui/confirm-dialog';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { fmtTimeFull, relTime } from '../../hpa/format';
import { ApplyStatusBadge } from '../../hpa/components/Badges';
import { Timeline } from '../../hpa/components/ApplyDialog';
import { useApply, useApplyAction } from '../hooks';
import { describeChange } from '../format';
import type { ApplyAction } from '../api';
import type { ApplyStatus } from '../types';

interface Action { action: ApplyAction; label: string; perm: 'HPA_APPLY' | 'HPA_ROLLBACK'; from: ApplyStatus[]; danger?: boolean; confirm: string }
const ACTIONS: Action[] = [
  { action: 'restore', label: 'Restore now', perm: 'HPA_APPLY', from: ['APPLIED', 'OBSERVING', 'NEEDS_ATTENTION'],
    confirm: "Put the autoscaler's minimum back now, ahead of the window ending? The added capacity stays unless “shrink back” was chosen." },
  { action: 'rollback', label: 'Roll back', perm: 'HPA_ROLLBACK', from: ['APPLYING', 'OBSERVING', 'APPLIED', 'NEEDS_ATTENTION'], danger: true,
    confirm: "Stop and put the autoscaler's minimum back? Capacity that was already added is kept." },
  { action: 'cancel', label: 'Cancel', perm: 'HPA_ROLLBACK', from: ['PENDING'], confirm: 'Cancel this change before it starts?' },
  { action: 'acknowledge', label: 'Give up', perm: 'HPA_ROLLBACK', from: ['NEEDS_ATTENTION'],
    confirm: "Stop handling this and put the autoscaler's minimum back (if it was held)? Capacity that was already added is kept. Check the target by hand afterwards." },
];

export default function ScaleApplyDialog({ id, onClose }: { id: string | null; onClose: () => void }) {
  const q = useApply(id);
  const act = useApplyAction();
  const confirm = useConfirm();
  const a = q.data?.apply;

  return (
    <Dialog open={!!id} onOpenChange={(o) => !o && onClose()}>
      <DialogContent size="xl">
        <DialogHeader>
          <DialogTitle>{a ? `${a.targetKind === 'DB' ? 'Read pool' : 'Valkey'} change` : 'Change'}</DialogTitle>
          <DialogDescription>{a ? `${a.trigger === 'MANUAL' ? 'Manual change' : 'Scheduled change'} by ${a.createdBy}` : ''}</DialogDescription>
        </DialogHeader>
        <DialogBody className="space-y-5">
          {q.isLoading || !a ? <Spinner label="Loading…" /> : (
            <>
              <div className="flex flex-wrap items-center gap-2">
                <ApplyStatusBadge status={a.status} />
                {a.step && <Badge variant="muted">step {a.step.toLowerCase()}</Badge>}
                {a.attempt > 0 && <Badge variant="warning">{a.attempt} retr{a.attempt > 1 ? 'ies' : 'y'}</Badge>}
                {a.deferCount > 0 && <Badge variant="muted">waited for the target {a.deferCount}×</Badge>}
                <div className="ml-auto flex gap-2">
                  {ACTIONS.filter((x) => x.from.includes(a.status)).map((x) => (
                    <PermissionGate key={x.action} product="autopilot" permission={x.perm}>
                      <Button size="sm" variant={x.danger ? 'danger' : 'secondary'} loading={act.isPending}
                        onClick={async () => { if (await confirm({ title: x.label, description: x.confirm, confirmLabel: x.label, variant: x.danger ? 'danger' : 'primary' })) act.mutate({ id: a.id, action: x.action }); }}>
                        {x.label}
                      </Button>
                    </PermissionGate>
                  ))}
                </div>
              </div>

              {a.status === 'NEEDS_ATTENTION' && (
                <div className="rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-xs text-red-800">
                  Automatic handling stopped{a.error ? `: ${a.error}` : ''}. Check the target, then restore, roll back or give up.
                  {(a.afterSpec?.pinned ?? a.afterSpec?.pinIntent) != null && ` The autoscaler's minimum is still held at ${a.afterSpec?.pinned ?? a.afterSpec?.pinIntent} until you do.`}
                </div>
              )}
              {a.rollbackReason && <div className="rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-800">Reason: {a.rollbackReason}</div>}

              <Section title="What it does">
                <div className="flex flex-wrap gap-1.5">{describeChange(a.change, a.targetKind).map((c) => <Badge key={c} variant="blue">{c}</Badge>)}</div>
                <dl className="mt-3 grid grid-cols-2 gap-x-6 gap-y-1 text-xs">
                  <Row label="Before" v={a.beforeSpec ? `${a.beforeSpec.units} ${a.targetKind === 'DB' ? 'nodes' : 'shards'}${a.targetKind === 'REDIS' ? `, ${a.beforeSpec.replicas} replicas` : ''}${a.beforeSpec.minimum != null ? `, autoscaler minimum ${a.beforeSpec.minimum}` : ''}` : 'not recorded yet'} />
                  <Row label="Autoscaler minimum held at" v={a.afterSpec?.pinned != null ? String(a.afterSpec.pinned) : a.afterSpec?.pinIntent != null ? `${a.afterSpec.pinIntent} (being written)` : '—'} />
                  <Row label="Resize operation" v={a.afterSpec?.operation ?? '—'} />
                </dl>
              </Section>

              <Section title="Timing">
                <dl className="grid grid-cols-2 gap-x-6 gap-y-1 text-xs">
                  <T label="Window starts" v={a.windowStart} /><T label="Window ends" v={a.windowEnd} />
                  <T label="Created" v={a.createdAt} /><T label="Finished" v={a.finishedAt} />
                  {a.observeUntil && <T label="Waiting for the resize until" v={a.observeUntil} />}
                </dl>
              </Section>

              <Section title="Timeline">
                <Timeline events={q.data?.events ?? []} />
              </Section>
            </>
          )}
        </DialogBody>
      </DialogContent>
    </Dialog>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return <div><div className="mb-1.5 text-xs font-semibold uppercase tracking-wide text-zinc-500">{title}</div>{children}</div>;
}

function Row({ label, v }: { label: string; v: string }) {
  return <div className="col-span-2 flex justify-between gap-3 border-b border-zinc-100 py-1"><dt className="text-zinc-500">{label}</dt><dd className="text-right text-zinc-800">{v}</dd></div>;
}

function T({ label, v }: { label: string; v: string | null }) {
  return <div className="flex justify-between gap-3 border-b border-zinc-100 py-1"><dt className="text-zinc-500">{label}</dt><dd className="text-right text-zinc-800" title={v ?? ''}>{v ? `${fmtTimeFull(v)} (${relTime(v)})` : '—'}</dd></div>;
}
