import type { APRelease } from '../api';
import { cn } from '../../../lib/utils';
import { XIcon } from '@phosphor-icons/react';
import { isFirebaseInternal, FirebaseInternalBadge } from './FirebaseBadge';

// Canonical status in the mockup pill language. Mirrors ReleaseStatusBadge's
// derivation EXACTLY — terminal truth beats a stale wf phase, so an aborted
// build reads "Failed"/"User aborted", never a leftover "Building".
const V4_PILL: Record<string, string> = {
  success: 'bg-emerald-50 border-emerald-200 text-emerald-700',
  warning: 'bg-amber-50 border-amber-200 text-amber-700',
  danger: 'bg-red-50 border-red-200 text-red-700',
  info: 'bg-sky-50 border-sky-200 text-sky-700',
  purple: 'bg-violet-50 border-violet-200 text-violet-700',
  blue: 'bg-blue-50 border-blue-200 text-blue-700',
  default: 'bg-zinc-100 border-zinc-200 text-zinc-500',
};
const V4_DOT: Record<string, string> = {
  success: 'bg-emerald-500',
  warning: 'bg-amber-500',
  info: 'bg-sky-500',
  purple: 'bg-violet-500',
  blue: 'bg-blue-500',
};
const RAW_STATUS_VARIANT: Record<string, string> = {
  CREATED: 'default',
  INPROGRESS: 'warning',
  COMPLETED: 'success',
  PAUSED: 'warning',
  ABORTED: 'danger',
  USER_ABORTED: 'danger',
  GCLT_ABORTED: 'danger',
  ABORTING: 'danger',
  DISCARDED: 'default',
  DISCARDING: 'default',
  REVERTED: 'purple',
  REVERTING: 'purple',
  RESTARTING: 'warning',
};
export function mobileDisplayOf(release: APRelease, suppressPromote = false): { label: string; variant: string } {
  const ctx = release.release_context;
  const phase = ctx?.display_phase;
  // Terminal truth FIRST — a dead row still carries its stale phase (an aborted
  // promote keeps display_phase 'internal_held'), and must never read from it.
  if (release.status === 'USER_ABORTED') return { label: 'User aborted', variant: 'danger' };
  if (release.status === 'ABORTED' && phase !== 'rejected') return { label: 'Failed', variant: 'danger' };
  const promotable = phase === 'internal_held' && !isFirebaseInternal(release);
  if (promotable && (suppressPromote || ctx?.promotable === false)) return { label: 'Superseded', variant: 'default' };
  const override =
    release.status === 'INPROGRESS' ||
    ['rolling_out', 'halted', 'superseded', 'live', 'rejected', 'aborted', 'build_failed'].includes(phase ?? '') ||
    promotable;
  const keepRaw = release.status === 'REVERTED';
  if (override && phase && !keepRaw && ctx?.display_label && ctx?.display_variant)
    return { label: ctx.display_label, variant: ctx.display_variant };
  if (phase === 'building' && release.status === 'INPROGRESS') return { label: 'Building', variant: 'warning' };
  const raw = release.status.charAt(0) + release.status.slice(1).toLowerCase().replace(/_/g, ' ');
  return { label: raw, variant: RAW_STATUS_VARIANT[release.status] ?? 'default' };
}
export function V4StatusPill({ release, suppressPromote = false }: { release: APRelease; suppressPromote?: boolean }) {
  const { label, variant } = mobileDisplayOf(release, suppressPromote);
  const phase = release.release_context?.display_phase ?? '';
  const pulse =
    variant !== 'danger' && (['building', 'in_review', 'rolling_out'].includes(phase) || release.status === 'INPROGRESS');
  const dot = V4_DOT[variant];
  return (
    <>
      {isFirebaseInternal(release) && <FirebaseInternalBadge />}
      <span
        className={cn(
          'inline-flex items-center gap-1.5 text-[10px] font-bold uppercase rounded-full border px-2 py-0.5',
          V4_PILL[variant] ?? V4_PILL.default,
        )}
      >
        {variant === 'danger' ? (
          <XIcon size={10} weight="bold" aria-hidden="true" />
        ) : dot && pulse ? (
          <span className={cn('w-1.5 h-1.5 rounded-full animate-pulse motion-reduce:animate-none', dot)} />
        ) : phase === 'internal_held' && dot ? (
          <span className={cn('w-1.5 h-1.5 rounded-full', dot)} />
        ) : null}
        {label}
      </span>
    </>
  );
}

