import { cn } from '../../../lib/utils';
import { formatRolloutPercent } from '../utils';

interface RolloutBarProps {
  pct: number;
  /** A rollout halted mid-ramp renders amber instead of indigo. */
  halted?: boolean;
  /** Show the trailing "NN%" label (default true). */
  showLabel?: boolean;
  className?: string;
}

/**
 * A staged-rollout progress bar. The fill is clamped to a 3% minimum so a tiny
 * live ramp is still visible, and to 100% max. Indigo while ramping, amber when
 * halted — the same accent the lifecycle badge uses, so the two always agree.
 */
export function RolloutBar({ pct, halted = false, showLabel = true, className }: RolloutBarProps) {
  const width = Math.max(3, Math.min(100, pct));
  return (
    <div className={cn('flex items-center gap-2', className)}>
      <div className="relative h-1.5 flex-1 overflow-hidden rounded-full bg-zinc-200">
        <div
          className={cn(
            'absolute inset-y-0 left-0 rounded-full transition-all duration-500',
            halted ? 'bg-amber-400' : 'bg-indigo-500',
          )}
          style={{ width: `${width}%` }}
        />
      </div>
      {showLabel && (
        <span
          className={cn(
            'shrink-0 font-mono text-xs font-semibold tabular-nums',
            halted ? 'text-amber-600' : 'text-indigo-600',
          )}
        >
          {formatRolloutPercent(pct)}%
        </span>
      )}
    </div>
  );
}
