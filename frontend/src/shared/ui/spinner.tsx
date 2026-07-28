import { cn } from '../../lib/utils';

/**
 * Round indeterminate spinner — the standard inline loading affordance for a
 * region whose data is still being fetched (use it IN PLACE of the content,
 * never as a global overlay). Pass `label` for a short "Loading …" text next
 * to the circle; screen readers get it via role="status" either way.
 */
export function Spinner({
  size = 'md',
  label,
  className,
}: {
  size?: 'sm' | 'md';
  /** Optional text shown beside the circle (e.g. "Loading packages…"). */
  label?: string;
  className?: string;
}) {
  const circle = (
    <span
      aria-hidden
      className={cn(
        'inline-block shrink-0 animate-spin rounded-full border-zinc-300 border-t-violet-600',
        size === 'sm' ? 'h-3 w-3 border-2' : 'h-4 w-4 border-2',
      )}
    />
  );
  return (
    <span
      role="status"
      aria-label={label ?? 'Loading'}
      className={cn('inline-flex items-center gap-2 text-xs text-zinc-600', className)}
    >
      {circle}
      {label}
    </span>
  );
}
