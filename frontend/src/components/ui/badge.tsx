import { cn } from '../../lib/utils';
import type { ReleaseStatus } from '../../api';

interface BadgeProps {
  children: React.ReactNode;
  variant?: 'default' | 'success' | 'warning' | 'danger' | 'info' | 'muted' | 'purple';
  size?: 'sm' | 'md';
  dot?: boolean;
  className?: string;
}

const variantStyles: Record<string, string> = {
  default: 'bg-zinc-100 text-zinc-700 border-zinc-200',
  success: 'bg-emerald-50 text-emerald-700 border-emerald-200',
  warning: 'bg-amber-50 text-amber-700 border-amber-200',
  danger: 'bg-red-50 text-red-700 border-red-200',
  info: 'bg-sky-50 text-sky-700 border-sky-200',
  muted: 'bg-zinc-50 text-zinc-500 border-zinc-200',
  purple: 'bg-violet-50 text-violet-700 border-violet-200',
};

const dotColors: Record<string, string> = {
  default: 'bg-zinc-400',
  success: 'bg-emerald-500',
  warning: 'bg-amber-500',
  danger: 'bg-red-500',
  info: 'bg-sky-500',
  muted: 'bg-zinc-400',
  purple: 'bg-violet-500',
};

export function Badge({ children, variant = 'default', size = 'sm', dot, className }: BadgeProps) {
  return (
    <span
      className={cn(
        'inline-flex items-center gap-1.5 rounded-md border font-medium tracking-wide uppercase',
        size === 'sm' ? 'px-2 py-0.5 text-[10px]' : 'px-2.5 py-1 text-xs',
        variantStyles[variant],
        className
      )}
    >
      {dot && <span className={cn('w-1.5 h-1.5 rounded-full', dotColors[variant])} />}
      {children}
    </span>
  );
}

export function statusVariant(status: ReleaseStatus | string): BadgeProps['variant'] {
  switch (status) {
    case 'COMPLETED':
    case 'RECORDED':
      return 'success';
    case 'INPROGRESS':
    case 'RECORDING':
    case 'RESTARTING':
      return 'warning';
    case 'PAUSED':
      return 'info';
    case 'CREATED':
      return 'info';
    case 'DISCARDED':
    case 'DISCARDING':
      return 'muted';
    case 'REVERTING':
    case 'REVERTED':
    case 'VS_APPLIED':
      return 'purple';
    case 'ABORTED':
    case 'USER_ABORTED':
    case 'GCLT_ABORTED':
    case 'ABORTING':
      return 'danger';
    default:
      return 'default';
  }
}

export function StatusBadge({ status }: { status: ReleaseStatus | string }) {
  return (
    <Badge variant={statusVariant(status)} dot size="sm">
      {status.replace(/_/g, ' ')}
    </Badge>
  );
}
