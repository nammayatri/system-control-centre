import { CheckIcon, PauseIcon, XIcon } from '@phosphor-icons/react';
import { cn } from '../../../../../lib/utils';
import { isFirebaseInternal } from '../../../components/FirebaseBadge';
import type { APRelease, RolloutDetail } from '../../../api';

/**
 * PhaseRail — full-width phase indicator for ONE mobile release.
 *
 * Store rail:        Draft → Approve → Build → Promote → Review → Rollout → Live
 * Distribution rail: Draft → Approve → Build → Distributed   (debug / Firebase builds)
 *
 * Legend (dot states):
 *   done    = emerald-500 fill + white check
 *   current = violet-600 fill + violet ring + pulsing white core (motion-reduce: static)
 *   failed  = rose-500 fill + rose ring + white X, pinned at the step the failure interrupted
 *   todo    = white fill, zinc-200 outline
 *   terminal 'superseded' mutes the whole rail to zinc (complete, but overtaken)
 *
 * All state comes from the canonical backend vocabulary — display_phase /
 * rdPhase (phaseSlug), the engine status, and the backend displayStatus label.
 * Sub-labels are never re-derived from raw fields; wf memory (mb_wf_status) is
 * consulted only to place dead rows at the step their failure interrupted,
 * mirroring rowMark in ReleaseGroupDetail.
 *
 * <PhaseRail> is pure: no hooks, no fetching. deriveRail is exported
 * separately so the mapping can be unit-tested without rendering.
 */

export interface RailStep {
  name: string;
  state: 'done' | 'current' | 'failed' | 'todo';
  subLabel?: string;
}

export interface DerivedRail {
  steps: RailStep[];
  terminal?: 'reverted' | 'superseded' | null;
}

export const STORE_STEPS = [
  'Draft',
  'Approve',
  'Build',
  'Promote',
  'Review',
  'Rollout',
  'Live',
] as const;

export const DISTRIBUTION_STEPS = ['Draft', 'Approve', 'Build', 'Distributed'] as const;

// The step a dead/reverted row's workflow memory says it reached — same rule
// as rowMark (ReleaseGroupDetail.tsx), plus MBCompleted→Live: a REVERTED row
// that fully shipped pins "Reverted" at Live, not Build. Covers MBFailed's
// `MBFailed "err"` show-string via the default arm.
function wfStep(wf: string): number {
  if (wf === 'MBCompleted') return 6;
  if (wf === 'MBReviewApproved' || wf === 'MBRollingOut') return 5;
  if (wf === 'MBSubmittingForReview' || wf === 'MBInReview') return 4;
  if (wf === 'MBTagPushed') return 3;
  return 2;
}

// Engine statuses that mean the row is dead, with the sub-label each shows
// (parity with ReleaseStatusBadge / effectivePhase folding).
const DEAD_STATUS_SUB: Record<string, string> = {
  ABORTED: 'Failed',
  USER_ABORTED: 'User aborted',
  GCLT_ABORTED: 'Aborted',
  DISCARDED: 'Discarded',
};

// In-flight teardown statuses: shown as a live (violet) pin at the same
// wf-memory step the terminal state will land on.
const TEARDOWN_STATUS_SUB: Record<string, string> = {
  ABORTING: 'Aborting',
  DISCARDING: 'Discarding',
  REVERTING: 'Reverting',
};

// Steps before `at` are done, `at` carries the state + sub-label, rest todo.
function pinAt(
  names: readonly string[],
  at: number,
  state: 'current' | 'failed',
  subLabel?: string,
): RailStep[] {
  return names.map((name, i) => ({
    name,
    state: i < at ? 'done' : i === at ? state : 'todo',
    ...(i === at && subLabel ? { subLabel } : {}),
  }));
}

function allDone(names: readonly string[], subLabel?: string): RailStep[] {
  return names.map((name, i) => ({
    name,
    state: 'done',
    ...(i === names.length - 1 && subLabel ? { subLabel } : {}),
  }));
}

export function deriveRail(release: APRelease, rollout?: RolloutDetail): DerivedRail {
  const ctx = release.release_context;
  // Canonical sources — rollout detail wins over the serialized list row.
  const phase = rollout?.rdPhase ?? ctx?.display_phase ?? '';
  const wf = rollout?.rdMbStatus ?? ctx?.mb_wf_status ?? '';
  const label = rollout?.rdStatusLabel ?? ctx?.display_label;
  const debugRail = ctx?.build_type === 'debug' || isFirebaseInternal(release);
  const names: readonly string[] = debugRail ? DISTRIBUTION_STEPS : STORE_STEPS;
  const last = names.length - 1;
  // Store-rail step indices can exceed the 4-step distribution rail; a dead
  // debug row never legally passes Build, but stay defined regardless.
  const clamp = (i: number) => Math.min(i, last);
  const status = release.status;

  // 1. Failure branch. Specific failed phases outrank the raw engine status
  //    (an ABORTED row whose phase says 'rejected' died in review, not "somewhere").
  if (phase === 'rejected') {
    return { steps: pinAt(names, clamp(4), 'failed', 'Rejected'), terminal: null };
  }
  if (phase === 'build_failed') {
    return { steps: pinAt(names, 2, 'failed', 'Build failed'), terminal: null };
  }
  if (status === 'REVERTED') {
    return { steps: pinAt(names, clamp(wfStep(wf)), 'failed', 'Reverted'), terminal: 'reverted' };
  }
  const deadSub = DEAD_STATUS_SUB[status];
  if (deadSub) {
    return { steps: pinAt(names, clamp(wfStep(wf)), 'failed', deadSub), terminal: null };
  }
  // phase 'aborted' with a not-yet-folded engine status (pEngineStatus lag).
  if (phase === 'aborted') {
    return { steps: pinAt(names, clamp(wfStep(wf)), 'failed', 'Aborted'), terminal: null };
  }
  const teardownSub = TEARDOWN_STATUS_SUB[status];
  if (teardownSub) {
    return { steps: pinAt(names, clamp(wfStep(wf)), 'current', teardownSub), terminal: null };
  }

  // 2. Pre-dispatch draft.
  if (status === 'CREATED') {
    return release.is_approved === 1
      ? { steps: pinAt(names, 1, 'current', 'ready to dispatch'), terminal: null }
      : { steps: pinAt(names, 0, 'current', 'awaiting approval'), terminal: null };
  }

  // 3. Canonical phase-slug mapping. Sub-labels prefer the backend
  //    displayStatus label; literals are last-resort fallbacks only.
  switch (phase) {
    case 'building':
      return { steps: pinAt(names, 2, 'current', label ?? 'Building'), terminal: null };
    case 'internal_held':
      return { steps: pinAt(names, clamp(3), 'current', label ?? 'Ready to promote'), terminal: null };
    case 'in_review':
      return { steps: pinAt(names, clamp(4), 'current', label ?? 'In review'), terminal: null };
    case 'approved':
      return { steps: pinAt(names, clamp(5), 'current', label ?? 'Approved · held'), terminal: null };
    case 'rolling_out':
      return { steps: pinAt(names, clamp(5), 'current', label ?? 'Rolling out'), terminal: null };
    case 'halted':
      return { steps: pinAt(names, clamp(5), 'current', label ?? 'Halted'), terminal: null };
    case 'live':
      return { steps: allDone(names, label ?? 'Released · 100%'), terminal: null };
    case 'superseded':
      return { steps: allDone(names, 'Superseded'), terminal: 'superseded' };
    case 'distributed':
      return { steps: allDone(names, label ?? 'Distributed'), terminal: null };
  }

  // 4. No phase on the wire (row pre-dates the serializer / just dispatched):
  //    place by status + wf memory so the rail never renders empty.
  if (status === 'COMPLETED') {
    return { steps: allDone(names, label), terminal: null };
  }
  return { steps: pinAt(names, clamp(wfStep(wf)), 'current', label), terminal: null };
}

const ARIA_STATE: Record<RailStep['state'], string> = {
  done: 'done',
  current: 'current',
  failed: 'failed',
  todo: 'upcoming',
};

export function PhaseRail({
  release,
  rollout,
}: {
  release: APRelease;
  rollout?: RolloutDetail;
}) {
  const { steps, terminal } = deriveRail(release, rollout);
  const n = steps.length;
  const muted = terminal === 'superseded';
  const pinIdx = steps.findIndex((s) => s.state === 'current' || s.state === 'failed');
  const reach = pinIdx === -1 ? n - 1 : pinIdx; // progress line filled up to here
  const pin = pinIdx === -1 ? undefined : steps[pinIdx];
  const failed = pin?.state === 'failed';
  // Pin tone follows the mockup: Rollout activity pulses emerald, everything
  // else (promote/review pins) pulses violet; an approved-held build shows a
  // pause glyph instead of the pulsing core.
  const held = (rollout?.rdPhase ?? release.release_context?.display_phase) === 'approved';
  const pinEmerald = pin?.name === 'Rollout';
  const railLabel = pin
    ? `Release progress: step ${pinIdx + 1} of ${n}, ${pin.name}${pin.subLabel ? ` — ${pin.subLabel}` : ''}`
    : muted
      ? `Release superseded: all ${n} steps complete, overtaken by a newer build`
      : `Release complete: all ${n} steps done`;

  return (
    <div className="overflow-x-auto">
      <div className="relative w-full min-w-140">
        {/* Base + progress lines (mockup: absolute 2px rails behind the dots) */}
        <div aria-hidden="true" className="absolute top-5 left-0 right-0 h-0.5 bg-zinc-200 z-0" />
        <div
          aria-hidden="true"
          className={cn(
            'absolute top-5 left-0 h-0.5 z-10 transition-all duration-500',
            failed ? 'bg-red-500' : muted ? 'bg-zinc-300' : 'bg-emerald-500',
          )}
          style={{ width: `${(reach / (n - 1)) * 100}%` }}
        />
        <ol role="list" aria-label={railLabel} className="relative z-20 flex justify-between items-start w-full">
          {steps.map((step, i) => (
            <li
              key={step.name}
              role="listitem"
              aria-current={step.state === 'current' ? 'step' : undefined}
              aria-label={`Step ${i + 1} of ${n}: ${step.name} — ${ARIA_STATE[step.state]}${step.subLabel ? ` (${step.subLabel})` : ''}`}
              className="flex flex-col items-center gap-2 w-16 sm:w-20"
              title={step.subLabel ? `${step.name} — ${step.subLabel}` : step.name}
            >
              {step.state === 'done' && (
                <span
                  className={cn(
                    'w-10 h-10 rounded-full border-2 border-white flex items-center justify-center text-white shadow-md',
                    muted ? 'bg-zinc-300' : 'bg-emerald-500',
                  )}
                >
                  <CheckIcon size={14} weight="bold" aria-hidden="true" />
                </span>
              )}
              {step.state === 'current' && (
                <span
                  className={cn(
                    'w-10 h-10 rounded-full bg-white border-[3px] flex items-center justify-center relative',
                    pinEmerald ? 'border-emerald-500' : 'border-violet-500',
                  )}
                >
                  <span
                    aria-hidden="true"
                    className={cn(
                      'absolute inset-0 rounded-full border-2 animate-ping opacity-50 -z-10 motion-reduce:animate-none',
                      pinEmerald ? 'border-emerald-400' : 'border-violet-400',
                    )}
                  />
                  {held && pinEmerald ? (
                    <PauseIcon size={16} weight="bold" className="text-emerald-500" aria-hidden="true" />
                  ) : (
                    <span
                      className={cn('w-3 h-3 rounded-full', pinEmerald ? 'bg-emerald-500' : 'bg-violet-500')}
                    />
                  )}
                </span>
              )}
              {step.state === 'failed' && (
                <span className="w-10 h-10 rounded-full bg-red-50 border-2 border-red-500 flex items-center justify-center text-red-500 relative">
                  <span
                    aria-hidden="true"
                    className="absolute inset-0 rounded-full border-2 border-red-300 animate-ping opacity-50 -z-10 motion-reduce:animate-none"
                  />
                  <XIcon size={14} weight="bold" aria-hidden="true" />
                </span>
              )}
              {step.state === 'todo' && (
                <span className="w-10 h-10 rounded-full bg-zinc-100 border-2 border-white flex items-center justify-center">
                  <span className="w-2 h-2 rounded-full bg-zinc-300" />
                </span>
              )}

              <span className="text-center">
                <span
                  className={cn(
                    'block text-[11px] leading-tight whitespace-nowrap',
                    step.state === 'todo' ? 'font-medium text-zinc-400' : 'font-bold text-zinc-700',
                  )}
                >
                  {step.name}
                </span>
                {step.subLabel && (
                  <span
                    className={cn(
                      'block text-[10px] font-bold uppercase mt-1 whitespace-nowrap',
                      step.state === 'failed'
                        ? 'text-red-600'
                        : step.state === 'current'
                          ? pinEmerald
                            ? 'text-emerald-600'
                            : 'text-violet-600'
                          : 'text-zinc-500',
                    )}
                  >
                    {step.subLabel}
                  </span>
                )}
              </span>
            </li>
          ))}
        </ol>
      </div>
    </div>
  );
}
