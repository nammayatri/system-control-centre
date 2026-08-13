import { useEffect, useMemo, useState } from 'react';
import { Link, useParams, useNavigate } from 'react-router-dom';
import {
  AndroidLogoIcon,
  AppleLogoIcon,
  ArrowsClockwiseIcon,
  ArrowUpRightIcon,
  ArrowUUpLeftIcon,
  CaretRightIcon,
  CheckCircleIcon,
  CheckIcon,
  CheckSquareIcon,
  CopyIcon,
  CursorClickIcon,
  GitBranchIcon,
  InfoIcon,
  PaperPlaneTiltIcon,
  PauseIcon,
  PlayIcon,
  PlusIcon,
  RocketLaunchIcon,
  TrashIcon,
  XCircleIcon,
  XIcon,
} from '@phosphor-icons/react';
import { useMobileGroup, useDispatchMobileReleases } from '../../hooks';
import { useGroupOta } from '../../otaApi';
import { OtaSection } from '../../components/ota/OtaSection';
import { OtaBranchPicker } from '../../components/ota/OtaPanel';
import { usePermissions } from '../../../../core/auth/PermissionsContext';
import { abortMobileRelease, approveMobileRelease, createMobileRevert, discardMobileRelease, getMobileRevertDraft, mobileApi } from '../../api';
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
import { useConfirm } from '../../../../shared/ui/confirm-dialog';
import { BrandLogo } from '../../components/BrandLogo';
import { V4StatusPill } from '../../components/V4StatusPill';
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
    ? <AppleLogoIcon size={14} weight="fill" className="text-zinc-700" aria-hidden="true" />
    : <AndroidLogoIcon size={14} weight="fill" className="text-emerald-600" aria-hidden="true" />;

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

// ── Fleet Rail — the release lifecycle as one wide card, member counts pinned
// to the step they sit at (matches docs/design/release-group-detail-mockup-v1). ─
type RailTone = 'violet' | 'amber' | 'blue' | 'emerald' | 'sky';
const RAIL_TONE: Record<RailTone, { border: string; text: string; ping: string }> = {
  violet: { border: 'border-violet-500', text: 'text-violet-700', ping: 'border-violet-400' },
  amber: { border: 'border-amber-500', text: 'text-amber-700', ping: 'border-amber-400' },
  blue: { border: 'border-blue-500', text: 'text-blue-700', ping: 'border-blue-400' },
  emerald: { border: 'border-emerald-500', text: 'text-emerald-700', ping: 'border-emerald-400' },
  sky: { border: 'border-sky-500', text: 'text-sky-700', ping: 'border-sky-400' },
};
const RAIL_LABELS: { label: string; tone: RailTone; word: string }[] = [
  { label: 'Draft', tone: 'emerald', word: '' },
  { label: 'Approve', tone: 'violet', word: 'await' },
  { label: 'Build', tone: 'amber', word: 'here' },
  { label: 'Promote', tone: 'blue', word: 'held' },
  { label: 'Review', tone: 'violet', word: 'in review' },
  { label: 'Rollout', tone: 'emerald', word: 'rolling' },
  { label: 'Live', tone: 'emerald', word: 'live' },
];

export type RailMarks = Record<number, { ok: number; failed: number; sup: number }>;

/**
 * The fleet rail — pinned to where MEMBERS actually are (rowMark), never a
 * blended group stage: a step holding members gets a count ring (red X when
 * every member there failed), steps behind the furthest member read done,
 * steps ahead read todo. Scoped to the selection when one exists.
 */
function FleetRail({
  marks,
  total,
  selectionCount = 0,
}: {
  marks: RailMarks | null;
  total: number;
  selectionCount?: number;
}) {
  const stepKeys = Object.keys(marks ?? {}).map(Number);
  const maxMark = stepKeys.length > 0 ? Math.max(...stepKeys) : 0;
  const failedOnly = (m?: { ok: number; failed: number; sup: number }) =>
    !!m && m.failed > 0 && m.ok === 0 && m.sup === 0;
  // Whole fleet superseded → the rail is history: complete but overtaken,
  // muted to zinc end to end (summary-page parity).
  const allSup =
    stepKeys.length === 1 && (marks?.[6]?.sup ?? 0) === total && total > 0;
  const progressPct = allSup ? 100 : Math.max(6, Math.min(100, (maxMark / (RAIL_LABELS.length - 1)) * 100));
  const lineRed = !allSup && failedOnly(marks?.[maxMark]);
  return (
    <section className="stagger-item card-surface px-6 py-8" style={{ ['--index' as string]: 1 }}>
      <div className="flex items-center justify-between mb-6">
        <p className="eyebrow">Release Lifecycle · Fleet of {total}</p>
        {selectionCount > 0 && (
          <p className="text-[10px] font-bold text-violet-600 uppercase tracking-widest">
            scoped to selection · {selectionCount}
          </p>
        )}
      </div>
      <div className="relative w-full">
        <div className="absolute top-5 left-0 right-0 h-0.5 bg-zinc-200 z-0" />
        <div
          className={cn(
            'absolute top-5 left-0 h-0.5 z-10 transition-all duration-500',
            lineRed ? 'bg-red-500' : allSup ? 'bg-zinc-300' : 'bg-emerald-500',
          )}
          style={{ width: `${progressPct}%` }}
        />
        <div className="relative z-20 flex justify-between items-start w-full">
          {RAIL_LABELS.map((step, i) => {
            const m = marks?.[i];
            const tone = RAIL_TONE[step.tone];
            const isRose = failedOnly(m);
            const isLast = i === RAIL_LABELS.length - 1;
            // Live step truth: ticked when members genuinely serve; a
            // superseded-only step reads "superseded", never 100%.
            const liveDone = !allSup && isLast && !!m && m.ok > 0;
            const supOnly = isLast && !!m && m.ok === 0 && m.failed === 0 && m.sup > 0;
            const captionAllSup = allSup && isLast ? 'superseded' : null;
            const caption = captionAllSup
              ? captionAllSup
              : !m
              ? null
              : isRose
                ? `${m.failed} failed`
                : isLast
                  ? [
                      m.ok > 0 ? (m.ok === total && m.sup === 0 ? '100%' : `${m.ok} live`) : null,
                      m.sup > 0 ? `${m.sup} superseded` : null,
                      m.failed > 0 ? `${m.failed} failed` : null,
                    ]
                      .filter(Boolean)
                      .join(' · ')
                  : m.failed > 0
                    ? `${m.ok} · ${m.failed} failed`
                    : step.word
                      ? `${m.ok} ${step.word}`
                      : String(m.ok);
            return (
              <div key={step.label} className="flex flex-col items-center gap-2 w-16">
                {allSup ? (
                  <div className="w-10 h-10 rounded-full bg-zinc-200 border-2 border-white flex items-center justify-center text-zinc-400 shadow-sm">
                    <CheckIcon size={16} weight="bold" aria-hidden="true" />
                  </div>
                ) : isRose ? (
                  <div className="w-10 h-10 rounded-full bg-red-50 border-2 border-red-500 flex items-center justify-center text-red-500 relative">
                    <div className="absolute inset-0 rounded-full border-2 border-red-300 animate-ping opacity-50 z-[-1] motion-reduce:animate-none" />
                    <XIcon size={16} weight="bold" aria-hidden="true" />
                  </div>
                ) : liveDone ? (
                  <div className="w-10 h-10 rounded-full bg-emerald-500 border-2 border-white flex items-center justify-center text-white shadow-md">
                    <CheckIcon size={16} weight="bold" aria-hidden="true" />
                  </div>
                ) : supOnly ? (
                  <div
                    className="w-10 h-10 rounded-full bg-zinc-200 border-2 border-white flex items-center justify-center text-zinc-500 shadow-sm"
                    title="This build shipped, then a newer version took over"
                  >
                    <CheckIcon size={16} weight="bold" aria-hidden="true" />
                  </div>
                ) : m ? (
                  <div
                    className={cn(
                      'w-10 h-10 rounded-full bg-white border-[3px] flex items-center justify-center relative',
                      tone.border,
                    )}
                  >
                    <div
                      className={cn(
                        'absolute inset-0 rounded-full border-2 animate-ping opacity-50 z-[-1] motion-reduce:animate-none',
                        tone.ping,
                      )}
                    />
                    <span className={cn('text-[11px] font-mono font-bold', tone.text)}>{m.ok + m.failed}</span>
                  </div>
                ) : i < maxMark || (i === 0 && stepKeys.length > 0) ? (
                  <div className="w-10 h-10 rounded-full bg-emerald-500 border-2 border-white flex items-center justify-center text-white shadow-md">
                    <CheckIcon size={16} weight="bold" aria-hidden="true" />
                  </div>
                ) : (
                  <div className="w-10 h-10 rounded-full bg-zinc-100 border-2 border-white flex items-center justify-center">
                    <div className="w-2 h-2 rounded-full bg-zinc-300" />
                  </div>
                )}
                <div className="text-center">
                  <span
                    className={cn(
                      'block text-[11px] leading-tight',
                      allSup ? 'font-bold text-zinc-500' : m || i < maxMark ? 'font-bold text-zinc-700' : 'font-medium text-zinc-400',
                    )}
                  >
                    {step.label}
                  </span>
                  {caption && (
                    <span
                      className={cn(
                        'block text-[10px] font-bold uppercase mt-1',
                        allSup || supOnly ? 'text-zinc-500' : isRose ? 'text-red-600' : m && m.failed > 0 ? 'text-red-600' : tone.text,
                      )}
                    >
                      {caption}
                    </span>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </section>
  );
}


// THE mockup stage pill — one summary chip in the identity row, derived from
// the same server summary the home row uses (stage + phase counts).
function StagePill({
  stage,
  counts,
  pending,
  total,
  failed,
}: {
  stage: string;
  counts: Record<string, number>;
  pending: number;
  total: number;
  failed: boolean;
}) {
  const live = (counts['live'] ?? 0) + (counts['distributed'] ?? 0);
  const base =
    'inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-bold uppercase tracking-wider border';
  if (stage === 'done' && failed && live === 0)
    return (
      <span className={cn(base, 'bg-red-50 border-red-200 text-red-700')}>
        <XCircleIcon size={12} weight="bold" aria-hidden="true" /> Aborted
      </span>
    );
  if (stage === 'done' && live === 0 && (counts['superseded'] ?? 0) > 0)
    return (
      <span className={cn(base, 'bg-zinc-100 border-zinc-200 text-zinc-600')}>
        Superseded · {counts['superseded']}/{total}
      </span>
    );
  if (stage === 'done')
    return <span className={cn(base, 'bg-emerald-50 border-emerald-200 text-emerald-700')}>Live · {live}/{total}</span>;
  if (stage === 'releasing' || stage === 'rolling_out') {
    const n = (counts['rolling_out'] ?? 0) + (counts['halted'] ?? 0) + (counts['approved'] ?? 0);
    return (
      <span className={cn(base, 'bg-emerald-50 border-emerald-200 text-emerald-700')}>
        <span className="w-2 h-2 rounded-full bg-emerald-500 animate-pulse-slow motion-reduce:animate-none" /> Rolling out {n}/{total}
      </span>
    );
  }
  if (stage === 'promote' || stage === 'in_review')
    return (
      <span className={cn(base, 'bg-violet-50 border-violet-200 text-violet-700')}>
        <span className="w-2 h-2 rounded-full bg-violet-500 animate-pulse-slow motion-reduce:animate-none" /> Store stage
      </span>
    );
  if (stage === 'building' || stage === 'dispatch')
    return (
      <span className={cn(base, 'bg-amber-50 border-amber-200 text-amber-700')}>
        <span className="w-2 h-2 rounded-full bg-amber-500 animate-pulse-slow motion-reduce:animate-none" /> Building {counts['building'] ?? 0}
      </span>
    );
  return (
    <span className={cn(base, 'bg-zinc-100 border-zinc-200 text-zinc-600')}>
      <span className="w-2 h-2 rounded-full bg-zinc-400" /> Draft · {total - pending}/{total} approved
    </span>
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
  const confirmDialog = useConfirm();
  const [cancellingBuild, setCancellingBuild] = useState<string | null>(null);

  // Cancel a BUILDING member: abortability + shared-run blast radius come from
  // the rollout detail (BE truth) — a shared GitHub run cancels siblings too,
  // so those get the explicit warning popup before anything happens.
  const cancelBuild = async (r: APRelease) => {
    setCancellingBuild(r.id);
    try {
      // Debug builds have no rollout detail (the endpoint 400s for them) —
      // derive abortability locally: cancellable until the artifact uploads
      // (MBSubmittedToStore and beyond), mirroring the BE's rdAbortable.
      const isDebugRow = r.release_context?.build_type === 'debug';
      let siblings: string[] = [];
      if (isDebugRow) {
        const wf = (r.release_context as Record<string, any>)?.mb_wf_status ?? '';
        if (!['MBInit', 'MBVersionResolved', 'MBDispatched', 'MBRunIdResolved', 'MBBuilding'].includes(wf)) {
          toast.error('Too late to cancel — the build already produced artifacts.');
          return;
        }
      } else {
        const d = await mobileApi.getRolloutDetail(r.id);
        if (!d.rdAbortable) {
          toast.error('Too late to cancel — the build already produced artifacts. Use Revert instead.');
          return;
        }
        siblings = d.rdRunSiblings ?? [];
      }
      const ok = await confirmDialog({
        title: 'Cancel build',
        description: siblings.length
          ? `This cancels the shared GitHub run. Still building in the same run and will ALSO be cancelled: ${siblings.join(', ')}.`
          : isDebugRow
            ? `Cancel the ${r.appGroup} · ${r.env} build? This stops the shared GitHub run — sibling apps still building in the same run are cancelled with it.`
            : `Cancel the ${r.appGroup} · ${r.env} build? The GitHub job is cancelled and this release is aborted.`,
        confirmLabel: 'Cancel build',
        cancelLabel: 'Keep building',
        variant: 'danger',
      });
      if (!ok) return;
      await abortMobileRelease(r.id);
      toast.success('Build cancellation initiated');
      void refetch();
    } catch (err: any) {
      toast.error(err?.response?.data?.message || err?.message || 'Could not cancel the build');
    } finally {
      setCancellingBuild(null);
    }
  };

  // OTA section data — the GET also drives backend push-status convergence.
  // Debug groups have no OTA (backend returns available=false and blocks
  // dispatch), so skip the query entirely: with otaQ.data undefined, neither
  // the OTA section nor the "No OTA" placeholder can render for a debug build.
  const groupIsDebug = (group?.members ?? [])[0]?.release_context?.build_type === 'debug';
  const otaQ = useGroupOta(groupId, !groupIsDebug);
  const { hasPermission } = usePermissions();
  // Per-app grant key "<name>/<platform>" (unified model); falls back to the
  // product-level permission for fleet-wide role holders.
  const canOtaDispatchFor = (app: string, platform: string) =>
    hasPermission('mobile', 'MB_MOBILE_DISPATCH', `${app}/${platform}`);
  const otaAvailable = !!otaQ.data?.available && otaQ.data.capableApps.length > 0;

  const groupReleases = useMemo(() => group?.members ?? [], [group]);

  // The group's source branch — from any member that has one (uniform per
  // group). Store-sync groups have none until adopted via the picker.
  const groupBranch = useMemo(
    () => groupReleases.find((r) => r.sourceRef)?.sourceRef ?? null,
    [groupReleases],
  );
  // Picker target: the first OTA-capable app still missing a branch (its
  // recovered anchor commit is what candidates are verified against).
  const branchPickTarget = useMemo(
    () =>
      otaAvailable
        ? (otaQ.data!.capableApps.find(
            (c) =>
              !groupReleases.find((r) => r.appGroup === c.appName && r.env === c.platform)
                ?.sourceRef,
          )?.airborneAppRef ?? null)
        : null,
    [otaAvailable, otaQ.data, groupReleases],
  );
  // The tracker row the header picker adopts a branch onto (build-level route).
  const branchPickReleaseId = useMemo(() => {
    if (!otaAvailable || !branchPickTarget) return null;
    const c = otaQ.data!.capableApps.find((x) => x.airborneAppRef === branchPickTarget);
    if (!c) return null;
    return groupReleases.find((r) => r.appGroup === c.appName && r.env === c.platform)?.id ?? null;
  }, [otaAvailable, otaQ.data, branchPickTarget, groupReleases]);
  const [headerPickerOpen, setHeaderPickerOpen] = useState(false);
  // Group members with no airborne app — shown inert in the OTA section so
  // "this app has no OTA" is visible instead of silently absent.
  const unmappedOta = useMemo(() => {
    if (!otaQ.data) return [];
    const capable = new Set(otaQ.data.capableApps.map((c) => `${c.appName}|${c.platform}`));
    const seen = new Set<string>();
    return groupReleases
      .filter((r) => {
        const k = `${r.appGroup}|${r.env}`;
        if (capable.has(k) || seen.has(k)) return false;
        seen.add(k);
        return true;
      })
      .map((r) => ({ appName: r.appGroup, platform: r.env, surface: r.service }));
  }, [otaQ.data, groupReleases]);
  // The capable app the picker would adopt a branch for (named in the banner).
  const branchPickApp = useMemo(
    () =>
      otaAvailable && branchPickTarget
        ? (otaQ.data!.capableApps.find((c) => c.airborneAppRef === branchPickTarget) ?? null)
        : null,
    [otaAvailable, otaQ.data, branchPickTarget],
  );

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

  // Where each member sits on the 7-step rail (0 Draft … 6 Live). Dead rows
  // pin RED at the stage the abort/failure interrupted (wf-status memory).
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
  const rowMark = (r: APRelease): { step: number; failed: boolean; superseded?: boolean } => {
    if (phaseOf(r) === 'superseded') return { step: 6, failed: false, superseded: true };
    if (phaseOf(r) === 'rejected') return { step: 4, failed: true };
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

  const VERB_ELIGIBLE: Record<string, (r: APRelease) => boolean> = {
    approve: (r) => r.status === 'CREATED' && r.is_approved !== 1,
    // A stamped row is already in the runner's hands — re-dispatch would fork
    // a second CI run. The status stays CREATED until the build starts, so the
    // dispatch_id is the only reliable "already clicked" signal.
    dispatch: (r) =>
      r.status === 'CREATED' && r.is_approved === 1 && !r.release_context?.dispatch_id,
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

  // Rail marks: the selection when there is one, otherwise EVERY member — the
  // rail always shows where apps actually are, never a blended stage that
  // hides a straggler.
  const railMarks = useMemo<RailMarks | null>(() => {
    const rows = selectedRows.length > 0 ? selectedRows : groupReleases;
    if (rows.length === 0) return null;
    const marks: RailMarks = {};
    for (const r of rows) {
      const { step, failed, superseded } = rowMark(r);
      if (!marks[step]) marks[step] = { ok: 0, failed: 0, sup: 0 };
      if (failed) marks[step].failed++;
      else if (superseded) marks[step].sup++;
      else marks[step].ok++;
    }
    return marks;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedRows, groupReleases]);
  // Toolbar segments render only when at least one of their verbs is currently
  // performable on ANY member — dead segments are noise. RECOVER always shows
  // (Copy is performable on every group).
  const segHasEligible = (verbs: string[]) =>
    groupReleases.some((r) => verbs.some((v) => VERB_ELIGIBLE[v]?.(r)));
  const showBuildSeg = segHasEligible(['approve', 'dispatch', 'discard']);
  const showReviewSeg = segHasEligible(['promote', 'markApproved', 'markRejected', 'withdraw']);
  const showRolloutSeg = segHasEligible(['release', 'rollout', 'halt', 'resume', 'releaseAll']);
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
  // Fleet Rail data: drafts still awaiting approval + platform split (the rest
  // of the per-step counts come from the server-derived summary.counts).
  const pendingApprovals = useMemo(
    () => groupReleases.filter((r) => r.status === 'CREATED' && r.is_approved !== 1).length,
    [groupReleases],
  );
  const platformSplit = useMemo(() => {
    const android = groupReleases.filter((r) => r.env === 'android').length;
    const ios = groupReleases.filter((r) => r.env === 'ios').length;
    return { android, ios };
  }, [groupReleases]);
  const groupFailedStep = useMemo(() => {
    const c = group?.summary?.counts ?? {};
    const shipped = (c['live'] ?? 0) + (c['superseded'] ?? 0) + (c['distributed'] ?? 0);
    if (group?.summary?.stage !== 'done' || shipped > 0) return null;
    const wfStep = (wf: string): number => {
      if (['MBReviewApproved', 'MBRollingOut'].includes(wf)) return 5;
      if (['MBSubmittingForReview', 'MBInReview'].includes(wf)) return 4;
      if (wf === 'MBTagPushed') return 3;
      return 2;
    };
    return Math.max(2, ...groupReleases.map((r) => wfStep(r.release_context?.mb_wf_status ?? '')));
  }, [group, groupReleases]);

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
      (id) => approveMobileRelease(id, user?.email || 'local_admin'),
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
  // Destructive verbs read red; every other verb is neutral white with the
  // suggested next step (primary) getting the solid blue fill.
  const DANGER_VERBS = new Set(['discard', 'markRejected', 'revert']);
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
    const loading = busyVerb === verb;
    const disabled = n === 0 || (busyVerb !== null && busyVerb !== verb);
    const danger = DANGER_VERBS.has(verb);
    const names = targets.map((r) => `${r.appGroup} ${r.env}`).join(', ');
    return (
      // span carries the tooltip — disabled buttons swallow mouse events
      <span
        title={reason ?? `${label.replace(/…$/, '')}: ${names}`}
        onMouseEnter={() => setHoveredVerb(verb)}
        onMouseLeave={() => setHoveredVerb(null)}
      >
        <button
          onClick={onClick}
          disabled={disabled}
          className={cn(
            // Mockup color states: armed (has targets) = violet tint, danger =
            // red tint, the recommended primary verb = solid violet (solid red
            // when destructive), idle = quiet zinc outline.
            'verbbtn px-3 py-1.5 text-xs font-bold rounded-lg border bg-white shadow-sm inline-flex items-center gap-1.5 transition-colors disabled:opacity-40 disabled:cursor-not-allowed active:scale-[0.98]',
            primary
              ? 'border-blue-300 text-blue-700 enabled:hover:bg-blue-50'
              : danger
                ? 'border-red-200 text-red-600 enabled:hover:bg-red-50'
                : 'border-zinc-200 text-zinc-700 enabled:hover:bg-zinc-50',
          )}
        >
          {loading ? <ArrowsClockwiseIcon size={14} className="animate-spin" aria-hidden="true" /> : icon}
          {label}
          {n > 0 && (
            <span
              className={cn(
                'rounded px-1 text-[9px] font-mono font-bold',
                primary ? 'bg-blue-100 text-blue-700' : 'bg-zinc-100 text-zinc-500',
              )}
            >
              {n}
            </span>
          )}
        </button>
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
      {/* Breadcrumb + freshness */}
      <div className="flex items-center justify-between mb-4 text-xs">
        <div className="flex items-center gap-2 font-medium text-zinc-500 min-w-0">
          <Link to="/mobile/releases" className="hover:text-zinc-900 shrink-0 cursor-pointer">
            Mobile releases
          </Link>
          <CaretRightIcon size={10} aria-hidden="true" />
          <button
            onClick={() => {
              void navigator.clipboard.writeText(groupId ?? '');
              toast.success('Group ID copied');
            }}
            title={`${groupId} — click to copy`}
            className="font-mono text-zinc-700 bg-zinc-100 hover:bg-zinc-200 px-1.5 py-0.5 rounded transition-colors cursor-copy"
          >
            {groupId?.slice(0, 8)}… ⧉
          </button>
        </div>
        <button
          onClick={() => void refetch()}
          title="Refresh"
          aria-label="Refresh"
          className="text-zinc-500 hover:text-zinc-900"
        >
          <ArrowsClockwiseIcon size={14} className={isLoading ? 'animate-spin' : ''} aria-hidden="true" />
        </button>
      </div>

      {/* Identity row — fleet avatar stack, title, stage chip, fleet summary */}
      <div className="stagger-item flex flex-col md:flex-row md:items-center justify-between gap-4 mb-6" style={{ ['--index' as string]: 0 }}>
        <div className="flex flex-wrap items-center gap-4 min-w-0">
          {/* Fleet avatar stack — up to 3 distinct apps in the group */}
          <div className="flex -space-x-2.5 shrink-0">
            {Array.from(new Map(groupReleases.map((r) => [r.appGroup, r])).values())
              .slice(0, 3)
              .map((r, i) => (
                <div
                  key={r.appGroup}
                  className="ring-2 ring-white rounded-lg"
                  style={{ zIndex: 30 - i * 10 }}
                >
                  <BrandLogo brand={r.appGroup} surface={r.service === 'driver' ? 'driver' : undefined} size="lg" />
                </div>
              ))}
          </div>
          <div className="flex flex-col min-w-0">
            <div className="flex items-center gap-2 flex-wrap">
              <h1 className="text-lg font-bold leading-none tracking-tight text-zinc-900">
                {group?.label || 'Release group'}
              </h1>
              {group?.summary && (
                <StagePill
                  stage={group.summary.stage}
                  counts={group.summary.counts}
                  pending={pendingApprovals}
                  total={groupReleases.length}
                  failed={groupFailedStep != null}
                />
              )}
            </div>
            {/* Fleet summary line */}
            <div className="flex items-center gap-2 mt-1.5 flex-wrap text-[11px] text-zinc-500">
              <span className="font-mono font-bold text-zinc-800 text-sm">
                {groupReleases.length} build{groupReleases.length === 1 ? '' : 's'}
              </span>
              {platformSplit.android > 0 && <span>· {platformSplit.android} android</span>}
              {platformSplit.ios > 0 && <span>· {platformSplit.ios} ios</span>}
              {/* Branch always in the chip — the git icon makes it unambiguous,
                  and the title never shows the branch, so no duplication. */}
              {groupBranch && (
                <span
                  className="bg-zinc-100 text-zinc-800 font-mono font-bold px-2 py-0.5 rounded inline-flex items-center gap-1 border border-zinc-200"
                  title={`Source branch: ${groupBranch}`}
                >
                  <GitBranchIcon size={12} className="text-zinc-500" aria-hidden="true" /> {groupBranch}
                </span>
              )}
              {slack?.state === 'failed' && (
                <span className="inline-flex items-center gap-1.5">
                  <span
                    title={slack.error ?? undefined}
                    className="inline-flex items-center gap-1 font-medium rounded-full border border-rose-200 bg-rose-50 text-rose-700 px-2 py-0.5"
                  >
                    <PaperPlaneTiltIcon size={12} aria-hidden="true" /> Changelog → Slack failed
                  </span>
                  <button
                    onClick={() => handleResendSlack()}
                    disabled={resendingSlack}
                    className="inline-flex items-center gap-1 font-bold rounded-full border border-violet-300 text-violet-700 hover:bg-violet-50 px-2 py-0.5 transition-colors disabled:opacity-50"
                  >
                    {resendingSlack ? 'Sending…' : 'Resend'}
                  </button>
                </span>
              )}
              {slack?.state === 'sent' && (
                <span className="inline-flex items-center gap-1 text-emerald-600 font-medium" title="Changelog posted to Slack">
                  <CheckCircleIcon size={12} weight="fill" aria-hidden="true" /> Sent to Slack
                </span>
              )}
            </div>
          </div>
        </div>
        <div className="flex items-center gap-2 shrink-0">
          <PermissionGate product="mobile" permission="MB_RELEASE_CREATE">
            <button
              onClick={() => navigate('/mobile/releases/new')}
              className="bg-white border border-zinc-200 text-zinc-600 px-3 py-1.5 text-sm font-semibold rounded-lg shadow-sm hover:bg-zinc-50 transition-all inline-flex items-center gap-1.5"
            >
              <PlusIcon size={14} weight="bold" aria-hidden="true" /> New release
            </button>
          </PermissionGate>
        </div>
      </div>

      {/* Fleet Rail */}
      {groupReleases.length > 0 && (
        <FleetRail
          marks={railMarks}
          total={selectedRows.length > 0 ? selectedRows.length : groupReleases.length}
          selectionCount={selectedRows.length}
        />
      )}

      {/* Missing source branch — standalone banner, surfaced at the top so
          it's never discovered only after expanding a row. */}
      {branchPickTarget && (
        <div
          className="stagger-item flex items-center justify-between gap-3 rounded-lg border border-sky-200 bg-sky-50/60 px-4 py-2.5 mt-6"
          style={{ ['--index' as string]: 2 }}
        >
          <span className="text-xs text-sky-900 flex items-center gap-2">
            <InfoIcon size={14} weight="fill" className="text-sky-500 shrink-0" aria-hidden="true" />
            Imported from store — no source branch known
            {branchPickApp ? ` for ${branchPickApp.appName} · ${branchPickApp.platform}` : ''}. OTA
            bundle pushes need a branch.
          </span>
          <button
            onClick={() => setHeaderPickerOpen(true)}
            className="shrink-0 inline-flex items-center gap-1 text-xs font-bold rounded-md border border-sky-300 bg-white text-sky-700 hover:bg-sky-100 px-2.5 py-1 transition-colors"
          >
            <GitBranchIcon size={14} aria-hidden="true" /> Set source branch
          </button>
        </div>
      )}

      {/* ── Command bar (card): EVERY stage verb, always visible — disabled
          (never hidden) when the selection can't take that action. Segments
          mirror the stepper: Build → Store review → Rollout → Recover. The
          container-level mouseleave is the stuck-hover safety net (VerbButton
          spans remount on every poll and can swallow their own onMouseLeave). ── */}
      <section
        onMouseLeave={() => setHoveredVerb(null)}
        className="stagger-item card-surface px-4 py-3 flex flex-wrap items-center gap-x-5 gap-y-3 mt-6"
        style={{ ['--index' as string]: 3 }}
      >
        {/* Selection state — verbs act on the rows selected in the table. */}
        {selectedRows.length > 0 ? (
          <span className="inline-flex items-center gap-2 border border-blue-200 bg-blue-50 text-blue-700 text-[11px] font-bold px-2.5 py-1.5 rounded-lg">
            <CheckSquareIcon size={14} weight="bold" aria-hidden="true" /> {selectedRows.length} selected
            <button
              onClick={() => setSelectedIds(new Set())}
              className="text-blue-500 hover:text-blue-700 text-[9px] font-bold uppercase tracking-wide underline underline-offset-2"
            >
              clear
            </button>
          </span>
        ) : (
          <span
            className="inline-flex items-center gap-1.5 border border-dashed border-zinc-300 text-zinc-400 text-[11px] font-semibold px-2.5 py-1.5 rounded-lg"
            title="Verbs act on the rows you select in the table below"
          >
            <CursorClickIcon size={14} weight="bold" aria-hidden="true" /> Select rows below — verbs act on your selection
          </span>
        )}
        <span className="w-px h-6 bg-zinc-200 hidden sm:block" />

          {showBuildSeg && (
          <span className="inline-flex items-center gap-2">
            <span className="eyebrow">Build</span>
            <VerbButton
              verb="approve"
              label="Approve"
              icon={<CheckCircleIcon size={15} weight="bold" aria-hidden="true" />}
              primary={group?.summary?.primaryVerb === 'approve'}
              onClick={onApproveSelected}
            />
            <VerbButton
              verb="dispatch"
              label="Dispatch"
              icon={<PaperPlaneTiltIcon size={15} weight="bold" aria-hidden="true" />}
              primary={group?.summary?.primaryVerb === 'dispatch'}
              onClick={onDispatchSelected}
            />
            {/* Discard a never-dispatched draft — sits with the other draft-stage
                verbs. Destructive → explicit selection + confirm. */}
            <PermissionGate product="mobile" permission="MB_RELEASE_CREATE">
              <VerbButton
                verb="discard"
                label="Discard"
                icon={<TrashIcon size={15} weight="bold" aria-hidden="true" />}
                onClick={() => {
                  const targets = eligibleSelected('discard');
                  if (
                    window.confirm(
                      `Discard ${targets.length} draft${targets.length === 1 ? '' : 's'}? This can't be undone — the draft${targets.length === 1 ? '' : 's'} won't build.`,
                    )
                  )
                    void runPerId('discard', targets, (id) => discardMobileRelease(id), 'Discarded');
                }}
              />
            </PermissionGate>
          </span>
          )}
          {showReviewSeg && (
          <>
          {showBuildSeg && <span className="w-px h-6 bg-zinc-200 hidden sm:block" />}
          <span className="inline-flex items-center gap-2">
            <span className="eyebrow">Store review</span>
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
              label="Withdraw iOS"
              onClick={() => {
                if (window.confirm(`Withdraw ${eligibleSelected('withdraw').length} iOS app(s) from App Store review?`))
                  void runPerId('withdraw', eligibleSelected('withdraw'), mobileApi.withdraw, 'Withdrew');
              }}
            />
          </span>
          </>
          )}
          {showRolloutSeg && (
          <>
          {(showBuildSeg || showReviewSeg) && (
            <span className="w-px h-6 bg-zinc-200 hidden sm:block" />
          )}
          <span className="inline-flex items-center gap-2">
            <span className="eyebrow">Rollout</span>
            {/* "Release" starts shipping the approved iOS build — a rollout
                action, so it sits with the rollout controls. */}
            <VerbButton
              verb="release"
              label="Release iOS"
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
              icon={<PauseIcon size={15} weight="bold" aria-hidden="true" />}
              onClick={() => runPerId('halt', eligibleSelected('halt'), mobileApi.rolloutHalt, 'Halted')}
            />
            <VerbButton
              verb="resume"
              label="Resume"
              icon={<PlayIcon size={15} weight="bold" aria-hidden="true" />}
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
          </>
          )}
          {(showBuildSeg || showReviewSeg || showRolloutSeg) && (
            <span className="w-px h-6 bg-zinc-200 hidden sm:block" />
          )}
          <span className="inline-flex items-center gap-2">
            <span className="eyebrow">Recover</span>
            <PermissionGate product="mobile" permission="MB_RELEASE_REVERT">
              <VerbButton
                verb="revert"
                label="Revert"
                icon={<ArrowUUpLeftIcon size={15} weight="bold" aria-hidden="true" />}
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
            <PermissionGate product="mobile" permission="MB_RELEASE_CREATE">
              <span
                title={
                  selectedRows.length > 0
                    ? `Start a new release with the ${copyTargets.length} selected app${copyTargets.length === 1 ? '' : 's'} prefilled`
                    : "Start a new release with this group's apps and changelog prefilled"
                }
              >
                <button
                  onClick={() => {
                    const only =
                      selectedRows.length > 0
                        ? `&only=${copyTargets.map((r) => encodeURIComponent(r.id)).join(',')}`
                        : '';
                    navigate(`/mobile/releases/new?copyFrom=${groupId}${only}`);
                  }}
                  className="verbbtn px-3 py-1.5 text-xs font-bold rounded-lg border border-zinc-200 bg-white text-zinc-700 shadow-sm inline-flex items-center gap-1.5 transition-colors hover:bg-zinc-50 active:scale-[0.98]"
                >
                  <CopyIcon size={15} weight="bold" aria-hidden="true" />
                  Copy{selectedRows.length > 0 ? ` (${copyTargets.length})` : ''}
                </button>
              </span>
            </PermissionGate>
          </span>
      </section>

      {/* Dispatch preview — standalone banner: one-vs-many-runs at selection
          time (apps selected TOGETHER share one GitHub run per platform). */}
      {dispatchPreview && (
        <div
          className="stagger-item flex items-start gap-2.5 rounded-lg border border-blue-100 bg-blue-50/70 px-4 py-3 text-xs text-blue-900 mt-6"
          style={{ ['--index' as string]: 4 }}
        >
          <PaperPlaneTiltIcon size={16} weight="fill" className="shrink-0 mt-0.5 text-blue-500" aria-hidden="true" />
          <div>
            <span className="font-bold">
              {dispatchPreview.apps} app{dispatchPreview.apps === 1 ? '' : 's'} selected →{' '}
              {dispatchPreview.runs} build run{dispatchPreview.runs === 1 ? '' : 's'}
            </span>
            <span className="text-blue-700"> ({dispatchPreview.parts.join(' · ')})</span>
            <p className="text-blue-700/80 mt-0.5">
              Apps in a shared run build together, each at its own version; un-selected apps stay
              here and dispatch later as a separate run.
            </p>
          </div>
        </div>
      )}

      {/* Fleet table (card) */}
      <section className="stagger-item card-surface overflow-hidden mt-6" style={{ ['--index' as string]: 5 }}>
        {groupingMissing && (
          <div className="px-4 py-3 sm:px-6 border-b border-amber-200 bg-amber-50 text-amber-800 text-xs flex gap-2 items-start">
            <InfoIcon size={16} className="mt-0.5 shrink-0" aria-hidden="true" />
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
            {/* Select-to-act hint — the table rows are what the command-bar
                verbs operate on. */}
            <div className="px-4 py-2 bg-violet-50/50 border-b border-violet-100 flex items-center gap-1.5">
              <CursorClickIcon size={14} weight="bold" className="text-violet-500 shrink-0" aria-hidden="true" />
              <span className="text-[10px] font-bold text-violet-700 uppercase tracking-wider">
                Click rows to select
              </span>
              <span className="text-[10px] font-medium text-violet-600/80">
                — selected apps are what the verbs above act on · hover a verb to preview its targets
              </span>
            </div>
            <div className="hidden md:block overflow-x-auto">
              <table className="w-full text-left whitespace-nowrap">
                <thead>
                  <tr className="bg-zinc-50 border-b border-zinc-200 text-[10px] text-zinc-500 font-bold uppercase tracking-widest">
                    <th className="py-3 px-4 w-10">
                      <input
                        type="checkbox"
                        checked={allChecked}
                        onChange={toggleAll}
                        className="rounded border-zinc-300 accent-zinc-900"
                      />
                    </th>
                    <th className="py-3 px-4">App</th>
                    <th className="py-3 px-4">Platform</th>
                    <th className="py-3 px-4">Version</th>
                    <th className="py-3 px-4">Status</th>
                    <th className="py-3 px-4">Next step</th>
                    <th className="py-3 px-4 text-right">Open</th>
                  </tr>
                </thead>
                <tbody className="text-sm">
                  {groupReleases.map((r) => {
                    const checked = selectedIds.has(r.id);
                    // Hovering a verb previews its CANDIDATES: every row the
                    // verb can apply to glows (selected or not), the rest fade.
                    // Discoverable — you see what a verb targets before selecting.
                    const eligibleForHovered =
                      hoveredVerb != null && !!VERB_ELIGIBLE[hoveredVerb]?.(r);
                    return (
                      <tr
                        key={r.id}
                        onClick={() => toggleOne(r.id)}
                        // Selected rows: neutral highlight + a blue inset edge.
                        style={checked ? { boxShadow: 'inset 3px 0 0 #8b5cf6' } : undefined}
                        className={cn(
                          'border-b border-zinc-100 transition-all cursor-pointer',
                          checked
                            ? 'bg-violet-50/50 hover:bg-violet-50/70'
                            : 'bg-white hover:bg-zinc-50',
                          // hover a verb → every eligible row glows; ineligible fade.
                          eligibleForHovered && 'bg-violet-100/80 hover:bg-violet-100/80',
                          hoveredVerb != null && !eligibleForHovered && 'opacity-40',
                        )}
                      >
                        <td className="py-3 px-4">
                          <input
                            type="checkbox"
                            checked={checked}
                            onChange={() => toggleOne(r.id)}
                            onClick={(e) => e.stopPropagation()}
                            className={cn('rounded border-zinc-300', checked ? 'accent-violet-600' : 'accent-zinc-900')}
                          />
                        </td>
                        <td className="py-3 px-4">
                          <span className="inline-flex items-center gap-2.5">
                            <BrandLogo brand={r.appGroup} surface={r.service === 'driver' ? 'driver' : undefined} size="sm" />
                            <span className="font-medium text-zinc-800">
                              {r.appGroup}{' '}
                              <span className="font-medium text-zinc-400 text-xs">· {r.service === 'driver' ? 'provider' : 'consumer'}</span>
                            </span>
                          </span>
                        </td>
                        <td className="py-3 px-4">
                          <span className="inline-flex items-center gap-1.5 text-xs text-zinc-600">
                            <PlatformIcon platform={r.env} /> {r.env}
                          </span>
                        </td>
                        <td className="py-3 px-4 font-mono text-xs font-bold text-zinc-800">
                          {r.new_version}{' '}
                          {r.release_context?.version_code != null && (
                            <span className="text-zinc-400 font-medium">+{r.release_context.version_code}</span>
                          )}
                        </td>
                        <td className="py-3 px-4">
                          <div className="flex items-center gap-1.5 flex-wrap">
                            <V4StatusPill release={r} />
                            {/* Draft approval gates Dispatch — after dispatch every
                                build is approved by definition, so the chip only
                                renders while the row is still a draft. */}
                            {r.is_approved === 1 && r.status === 'CREATED' && (
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
                            <span className="inline-flex items-center gap-1.5">
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
                              {nextStepOf(r) === 'Building…' && hasPermission('mobile', 'MB_RELEASE_ABORT', `${r.appGroup}/${r.env}`) && (
                                <button
                                  type="button"
                                  disabled={cancellingBuild === r.id}
                                  onClick={(e) => {
                                    e.stopPropagation();
                                    void cancelBuild(r);
                                  }}
                                  title="Cancel this build (aborts the GitHub job)"
                                  className="text-[10px] font-bold uppercase tracking-wide rounded-full border border-red-200 bg-white text-red-600 px-2 py-0.5 hover:bg-red-50 transition-colors cursor-pointer disabled:opacity-50"
                                >
                                  {cancellingBuild === r.id ? 'Cancelling…' : 'Cancel'}
                                </button>
                              )}
                            </span>
                          ) : (
                            <span className="text-xs text-zinc-300">—</span>
                          )}
                        </td>
                        <td className="py-3 px-4 text-right">
                          <button
                            onClick={(e) => {
                              e.stopPropagation();
                              navigate(`/mobile/releases/${r.id}`);
                            }}
                            title="Open release"
                            aria-label={`Open ${r.appGroup} ${r.env}`}
                            className="text-zinc-400 hover:text-zinc-900 cursor-pointer"
                          >
                            <ArrowUpRightIcon size={16} weight="bold" aria-hidden="true" />
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
                    className={cn('p-4 cursor-pointer transition-colors', checked && 'bg-zinc-100')}
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
                          <V4StatusPill release={r} />
                          {r.is_approved === 1 && r.status === 'CREATED' && (
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
      </section>

      {/* ── OTA bundles — its own section below the release group; debug
          groups stay silent, but a production group with NO mapped apps says
          so instead of hiding the concept. ── */}
      {!otaAvailable &&
        otaQ.data &&
        groupReleases.length > 0 &&
        groupReleases[0]?.release_context?.build_type !== 'debug' && (
          <div className="stagger-item mt-12 flex items-center gap-2 rounded-lg border border-zinc-200 bg-zinc-50 px-3 py-2.5 text-xs text-zinc-500">
            <RocketLaunchIcon size={14} weight="duotone" className="text-zinc-400" aria-hidden="true" />
            {groupReleases.every((r) => r.service === 'driver')
              ? 'No OTA — airborne is not available for provider apps.'
              : 'No OTA — none of this group’s apps have an airborne app mapped (set "OTA ref" in Mobile Apps admin).'}
          </div>
        )}
      {otaAvailable && otaQ.data && (
        <div className="stagger-item mt-12">
          <h2 className="flex items-baseline gap-2 mb-2">
            <span className="inline-flex items-center gap-1.5 text-sm font-bold text-violet-700">
              <RocketLaunchIcon size={16} weight="fill" aria-hidden="true" /> OTA bundles
            </span>
            <span className="text-xs text-zinc-500">
              over-the-air JS bundles · separate from the store builds above
            </span>
          </h2>
          <OtaSection
            groupId={groupId!}
            ota={otaQ.data}
            sourceRefFor={(app, platform) =>
              groupReleases.find((r) => r.appGroup === app && r.env === platform)?.sourceRef ??
              null
            }
            releaseIdFor={(app, platform) =>
              groupReleases.find((r) => r.appGroup === app && r.env === platform)?.id ?? null
            }
            nativeVersionFor={(app, platform) =>
              groupReleases.find((r) => r.appGroup === app && r.env === platform)?.new_version ??
              null
            }
            canDispatchFor={canOtaDispatchFor}
            unmapped={unmappedOta}
            onChanged={() => void otaQ.refetch()}
          />
        </div>
      )}

      {headerPickerOpen && branchPickReleaseId && (
        <OtaBranchPicker
          releaseId={branchPickReleaseId}
          onClose={() => setHeaderPickerOpen(false)}
          onAdopted={() => {
            void refetch();
            void otaQ.refetch();
          }}
        />
      )}

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
  // Highest live % among the targeted rows — Play rollouts only ramp UP, so
  // the suggested next step (and the validation floor) must clear all of them.
  const current = Math.max(0, ...rows.map((r) => r.release_context?.rollout_percent ?? 0));
  const nextStep = [1, 5, 10, 25, 50, 100].find((p) => p > current) ?? 100;
  const [percent, setPercent] = useState(String(nextStep));
  // Re-suggest on every open (rows/current change between opens).
  useEffect(() => {
    if (open) setPercent(String(nextStep));
  }, [open, nextStep]);
  return (
    <Dialog open={open} onOpenChange={(v) => !v && onClose()}>
      <DialogContent size="md" fullScreenOnMobile={false}>
        <DialogHeader>
          <DialogTitle>Set rollout % for {rows.length} Android app{rows.length === 1 ? '' : 's'}</DialogTitle>
        </DialogHeader>
        <DialogBody className="space-y-4">
          <div className="text-xs text-zinc-500">
            {rows
              .map(
                (r) =>
                  `${r.appGroup}${
                    (r.release_context?.rollout_percent ?? 0) > 0
                      ? ` (now ${r.release_context!.rollout_percent}%)`
                      : ''
                  }`,
              )
              .join(' · ')}
          </div>
          <div className="flex items-center gap-2">
            {[1, 5, 10, 25, 50, 100].map((p) => (
              <button
                key={p}
                onClick={() => setPercent(String(p))}
                disabled={p <= current}
                title={p <= current ? `Already at ${current}% — rollouts only ramp up` : undefined}
                className={cn(
                  'px-2.5 py-1.5 rounded-lg border text-xs font-medium transition-colors',
                  percent === String(p)
                    ? 'bg-zinc-900 text-white border-zinc-900'
                    : 'bg-white text-zinc-600 border-zinc-200 hover:border-zinc-400',
                  p <= current && 'opacity-40 cursor-not-allowed hover:border-zinc-200',
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
              if (p <= current) {
                toast.error(
                  `Must be greater than the current ${current}% — staged rollouts only ramp up.`,
                );
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
