import type { ReleaseStatus } from '../api';

// Solid pill colors matching production autopilot
const statusPillColor: Record<string, string> = {
  COMPLETED: 'bg-green-800 text-white',
  APPLIED: 'bg-green-800 text-white',
  RECORDED: 'bg-green-800 text-white',
  INPROGRESS: 'bg-orange-700 text-white',
  RECORDING: 'bg-orange-700 text-white',
  PAUSED: 'bg-orange-700 text-white',
  RESTARTING: 'bg-orange-700 text-white',
  CREATED: 'bg-blue-700 text-white',
  LOCKED: 'bg-amber-600 text-white',
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
  VS_APPLIED: 'bg-orange-700 text-white',
};

export function StatusBadge({ status }: { status: ReleaseStatus | string }) {
  const upper = (status || '').toUpperCase().replace(/\s+/g, '_');
  const displayStatus = (status || '').replace(/_/g, ' ');
  const color = statusPillColor[upper] || 'bg-zinc-500 text-white';
  return (
    <span className={`inline-flex items-center rounded px-2.5 py-1 text-[11px] font-bold uppercase tracking-wide ${color}`}>
      {displayStatus}
    </span>
  );
}
