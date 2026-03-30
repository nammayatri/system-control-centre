import { cn } from '../../lib/utils';

export function Skeleton({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      className={cn('rounded-md skeleton-shimmer', className)}
      style={{ minHeight: '1rem' }}
      {...props}
    />
  );
}

export function TableSkeleton({ rows = 5, cols = 6 }: { rows?: number; cols?: number }) {
  return (
    <div className="space-y-2 p-4">
      <div className="flex gap-3">
        {Array.from({ length: cols }).map((_, i) => (
          <Skeleton key={i} className="h-3.5 flex-1 rounded" />
        ))}
      </div>
      {Array.from({ length: rows }).map((_, i) => (
        <div key={i} className="flex gap-3 animate-fadeInUp" style={{ animationDelay: `${i * 40}ms` }}>
          {Array.from({ length: cols }).map((_, j) => (
            <Skeleton key={j} className="h-9 flex-1 rounded" />
          ))}
        </div>
      ))}
    </div>
  );
}

export function CardSkeleton() {
  return (
    <div className="rounded-xl border border-zinc-200 bg-white p-5 space-y-3 animate-fadeInUp">
      <Skeleton className="h-3.5 w-1/3 rounded" />
      <Skeleton className="h-7 w-2/3 rounded" />
      <Skeleton className="h-3.5 w-1/2 rounded" />
    </div>
  );
}

export function KPISkeleton() {
  return (
    <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
      {Array.from({ length: 4 }).map((_, i) => (
        <div key={i} className="rounded-xl border border-zinc-200 bg-white p-4 animate-fadeInUp" style={{ animationDelay: `${i * 50}ms` }}>
          <Skeleton className="h-3 w-16 rounded mb-2" />
          <Skeleton className="h-7 w-12 rounded" />
        </div>
      ))}
    </div>
  );
}
