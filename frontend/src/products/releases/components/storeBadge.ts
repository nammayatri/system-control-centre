// Lifecycle-badge derivation for the App Release Monitoring dashboard.
// Computed purely in the UI from a TrackCell (status + reviewStatus +
// rolloutPercent), so the same logic drives the card cells and the modal.
// Mirrors the badge table in the design doc (§4) exactly.

import type { TrackCell } from '../api';

type BadgeVariant =
  | 'default'
  | 'success'
  | 'warning'
  | 'danger'
  | 'info'
  | 'muted'
  | 'purple'
  | 'blue';

export interface StoreBadge {
  label: string;
  variant: BadgeVariant;
}

// Below ~1% a production % is the parked "pending" fraction (a submitted /
// approved-held build under managed publishing), not a real ramp — mirrors the
// backend's androidRolloutFloorPercent so the two never disagree.
const ROLLOUT_FLOOR = 1;

/** A rollout %, trimmed to 1 decimal (10 → "10", 12.5 → "12.5"). */
export function formatRolloutPercent(pct: number): string {
  return `${Math.round(pct * 10) / 10}`;
}

export interface ActiveRollout {
  pct: number;
  halted: boolean;
}

/**
 * An IN-FLIGHT production rollout — actively ramping (≥ floor, < 100) or halted
 * mid-ramp — with its %. `null` when the track isn't in a rollout: parked at the
 * pending fraction, fully live, or empty. Shared by the badge, the inline
 * progress bars, and the "Active rollouts" band so they never disagree.
 */
export function activeRolloutOf(cell: TrackCell | null): ActiveRollout | null {
  if (!cell || cell.rolloutPercent == null) return null;
  const pct = cell.rolloutPercent;
  if (cell.status === 'halted') return { pct, halted: true };
  if (cell.status === 'inProgress' && pct >= ROLLOUT_FLOOR && pct < 100) return { pct, halted: false };
  return null;
}

/** Which store track a cell belongs to — drives the testing-track badges. */
export type TrackKind = 'production' | 'internal' | 'testflight';

/**
 * Derive the lifecycle badge for a single track cell. `null`/`none` tracks
 * collapse to an em-dash so empty rows read as "nothing here" rather than a
 * misleading status.
 *
 * The TESTING tracks (internal / testflight) are never "live to users", so they
 * badge by track — an internal build reads "Internal", not "Live". (A review /
 * rollout is a production-track concept and is mirrored onto the production cell,
 * so the testing cell only ever reports the build sitting on that testing track.)
 *
 * Production precedence: a terminal review verdict (rejected / in-review) first,
 * then the LIVE rollout state (halted / actively ramping) — an active ramp
 * outranks the prior "approved", so a build approved AND rolling out at 10% reads
 * "Rolling out 10%", while one approved but still parked at the pending fraction
 * reads "Approved · held".
 */
export function deriveStoreBadge(cell: TrackCell | null, track: TrackKind = 'production'): StoreBadge {
  if (!cell) return { label: '—', variant: 'muted' };

  const { status, reviewStatus, rolloutPercent: pct } = cell;

  // Testing tracks: badge purely by track (an internal/TestFlight build is "available
  // for testing", never "Live"). The production-review verdict (In review / Approved ·
  // held / Rejected) is NOT shown here — it belongs to the dedicated Incoming cell, so
  // surfacing it on the testing row too would double-show the same state.
  if (track === 'internal' || track === 'testflight') {
    if (status == null || status === 'none') return { label: '—', variant: 'muted' };
    return track === 'internal'
      ? { label: 'Internal', variant: 'blue' }
      : { label: 'TestFlight', variant: 'info' };
  }

  if (reviewStatus === 'rejected') return { label: 'Rejected', variant: 'danger' };
  if (reviewStatus === 'in_review') return { label: 'In review', variant: 'purple' };

  // Live rollout state beats "approved" — once it's moving (or halted mid-ramp)
  // that's the headline, not the approval that preceded it.
  const ar = activeRolloutOf(cell);
  if (ar?.halted) return { label: `Halted @ ${formatRolloutPercent(ar.pct)}%`, variant: 'warning' };
  if (ar) return { label: `Rolling out ${formatRolloutPercent(ar.pct)}%`, variant: 'info' };

  // Approved but not yet ramping (parked at the pending fraction / held).
  if (reviewStatus === 'approved') return { label: 'Approved · held', variant: 'success' };

  if (status === 'live' || status === 'completed') {
    return { label: pct === 100 ? 'Live · 100%' : 'Live', variant: 'success' };
  }

  if (status === 'VALID') return { label: 'TestFlight', variant: 'info' };

  return { label: '—', variant: 'muted' };
}
