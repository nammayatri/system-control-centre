import { useEffect, useMemo, useState } from 'react';
import { Link, useParams, useNavigate } from 'react-router-dom';
import { ArrowLeft, CheckCircle2, Copy, Send, Smartphone, Apple, Cpu, Info, Trash2, Undo2 } from 'lucide-react';
import { useMobileGroup, useDispatchMobileReleases } from '../../hooks';
import { approveRelease, createMobileRevert, discardRelease, getMobileRevertDraft, mobileApi } from '../../api';
import type { BulkActionResp, RevertDraft } from '../../api';
import { PermissionGate } from '../../../../core/auth/PermissionGate';
import {
  Dialog,
  DialogBody,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '../../../../shared/ui/dialog';
import { useAuth } from '../../../../core/auth/AuthContext';
import { GroupStageChip } from '../../components/GroupStageChip';
import { ReleaseStatusBadge } from '../../components/ReleaseStatusBadge';
import { BrandLogo } from '../../components/BrandLogo';
import { versionWithBuild } from '../../utils';
import { Button } from '../../../../shared/ui/button';
import { TableSkeleton } from '../../../../shared/ui/skeleton';
import { cn } from '../../../../lib/utils';
import { toast } from 'sonner';
import type { APRelease } from '../../api';

// Mobile rows reuse the legacy tracker columns: appGroup=app name,
// service=surface, env=platform. See backend insertMobileTracker for the
// origin of this mapping.
const PlatformIcon = ({ platform }: { platform: string }) =>
  platform === 'ios'
    ? <Apple className="w-4 h-4 text-zinc-500" />
    : <Cpu className="w-4 h-4 text-emerald-600" />;

// Mirrors the backend dispatch grouping (Handlers/Release.hs): consumer rows
// share one GH run per (surface, platform); provider (driver) rows additionally
// split by (version, destination) — their workflow takes one version_name per run.
function runKeyOf(r: APRelease): string {
  return r.service === 'driver'
    ? `${r.service}|${r.env}|${r.new_version}|${r.release_context?.destination ?? ''}`
    : `${r.service}|${r.env}`;
}

// ── Pipeline stepper: one glance answers "where is this group?" ──────
const STEPS = ['Draft', 'Approve', 'Build', 'Promote', 'Review', 'Rollout', 'Live'];
const STAGE_STEP: Record<string, number> = {
  approval: 1,
  dispatch: 2,
  building: 2,
  promote: 3,
  in_review: 4,
  releasing: 5,
  rolling_out: 5,
  done: 6,
};

type StepMarks = Record<number, { ok: number; failed: number }>;

function GroupStepper({
  stage,
  failedStep = null,
  marks = null,
  marksLabel = null,
}: {
  stage?: string;
  // Step index where a fully-failed group died (Failed marker renders THERE,
  // not at the end — a build failure never reached Promote, let alone Live).
  failedStep?: number | null;
  // step index -> counts of rows sitting there. Non-empty switches the
  // stepper from "group stage" to "where are the apps": one bright dot per
  // occupied stage, ×n on the label when several share it.
  marks?: StepMarks | null;
  // Prefix shown in marks mode ("Selected" when a selection narrows the
  // marks; null for the everyone view).
  marksLabel?: string | null;
}) {
  const selMode = !!marks && Object.keys(marks).length > 0;
  if (!stage && !selMode) return null;
  const active = failedStep ?? STAGE_STEP[stage ?? ''] ?? 2;
  const failed = failedStep != null;
  const maxMark = selMode ? Math.max(...Object.keys(marks!).map(Number)) : -1;
  const aria = selMode
    ? `${marksLabel ?? 'Apps'}: ` +
      Object.entries(marks!)
        .map(([i, m]) => `${m.ok + m.failed} at ${STEPS[Number(i)]}${m.failed > 0 ? ' (failed)' : ''}`)
        .join(', ')
    : failed
      ? `Failed during ${STEPS[active]}`
      : `Release progress: ${STEPS[active]}`;
  return (
    <div className="hidden md:flex items-start" aria-label={aria}>
      {selMode && marksLabel && (
        <span className="text-[9px] font-semibold uppercase tracking-wider text-violet-600 mr-1.5 mt-[3px] select-none">
          {marksLabel}
        </span>
      )}
      {STEPS.map((s, i) => {
        const m = selMode ? marks![i] : undefined;
        const isActive = selMode ? !!m : i === active;
        const isFilled = selMode ? i <= maxMark : i <= active;
        const isRose = selMode ? !!m && m.ok === 0 && m.failed > 0 : failed && i === active;
        const count = m ? m.ok + m.failed : 0;
        const label = !selMode && failed && i === active ? 'Failed' : s;
        return (
          <span key={s} className="flex items-start">
            {i > 0 && (
              <span
                className={cn('h-px w-4 lg:w-6 mt-[5px]', isFilled ? 'bg-violet-400' : 'bg-zinc-200')}
              />
            )}
            <span
              className="flex flex-col items-center gap-1 w-12"
              title={
                selMode && m
                  ? `${count} selected app${count === 1 ? '' : 's'} at ${s}`
                  : !selMode && failed && i === active
                    ? `Failed during ${s}`
                    : undefined
              }
            >
              <span
                className={cn(
                  'w-2.5 h-2.5 rounded-full transition-colors',
                  isActive
                    ? isRose
                      ? 'bg-rose-500 ring-4 ring-rose-100'
                      : 'bg-violet-600 ring-4 ring-violet-100'
                    : isFilled
                      ? 'bg-violet-400'
                      : 'bg-zinc-200',
                )}
              />
              <span
                className={cn(
                  'text-[9px] leading-none whitespace-nowrap',
                  isActive
                    ? isRose
                      ? 'text-rose-600 font-semibold'
                      : 'text-violet-700 font-semibold'
                    : 'text-zinc-400',
                )}
              >
                {label}
                {selMode && count > 1 ? ` ×${count}` : ''}
              </span>
            </span>
          </span>
        );
      })}
    </div>
  );
}

// A MANUAL row holding a store tag it never dispatched for = store-sync
// adopted the draft (the build was uploaded outside SCC).
const isAdopted = (r: APRelease) =>
  r.mode === 'MANUAL' && !!r.release_context?.tag_pushed && !r.release_context?.dispatch_id;

export default function ReleaseGroupDetail() {
  const { groupId } = useParams<{ groupId: string }>();
  const navigate = useNavigate();
  const { user } = useAuth();

  // Server-side group fetch (indexed release_group_id column) — members arrive
  // as normalized APRelease rows, any age (no 24h window), and the GET kicks
  // the backend's cooldown-gated store refresh for stale member apps.
  const { data: group, isLoading, isError, refetch } = useMobileGroup(groupId);

  const groupReleases = useMemo(() => group?.members ?? [], [group]);

  const groupingMissing = !isLoading && (isError || (!!group && groupReleases.length === 0));

  // Every row is selectable; feasibility is judged PER VERB below, so the
  // stage buttons enable/disable off the selection instead of hiding rows.
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const allChecked =
    groupReleases.length > 0 && groupReleases.every((r) => selectedIds.has(r.id));

  const toggleAll = () => {
    setSelectedIds(allChecked ? new Set() : new Set(groupReleases.map((r) => r.id)));
  };

  // ── Changelog → Slack: recovery for a post that failed (e.g. a transient
  // Slack error). Re-runs the same settle-time send server-side. ──
  const slack = group?.changelogSlack;
  const [resendingSlack, setResendingSlack] = useState(false);
  const handleResendSlack = async () => {
    if (!groupId || resendingSlack) return;
    setResendingSlack(true);
    try {
      const res = await mobileApi.resendGroupChangelog(groupId);
      if (res.state === 'sent') toast.success('Changelog posted to Slack');
      else if (res.state === 'failed')
        toast.error(`Slack still failing: ${res.error ?? 'unknown error'}`);
      else toast.message('Nothing to post yet — builds not settled');
      void refetch();
    } catch {
      toast.error('Resend failed');
    } finally {
      setResendingSlack(false);
    }
  };

  // ── Per-verb eligibility (mirrors the backend guards, so the UI never
  // offers what the server would reject; the server still re-checks). ──
  const phaseOf = (r: APRelease) => r.release_context?.display_phase ?? '';
  const VERB_ELIGIBLE: Record<string, (r: APRelease) => boolean> = {
    approve: (r) => r.status === 'CREATED' && r.is_approved !== 1,
    dispatch: (r) => r.status === 'CREATED' && r.is_approved === 1,
    promote: (r) => phaseOf(r) === 'internal_held' && r.release_context?.promotable !== false,
    release: (r) => r.env === 'ios' && phaseOf(r) === 'approved',
    rollout: (r) =>
      r.env === 'android' && ['approved', 'rolling_out', 'halted'].includes(phaseOf(r)),
    halt: (r) => phaseOf(r) === 'rolling_out',
    resume: (r) => phaseOf(r) === 'halted',
    releaseAll: (r) => ['rolling_out', 'halted'].includes(phaseOf(r)),
    markApproved: (r) => r.env === 'android' && phaseOf(r) === 'in_review',
    markRejected: (r) => r.env === 'android' && phaseOf(r) === 'in_review',
    withdraw: (r) => r.env === 'ios' && phaseOf(r) === 'in_review',
    // Mirrors mobileRevertCreateH guards: only shipped, non-debug builds that
    // haven't already been reverted (the server re-checks everything).
    revert: (r) =>
      r.status === 'COMPLETED' &&
      !r.metadata?.reverted_by &&
      r.release_context?.build_type !== 'debug',
    // A never-dispatched draft can be thrown away (CREATED → DISCARDED). Once
    // it's building/shipped, Revert/Abort are the right tools, not Discard.
    discard: (r) => r.status === 'CREATED',
  };
  const selectedRows = useMemo(
    () => groupReleases.filter((r) => selectedIds.has(r.id)),
    [groupReleases, selectedIds],
  );
  // Which verb button is being hovered — its target rows highlight, the rest
  // dim, so "Approve (2)" visibly means THESE two rows.
  const [hoveredVerb, setHoveredVerb] = useState<string | null>(null);

  // Each row's next lifecycle action, shown as a chip so the mapping from
  // buttons to rows is readable without hovering anything.
  const NEXT_VERB_ORDER: [string, string][] = [
    ['approve', 'Approve'],
    ['dispatch', 'Dispatch'],
    ['promote', 'Promote'],
    ['release', 'Release'],
    ['markApproved', 'Mark review'],
    ['resume', 'Resume'],
    ['rollout', 'Rollout'],
  ];
  const nextStepOf = (r: APRelease): string | null => {
    // Dead rows have no next step — the stale wf phase would otherwise
    // read "Building…" on an aborted build.
    if (['ABORTED', 'USER_ABORTED', 'GCLT_ABORTED', 'DISCARDED', 'REVERTED'].includes(r.status))
      return null;
    for (const [verb, label] of NEXT_VERB_ORDER) if (VERB_ELIGIBLE[verb](r)) return label;
    if (phaseOf(r) === 'in_review') return 'Waiting on review';
    if (phaseOf(r) === 'building') return 'Building…';
    return null;
  };
  // ── Where does a row sit on the stepper? Same vocabulary as the badges. ──
  const ROW_STEP: Record<string, number> = {
    building: 2,
    internal_held: 3,
    in_review: 4,
    approved: 5,
    rolling_out: 5,
    halted: 5,
    live: 6,
    distributed: 6,
    superseded: 6,
  };
  const rowMark = (r: APRelease): { step: number; failed: boolean } => {
    if (phaseOf(r) === 'rejected') return { step: 4, failed: true };
    // Dead rows mark rose at the stage the abort/failure interrupted.
    if (['ABORTED', 'USER_ABORTED', 'GCLT_ABORTED', 'DISCARDED', 'REVERTED'].includes(r.status)) {
      const wf = r.release_context?.mb_wf_status ?? '';
      const step = ['MBReviewApproved', 'MBRollingOut'].includes(wf)
        ? 5
        : ['MBSubmittingForReview', 'MBInReview'].includes(wf)
          ? 4
          : wf === 'MBTagPushed'
            ? 3
            : 2;
      return { step, failed: true };
    }
    // Draft rows: pending approval sits at Approve, approved-held at Build.
    if (r.status === 'CREATED') return { step: r.is_approved === 1 ? 2 : 1, failed: false };
    return { step: ROW_STEP[phaseOf(r)] ?? 2, failed: false };
  };
  // Stepper marks: the selection when there is one, otherwise EVERY member —
  // the corner always shows where apps actually are, never a single blended
  // stage that hides a straggler.
  const stepperMarks = useMemo(() => {
    const rows = selectedRows.length > 0 ? selectedRows : groupReleases;
    if (rows.length === 0) return null;
    const marks: Record<number, { ok: number; failed: number }> = {};
    for (const r of rows) {
      const { step, failed } = rowMark(r);
      if (!marks[step]) marks[step] = { ok: 0, failed: 0 };
      if (failed) marks[step].failed++;
      else marks[step].ok++;
    }
    return marks;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedRows, groupReleases]);

  // Selected rows a verb can actually act on.
  const eligibleSelected = (verb: string) => selectedRows.filter(VERB_ELIGIBLE[verb]);
  // Revert/Copy read the selection as a FILTER, not a requirement: a selection
  // narrows them to those apps; no selection means the whole group.
  const revertTargets = (selectedRows.length > 0 ? selectedRows : groupReleases).filter(
    VERB_ELIGIBLE.revert,
  );
  const copyTargets = selectedRows.length > 0 ? selectedRows : groupReleases;
  // Why a verb is disabled — for the tooltip on the greyed button.
  const disabledReason = (verb: string): string | undefined => {
    if (eligibleSelected(verb).length > 0) return undefined;
    if (selectedRows.length === 0) return 'Select apps first';
    return groupReleases.some(VERB_ELIGIBLE[verb])
      ? 'None of the selected apps is in the right state for this'
      : 'No app in this group is in the right state for this';
  };

  const toggleOne = (id: string) => {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  // Live preview of what THIS selection dispatches as ("3 apps → 1 build run"),
  // so the one-vs-many-runners consequence is visible BEFORE the click. Only
  // counts dispatch-ELIGIBLE selected rows — an already-built app must not
  // inflate the promised run.
  const dispatchPreview = useMemo(() => {
    const rows = groupReleases.filter((r) => selectedIds.has(r.id) && VERB_ELIGIBLE.dispatch(r));
    if (rows.length === 0) return null;
    const runs = new Map<string, APRelease[]>();
    for (const r of rows) {
      const k = runKeyOf(r);
      runs.set(k, [...(runs.get(k) ?? []), r]);
    }
    const parts = Array.from(runs.entries()).map(([k, rs]) => {
      const platform = k.split('|')[1];
      return rs.length > 1 ? `${platform} ×${rs.length} shared` : `${platform} ×1`;
    });
    return { apps: rows.length, runs: runs.size, parts };
  }, [groupReleases, selectedIds]);

  const dispatchMutation = useDispatchMobileReleases();
  // One verb runs at a time; its buttons show a spinner, the rest disable.
  const [busyVerb, setBusyVerb] = useState<string | null>(null);
  const [promoteOpen, setPromoteOpen] = useState(false);
  const [rolloutOpen, setRolloutOpen] = useState(false);
  const [rejectOpen, setRejectOpen] = useState(false);
  const [revertOpen, setRevertOpen] = useState(false);

  const appNameOf = (id: string) => {
    const r = groupReleases.find((x) => x.id === id);
    return r ? `${r.appGroup} ${r.env}` : id;
  };

  // Sequential per-release runner (Play quota / ASC token reuse) with
  // per-item isolation and an aggregate verdict — the approve-loop pattern
  // generalised to every per-id stage endpoint.
  const runPerId = async (
    verb: string,
    rows: APRelease[],
    fn: (id: string) => Promise<unknown>,
    doneWord: string,
  ) => {
    if (rows.length === 0 || busyVerb) return;
    setBusyVerb(verb);
    let ok = 0;
    for (const r of rows) {
      try {
        await fn(r.id);
        ok++;
      } catch (err: any) {
        toast.error(`${appNameOf(r.id)}: ${err?.response?.data?.message || err.message || 'failed'}`);
      }
    }
    setBusyVerb(null);
    if (ok > 0) toast.success(`${doneWord} ${ok} app${ok === 1 ? '' : 's'}`);
    void refetch();
  };

  const onApproveSelected = () =>
    runPerId(
      'approve',
      eligibleSelected('approve'),
      (id) => approveRelease(id, user?.email || 'local_admin'),
      'Approved',
    );

  const onDispatchSelected = async () => {
    const rows = eligibleSelected('dispatch');
    if (rows.length === 0 || busyVerb) return;
    setBusyVerb('dispatch');
    try {
      const resp = await dispatchMutation.mutateAsync(rows.map((r) => r.id));
      const nRuns = resp.dispatches.length;
      toast.success(
        `Dispatched ${rows.length} app${rows.length === 1 ? '' : 's'} in ${nRuns} build run${nRuns === 1 ? '' : 's'}`,
      );
      void refetch();
    } catch {
      // hook handles error toast
    } finally {
      setBusyVerb(null);
    }
  };

  // BulkActionResp verdicts → per-app toasts (bulk promote / bulk rollout).
  const reportBulk = (resp: BulkActionResp, doneWord: string) => {
    if (resp.barSucceeded > 0) toast.success(`${doneWord} ${resp.barSucceeded} app${resp.barSucceeded === 1 ? '' : 's'}`);
    for (const item of resp.barResults) {
      if (!item.birOk) toast.error(`${appNameOf(item.birReleaseId)}: ${item.birMessage || 'failed'}`);
      else if (item.birWarning) toast.warning?.(`${appNameOf(item.birReleaseId)}: ${item.birWarning}`);
    }
    void refetch();
  };

  const onPromoteSubmit = async (notes: string, iosPhased: boolean, androidPercent: number | null) => {
    const rows = eligibleSelected('promote');
    if (rows.length === 0 || busyVerb) return;
    setBusyVerb('promote');
    try {
      const resp = await mobileApi.bulkPromote(
        rows.map((r) => ({
          bpiReleaseId: r.id,
          bpiReleaseNotes: notes,
          ...(r.env === 'ios' ? { bpiEnablePhasedRelease: iosPhased } : {}),
          ...(r.env === 'android' && androidPercent != null
            ? { bpiInitialRolloutPercent: androidPercent }
            : {}),
        })),
      );
      setPromoteOpen(false);
      reportBulk(resp, 'Promoted');
    } catch (err: any) {
      toast.error(err?.response?.data?.message || err.message || 'Promote failed');
    } finally {
      setBusyVerb(null);
    }
  };

  const onRolloutSubmit = async (percent: number) => {
    const rows = eligibleSelected('rollout');
    if (rows.length === 0 || busyVerb) return;
    setBusyVerb('rollout');
    try {
      const resp = await mobileApi.bulkRollout(
        rows.map((r) => ({ briReleaseId: r.id, briPercent: percent })),
      );
      setRolloutOpen(false);
      reportBulk(resp, `Rollout set to ${percent}% for`);
    } catch (err: any) {
      toast.error(err?.response?.data?.message || err.message || 'Rollout failed');
    } finally {
      setBusyVerb(null);
    }
  };

  const onRejectSubmit = async (reason: string) => {
    setRejectOpen(false);
    await runPerId(
      'markRejected',
      eligibleSelected('markRejected'),
      (id) => mobileApi.markRejected(id, reason),
      'Marked rejected',
    );
  };

  // ── Stage-bar building blocks (closures over selection/eligibility) ──
  const VerbButton = ({
    verb,
    label,
    icon,
    primary = false,
    onClick,
    targets: targetsOverride,
    emptyReason,
  }: {
    verb: string;
    label: string;
    icon?: React.ReactNode;
    primary?: boolean;
    onClick: () => void;
    // Override the default selection-driven targeting (e.g. revert's
    // "selection narrows, none = whole group" semantics).
    targets?: APRelease[];
    emptyReason?: string;
  }) => {
    const targets = targetsOverride ?? eligibleSelected(verb);
    const n = targets.length;
    const reason = targetsOverride
      ? n === 0
        ? emptyReason ?? 'Nothing eligible'
        : undefined
      : disabledReason(verb);
    const disabled = n === 0 || (busyVerb !== null && busyVerb !== verb);
    const names = targets.map((r) => `${r.appGroup} ${r.env}`).join(', ');
    return (
      // span carries the tooltip — disabled buttons swallow mouse events
      <span
        title={reason ?? `${label.replace(/…$/, '')}: ${names}`}
        onMouseEnter={() => setHoveredVerb(verb)}
        onMouseLeave={() => setHoveredVerb(null)}
      >
        <Button
          size="sm"
          variant={primary ? 'primary' : 'secondary'}
          onClick={onClick}
          loading={busyVerb === verb}
          disabled={disabled}
        >
          {icon}
          {label}
          {n > 0 ? ` (${n})` : ''}
        </Button>
      </span>
    );
  };

  // Re-poll every 5s while the page is open — picks up status transitions
  // (CREATED → INPROGRESS → COMPLETED) without forcing the user to refresh.
  // Note: useMobileGroup also polls at 15s; this overlay gives us a tighter
  // cadence, and each poll re-triggers the backend's stale-store kick.
  useEffect(() => {
    const t = setInterval(() => { void refetch(); }, 5000);
    return () => clearInterval(t);
  }, [refetch]);

  return (
    <div className="flex flex-col flex-1 w-full pb-12">
      <div className="flex items-center gap-2 mb-4">
        <Link
          to="/mobile/releases"
          className="inline-flex items-center gap-1 text-sm text-zinc-600 hover:text-zinc-900"
        >
          <ArrowLeft className="w-4 h-4" /> Mobile releases
        </Link>
      </div>

      <div className="bg-white rounded-xl border border-zinc-200">
        <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100 flex flex-wrap items-center justify-between gap-3">
          <div className="min-w-0">
            <h1 className="text-base sm:text-lg font-semibold text-zinc-900 flex items-center gap-2 flex-wrap">
              <Smartphone className="w-4 h-4 text-violet-600" />
              {group?.label || 'Release group'}
              {/* THE stage chip — same component + server derivation as the
                  home row and the stepper, so no surface can disagree. */}
              {group?.summary && (
                <GroupStageChip summary={group.summary} total={groupReleases.length} />
              )}
            </h1>
            <div className="flex items-center gap-2 mt-0.5">
              <button
                onClick={() => {
                  void navigator.clipboard.writeText(groupId ?? '');
                  toast.success('Group ID copied');
                }}
                title={groupId}
                className="inline-flex items-center gap-1 text-[11px] text-zinc-400 hover:text-zinc-700 font-mono border border-zinc-200 rounded px-1.5 py-0.5 transition-colors"
              >
                {groupId?.slice(0, 8)}… ⧉
              </button>
              {/* Changelog → Slack outcome: only for groups that opted in. A
                  failed post surfaces the reason + a one-click Resend. */}
              {slack?.state === 'failed' && (
                <span className="inline-flex items-center gap-1.5">
                  <span
                    title={slack.error ?? undefined}
                    className="inline-flex items-center gap-1 text-[11px] font-medium rounded-full border border-rose-200 bg-rose-50 text-rose-700 px-2 py-0.5"
                  >
                    <Send className="w-3 h-3" /> Changelog → Slack failed
                  </span>
                  <button
                    onClick={handleResendSlack}
                    disabled={resendingSlack}
                    className="inline-flex items-center gap-1 text-[11px] font-medium rounded-full border border-violet-300 text-violet-700 hover:bg-violet-50 px-2 py-0.5 transition-colors disabled:opacity-50"
                  >
                    {resendingSlack ? 'Sending…' : 'Resend to Slack'}
                  </button>
                </span>
              )}
              {slack?.state === 'sent' && (
                <span className="inline-flex items-center gap-1 text-[11px] text-emerald-600" title="Changelog posted to Slack">
                  <CheckCircle2 className="w-3 h-3" /> Sent to Slack
                </span>
              )}
            </div>
          </div>
          <GroupStepper
            stage={group?.summary?.stage}
            marks={stepperMarks}
            marksLabel={selectedRows.length > 0 ? 'Selected' : null}
            failedStep={(() => {
              const c = group?.summary?.counts ?? {};
              const shipped = (c['live'] ?? 0) + (c['superseded'] ?? 0) + (c['distributed'] ?? 0);
              if (group?.summary?.stage !== 'done' || shipped > 0) return null;
              // How far did the furthest member get before dying? The wf
              // status remembers the stage the abort/failure interrupted.
              const wfStep = (wf: string): number => {
                if (['MBReviewApproved', 'MBRollingOut'].includes(wf)) return 5; // Rollout
                if (['MBSubmittingForReview', 'MBInReview'].includes(wf)) return 4; // Review
                if (wf === 'MBTagPushed') return 3; // died held before/at Promote
                return 2; // Build (never produced an artifact)
              };
              return Math.max(
                2,
                ...groupReleases.map((r) => wfStep(r.release_context?.mb_wf_status ?? '')),
              );
            })()}
          />
        </header>

        {/* ── Stage action bar: EVERY stage verb, always visible — disabled
            (never hidden) when the selection can't take that action. The
            segments mirror the stepper: Build → Store review → Rollout. ── */}
        <div className="px-4 py-2.5 sm:px-6 border-b border-zinc-100 flex flex-wrap items-center gap-x-4 gap-y-2">
          <span className="inline-flex items-center gap-2">
            <span className="text-[9px] font-semibold uppercase tracking-wider text-zinc-400 select-none">
              Build
            </span>
            <VerbButton
              verb="approve"
              label="Approve"
              icon={<CheckCircle2 className="w-4 h-4" />}
              primary={group?.summary?.primaryVerb === 'approve'}
              onClick={onApproveSelected}
            />
            <VerbButton
              verb="dispatch"
              label="Dispatch"
              icon={<Send className="w-4 h-4" />}
              primary={group?.summary?.primaryVerb === 'dispatch'}
              onClick={onDispatchSelected}
            />
            {/* Discard a never-dispatched draft — sits with the other draft-stage
                verbs. Destructive → explicit selection + confirm. */}
            <PermissionGate product="autopilot" permission="RELEASE_DISCARD">
              <VerbButton
                verb="discard"
                label="Discard"
                icon={<Trash2 className="w-4 h-4" />}
                onClick={() => {
                  const targets = eligibleSelected('discard');
                  if (
                    window.confirm(
                      `Discard ${targets.length} draft${targets.length === 1 ? '' : 's'}? This can't be undone — the draft${targets.length === 1 ? '' : 's'} won't build.`,
                    )
                  )
                    void runPerId('discard', targets, (id) => discardRelease(id), 'Discarded');
                }}
              />
            </PermissionGate>
          </span>
          <span className="w-px h-6 bg-zinc-200 hidden sm:block" />
          <span className="inline-flex items-center gap-2">
            <span className="text-[9px] font-semibold uppercase tracking-wider text-zinc-400 select-none">
              Store review
            </span>
            <VerbButton
              verb="promote"
              label="Promote"
              primary={group?.summary?.primaryVerb === 'promote'}
              onClick={() => setPromoteOpen(true)}
            />
            {/* Review-outcome verbs live here permanently — every verb is
                always visible, disabled (with the reason) when not applicable. */}
            <VerbButton
              verb="markApproved"
              label="Mark approved"
              onClick={() =>
                runPerId('markApproved', eligibleSelected('markApproved'), mobileApi.markApproved, 'Marked approved')
              }
            />
            <VerbButton
              verb="markRejected"
              label="Mark rejected"
              onClick={() => setRejectOpen(true)}
            />
            <VerbButton
              verb="withdraw"
              label="Withdraw (iOS)"
              onClick={() => {
                if (window.confirm(`Withdraw ${eligibleSelected('withdraw').length} iOS app(s) from App Store review?`))
                  void runPerId('withdraw', eligibleSelected('withdraw'), mobileApi.withdraw, 'Withdrew');
              }}
            />
          </span>
          <span className="w-px h-6 bg-zinc-200 hidden sm:block" />
          <span className="inline-flex items-center gap-2">
            <span className="text-[9px] font-semibold uppercase tracking-wider text-zinc-400 select-none">
              Rollout
            </span>
            {/* "Release" starts shipping the approved iOS build — a rollout
                action, so it sits with the rollout controls. */}
            <VerbButton
              verb="release"
              label="Release (iOS)"
              primary={group?.summary?.primaryVerb === 'release_or_rollout'}
              onClick={() =>
                runPerId('release', eligibleSelected('release'), mobileApi.releaseApproved, 'Released')
              }
            />
            <VerbButton
              verb="rollout"
              label="Set %"
              primary={['release_or_rollout', 'rollout_controls'].includes(group?.summary?.primaryVerb ?? '')}
              onClick={() => setRolloutOpen(true)}
            />
            <VerbButton
              verb="halt"
              label="Halt"
              onClick={() => runPerId('halt', eligibleSelected('halt'), mobileApi.rolloutHalt, 'Halted')}
            />
            <VerbButton
              verb="resume"
              label="Resume"
              onClick={() => runPerId('resume', eligibleSelected('resume'), mobileApi.rolloutResume, 'Resumed')}
            />
            <VerbButton
              verb="releaseAll"
              label="100%"
              onClick={() => {
                if (window.confirm(`Complete the rollout (100%) for ${eligibleSelected('releaseAll').length} app(s)?`))
                  void runPerId('releaseAll', eligibleSelected('releaseAll'), mobileApi.rolloutReleaseAll, 'Completed');
              }}
            />
          </span>
          <span className="w-px h-6 bg-zinc-200 hidden sm:block" />
          <span className="inline-flex items-center gap-2">
            <span className="text-[9px] font-semibold uppercase tracking-wider text-zinc-400 select-none">
              Recover
            </span>
            <PermissionGate product="autopilot" permission="RELEASE_REVERT">
              <VerbButton
                verb="revert"
                label="Revert"
                icon={<Undo2 className="w-4 h-4" />}
                targets={revertTargets}
                emptyReason={
                  selectedRows.length > 0
                    ? 'No selected app has a shipped (COMPLETED) build to revert'
                    : 'No app in this group has a shipped (COMPLETED) build to revert'
                }
                // A single-app revert opens the FULL revert page (source
                // branch/commit, auto-changelog, rolled-back commits, diff,
                // warnings). Multi-app uses the compact bulk dialog.
                onClick={() =>
                  revertTargets.length === 1
                    ? navigate(`/mobile/releases/${revertTargets[0].id}/revert`)
                    : setRevertOpen(true)
                }
              />
            </PermissionGate>
            <PermissionGate product="autopilot" permission="RELEASE_CREATE">
              <span
                title={
                  selectedRows.length > 0
                    ? `Start a new release with the ${copyTargets.length} selected app${copyTargets.length === 1 ? '' : 's'} prefilled`
                    : "Start a new release with this group's apps and changelog prefilled"
                }
              >
                <Button
                  variant="secondary"
                  size="sm"
                  onClick={() => {
                    const only =
                      selectedRows.length > 0
                        ? `&only=${copyTargets.map((r) => encodeURIComponent(r.id)).join(',')}`
                        : '';
                    navigate(`/mobile/releases/new?copyFrom=${groupId}${only}`);
                  }}
                >
                  <Copy className="w-4 h-4" />
                  Copy{selectedRows.length > 0 ? ` (${copyTargets.length})` : ''}
                </Button>
              </span>
            </PermissionGate>
          </span>
        </div>

        {/* Dispatch preview: teaches the one-vs-many-runs semantics at selection
            time — apps selected TOGETHER share one GitHub run per platform. */}
        {dispatchPreview && (
          <div className="px-4 py-2.5 sm:px-6 border-b border-blue-100 bg-blue-50/60 text-xs text-blue-900 flex flex-wrap items-center gap-x-2 gap-y-1">
            <Send className="w-3.5 h-3.5 shrink-0" />
            <span className="font-semibold">
              {dispatchPreview.apps} app{dispatchPreview.apps === 1 ? '' : 's'} selected →{' '}
              {dispatchPreview.runs} build run{dispatchPreview.runs === 1 ? '' : 's'}
            </span>
            <span className="text-blue-700">({dispatchPreview.parts.join(' · ')})</span>
            <span className="text-blue-700/80">
              — apps in a shared run build together, each at its own version;
              un-selected apps stay here and dispatch later as a separate run.
            </span>
          </div>
        )}

        {groupingMissing && (
          <div className="px-4 py-3 sm:px-6 border-b border-amber-200 bg-amber-50 text-amber-800 text-xs flex gap-2 items-start">
            <Info className="w-4 h-4 mt-0.5 shrink-0" />
            <span>
              No release group found for this ID — it may have been created
              before the group column existed,
              or the ID is wrong.
            </span>
          </div>
        )}

        {isLoading ? (
          <TableSkeleton rows={4} cols={6} />
        ) : groupReleases.length === 0 ? (
          <div className="py-16 text-center text-zinc-400 text-sm">
            No releases in this group.
          </div>
        ) : (
          <>
            <div className="hidden md:block overflow-x-auto">
              <table className="w-full text-left whitespace-nowrap">
                <thead>
                  <tr className="bg-zinc-50 border-b border-zinc-200 text-[11px] text-zinc-500 font-medium uppercase tracking-wider">
                    <th className="py-3 px-4 w-10">
                      <input
                        type="checkbox"
                        checked={allChecked}
                        onChange={toggleAll}
                        className="rounded border-zinc-300 accent-zinc-900"
                      />
                    </th>
                    <th className="py-3 px-4">App</th>
                    <th className="py-3 px-4">Surface</th>
                    <th className="py-3 px-4">Platform</th>
                    <th className="py-3 px-4">Version</th>
                    <th className="py-3 px-4">Status</th>
                    <th className="py-3 px-4">Next step</th>
                    <th className="py-3 px-4">Actions</th>
                  </tr>
                </thead>
                <tbody className="text-sm">
                  {groupReleases.map((r) => {
                    const checked = selectedIds.has(r.id);
                    // Revert targets the whole group when nothing is selected.
                    const inScope =
                      checked || (hoveredVerb === 'revert' && selectedIds.size === 0);
                    const verbTarget =
                      hoveredVerb != null && inScope && VERB_ELIGIBLE[hoveredVerb]?.(r);
                    return (
                      <tr
                        key={r.id}
                        onClick={() => toggleOne(r.id)}
                        className={cn(
                          'border-b border-zinc-100 transition-all cursor-pointer',
                          checked
                            ? 'bg-violet-50/50 hover:bg-violet-50/70'
                            : 'bg-white hover:bg-zinc-50',
                          // hovering a verb button: its targets glow, the rest fade
                          verbTarget && 'bg-violet-100/80 hover:bg-violet-100/80',
                          hoveredVerb != null && !verbTarget && 'opacity-40',
                        )}
                      >
                        <td className="py-3 px-4">
                          <input
                            type="checkbox"
                            checked={checked}
                            onChange={() => toggleOne(r.id)}
                            onClick={(e) => e.stopPropagation()}
                            className="rounded border-zinc-300 accent-zinc-900"
                          />
                        </td>
                        <td className="py-3 px-4 font-medium text-zinc-800">
                          <span className="inline-flex items-center gap-2">
                            <BrandLogo brand={r.appGroup} surface={r.service === 'driver' ? 'driver' : undefined} size="sm" />
                            {r.appGroup}
                          </span>
                        </td>
                        <td className="py-3 px-4 text-xs text-zinc-600">{r.service}</td>
                        <td className="py-3 px-4">
                          <span className="inline-flex items-center gap-1.5 text-xs text-zinc-600">
                            <PlatformIcon platform={r.env} /> {r.env}
                          </span>
                        </td>
                        <td className="py-3 px-4 font-mono text-xs text-zinc-600">{versionWithBuild(r)}</td>
                        <td className="py-3 px-4">
                          <div className="flex items-center gap-1.5 flex-wrap">
                            <ReleaseStatusBadge release={r} />
                            {r.is_approved === 1 && (
                              <span className="rounded px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-emerald-700 text-white">
                                APPROVED
                              </span>
                            )}
                            {isAdopted(r) && (
                              <span
                                className="inline-flex items-center rounded-full border border-amber-200 bg-amber-50 px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide text-amber-800"
                                title="This build was uploaded to the store outside SCC — the draft was adopted and its build stages skipped."
                              >
                                Adopted from store
                              </span>
                            )}
                          </div>
                        </td>
                        <td className="py-3 px-4">
                          {nextStepOf(r) ? (
                            <span
                              className={cn(
                                'inline-flex items-center gap-1 text-[10px] font-semibold uppercase tracking-wide rounded-full border px-2 py-0.5',
                                ['Waiting on review', 'Building…'].includes(nextStepOf(r)!)
                                  ? 'text-zinc-400 border-zinc-200 bg-white'
                                  : 'text-violet-700 border-violet-200 bg-violet-50',
                              )}
                            >
                              {!['Waiting on review', 'Building…'].includes(nextStepOf(r)!) && '→'}{' '}
                              {nextStepOf(r)}
                            </span>
                          ) : (
                            <span className="text-xs text-zinc-300">—</span>
                          )}
                        </td>
                        <td className="py-3 px-4">
                          <button
                            onClick={(e) => {
                              e.stopPropagation();
                              navigate(`/mobile/releases/${r.id}`);
                            }}
                            className="text-xs text-zinc-600 hover:text-zinc-900 underline"
                          >
                            Open
                          </button>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>

            {/* Mobile cards */}
            <div className="md:hidden divide-y divide-zinc-100">
              {groupReleases.map((r) => {
                const checked = selectedIds.has(r.id);
                return (
                  <div
                    key={r.id}
                    onClick={() => toggleOne(r.id)}
                    className={cn('p-4 cursor-pointer transition-colors', checked && 'bg-violet-50/50')}
                  >
                    <div className="flex items-start gap-3">
                      <input
                        type="checkbox"
                        checked={checked}
                        onChange={() => toggleOne(r.id)}
                        onClick={(e) => e.stopPropagation()}
                        className="mt-1 rounded border-zinc-300 accent-zinc-900"
                      />
                      <div className="min-w-0 flex-1">
                        <div className="flex items-center gap-2 text-sm font-medium text-zinc-900">
                          <BrandLogo brand={r.appGroup} surface={r.service === 'driver' ? 'driver' : undefined} size="sm" />
                          <span className="truncate">{r.appGroup}</span>
                        </div>
                        <div className="text-xs text-zinc-500 mt-0.5">
                          {r.service} ·{' '}
                          <span className="inline-flex items-center gap-1">
                            <PlatformIcon platform={r.env} /> {r.env}
                          </span>
                        </div>
                        <div className="flex items-center gap-1.5 flex-wrap mt-2">
                          <ReleaseStatusBadge release={r} />
                          {r.is_approved === 1 && (
                            <span className="rounded px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-emerald-700 text-white">
                              APPROVED
                            </span>
                          )}
                          {isAdopted(r) && (
                            <span
                              className="inline-flex items-center rounded-full border border-amber-200 bg-amber-50 px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide text-amber-800"
                              title="This build was uploaded to the store outside SCC — the draft was adopted and its build stages skipped."
                            >
                              Adopted from store
                            </span>
                          )}
                          {nextStepOf(r) && (
                            <span className="inline-flex items-center gap-1 text-[10px] font-semibold uppercase tracking-wide rounded-full border border-violet-200 bg-violet-50 px-2 py-0.5 text-violet-700">
                              → {nextStepOf(r)}
                            </span>
                          )}
                        </div>
                        <div className="text-[11px] text-zinc-500 font-mono mt-2">
                          {versionWithBuild(r)}
                        </div>
                      </div>
                    </div>
                  </div>
                );
              })}
            </div>
          </>
        )}
      </div>

      <PromoteGroupDialog
        open={promoteOpen}
        onClose={() => setPromoteOpen(false)}
        rows={eligibleSelected('promote')}
        busy={busyVerb === 'promote'}
        defaultFraction={group?.androidReviewFraction ?? null}
        onSubmit={onPromoteSubmit}
      />
      <RolloutGroupDialog
        open={rolloutOpen}
        onClose={() => setRolloutOpen(false)}
        rows={eligibleSelected('rollout')}
        busy={busyVerb === 'rollout'}
        onSubmit={onRolloutSubmit}
      />
      <RejectReasonDialog
        open={rejectOpen}
        onClose={() => setRejectOpen(false)}
        count={eligibleSelected('markRejected').length}
        onSubmit={onRejectSubmit}
      />
      <RevertGroupDialog
        open={revertOpen}
        onClose={() => setRevertOpen(false)}
        rows={revertTargets}
        onDone={() => {
          setRevertOpen(false);
          void refetch();
        }}
      />
    </div>
  );
}

// ── Dialogs ──────────────────────────────────────────────────────────

type RevertRowState = {
  loading: boolean;
  error?: string;
  draft?: RevertDraft;
  versionName: string;
  versionCode: string;
};

/** Revert N selected shipped apps. Each row fetches its own draft from the
 * existing single-release endpoints (target + suggested next version differ
 * per app), then reverts are created sequentially — every one lands as a new
 * CREATED draft in THIS group (the backend inherits release_group_id). Rows
 * whose plan needs a manual source commit link to the full revert page. */
function RevertGroupDialog({
  open,
  onClose,
  rows,
  onDone,
}: {
  open: boolean;
  onClose: () => void;
  rows: APRelease[];
  onDone: () => void;
}) {
  const [states, setStates] = useState<Record<string, RevertRowState>>({});
  const [overrideLog, setOverrideLog] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!open) return;
    setOverrideLog('');
    setStates(
      Object.fromEntries(rows.map((r) => [r.id, { loading: true, versionName: '', versionCode: '' }])),
    );
    rows.forEach((r) => {
      getMobileRevertDraft(r.id)
        .then((d) =>
          setStates((s) => ({
            ...s,
            [r.id]: {
              loading: false,
              draft: d,
              versionName: d.rdSuggestedVersion,
              versionCode: d.rdSuggestedCode != null ? String(d.rdSuggestedCode) : '',
            },
          })),
        )
        .catch((err) =>
          setStates((s) => ({
            ...s,
            [r.id]: {
              loading: false,
              error: err?.response?.data?.message || err?.message || 'failed to load draft',
              versionName: '',
              versionCode: '',
            },
          })),
        );
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);

  const setField = (id: string, field: 'versionName' | 'versionCode', v: string) =>
    setStates((s) => ({ ...s, [id]: { ...s[id], [field]: v } }));

  const manualRequired = (st?: RevertRowState) => st?.draft?.rdBuildSourceKind === 'manual_required';
  const readyRows = rows.filter((r) => states[r.id]?.draft && !manualRequired(states[r.id]));

  const submit = async () => {
    for (const r of readyRows) {
      const st = states[r.id];
      if (!st.versionName.trim()) {
        toast.error(`${r.appGroup} ${r.env}: new version name is required`);
        return;
      }
      if (r.env === 'android' && !/^\d+$/.test(st.versionCode.trim())) {
        toast.error(`${r.appGroup} ${r.env}: a numeric version code is required`);
        return;
      }
    }
    setBusy(true);
    let ok = 0;
    // Sequential on purpose — same reason as runPerId (store API quotas).
    for (const r of readyRows) {
      const st = states[r.id];
      try {
        await createMobileRevert(r.id, {
          rrNewVersionName: st.versionName.trim(),
          rrNewVersionCode: r.env === 'android' ? parseInt(st.versionCode.trim(), 10) : null,
          rrChangelog: overrideLog.trim() || st.draft!.rdChangelog,
          rrSourceCommit: null,
        });
        ok++;
      } catch (err: any) {
        toast.error(`${r.appGroup} ${r.env}: ${err?.response?.data?.message || err?.message || 'revert failed'}`);
      }
    }
    setBusy(false);
    if (ok > 0) toast.success(`Created ${ok} revert draft${ok === 1 ? '' : 's'} — approve & dispatch below`);
    onDone();
  };

  return (
    <Dialog open={open} onOpenChange={(v) => !v && onClose()}>
      <DialogContent size="lg" fullScreenOnMobile={false}>
        <DialogHeader>
          <DialogTitle>
            Revert {rows.length} app{rows.length === 1 ? '' : 's'}
          </DialogTitle>
        </DialogHeader>
        <DialogBody className="space-y-3">
          <p className="text-xs text-zinc-500">
            Each revert becomes a new higher-versioned draft in this group and ships through the
            normal approve → dispatch pipeline — nothing touches the stores right now.
          </p>
          {rows.map((r) => {
            const st = states[r.id];
            return (
              <div key={r.id} className="rounded-lg border border-zinc-200 px-3 py-2.5">
                <div className="flex items-center justify-between gap-2 flex-wrap">
                  <span className="inline-flex items-center gap-1.5 text-sm font-medium text-zinc-900">
                    <PlatformIcon platform={r.env} />
                    {r.appGroup}
                    <span className="text-xs text-zinc-400">{r.env}</span>
                  </span>
                  {st?.loading ? (
                    <span className="text-xs text-zinc-400">Loading draft…</span>
                  ) : st?.error ? (
                    <span className="text-xs text-rose-600">{st.error}</span>
                  ) : st?.draft ? (
                    <span className="text-xs text-zinc-500 font-mono">
                      {st.draft.rdBadVersion} → {st.draft.rdTargetVersion || st.draft.rdPrevGoodVersion}
                    </span>
                  ) : null}
                </div>
                {st?.draft && manualRequired(st) && (
                  <p className="mt-1.5 text-xs text-amber-700">
                    No SCC artifact below this version — a manual source commit is needed.{' '}
                    <Link to={`/mobile/releases/${r.id}/revert`} className="underline">
                      Use the full revert page
                    </Link>
                    .
                  </p>
                )}
                {st?.draft && !manualRequired(st) && (
                  <div className="mt-2 flex items-end gap-2 flex-wrap">
                    <label className="block">
                      <span className="text-[11px] font-medium text-zinc-600 uppercase tracking-wider">
                        New version
                      </span>
                      <input
                        value={st.versionName}
                        onChange={(e) => setField(r.id, 'versionName', e.target.value)}
                        className="mt-1 block w-36 h-8 border border-zinc-300 rounded-md px-2 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-zinc-400"
                      />
                    </label>
                    {r.env === 'android' && (
                      <label className="block">
                        <span className="text-[11px] font-medium text-zinc-600 uppercase tracking-wider">
                          Code
                        </span>
                        <input
                          type="number"
                          value={st.versionCode}
                          onChange={(e) => setField(r.id, 'versionCode', e.target.value)}
                          className="mt-1 block w-28 h-8 border border-zinc-300 rounded-md px-2 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-zinc-400"
                        />
                      </label>
                    )}
                    {st.draft.rdBuildSourceKind === 'rebuild_lower' && (
                      <span className="pb-1.5 text-[11px] text-amber-700">
                        target has no artifact — rebuilds from {st.draft.rdPrevGoodVersion}
                      </span>
                    )}
                  </div>
                )}
              </div>
            );
          })}
          <label className="block">
            <span className="text-xs font-medium text-zinc-600">
              Changelog override (optional — blank keeps each app's auto-generated rollback notes)
            </span>
            <textarea
              value={overrideLog}
              onChange={(e) => setOverrideLog(e.target.value)}
              rows={2}
              className="mt-1 w-full border border-zinc-200 rounded-lg p-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-300"
            />
          </label>
        </DialogBody>
        <DialogFooter>
          <Button variant="secondary" onClick={onClose} disabled={busy}>
            Cancel
          </Button>
          <Button onClick={() => void submit()} loading={busy} disabled={readyRows.length === 0}>
            Create {readyRows.length} revert{readyRows.length === 1 ? '' : 's'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

// Config fraction (0,1) -> percent string for the % input ("0.000006" -> "0.0006").
const fractionToPercentStr = (f?: number | null): string => {
  if (!f || f <= 0 || f >= 1) return '';
  return (f * 100).toFixed(10).replace(/0+$/, '').replace(/\.$/, '');
};

/** Promote N selected apps with ONE shared release-notes text; the Android
 * initial % / iOS phased knobs apply only to matching platforms. */
function PromoteGroupDialog({
  open,
  onClose,
  rows,
  busy,
  defaultFraction = null,
  onSubmit,
}: {
  open: boolean;
  onClose: () => void;
  rows: APRelease[];
  busy: boolean;
  // android_review_rollout_fraction from the group payload — prefills the % input.
  defaultFraction?: number | null;
  onSubmit: (notes: string, iosPhased: boolean, androidPercent: number | null) => void;
}) {
  const [notes, setNotes] = useState('');
  const [iosPhased, setIosPhased] = useState(true);
  const [androidPercent, setAndroidPercent] = useState('');
  // Two explicit note sources with a toggle. Default = the AI short summary
  // ("what's new in THIS build", combined across the selection); the alternative
  // is the store's current production "What's New" (first app's). Auto-fills
  // never clobber text the operator already edited.
  const [source, setSource] = useState<'ai' | 'prod'>('ai');
  const [aiText, setAiText] = useState<string | null>(null);
  const [prodText, setProdText] = useState<string | null>(null);
  const [aiPending, setAiPending] = useState(false);
  useEffect(() => {
    if (!open) return;
    const first = rows[0];
    const fallback = first?.release_context?.change_log || first?.change_log || '';
    // The box stays EMPTY until both sources have settled — no flash of the
    // changelog / prod notes getting replaced mid-read.
    setNotes('');
    setSource('ai');
    setAiText(null);
    setProdText(null);
    setAiPending(true);
    setAndroidPercent(fractionToPercentStr(defaultFraction));
    if (!first) {
      setAiPending(false);
      return;
    }
    let cancelled = false;
    void (async () => {
      // One promote-form call carries BOTH sources: prod "What's New" and the
      // AI short synopsis STORED at create time (describes this build's
      // commits; a live re-query would diff the moved branch head).
      const form = await mobileApi.getPromoteForm(first.id).catch(() => null);
      const p = (form?.pfReleaseNotes || '').trim() || null;
      const stored = (form?.pfAiShort || '').trim() || null;
      // Live AI only for rows created before the short was stored — the
      // COMBINED summary for a multi-app selection.
      const a =
        stored ??
        (await (async (): Promise<string | null> => {
          try {
            const branch = first.sourceRef || 'main';
            for (let attempt = 0; attempt < 15 && !cancelled; attempt++) {
              const ai =
                rows.length > 1
                  ? await mobileApi.changelogAiSummaryCombined(
                      rows.map((r) => ({ app: r.appGroup, surface: r.service, platform: r.env })),
                      branch,
                      'production',
                    )
                  : await mobileApi.changelogAiSummary(
                      first.appGroup,
                      first.service,
                      first.env,
                      branch,
                      'production',
                      first.new_version,
                      // iOS summaries were keyed with an empty code at create
                      // (workflow assigns the build number); Android used the code.
                      first.env === 'ios'
                        ? ''
                        : first.release_context?.version_code != null
                          ? String(first.release_context.version_code)
                          : '',
                    );
              if (ai.status === 'ready') return ai.summaryShort?.trim() || null;
              if (ai.status !== 'pending') return null;
              await new Promise((r) => setTimeout(r, 4000));
            }
            return null;
          } catch {
            return null;
          }
        })());
      if (cancelled) return;
      setProdText(p);
      setAiText(a);
      setAiPending(false);
      // Fill only once both settled, and only if the operator hasn't typed:
      // AI (the default) > prod notes > workflow changelog.
      setSource(a ? 'ai' : 'prod');
      setNotes((prev) => (prev === '' ? (a ?? p ?? fallback) : prev));
    })();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);
  const androidCount = rows.filter((r) => r.env === 'android').length;
  const iosCount = rows.filter((r) => r.env === 'ios').length;
  return (
    <Dialog open={open} onOpenChange={(v) => !v && onClose()}>
      <DialogContent size="lg" fullScreenOnMobile={false}>
        <DialogHeader>
          <DialogTitle>Promote {rows.length} app{rows.length === 1 ? '' : 's'} to review</DialogTitle>
        </DialogHeader>
        <DialogBody className="space-y-4">
          <div className="text-xs text-zinc-500">
            {rows.map((r) => `${r.appGroup} ${r.env}`).join(' · ')}
          </div>
          <div>
            <div className="flex items-center justify-between gap-2">
              <span className="text-xs font-medium text-zinc-600">
                Release notes (applied to every app)
              </span>
              {/* Source toggle: clicking REPLACES the textarea with that source. */}
              <div className="inline-flex rounded-md border border-zinc-200 overflow-hidden text-[11px] font-medium">
                <button
                  type="button"
                  disabled={!aiText}
                  title={
                    aiText
                      ? 'AI summary of what changed in this build'
                      : aiPending
                        ? 'AI summary is generating…'
                        : 'No AI summary available'
                  }
                  onClick={() => {
                    if (!aiText) return;
                    setSource('ai');
                    setNotes(aiText);
                  }}
                  className={cn(
                    'px-2.5 py-1 transition-colors disabled:opacity-40',
                    source === 'ai' ? 'bg-zinc-900 text-white' : 'bg-white text-zinc-500 hover:text-zinc-700',
                  )}
                >
                  AI summary{aiPending && !aiText ? '…' : ''}
                </button>
                <button
                  type="button"
                  disabled={!prodText}
                  title={
                    prodText
                      ? rows.length > 1
                        ? `Current production "What's New" of ${rows[0]?.appGroup}`
                        : 'Current production "What\'s New" from the store'
                      : 'No production notes found'
                  }
                  onClick={() => {
                    if (!prodText) return;
                    setSource('prod');
                    setNotes(prodText);
                  }}
                  className={cn(
                    'px-2.5 py-1 border-l border-zinc-200 transition-colors disabled:opacity-40',
                    source === 'prod' ? 'bg-zinc-900 text-white' : 'bg-white text-zinc-500 hover:text-zinc-700',
                  )}
                >
                  Prod notes
                </button>
              </div>
            </div>
            <textarea
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              rows={5}
              className="mt-1 w-full border border-zinc-200 rounded-lg p-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-300"
              placeholder={
                aiPending
                  ? 'Loading AI summary and production notes…'
                  : "What's new in this release…"
              }
            />
          </div>
          <div className="flex flex-wrap gap-6">
            {androidCount > 0 && (
              <label className="block">
                <span className="text-xs font-medium text-zinc-600">
                  Android initial rollout % ({androidCount} app{androidCount === 1 ? '' : 's'})
                </span>
                <input
                  type="number"
                  min={0.001}
                  max={100}
                  step="any"
                  value={androidPercent}
                  onChange={(e) => setAndroidPercent(e.target.value)}
                  placeholder="default: ~0% (parked)"
                  className="mt-1 w-44 border border-zinc-200 rounded-lg p-2 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-300"
                />
              </label>
            )}
            {iosCount > 0 && (
              <label className="inline-flex items-center gap-2 mt-5 text-sm text-zinc-700">
                <input
                  type="checkbox"
                  checked={iosPhased}
                  onChange={(e) => setIosPhased(e.target.checked)}
                  className="rounded border-zinc-300 accent-zinc-900"
                />
                iOS phased release ({iosCount} app{iosCount === 1 ? '' : 's'}, Apple 7-day schedule)
              </label>
            )}
          </div>
        </DialogBody>
        <DialogFooter>
          <Button variant="secondary" onClick={onClose} disabled={busy}>
            Cancel
          </Button>
          <Button
            onClick={() => {
              const pct = androidPercent.trim() === '' ? null : Number(androidPercent);
              if (pct != null && (Number.isNaN(pct) || pct <= 0 || pct > 100)) {
                toast.error('Initial rollout % must be between 0 and 100');
                return;
              }
              if (!notes.trim()) {
                toast.error('Release notes must not be empty');
                return;
              }
              onSubmit(notes.trim(), iosPhased, pct);
            }}
            loading={busy}
          >
            Promote {rows.length}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/** One staged-rollout % applied to every selected Android app. */
function RolloutGroupDialog({
  open,
  onClose,
  rows,
  busy,
  onSubmit,
}: {
  open: boolean;
  onClose: () => void;
  rows: APRelease[];
  busy: boolean;
  onSubmit: (percent: number) => void;
}) {
  const [percent, setPercent] = useState('10');
  return (
    <Dialog open={open} onOpenChange={(v) => !v && onClose()}>
      <DialogContent size="md" fullScreenOnMobile={false}>
        <DialogHeader>
          <DialogTitle>Set rollout % for {rows.length} Android app{rows.length === 1 ? '' : 's'}</DialogTitle>
        </DialogHeader>
        <DialogBody className="space-y-4">
          <div className="text-xs text-zinc-500">
            {rows.map((r) => `${r.appGroup}`).join(' · ')}
          </div>
          <div className="flex items-center gap-2">
            {[1, 5, 10, 25, 50, 100].map((p) => (
              <button
                key={p}
                onClick={() => setPercent(String(p))}
                className={cn(
                  'px-2.5 py-1.5 rounded-lg border text-xs font-medium transition-colors',
                  percent === String(p)
                    ? 'bg-zinc-900 text-white border-zinc-900'
                    : 'bg-white text-zinc-600 border-zinc-200 hover:border-zinc-400',
                )}
              >
                {p}%
              </button>
            ))}
            <input
              type="number"
              min={0.001}
              max={100}
              step="any"
              value={percent}
              onChange={(e) => setPercent(e.target.value)}
              className="w-24 border border-zinc-200 rounded-lg p-2 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-300"
            />
          </div>
          <p className="text-[11px] text-zinc-400">
            100% completes the rollout. iOS apps ramp on Apple's fixed 7-day
            schedule and aren't affected by this.
          </p>
        </DialogBody>
        <DialogFooter>
          <Button variant="secondary" onClick={onClose} disabled={busy}>
            Cancel
          </Button>
          <Button
            onClick={() => {
              const p = Number(percent);
              if (Number.isNaN(p) || p <= 0 || p > 100) {
                toast.error('Percent must be between 0 and 100');
                return;
              }
              onSubmit(p);
            }}
            loading={busy}
          >
            Apply to {rows.length}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/** Android review rejection needs a recorded reason. */
function RejectReasonDialog({
  open,
  onClose,
  count,
  onSubmit,
}: {
  open: boolean;
  onClose: () => void;
  count: number;
  onSubmit: (reason: string) => void;
}) {
  const [reason, setReason] = useState('');
  return (
    <Dialog open={open} onOpenChange={(v) => !v && onClose()}>
      <DialogContent size="md" fullScreenOnMobile={false}>
        <DialogHeader>
          <DialogTitle>Mark {count} app{count === 1 ? '' : 's'} rejected</DialogTitle>
        </DialogHeader>
        <DialogBody>
          <label className="block">
            <span className="text-xs font-medium text-zinc-600">Rejection reason</span>
            <textarea
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              rows={3}
              className="mt-1 w-full border border-zinc-200 rounded-lg p-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-300"
              placeholder="Why did Play reject it?"
            />
          </label>
        </DialogBody>
        <DialogFooter>
          <Button variant="secondary" onClick={onClose}>
            Cancel
          </Button>
          <Button
            variant="danger"
            onClick={() => {
              if (!reason.trim()) {
                toast.error('A reason is required');
                return;
              }
              onSubmit(reason.trim());
              setReason('');
            }}
          >
            Mark rejected
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
