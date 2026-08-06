import type { APRelease, RolloutDetail } from '../../../api';
import { isFirebaseInternal } from '../../../components/FirebaseBadge';

/**
 * The page-wide state machine (v4 design: docs/design/
 * mobile-release-summary-mockup-v4.html). One scenario drives every accent on
 * the page — status pill, cockpit top bar, rail pin tones — exactly like the
 * mockup's `data-scenario`. Derived ONLY from canonical sources (rdPhase /
 * display_phase, engine status, platform), never re-derived per component.
 */
export type Scenario =
  | 'draft'
  | 'building'
  | 'promote' // built · held on internal track
  | 'review' // in store review
  | 'held' // approved · held
  | 'rollout-android' // Play staged rollout (incl. halted)
  | 'rollout-ios' // Apple phased release
  | 'live'
  | 'superseded'
  | 'failed' // build failed / rejected / aborted / reverted
  | 'debug'; // Firebase / TestFlight internal distribution

const DEAD = new Set(['ABORTED', 'USER_ABORTED', 'GCLT_ABORTED', 'DISCARDED', 'REVERTED']);

export function deriveScenario(release: APRelease, rollout?: RolloutDetail): Scenario {
  const phase = rollout?.rdPhase ?? release.release_context?.display_phase ?? '';
  if (DEAD.has(release.status) || phase === 'build_failed' || phase === 'rejected' || phase === 'aborted')
    return 'failed';
  if (release.status === 'CREATED') return 'draft';
  switch (phase) {
    case 'building':
      return 'building';
    case 'distributed':
      return 'debug';
    case 'internal_held':
      return 'promote';
    case 'in_review':
      return 'review';
    case 'approved':
      return 'held';
    case 'rolling_out':
    case 'halted':
      return release.env === 'ios' ? 'rollout-ios' : 'rollout-android';
    case 'live':
      return 'live';
    case 'superseded':
      return 'superseded';
  }
  // No phase on the wire: a debug row that finished distributes; anything else
  // completed reads live; in-flight defaults to building.
  if (release.status === 'COMPLETED')
    return release.release_context?.build_type === 'debug' || isFirebaseInternal(release) ? 'debug' : 'live';
  return 'building';
}

/** Cockpit top-accent bar per scenario (mockup's state accents, extended). */
export const SCENARIO_ACCENT: Record<Scenario, string> = {
  'draft': 'bg-zinc-300',
  'building': 'bg-amber-400',
  'promote': 'bg-blue-500',
  'review': 'bg-violet-500',
  'held': 'bg-emerald-400',
  'rollout-android': 'bg-emerald-500',
  'rollout-ios': 'bg-sky-500',
  'live': 'bg-emerald-500',
  'superseded': 'bg-zinc-300',
  'failed': 'bg-red-500',
  'debug': 'bg-amber-400',
};

/** Status-pill colors per scenario (mockup pill language, extended). */
export const SCENARIO_PILL: Record<Scenario, { box: string; dot: string | null }> = {
  'draft': { box: 'bg-zinc-100 border-zinc-200 text-zinc-600', dot: 'bg-zinc-400' },
  'building': { box: 'bg-amber-50 border-amber-200 text-amber-700', dot: 'bg-amber-500' },
  'promote': { box: 'bg-blue-50 border-blue-200 text-blue-700', dot: 'bg-blue-500' },
  'review': { box: 'bg-violet-50 border-violet-200 text-violet-700', dot: 'bg-violet-500' },
  'held': { box: 'bg-emerald-50 border-emerald-200 text-emerald-700', dot: null },
  'rollout-android': { box: 'bg-emerald-50 border-emerald-200 text-emerald-700', dot: 'bg-emerald-500' },
  'rollout-ios': { box: 'bg-sky-50 border-sky-200 text-sky-700', dot: 'bg-sky-500' },
  'live': { box: 'bg-emerald-50 border-emerald-200 text-emerald-700', dot: null },
  'superseded': { box: 'bg-zinc-100 border-zinc-200 text-zinc-500', dot: null },
  'failed': { box: 'bg-red-50 border-red-200 text-red-700', dot: null },
  'debug': { box: 'bg-amber-50 border-amber-200 text-amber-700', dot: null },
};

/**
 * Human words for the build workflow's internal stage (mb_wf_status), shown
 * while the page scenario is 'building' — the operator sees WHERE the
 * workflow is (dispatching / building / uploading), not just "Building".
 */
export const BUILD_WORKFLOW_STEPS = ['Preparing', 'Dispatched', 'Building', 'Uploading'] as const;

export interface BuildStageInfo {
  step: number; // 1-based index into BUILD_WORKFLOW_STEPS
  label: (typeof BUILD_WORKFLOW_STEPS)[number];
  detail: string;
}

export function buildWorkflowStage(release: APRelease): BuildStageInfo | null {
  const mb = (release.release_context?.mb_wf_status ?? '') as string;
  switch (mb) {
    case 'MBInit':
    case 'MBVersionResolved':
      return { step: 1, label: 'Preparing', detail: 'Resolving the version and claiming the build slot.' };
    case 'MBDispatched':
      return { step: 2, label: 'Dispatched', detail: 'Workflow dispatched — waiting for GitHub to start the run.' };
    case 'MBRunIdResolved':
    case 'MBBuilding':
      return { step: 3, label: 'Building', detail: 'GitHub runners are building the app.' };
    case 'MBSubmittedToStore':
      return { step: 4, label: 'Uploading', detail: 'Artifact uploaded — waiting for the store to process it and the release tag to land.' };
    default:
      return null;
  }
}
