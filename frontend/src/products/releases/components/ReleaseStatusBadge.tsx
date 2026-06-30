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
    // The raw rt_status is misleading for a build sitting on the store — override it with
    // the canonical backend displayStatus for the lifecycle phases (INPROGRESS review/
    // approve, a rolling/halted/superseded snapshot, a promotable internal build). A still-
    // building or terminal row keeps its truthful raw badge.
    const override =
      release.status === 'INPROGRESS' ||
      phase === 'rolling_out' ||
      phase === 'halted' ||
      phase === 'superseded' ||
      promotable;
    if (override && phase && phase !== 'building' && ctx?.display_label && ctx?.display_variant) {
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
