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
  // metadata is consulted ONLY for review_inferred (a metadata-only flag). The
  // store_track / rollout COLUMNS are authoritative — fromRow flattens the live
  // value into release_context, so the stale rollout mirror is no longer read.
  const meta = release.metadata as { review_inferred?: boolean } | null | undefined;
  return {
    mbStatus: ctx?.mb_wf_status ?? '',
    storeTrack: ctx?.store_track ?? null,
    reviewInferred: meta?.review_inferred ?? null,
    rolloutStatus: ctx?.rollout_status ?? null,
    rolloutPercent: ctx?.rollout_percent ?? null,
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

// mobileDisplayStatus was removed — the badge is now the backend displayStatus,
// rendered from release_context.display_label/variant (list/bulk) and rdStatusLabel
// (detail/summary). stageOf above stays for sort/filter + control-logic only.
