import React from 'react';
import { Link, useParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Badge } from '../../../../shared/ui/badge';
import { Button } from '../../../../shared/ui/button';
import { useConfirm } from '../../../../shared/ui/confirm-dialog';
import { PermissionGate } from '../../../../core/auth/PermissionGate';
import { StatusBadge } from '../../components/StatusBadge';
import { abortGroupRun, approveGroupRun, fetchGroupRun, resumeGroupRun } from '../../api';
import type { GroupRun, GroupRunState, GroupRunStep } from '../../api';

const stateVariant: Record<GroupRunState, 'info' | 'warning' | 'danger' | 'success' | 'muted'> = {
  PENDING_APPROVAL: 'info',
  RUNNING: 'warning',
  HALTED: 'danger',
  COMPLETED: 'success',
  ABORTED: 'muted',
};

const stateLabel: Record<GroupRunState, string> = {
  PENDING_APPROVAL: 'Awaiting approval',
  RUNNING: 'Running',
  HALTED: 'Halted',
  COMPLETED: 'Completed',
  ABORTED: 'Aborted',
};

export const GroupStateBadge: React.FC<{ state: GroupRunState }> = ({ state }) => (
  <Badge variant={stateVariant[state]}>{stateLabel[state]}</Badge>
);

const stepNote = (s: GroupRunStep): string => {
  if (s.state === 'SKIPPED') return 'Skipped';
  if (s.state === 'WAITING') return 'Waiting for earlier stages';
  return '';
};

const GroupReleaseDetail: React.FC = () => {
  const { runId = '' } = useParams<{ runId: string }>();
  const qc = useQueryClient();
  const confirm = useConfirm();

  const { data: run, isLoading, error } = useQuery({
    queryKey: ['release-group', runId],
    queryFn: () => fetchGroupRun(runId),
    enabled: !!runId,
    refetchInterval: q => {
      const st = (q.state.data as GroupRun | undefined)?.state;
      return st === 'COMPLETED' || st === 'ABORTED' ? false : 5000;
    },
  });

  const onDone = (msg: string) => (data: GroupRun) => {
    toast.success(msg);
    qc.setQueryData(['release-group', runId], data);
    qc.invalidateQueries({ queryKey: ['release-groups'] });
  };
  const onError = (err: any) => toast.error(err?.response?.data?.message || err.message || 'Action failed');

  const approve = useMutation({ mutationFn: () => approveGroupRun(runId), onSuccess: onDone('Group approved — stage 1 is starting'), onError });
  const resume = useMutation({ mutationFn: (skip: boolean) => resumeGroupRun(runId, skip), onSuccess: onDone('Group resumed'), onError });
  const abort = useMutation({ mutationFn: () => abortGroupRun(runId), onSuccess: onDone('Group aborted'), onError });

  if (isLoading) return <p className="text-sm text-zinc-400">Loading…</p>;
  if (error || !run) return <p className="text-sm text-red-600">Could not load this group release.</p>;

  const stages = [...new Set(run.steps.map(s => s.stageIdx))].sort((a, b) => a - b);
  const groups = [...new Set(run.steps.map(s => s.appGroup))];
  const live = run.state === 'PENDING_APPROVAL' || run.state === 'RUNNING' || run.state === 'HALTED';

  const confirmApprove = async () => {
    const ok = await confirm({
      title: 'Approve group release?',
      description: `This approves all ${run.steps.length} services at once. Stage 1 starts immediately; later stages start automatically as the earlier ones complete.`,
      confirmLabel: 'Approve',
    });
    if (ok) approve.mutate();
  };
  const confirmAbort = async () => {
    const ok = await confirm({
      title: 'Abort group release?',
      description: 'Services that have not started are discarded. Services already rolling out keep going — stop those from their own release page.',
      confirmLabel: 'Abort group',
      variant: 'danger',
    });
    if (ok) abort.mutate();
  };

  return (
    <div className="space-y-5 pb-12">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="space-y-1">
          <div className="flex items-center gap-2">
            <h1 className="text-lg font-semibold text-zinc-900">{run.bundleName}</h1>
            <GroupStateBadge state={run.state} />
          </div>
          <p className="text-sm text-zinc-500">
            {run.env} · created by {run.createdBy}
            {run.approvedBy && ` · approved by ${run.approvedBy}`}
            {run.description && ` · ${run.description}`}
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          {run.state === 'PENDING_APPROVAL' && (
            <PermissionGate product="autopilot" permission="RELEASE_APPROVE">
              <Button variant="success" loading={approve.isPending} onClick={confirmApprove}>Approve all</Button>
            </PermissionGate>
          )}
          {run.state === 'HALTED' && (
            <PermissionGate product="autopilot" permission="RELEASE_APPROVE">
              <Button variant="secondary" loading={resume.isPending} onClick={() => resume.mutate(false)}>Resume</Button>
              <Button variant="secondary" loading={resume.isPending} onClick={() => resume.mutate(true)}>Skip failed &amp; resume</Button>
            </PermissionGate>
          )}
          <PermissionGate product="autopilot" permission="RELEASE_CREATE">
            <Link to={`/backend/group-releases/new?from=${run.runId}`}>
              <Button variant="secondary">Clone</Button>
            </Link>
          </PermissionGate>
          {live && (
            <PermissionGate product="autopilot" permission="RELEASE_DISCARD">
              <Button variant="danger" loading={abort.isPending} onClick={confirmAbort}>Abort</Button>
            </PermissionGate>
          )}
        </div>
      </div>

      {run.state === 'HALTED' && (
        <div className="bg-red-50 border border-red-200 text-red-800 px-4 py-3 rounded-xl text-sm">
          <strong>Halted:</strong> {run.haltReason || 'a service failed'}. Later stages are on hold. Restart the failed release
          from its page then Resume, or skip it to carry on without it.
        </div>
      )}
      {run.state === 'ABORTED' && run.haltReason && (
        <div className="bg-zinc-50 border border-zinc-200 text-zinc-700 px-4 py-3 rounded-xl text-sm">{run.haltReason}</div>
      )}

      <ol className="space-y-3">
        {stages.map((si, idx) => {
          const stageSteps = run.steps.filter(s => s.stageIdx === si);
          const first = stageSteps[0];
          return (
            <li key={si} className="bg-white rounded-xl border border-zinc-200">
              <div className="px-4 py-2.5 border-b border-zinc-100 flex items-center gap-2">
                <span className="text-xs font-mono text-zinc-400">{idx + 1}</span>
                <h3 className="text-sm font-medium text-zinc-900">{first.stageName}</h3>
                <span className="text-[10px] uppercase tracking-wide text-zinc-400">
                  {first.stageMode === 'PARALLEL' ? 'all at once' : 'one after another'}
                </span>
              </div>
              <ul className="divide-y divide-zinc-100">
                {stageSteps.map(s => (
                  <li key={s.releaseId} className="px-4 py-2.5 flex flex-wrap items-center justify-between gap-2">
                    <Link to={`/backend/releases/${s.releaseId}`} className="text-sm font-medium text-zinc-900 hover:underline">
                      {s.service} <span className="font-normal text-zinc-400">({s.appGroup})</span>
                    </Link>
                    <div className="flex items-center gap-2">
                      <span className="text-xs text-zinc-400">{stepNote(s)}</span>
                      {s.releaseStatus && <StatusBadge status={s.releaseStatus} />}
                    </div>
                  </li>
                ))}
              </ul>
            </li>
          );
        })}
      </ol>
      <p className="text-xs text-zinc-400">
        Covers {groups.join(', ')}. Approval needs the Approve permission on each of these app groups.
      </p>
    </div>
  );
};

export default GroupReleaseDetail;
