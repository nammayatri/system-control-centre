import { cn } from '../../lib/utils';

interface BadgeProps {
  children: React.ReactNode;
  variant?: 'default' | 'success' | 'warning' | 'danger' | 'info' | 'muted' | 'purple' | 'blue';
  size?: 'sm' | 'md';
  dot?: boolean;
  solid?: boolean;
  className?: string;
}

const subtleStyles: Record<string, string> = {
  default: 'bg-zinc-100 text-zinc-700 border-zinc-200',
  success: 'bg-emerald-50 text-emerald-800 border-emerald-200',
  warning: 'bg-amber-50 text-amber-800 border-amber-200',
  danger: 'bg-red-50 text-red-800 border-red-200',
  info: 'bg-sky-50 text-sky-800 border-sky-200',
  muted: 'bg-zinc-50 text-zinc-500 border-zinc-200',
  purple: 'bg-violet-50 text-violet-800 border-violet-200',
  blue: 'bg-blue-50 text-blue-800 border-blue-200',
};

const solidStyles: Record<string, string> = {
  default: 'bg-zinc-700 text-white border-zinc-700',
  success: 'bg-green-700 text-white border-green-700',
  warning: 'bg-amber-700 text-white border-amber-700',
  danger: 'bg-red-700 text-white border-red-700',
  info: 'bg-sky-700 text-white border-sky-700',
  muted: 'bg-zinc-500 text-white border-zinc-500',
  purple: 'bg-violet-700 text-white border-violet-700',
  blue: 'bg-blue-700 text-white border-blue-700',
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

export function Badge({ children, variant = 'default', size = 'sm', dot, solid, className }: BadgeProps) {
  const styles = solid ? solidStyles[variant] : subtleStyles[variant];
  return (
    <span
      className={cn(
        'inline-flex items-center gap-1.5 rounded-md border font-medium tracking-wide uppercase font-sans whitespace-nowrap',
        size === 'sm' ? 'px-2 py-0.5 text-[10px] sm:text-[11px]' : 'px-2.5 py-1 text-[11px] sm:text-xs',
        styles,
        className
      )}
    >
      {dot && <span className={cn('w-1.5 h-1.5 rounded-full shrink-0', dotColors[variant])} />}
      {children}
    </span>
  );
}
