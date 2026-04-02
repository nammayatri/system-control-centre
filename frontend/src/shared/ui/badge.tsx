import { cn } from '../../lib/utils';
import type { ReleaseStatus } from '../../api';

interface BadgeProps {
  children: React.ReactNode;
  variant?: 'default' | 'success' | 'warning' | 'danger' | 'info' | 'muted' | 'purple' | 'blue';
  size?: 'sm' | 'md';
  dot?: boolean;
  className?: string;
}

const variantStyles: Record<string, string> = {
  default: 'bg-zinc-100 text-zinc-700 border-zinc-200',
  success: 'bg-emerald-50 text-emerald-800 border-emerald-300',
  warning: 'bg-amber-50 text-amber-800 border-amber-300',
  danger: 'bg-red-50 text-red-800 border-red-300',
  info: 'bg-sky-50 text-sky-800 border-sky-300',
  muted: 'bg-zinc-50 text-zinc-500 border-zinc-200',
  purple: 'bg-violet-50 text-violet-800 border-violet-300',
  blue: 'bg-blue-50 text-blue-800 border-blue-300',
};

const dotColors: Record<string, string> = {
  default: 'bg-zinc-400',
  success: 'bg-emerald-500',
  warning: 'bg-amber-500',
  danger: 'bg-red-500',
  info: 'bg-sky-500',
  muted: 'bg-zinc-400',
  purple: 'bg-violet-500',
  blue: 'bg-blue-500',
};

export function Badge({ children, variant = 'default', size = 'sm', dot, className }: BadgeProps) {
  return (
    <span
      className={cn(
        'inline-flex items-center gap-1.5 rounded-md border font-medium tracking-wide uppercase font-sans',
        size === 'sm' ? 'px-2 py-0.5 text-[11px]' : 'px-2.5 py-1 text-xs',
        variantStyles[variant],
        className
      )}
    >
      {dot && <span className={cn('w-1.5 h-1.5 rounded-full shrink-0', dotColors[variant])} />}
      {children}
    </span>
  );
}

export function statusVariant(status: ReleaseStatus | string): BadgeProps['variant'] {
  const upper = (status || '').toUpperCase().replace(/\s+/g, '_');
  switch (upper) {
    case 'COMPLETED': case 'APPLIED':
      return 'success';
    case 'INPROGRESS': case 'RESTARTING':
      return 'warning';
    case 'PAUSED':
      return 'info';
    case 'CREATED':
      return 'blue';
    case 'DISCARDED': case 'DISCARDING':
      return 'muted';
    case 'REVERTING': case 'REVERTED':
      return 'purple';
    case 'ABORTED': case 'USER_ABORTED': case 'USERABORTED': case 'ABORTING':
      return 'danger';
    case 'LOCKED':
      return 'warning';
    case 'UNLOCKED':
      return 'muted';
    default:
      return 'default';
  }
}

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
