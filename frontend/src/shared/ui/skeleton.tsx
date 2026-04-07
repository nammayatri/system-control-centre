import { cn } from '../../lib/utils';

export function Skeleton({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      className={cn('rounded-md bg-zinc-100 animate-pulse', className)}
      style={{ minHeight: '0.75rem' }}
      {...props}
    />
  );
}

export function TableSkeleton({ rows = 5, cols = 6 }: { rows?: number; cols?: number }) {
  return (
    <div className="space-y-2 p-4">
      <div className="hidden md:flex gap-3">
        {Array.from({ length: cols }).map((_, i) => (
          <Skeleton key={i} className="h-3.5 flex-1" />
        ))}
      </div>
      {Array.from({ length: rows }).map((_, i) => (
        <div key={i} className="hidden md:flex gap-3">
          {Array.from({ length: cols }).map((_, j) => (
            <Skeleton key={j} className="h-9 flex-1" />
          ))}
        </div>
      ))}
      {/* Mobile skeleton: stacked cards */}
      <div className="md:hidden space-y-2">
        {Array.from({ length: rows }).map((_, i) => (
          <div key={i} className="rounded-xl border border-zinc-200 bg-white p-4 space-y-2">
            <Skeleton className="h-4 w-1/2" />
            <Skeleton className="h-3 w-3/4" />
            <Skeleton className="h-3 w-2/3" />
          </div>
        ))}
      </div>
    </div>
  );
}

export function CardSkeleton() {
  return (
    <div className="rounded-xl border border-zinc-200 bg-white p-4 sm:p-5 space-y-3">
      <Skeleton className="h-3.5 w-1/3" />
      <Skeleton className="h-7 w-2/3" />
      <Skeleton className="h-3.5 w-1/2" />
    </div>
  );
}

export function KPISkeleton() {
  return (
    <div className="grid grid-cols-2 sm:grid-cols-2 md:grid-cols-4 gap-3 sm:gap-4">
      {Array.from({ length: 4 }).map((_, i) => (
        <div key={i} className="rounded-xl border border-zinc-200 bg-white p-4">
          <Skeleton className="h-3 w-16 mb-2" />
          <Skeleton className="h-7 w-12" />
        </div>
      ))}
    </div>
  );
}
