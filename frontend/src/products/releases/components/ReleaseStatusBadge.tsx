import type { APRelease } from '../api';
import { StatusBadge } from './StatusBadge';
import { Badge } from '../../../shared/ui/badge';
import { mobileDisplayStatus, lifecycleFromRelease, stageOf } from './mobileStage';
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
    const lc = lifecycleFromRelease(release);
    // Override the raw status for an INPROGRESS row (its raw status is misleading)
    // OR a COMPLETED store-sync snapshot that's mirroring a live production rollout
    // (stage 'rollout') OR a superseded version frozen as history (stage 'superseded',
    // also COMPLETED) — so the badge matches the status filter and the row's track chip.
    const stage = stageOf(lc);
    // An internal / TestFlight store-sync build (stage 'promote') is NOT released — it's
    // the latest build pending promotion, so show "Ready to promote" instead of a
    // misleading COMPLETED. EXCEPT a Firebase provider build: Firebase App Distribution is
    // a terminal internal channel with nothing to promote to Play, so it keeps its plain
    // status (COMPLETED) + the Firebase badge.
    const promotable = stage === 'promote' && !isFirebaseInternal(release);
    // BE truth: a build at or below the production code is not promotable (overtaken by
    // production). Combined with the list's latest-per-app suppression — either makes a
    // promote-stage build read "Superseded" instead of "Ready to promote".
    const beNotPromotable = release.release_context?.promotable === false;
    // Only the latest, higher-than-production build is promotable; an older internal build
    // a newer one (or production) has overtaken reads "Superseded" (not COMPLETED — it
    // isn't released to users).
    if (promotable && (suppressPromote || beNotPromotable)) {
      return (
        <>
          {firebaseBadge}
          <Badge variant="default" dot>Superseded</Badge>
        </>
      );
    }
    if (
      release.status === 'INPROGRESS' ||
      stage === 'rollout' ||
      stage === 'superseded' ||
      promotable
    ) {
      const mb = mobileDisplayStatus(lc);
      if (mb)
        return (
          <>
            {firebaseBadge}
            <Badge variant={mb.variant} dot>{mb.label}</Badge>
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
