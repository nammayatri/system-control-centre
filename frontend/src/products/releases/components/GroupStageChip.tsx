import type { MobileGroupMemberLite, MobileGroupSummary } from '../api';
import { Badge } from '../../../shared/ui/badge';
import { cn } from '../../../lib/utils';

/**
 * THE release-group stage vocabulary — one map of names and colors shared by
 * the home list, the group console header, and the member sub-rows, all
 * driven by the server-derived summary so no surface can disagree.
 */

// member phase slug -> chip (mirrors the per-release badge vocabulary)
export const MEMBER_PHASE_CHIP: Record<string, { label: string; cls: string }> = {
  building: { label: 'Building', cls: 'bg-amber-50 text-amber-700 border-amber-200' },
  internal_held: { label: 'Ready to promote', cls: 'bg-blue-50 text-blue-700 border-blue-200' },
  in_review: { label: 'In review', cls: 'bg-violet-50 text-violet-700 border-violet-200' },
  approved: { label: 'Approved · held', cls: 'bg-emerald-50 text-emerald-700 border-emerald-200' },
  rolling_out: { label: 'Rolling out', cls: 'bg-emerald-50 text-emerald-700 border-emerald-200' },
  halted: { label: 'Halted', cls: 'bg-amber-50 text-amber-700 border-amber-200' },
  live: { label: 'Live', cls: 'bg-emerald-50 text-emerald-700 border-emerald-200' },
  distributed: { label: 'Distributed', cls: 'bg-emerald-50 text-emerald-700 border-emerald-200' },
  superseded: { label: 'Superseded', cls: 'bg-zinc-100 text-zinc-500 border-zinc-200' },
  rejected: { label: 'Rejected', cls: 'bg-red-50 text-red-700 border-red-200' },
  build_failed: { label: 'Failed', cls: 'bg-red-50 text-red-700 border-red-200' },
  aborted: { label: 'Aborted', cls: 'bg-red-50 text-red-700 border-red-200' },
  user_aborted: { label: 'User aborted', cls: 'bg-red-50 text-red-700 border-red-200' },
  discarded: { label: 'Discarded', cls: 'bg-zinc-100 text-zinc-500 border-zinc-200' },
};

// group stage slug -> chip
export const STAGE_CHIP: Record<string, { label: string; cls: string }> = {
  approval: { label: 'Pending approval', cls: 'bg-zinc-100 text-zinc-600 border-zinc-200' },
  dispatch: { label: 'Ready to dispatch', cls: 'bg-emerald-50 text-emerald-700 border-emerald-200' },
  building: { label: 'Building', cls: 'bg-amber-50 text-amber-700 border-amber-200' },
  promote: { label: 'Ready to promote', cls: 'bg-blue-50 text-blue-700 border-blue-200' },
  in_review: { label: 'In review', cls: 'bg-violet-50 text-violet-700 border-violet-200' },
  releasing: { label: 'Ready to release', cls: 'bg-emerald-50 text-emerald-700 border-emerald-200' },
  rolling_out: { label: 'Rolling out', cls: 'bg-emerald-50 text-emerald-700 border-emerald-200' },
  done: { label: 'Completed', cls: 'bg-emerald-50 text-emerald-700 border-emerald-200' },
};

const TROUBLE_SLUGS = ['build_failed', 'aborted', 'user_aborted', 'rejected', 'discarded'];

type BadgeVariant = 'default' | 'success' | 'warning' | 'danger' | 'info' | 'muted' | 'purple' | 'blue';

// Group stage -> the SAME Badge vocabulary the individual release rows use
// (shared/ui/badge with a status dot), so group and single rows read alike.
const STAGE_BADGE: Record<string, { label: string; variant: BadgeVariant }> = {
  approval: { label: 'Pending approval', variant: 'default' },
  dispatch: { label: 'Ready to dispatch', variant: 'success' },
  building: { label: 'Building', variant: 'blue' },
  promote: { label: 'Ready to promote', variant: 'purple' },
  in_review: { label: 'In review', variant: 'info' },
  releasing: { label: 'Ready to release', variant: 'success' },
  rolling_out: { label: 'Rolling out', variant: 'blue' },
  done: { label: 'Completed', variant: 'success' },
};

const TROUBLE_BADGE: Record<string, { label: string; variant: BadgeVariant }> = {
  build_failed: { label: 'Failed', variant: 'danger' },
  aborted: { label: 'Aborted', variant: 'danger' },
  user_aborted: { label: 'User aborted', variant: 'danger' },
  rejected: { label: 'Rejected', variant: 'danger' },
  discarded: { label: 'Discarded', variant: 'muted' },
};

/** The group's stage badge. Rendered through the shared Badge so a group row
 * and a single-release row use one visual language. A finished group that
 * shipped nothing takes its members' outcome name — one distinct cause verbatim,
 * a mix reads "Failed" — never a green "Completed". */
export function GroupStageChip({
  summary,
  total,
  members,
}: {
  summary: MobileGroupSummary;
  total: number;
  // when provided, a rolling group's chip carries the live % ("· 50%")
  members?: MobileGroupMemberLite[];
}) {
  const rollingPcts = Array.from(
    new Set(
      (members ?? [])
        .filter((m) => ['rolling_out', 'halted'].includes(m.phase) && m.rolloutPercent != null)
        .map((m) => Math.round(m.rolloutPercent as number)),
    ),
  ).sort((a, b) => a - b);
  const pctSuffix =
    summary.stage === 'rolling_out' && rollingPcts.length > 0
      ? rollingPcts.length === 1
        ? ` · ${rollingPcts[0]}%`
        : ` · ${rollingPcts[0]}–${rollingPcts[rollingPcts.length - 1]}%`
      : '';
  const shipped =
    (summary.counts['live'] ?? 0) +
    (summary.counts['superseded'] ?? 0) +
    (summary.counts['distributed'] ?? 0);
  const failedBadge = () => {
    const present = TROUBLE_SLUGS.filter((s) => (summary.counts[s] ?? 0) > 0);
    if (present.length === 1) return TROUBLE_BADGE[present[0]];
    if (present.length > 1) return TROUBLE_BADGE.build_failed; // mixed -> "Failed"
    return { label: 'Ended', variant: 'muted' as BadgeVariant };
  };
  const failed = summary.stage === 'done' && shipped === 0;
  const badge = failed ? failedBadge() : (STAGE_BADGE[summary.stage] ?? STAGE_BADGE.building);
  const cls = failed
    ? 'bg-red-50 text-red-700 border-red-200'
    : (STAGE_CHIP[summary.stage] ?? STAGE_CHIP.building).cls;
  const pulse = !failed && ['building', 'in_review', 'rolling_out', 'releasing'].includes(summary.stage);
  return (
    <span
      className={cn(
        'inline-flex items-center gap-1.5 text-[10px] font-bold uppercase tracking-wide border rounded-full px-2 py-0.5',
        cls,
      )}
    >
      <span
        className={cn(
          'w-1.5 h-1.5 rounded-full bg-current opacity-70',
          pulse && 'animate-pulse motion-reduce:animate-none',
        )}
      />
      {badge.label}
      {pctSuffix}
      {summary.stage === 'done' && shipped > 0 && total > 1 ? ` · ${shipped}/${total} shipped` : ''}
    </span>
  );
}
