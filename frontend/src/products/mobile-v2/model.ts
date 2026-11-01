import type { APRelease, MobileGroupListItem, MobileGroupMemberLite } from '../releases/api';
import type { AppCatalogEntry } from '../releases/types';

// ── Stages ────────────────────────────────────────────────────────
// One stage per app row, derived ONLY from the backend's canonical phase
// (release_context.display_phase / member.phase). Columns are the fixed
// release sequence the stage matrix draws as a "metro line".

export type Stage =
  | 'draft' | 'building' | 'failed' | 'aborted' | 'ready' | 'distributed'
  | 'review' | 'rejected' | 'approved' | 'rolling' | 'paused' | 'live' | 'superseded';

export const COLUMNS = ['Build', 'Internal', 'Review', 'Approved', 'Rollout', 'Live'] as const;

export const STAGE_META: Record<Stage, { col: number; label: string; broken?: boolean }> = {
  draft: { col: 0, label: 'Draft' },
  building: { col: 0, label: 'Building' },
  failed: { col: 0, label: 'Build failed', broken: true },
  aborted: { col: 0, label: 'Stopped', broken: true },
  ready: { col: 1, label: 'On internal' },
  distributed: { col: 1, label: 'Distributed' },
  review: { col: 2, label: 'In review' },
  rejected: { col: 2, label: 'Rejected', broken: true },
  approved: { col: 3, label: 'Approved' },
  rolling: { col: 4, label: 'Rolling out' },
  paused: { col: 4, label: 'Paused' },
  live: { col: 5, label: 'Live' },
  superseded: { col: 5, label: 'Superseded' },
};

const PHASE_TO_STAGE: Record<string, Stage> = {
  building: 'building', build_failed: 'failed', distributed: 'distributed', internal_held: 'ready',
  in_review: 'review', approved: 'approved', rolling_out: 'rolling', halted: 'paused', live: 'live',
  rejected: 'rejected', superseded: 'superseded', aborted: 'aborted',
};
const DEAD = new Set(['ABORTED', 'USER_ABORTED', 'GCLT_ABORTED', 'DISCARDED', 'DISCARDING', 'REVERTED']);

function stageFrom(status: string, phase: string | undefined | null): Stage {
  if (status === 'CREATED') return 'draft';
  if (phase && PHASE_TO_STAGE[phase]) return PHASE_TO_STAGE[phase];
  if (DEAD.has(status)) return 'aborted';
  if (status === 'COMPLETED') return 'live';
  return 'building';
}
export const stageOfRelease = (r: APRelease): Stage => stageFrom(r.status, r.release_context?.display_phase);
export const stageOfMember = (m: MobileGroupMemberLite): Stage => stageFrom(m.status, m.phase);

/** Column a stage sits in. A superseded build that never reached production
 * stops at Internal; one that did shows at Live. */
export function columnOf(stage: Stage, r?: APRelease): number {
  if (stage === 'superseded' && r && r.release_context?.store_track !== 'production') return 1;
  return STAGE_META[stage].col;
}

export const isAndroid = (platform: string) => platform !== 'ios';
export const RAMP_STEPS = [1, 2, 5, 10, 20, 50, 100];
export const nextRampStep = (pct: number | null | undefined) => RAMP_STEPS.find((s) => s > (pct ?? 0)) ?? 100;

/** Short status label under the row's marker. */
export function stageLabel(stage: Stage, r: APRelease): string {
  const pct = r.release_context?.rollout_percent;
  switch (stage) {
    case 'rolling': return isAndroid(r.env) && pct != null ? `Rolling · ${fmtPct(pct)}%` : 'Rolling · phased';
    case 'paused': return pct != null ? `Paused · ${fmtPct(pct)}%` : 'Paused';
    case 'draft': return r.is_approved === 1 ? 'Approved draft' : 'Draft';
    default: return STAGE_META[stage].label;
  }
}
export const fmtPct = (p: number) => `${Math.round(p * 10) / 10}`;

// ── The one primary action per app ────────────────────────────────

export type ActionKey = 'approve' | 'dispatch' | 'submit' | 'confirm' | 'release' | 'ramp' | 'resume' | 'pause' | 'releaseAll';

export const ACTIONS: Record<ActionKey, { title: string; verb: string; done: string }> = {
  approve: { title: 'Approve drafts', verb: 'Approve', done: 'Approved' },
  dispatch: { title: 'Start builds', verb: 'Start build', done: 'Build started' },
  submit: { title: 'Submit for review', verb: 'Submit', done: 'Submitted' },
  confirm: { title: 'Confirm Play approval', verb: 'Confirm', done: 'Approval confirmed' },
  release: { title: 'Release to users', verb: 'Release', done: 'Released' },
  ramp: { title: 'Ramp rollout', verb: 'Ramp', done: 'Ramped' },
  resume: { title: 'Resume rollout', verb: 'Resume', done: 'Resumed' },
  pause: { title: 'Pause rollout', verb: 'Pause', done: 'Paused' },
  releaseAll: { title: 'Release to everyone', verb: 'Release to everyone', done: 'Released to everyone' },
};

export function nextAction(r: APRelease, stage = stageOfRelease(r)): { key: ActionKey; label: string } | null {
  switch (stage) {
    case 'draft':
      if (r.is_approved !== 1) return { key: 'approve', label: 'Approve' };
      return r.release_context?.dispatch_id ? null : { key: 'dispatch', label: 'Start build' };
    case 'ready':
      return r.release_context?.promotable === false ? null : { key: 'submit', label: 'Submit' };
    case 'review':
      return isAndroid(r.env) ? { key: 'confirm', label: 'Confirm approval' } : null;
    case 'approved':
      return { key: 'release', label: isAndroid(r.env) ? 'Start rollout' : 'Release' };
    case 'rolling':
      return isAndroid(r.env) ? { key: 'ramp', label: `Ramp to ${nextRampStep(r.release_context?.rollout_percent)}%` } : null;
    case 'paused':
      return { key: 'resume', label: 'Resume' };
    default:
      return null;
  }
}

export function eligibleFor(key: ActionKey, r: APRelease): boolean {
  const s = stageOfRelease(r);
  if (key === 'pause' || key === 'releaseAll') return s === 'rolling';
  return nextAction(r, s)?.key === key;
}

/** Only PROMOTE/ROLLOUT-style verbs reach the store; drafts are internal. */
export const PERM_FOR: Record<ActionKey, string> = {
  approve: 'MB_RELEASE_CREATE', dispatch: 'MB_MOBILE_DISPATCH', submit: 'MB_RELEASE_PROMOTE', confirm: 'MB_RELEASE_PROMOTE',
  release: 'MB_RELEASE_ROLLOUT', ramp: 'MB_RELEASE_ROLLOUT', resume: 'MB_RELEASE_ROLLOUT', pause: 'MB_RELEASE_ROLLOUT', releaseAll: 'MB_RELEASE_ROLLOUT',
};

// ── Apps & brands ─────────────────────────────────────────────────

/** "NammaYatriPartner" → brand key "NammaYatri"; label "Namma Yatri". */
export const brandKey = (name: string) => name.replace(/(Partner|Driver)$/, '');
export const humanize = (s: string) => s.replace(/([a-z])([A-Z])/g, '$1 $2');
export const brandLabel = (name: string) => humanize(brandKey(name));
export const roleLabel = (surface: string) => (surface === 'driver' ? 'Driver' : 'Customer');
export const platLabel = (p: string) => (p === 'ios' ? 'iOS' : 'Android');
export const appName = (name: string, surface: string, platform: string) => `${brandLabel(name)} ${roleLabel(surface)} ${platLabel(platform)}`;

const BRAND_HUES = ['#2f3a36', '#2f8a4e', '#c08a17', '#c4453a', '#d26a2c', '#3a6fb8', '#7a4fb0', '#1f8f8a', '#9c5b2f', '#5b6b2f'];
export function brandColor(name: string): string {
  const k = brandKey(name);
  let h = 0;
  for (let i = 0; i < k.length; i++) h = (h * 31 + k.charCodeAt(i)) >>> 0;
  return BRAND_HUES[h % BRAND_HUES.length];
}

/** Customer before driver, Android before iOS — one stable order everywhere. */
export const appOrder = (surface: string, platform: string) => (surface === 'driver' ? 2 : 0) + (platform === 'ios' ? 1 : 0);

export function catalogFor(apps: AppCatalogEntry[] | undefined, name: string, surface: string, platform: string) {
  return apps?.find((a) => a.name === name && a.surface === surface && a.platform === platform);
}

/** A group's display name: its label, else "<version> · <date>". */
export function groupName(label: string | null | undefined, createdAt: string, version?: string | null): string {
  if (label) return label;
  return `${version || 'Release'} · ${new Date(createdAt).toLocaleDateString('en-IN', { day: 'numeric', month: 'short' })}`;
}
export const groupNameOf = (g: MobileGroupListItem) => groupName(g.label, g.createdAt, g.members.find((m) => m.version)?.version);

export const STAGE_COLOR: Record<Stage, string> = {
  failed: 'var(--m2-brick)', rejected: 'var(--m2-brick)', aborted: 'var(--m2-line2)', paused: 'var(--m2-ochre)',
  draft: 'var(--m2-line2)', building: 'var(--m2-line2)', ready: 'var(--m2-fg)', distributed: 'var(--m2-faint)',
  review: 'var(--m2-ochre)', approved: 'var(--m2-fg)', rolling: 'var(--m2-go)', live: 'var(--m2-faint)', superseded: 'var(--m2-line2)',
};
export const STAGE_ORDER: Stage[] = ['failed', 'rejected', 'paused', 'draft', 'building', 'ready', 'review', 'approved', 'rolling', 'distributed', 'live', 'superseded', 'aborted'];
