import type { APRelease } from '../api';
import { StatusBadge } from './StatusBadge';
import { Badge } from '../../../shared/ui/badge';
import { mobileDisplayStatus, lifecycleFromRelease, stageOf } from './mobileStage';

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
export function ReleaseStatusBadge({ release }: { release: APRelease }) {
  if (release.tracker_type === 'MobileBuild') {
    const lc = lifecycleFromRelease(release);
    // Override the raw status for an INPROGRESS row (its raw status is misleading)
    // OR a COMPLETED store-sync snapshot that's mirroring a live production rollout
    // (stage 'rollout' from the reflected rollout_status) — so the badge matches the
    // status filter and the row's track chip.
    if (release.status === 'INPROGRESS' || stageOf(lc) === 'rollout') {
      const mb = mobileDisplayStatus(lc);
      if (mb) return <Badge variant={mb.variant} dot>{mb.label}</Badge>;
    }
  }
  return <StatusBadge status={release.status} />;
}
