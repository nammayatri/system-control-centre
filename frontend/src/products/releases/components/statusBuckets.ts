import type { APRelease, MobileGroupMemberLite } from '../api';

// THE mobile status-bucket vocabulary (same values as MOBILE_STATUS_OPTIONS):
// one fn shared by the KPI tiles, the groups view and the app-slot view, so a
// tile's count always equals the rows its click filters to.

// Buckets that never occupy a store lane — they exist only as individual
// release/member rows, which only the Groups view (and history) renders.
// The Apps view must not filter on these: it would match rows it can't show.
export const ROW_ONLY_BUCKETS = new Set([
  'created',
  'to_dispatch',
  'building',
  'aborted',
  'rejected',
  'reverted',
]);

// Which History status-bucket a group MEMBER falls in.
export function memberBucket(m: MobileGroupMemberLite): string {
  if (m.phase === 'rejected') return 'rejected';
  if (m.status === 'REVERTED') return 'reverted';
  if (
    ['ABORTED', 'USER_ABORTED', 'GCLT_ABORTED', 'DISCARDED'].includes(m.status) ||
    ['build_failed', 'aborted', 'user_aborted', 'discarded'].includes(m.phase)
  )
    return 'aborted';
  // ACTIVE store-lifecycle phase wins over the raw status: a store-synced build
  // sitting on the internal track reads status=COMPLETED but is "ready to
  // promote" (phase internal_held) — bucket it by the phase the badge shows, or
  // the filter would never surface it under "Ready to promote".
  if (m.phase === 'rolling_out' || m.phase === 'halted') return 'rollout';
  if (m.phase === 'internal_held') return 'promote';
  if (m.phase === 'in_review') return 'review';
  if (m.phase === 'approved') return 'approved';
  // Terminal store phases read status=INPROGRESS on store-synced rows (their
  // rollout is done/superseded, not the SCC status) — bucket by the phase the
  // badge shows, or a live/superseded row wrongly falls through to "building".
  if (['live', 'distributed', 'superseded'].includes(m.phase)) return 'completed';
  if (m.status === 'COMPLETED') return 'completed';
  // Pre-dispatch rows share phase "building" but nothing is running yet —
  // split by the approval gate so each human queue gets its own bucket.
  if (m.status === 'CREATED') return m.approved ? 'to_dispatch' : 'created';
  return 'building'; // dispatched + genuinely building (phase 'building' or empty)
}

// Same bucketing for a store-detected row (APRelease shape).
export function storeBucket(r: APRelease): string {
  return memberBucket({
    releaseId: r.id,
    app: r.appGroup,
    surface: r.service,
    platform: r.env,
    version: r.new_version,
    phase: r.release_context?.display_phase ?? '',
    status: r.status,
    approved: r.is_approved === 1,
  });
}
