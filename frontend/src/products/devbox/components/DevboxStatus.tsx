import { Check, X } from 'lucide-react';
import { Badge } from '../../../shared/ui/badge';
import { cn } from '../../../lib/utils';
import { STAGES, type DevboxEvent, type DevboxRelease, type DevboxStatus } from '../types';

const STATUS_LOOK: Record<DevboxStatus, { label: string; variant: 'success' | 'warning' | 'danger' | 'muted' | 'info' }> = {
  READY: { label: 'Running', variant: 'success' },
  RUNNING: { label: 'In progress', variant: 'warning' },
  QUEUED: { label: 'Queued', variant: 'info' },
  STOPPING: { label: 'Stopping', variant: 'warning' },
  FAILED: { label: 'Failed', variant: 'danger' },
  STOPPED: { label: 'Stopped', variant: 'muted' },
};

export function DevboxStatusBadge({ status }: { status: DevboxStatus }) {
  const look = STATUS_LOOK[status];
  return (
    <Badge variant={look.variant} dot>
      {look.label}
    </Badge>
  );
}

export function stageLabel(stage: string): string {
  return STAGES.find((s) => s.key === stage)?.label ?? (stage === 'stop' ? 'Stop' : stage);
}

type DotState = 'done' | 'now' | 'failed' | 'skipped' | 'todo';

/**
 * The stage bar: one dot per GitHub step of the devbox workflow. Done / skipped
 * come from the step events the poller recorded; the current stage pulses while
 * the run is going.
 */
export function StageBar({ release, events }: { release: DevboxRelease; events: DevboxEvent[] }) {
  const idx = STAGES.findIndex((s) => s.key === release.stage);
  const label = (stage: string) => {
    const evs = events.filter((e) => e.stage === stage);
    if (evs.some((e) => e.label === 'failed')) return 'failed';
    if (evs.some((e) => e.label === 'skipped')) return 'skipped';
    if (evs.some((e) => e.label === 'done')) return 'done';
    return null;
  };
  const stateOf = (i: number, key: string): DotState => {
    if (release.status === 'READY' || (release.status === 'STOPPED' && !release.error && release.readyAt)) return label(key) === 'skipped' ? 'skipped' : 'done';
    const l = label(key);
    if (l === 'failed' || (release.status === 'FAILED' && i === idx)) return 'failed';
    if (l === 'skipped') return 'skipped';
    if (l === 'done' || i < idx) return 'done';
    if (i === idx && (release.status === 'RUNNING' || release.status === 'QUEUED')) return 'now';
    return 'todo';
  };
  const ms = (stage: string) => {
    const e = events.find((x) => x.stage === stage && (x.label === 'done' || x.label === 'failed'));
    const v = e?.payload?.ms;
    if (typeof v !== 'number') return '';
    return v < 60_000 ? `${Math.max(1, Math.round(v / 1000))}s` : `${Math.round(v / 60_000)}m`;
  };
  return (
    <div className="flex items-start overflow-x-auto py-2">
      {STAGES.map((s, i) => {
        const st = stateOf(i, s.key);
        return (
          <div key={s.key} className="relative flex min-w-[88px] flex-1 flex-col items-center gap-1.5 text-center">
            {i > 0 && (
              <span
                className={cn(
                  'absolute left-[-50%] top-[13px] h-0.5 w-full',
                  st === 'todo' ? 'bg-zinc-200 dark:bg-zinc-700' : 'bg-emerald-500',
                )}
              />
            )}
            <span
              className={cn(
                'relative z-10 grid h-7 w-7 place-items-center rounded-full border-2 text-xs font-bold',
                st === 'done' && 'border-emerald-500 bg-emerald-500 text-white',
                st === 'now' && 'border-amber-500 bg-amber-50 text-amber-700 dark:bg-amber-950 dark:text-amber-300 animate-pulse',
                st === 'failed' && 'border-red-500 bg-red-500 text-white',
                st === 'skipped' && 'border-dashed border-zinc-300 text-zinc-400 dark:border-zinc-600',
                st === 'todo' && 'border-zinc-200 bg-zinc-50 text-zinc-400 dark:border-zinc-700 dark:bg-zinc-900',
              )}
            >
              {st === 'done' ? <Check className="h-3.5 w-3.5" /> : st === 'failed' ? <X className="h-3.5 w-3.5" /> : i + 1}
            </span>
            <span className="text-xs font-semibold text-zinc-800 dark:text-zinc-200">{s.label}</span>
            <span className="font-mono text-[11px] text-zinc-500">
              {s.key === 'data' ? `${release.dataSource} ${release.dataVersion ?? ''}`.trim() : st === 'skipped' ? 'skipped' : ms(s.key)}
            </span>
          </div>
        );
      })}
    </div>
  );
}
