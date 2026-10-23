import { Dialog, DialogBody, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '../../../shared/ui/dialog';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { Spinner } from '../../../shared/ui/spinner';
import { useConfirm } from '../../../shared/ui/confirm-dialog';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { useApply, useApplyAction } from '../hooks';
import { describeChange, fmtTimeFull, relTime } from '../format';
import type { ApplyAction } from '../api';
import type { Apply, ApplyEvent, ApplyStatus } from '../types';
import { ApplyStatusBadge } from './Badges';
import DiffTable, { diffJson } from './DiffTable';

const KIND_STYLE: Record<string, string> = {
  health_breach: 'bg-red-500', verify_failed: 'bg-red-500', needs_attention: 'bg-red-500', failed: 'bg-red-500',
  rolled_back: 'bg-amber-500', deferred: 'bg-amber-500', refused: 'bg-amber-500', health_degraded: 'bg-amber-500', health_breach_ignored: 'bg-amber-500',
  applied: 'bg-emerald-500', observed_healthy: 'bg-emerald-500', restored: 'bg-emerald-500',
};

interface Action { action: ApplyAction; label: string; perm: 'HPA_APPLY' | 'HPA_ROLLBACK'; from: ApplyStatus[]; danger?: boolean; confirm: string }
const ACTIONS: Action[] = [
  { action: 'restore', label: 'Restore now', perm: 'HPA_APPLY', from: ['APPLIED', 'OBSERVING', 'NEEDS_ATTENTION'], confirm: 'Put the original values back now, ahead of the window ending?' },
  { action: 'rollback', label: 'Roll back', perm: 'HPA_ROLLBACK', from: ['APPLYING', 'OBSERVING', 'APPLIED', 'NEEDS_ATTENTION'], danger: true, confirm: 'Roll this change back to the values it replaced?' },
  { action: 'cancel', label: 'Cancel', perm: 'HPA_ROLLBACK', from: ['PENDING'], confirm: 'Cancel this change before it is applied?' },
  { action: 'acknowledge', label: 'Acknowledge', perm: 'HPA_ROLLBACK', from: ['NEEDS_ATTENTION'], confirm: 'Mark this as handled? The HPA is left as it is; check it by hand first.' },
];

export default function ApplyDialog({ id, onClose }: { id: string | null; onClose: () => void }) {
  const q = useApply(id);
  const act = useApplyAction();
  const confirm = useConfirm();
  const a = q.data?.apply;

  return (
    <Dialog open={!!id} onOpenChange={(o) => !o && onClose()}>
      <DialogContent size="xl">
        <DialogHeader>
          <DialogTitle>{a ? `${a.service} · ${a.hpaName}` : 'Change'}</DialogTitle>
          <DialogDescription>{a ? `${a.trigger === 'MANUAL' ? 'Manual change' : 'Scheduled change'} by ${a.createdBy}` : ''}</DialogDescription>
        </DialogHeader>
        <DialogBody className="space-y-5">
          {q.isLoading || !a ? <Spinner label="Loading…" /> : (
            <>
              <div className="flex flex-wrap items-center gap-2">
                <ApplyStatusBadge status={a.status} />
                {a.step && <Badge variant="muted">step {a.step.toLowerCase()}</Badge>}
                {a.attempt > 0 && <Badge variant="warning">{a.attempt} retry{a.attempt > 1 ? 'ies' : ''}</Badge>}
                {a.deferCount > 0 && <Badge variant="muted">deferred {a.deferCount}×</Badge>}
                <div className="ml-auto flex gap-2">
                  {ACTIONS.filter((x) => x.from.includes(a.status)).map((x) => (
                    <PermissionGate key={x.action} product="autopilot" permission={x.perm} appGroup={a.appGroup}>
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
                  Automatic handling gave up{a.error ? `: ${a.error}` : ''}. Check the HPA, then restore, roll back or acknowledge.
                </div>
              )}
              {a.rollbackReason && <div className="rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-800">Reason: {a.rollbackReason}</div>}

              <Section title="What it changes">
                <div className="flex flex-wrap gap-1.5">{describeChange(a.change).map((c) => <Badge key={c} variant="blue">{c}</Badge>)}</div>
                {a.beforeSpec && a.afterSpec && <div className="mt-3"><DiffTable diff={diffJson(a.beforeSpec, a.afterSpec)} /></div>}
              </Section>

              <Section title="Timing">
                <dl className="grid grid-cols-2 gap-x-6 gap-y-1 text-xs">
                  <T label="Window starts" v={a.windowStart} /><T label="Window ends" v={a.windowEnd} />
                  <T label="Created" v={a.createdAt} /><T label="Finished" v={a.finishedAt} />
                  {a.observeUntil && <T label="Observing until" v={a.observeUntil} />}
                  {a.unhealthySince && <T label="Unhealthy since" v={a.unhealthySince} />}
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

function T({ label, v }: { label: string; v: string | null }) {
  return <div className="flex justify-between gap-3 border-b border-zinc-100 py-1"><dt className="text-zinc-500">{label}</dt><dd className="text-right text-zinc-800" title={v ?? ''}>{v ? `${fmtTimeFull(v)} (${relTime(v)})` : '—'}</dd></div>;
}

export function Timeline({ events }: { events: ApplyEvent[] }) {
  if (events.length === 0) return <div className="text-xs text-zinc-500">Nothing recorded yet.</div>;
  return (
    <ol className="space-y-2">
      {events.map((e) => (
        <li key={e.id} className="flex gap-3 text-xs">
          <span className={`mt-1.5 h-2 w-2 shrink-0 rounded-full ${KIND_STYLE[e.kind] ?? 'bg-zinc-400'}`} />
          <div className="min-w-0 flex-1">
            <div className="text-zinc-800">{e.message}</div>
            <div className="text-zinc-400">{fmtTimeFull(e.ts)} · {e.kind.replace(/_/g, ' ')}</div>
          </div>
        </li>
      ))}
    </ol>
  );
}

export type { Apply };
