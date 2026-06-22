import type { RolloutDetail } from '../api';

// The mobile promote→rollout lifecycle, derived from the persisted state tuple
// (mb_wf_status + review_status + rollout_status + store_track). This is the
// single source of truth shared by the rollout panel, the detail-page badge, and
// the releases-list badge so they never drift.
export type Stage =
  | 'promote'
  | 'review'
  | 'approved'
  | 'rollout'
  | 'rejected'
  | 'superseded'
  | 'completed'
  | 'none';

// Minimal lifecycle inputs the stage logic needs. The detail/panel fills all of
// them from GET /rollout; a list row fills only mbStatus + storeTrack (review /
// rollout columns aren't in the list response) — which still yields the right
// stage, since mb_wf_status tracks the same progression (only the exact rollout %
// and the halted-vs-rolling distinction need the columns).
export interface MobileLifecycle {
  mbStatus: string;
  reviewStatus?: string | null;
  rolloutStatus?: string | null;
  rolloutPercent?: number | null;
  storeTrack?: string | null;
  // Review state inferred from the store track (Android out-of-band detection)
  // rather than read authoritatively — softens the label to "Pending review".
  reviewInferred?: boolean | null;
}

export function lifecycleFromRollout(d: RolloutDetail): MobileLifecycle {
  return {
    mbStatus: d.rdMbStatus,
    reviewStatus: d.rdReviewStatus,
    rolloutStatus: d.rdRolloutStatus,
    rolloutPercent: d.rdRolloutPercent,
    storeTrack: d.rdStoreTrack,
  };
}

// Build the lifecycle inputs from a list/group release row, where only
// mb_wf_status + store_track + the inferred flag are available (no review/rollout
// columns) — enough to derive the stage. Shared by the status badge and the
// releases-list mobile status filter so they bucket a row identically.
export function lifecycleFromRelease(release: {
  release_context?: {
    mb_wf_status?: string;
    // Authoritative columns injected by the backend serializer (migration 0034).
    rollout_status?: string | null;
    rollout_percent?: number | null;
    store_track?: string | null;
  } | null;
  metadata?: unknown;
}): MobileLifecycle {
  const ctx = release.release_context;
  const meta = release.metadata as
    | {
        store_track?: string;
        review_inferred?: boolean;
        // Store-sync's OBSERVED-rollout mirror — the fallback when the row predates
        // the column injection (otherwise the column below is authoritative).
        rollout_status?: string;
        rollout_percent?: number;
      }
    | null
    | undefined;
  return {
    mbStatus: ctx?.mb_wf_status ?? '',
    // Prefer the authoritative store_track COLUMN; fall back to the metadata mirror
    // for rows that predate the column injection.
    storeTrack: ctx?.store_track ?? meta?.store_track ?? null,
    reviewInferred: meta?.review_inferred ?? null,
    // Prefer the live rollout COLUMNS (updated on a successful set); fall back to the
    // store-sync metadata mirror.
    rolloutStatus: ctx?.rollout_status ?? meta?.rollout_status ?? null,
    rolloutPercent: ctx?.rollout_percent ?? meta?.rollout_percent ?? null,
  };
}

// Map mb_wf_status + review/rollout columns to a single UI stage.
export function stageOf(d: MobileLifecycle): Stage {
  const mb = d.mbStatus;
  // Option A: a store-sync INTERNAL / TestFlight snapshot that hasn't been
  // promoted yet (no review/rollout started) → offer the promote flow, even
  // though the snapshot row is itself "completed". Once promoted, the
  // review/rollout columns below drive the stage as usual.
  if (
    (d.storeTrack === 'internal' || d.storeTrack === 'testflight') &&
    !d.reviewStatus &&
    !d.rolloutStatus &&
    (mb === 'MBCompleted' || mb === 'MBTagPushed')
  )
    return 'promote';
  if (mb === 'MBReviewRejected' || d.reviewStatus === 'rejected') return 'rejected';
  // A previous live version overtaken by a newer rollout (Rule A, migration 0034):
  // frozen at its last % as history. Checked before the rolling/completed states.
  if (d.rolloutStatus === 'superseded') return 'superseded';
  // An active rollout outranks a "completed" build status: a store-sync snapshot
  // row stays mb=MBCompleted even while store-sync mirrors a live production ramp
  // onto it (rollout_status from metadata), so check rolling-out BEFORE completed.
  if (
    mb === 'MBRollingOut' ||
    d.rolloutStatus === 'rolling_out' ||
    d.rolloutStatus === 'halted'
  )
    return 'rollout';
  if (mb === 'MBCompleted' || d.rolloutStatus === 'completed') return 'completed';
  if (mb === 'MBReviewApproved' || d.reviewStatus === 'approved') return 'approved';
  if (
    mb === 'MBInReview' ||
    mb === 'MBSubmittingForReview' ||
    d.reviewStatus === 'in_review' ||
    d.reviewStatus === 'submitted'
  )
    return 'review';
  if (mb === 'MBTagPushed') return 'promote';
  return 'none'; // build not finished yet → nothing to show
}

type BadgeVariant = 'default' | 'success' | 'warning' | 'danger' | 'info' | 'purple' | 'blue';

/**
 * Operator-facing display status for a release status badge.
 *
 * The persisted `rt_status` (e.g. INPROGRESS) is a *mechanical* state — it tells
 * the runner the row is still its to drive. It is the wrong thing to surface once
 * a build is sitting on the store waiting for a human: nothing is "in progress",
 * and it is NOT "paused" (that's an operator-initiated suspend with a Resume).
 * This projects the lifecycle into what the operator should understand/do.
 *
 * Returns `null` while the build itself is still running (stage 'none') — the
 * caller falls back to the raw engine status (which correctly reads BUILDING /
 * INPROGRESS there).
 */
export function mobileDisplayStatus(
  d: MobileLifecycle,
): { label: string; variant: BadgeVariant } | null {
  const stage = stageOf(d);
  const pct = d.rolloutPercent;
  const pctSuffix = pct != null ? ` · ${pct}%` : '';
  switch (stage) {
    case 'promote':
      return { label: 'Ready to promote', variant: 'blue' };
    case 'review':
      // Android can't confirm in-review vs approved-held from the API, so an
      // inferred review surfaces as the honest "Pending review".
      return d.reviewInferred
        ? { label: 'Pending review', variant: 'purple' }
        : { label: 'In review', variant: 'purple' };
    case 'approved':
      return { label: 'Approved · held', variant: 'success' };
    case 'rollout':
      return d.rolloutStatus === 'halted'
        ? { label: `Halted${pctSuffix}`, variant: 'warning' }
        : { label: `Rolling out${pctSuffix}`, variant: 'info' };
    case 'superseded':
      // Overtaken by a newer version's rollout — history, frozen at its last %.
      return { label: `Superseded${pctSuffix}`, variant: 'default' };
    case 'rejected':
      return { label: 'Review rejected', variant: 'danger' };
    case 'completed':
      return { label: 'Released · 100%', variant: 'success' };
    default:
      return null; // build not done → caller shows the raw engine status
  }
}
