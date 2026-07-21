import { Badge } from '../../../shared/ui/badge';

type BadgeVariant = 'default' | 'success' | 'warning' | 'danger' | 'info' | 'muted';

export function otaStatusVariant(status: string | undefined): BadgeVariant {
  switch ((status || '').toUpperCase()) {
    case 'INPROGRESS': return 'info';
    case 'CONCLUDED': return 'success';
    case 'DISCARDED': return 'danger';
    case 'CREATED': return 'default';
    default: return 'muted';
  }
}

// Dark mode uses the airborne dashboard's outlined style: transparent fill,
// tinted border + text. Light mode keeps the shared Badge fills.
const darkStyles: Record<string, string> = {
  CONCLUDED: 'dark:bg-transparent dark:border-emerald-700 dark:text-emerald-300',
  INPROGRESS: 'dark:bg-transparent dark:border-blue-700 dark:text-blue-300',
  DISCARDED: 'dark:bg-transparent dark:border-red-700 dark:text-red-300',
  CREATED: 'dark:bg-transparent dark:border-zinc-600 dark:text-zinc-300',
};

const darkFallback = 'dark:bg-transparent dark:border-zinc-700 dark:text-zinc-400';

export function OtaStatusBadge({ status, size }: { status: string | undefined; size?: 'sm' | 'md' }) {
  const s = (status || '').toUpperCase();
  return (
    <Badge variant={otaStatusVariant(s)} size={size} dot className={darkStyles[s] ?? darkFallback}>
      {s || 'UNKNOWN'}
    </Badge>
  );
}
