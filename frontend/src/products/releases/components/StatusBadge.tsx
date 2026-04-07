import type { ReleaseStatus } from '../api';

// Solid pill colors matching production autopilot.
// Semantic mapping: green (success), amber/orange (in-progress/warning),
// blue (info/created), violet (revert), red (danger), zinc (terminal-neutral).
const statusPillColor: Record<string, string> = {
  COMPLETED: 'bg-green-700 text-white',
  APPLIED: 'bg-green-700 text-white',
  RECORDED: 'bg-green-700 text-white',
  INPROGRESS: 'bg-amber-700 text-white',
  RECORDING: 'bg-amber-700 text-white',
  PAUSED: 'bg-amber-700 text-white',
  RESTARTING: 'bg-amber-700 text-white',
  CREATED: 'bg-blue-700 text-white',
  LOCKED: 'bg-amber-700 text-white',
  DISCARDED: 'bg-zinc-500 text-white',
  DISCARDING: 'bg-zinc-500 text-white',
  UNLOCKED: 'bg-zinc-500 text-white',
  REVERTING: 'bg-violet-700 text-white',
  REVERTED: 'bg-violet-700 text-white',
  ABORTED: 'bg-red-700 text-white',
  USER_ABORTED: 'bg-red-700 text-white',
  USERABORTED: 'bg-red-700 text-white',
  ABORTING: 'bg-red-700 text-white',
  // Legacy statuses from production (backward compat)
  GCLT_ABORTED: 'bg-red-700 text-white',
  VS_APPLIED: 'bg-amber-700 text-white',
};

export function StatusBadge({ status }: { status: ReleaseStatus | string }) {
  const upper = (status || '').toUpperCase().replace(/\s+/g, '_');
  const displayStatus = (status || '').replace(/_/g, ' ');
  const color = statusPillColor[upper] || 'bg-zinc-500 text-white';
  return (
    <span
      className={`inline-flex items-center rounded px-2 py-0.5 sm:px-2.5 sm:py-1 text-[10px] sm:text-[11px] font-bold uppercase tracking-wide whitespace-nowrap ${color}`}
    >
      {displayStatus}
    </span>
  );
}
