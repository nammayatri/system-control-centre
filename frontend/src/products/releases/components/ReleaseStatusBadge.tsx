import type { APRelease } from '../api';
import { StatusBadge } from './StatusBadge';
import { Badge } from '../../../shared/ui/badge';
import { isFirebaseInternal, FirebaseInternalBadge } from './FirebaseBadge';

/**
 * Status badge for a release in a LIST / GROUP context.
 *
 * For an INPROGRESS mobile release the raw `rt_status` is misleading — it reads
 * "in progress" while the build is actually sitting on the store awaiting an
 * operator (promote / rollout), and it is NOT "paused". We project the lifecycle
 * stage from `mb_wf_status` + `store_track` (the same mapping the detail page
 * uses; here we only have those two — not the full /rollout detail — which still
 * yields the right stage). Only INPROGRESS is overridden: terminal rows, still-
 * building rows, and store-sync COMPLETED snapshots keep their truthful raw badge.
 *
 * The detail page derives from the richer GET /rollout payload directly; this is
 * the cheap list/group variant that needs no per-row request.
 */
export function ReleaseStatusBadge({
  release,
  suppressPromote = false,
}: {
  release: APRelease;
  // True when a NEWER build of the same app exists, so this (older) internal build is no
  // longer the one to promote — it reads "Superseded" instead of "Ready to promote".
  // Computed by the list (cross-row); defaults off everywhere else.
  suppressPromote?: boolean;
}) {
  // Firebase App Distribution builds go to an INTERNAL channel, not Google Play —
  // flag them so operators don't read them as a store release (shared component so
  // every surface shows the same badge).
  const firebaseBadge = isFirebaseInternal(release) ? <FirebaseInternalBadge /> : null;

  if (release.tracker_type === 'MobileBuild') {
    const ctx = release.release_context;
    const phase = ctx?.display_phase; // canonical backend phase tag
    // A held-on-internal build is promotable — EXCEPT a Firebase provider build (a terminal
    // internal channel with nothing to promote to Play; it keeps its plain status + badge).
    const promotable = phase === 'internal_held' && !isFirebaseInternal(release);
    // Reads "Superseded" instead of "Ready to promote" when a newer build of the same app
    // overtook it: the list's cross-row suppression OR the BE at-or-below-production flag.
    const beNotPromotable = ctx?.promotable === false;
    if (promotable && (suppressPromote || beNotPromotable)) {
      return (
        <>
          {firebaseBadge}
          <Badge variant="default" dot>Superseded</Badge>
        </>
      );
    }
    // Terminal truth beats the raw status word: an abort that came from the
    // Actions pipeline is a FAILURE, a user abort names the actor. (The wf
    // phase can be stale here — aborting flips rt_status only — so key on the
    // status itself; a genuine review 'rejected' phase still wins below.)
    if (release.status === 'USER_ABORTED') {
      return (
        <>
          {firebaseBadge}
          <Badge variant="danger" dot>User aborted</Badge>
        </>
      );
    }
    if (release.status === 'ABORTED' && phase !== 'rejected') {
      return (
        <>
          {firebaseBadge}
          <Badge variant="danger" dot>Failed</Badge>
        </>
      );
    }
    // The raw rt_status is misleading for a build with a store lifecycle — render the
    // canonical backend displayStatus (§15: one label on every surface) for active AND
    // terminal store phases, so the list can't drift from the monitor/detail (a live
    // build reads "Released · 100%" everywhere, a rejected one "Rejected" — not a raw
    // "Completed"/"Aborted"). Kept raw: still-building rows (CREATED/approval nuance),
    // distributed builds (the Firebase/debug chip already labels them), and REVERTED
    // releases (the revert verdict outranks the last store phase).
    const override =
      release.status === 'INPROGRESS' ||
      ['rolling_out', 'halted', 'superseded', 'live', 'rejected', 'aborted', 'build_failed'].includes(phase ?? '') ||
      promotable;
    const keepRaw = phase === 'building' || phase === 'distributed' || release.status === 'REVERTED';
    if (override && phase && !keepRaw && ctx?.display_label && ctx?.display_variant) {
      return (
        <>
          {firebaseBadge}
          <Badge variant={ctx.display_variant} dot>{ctx.display_label}</Badge>
        </>
      );
    }
  }
  return (
    <>
      {firebaseBadge}
      <StatusBadge status={release.status} />
    </>
  );
}
