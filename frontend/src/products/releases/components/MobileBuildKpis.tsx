import { useMemo } from 'react';
import type { APRelease } from '../api';
import { cn } from '../../../lib/utils';

/**
 * The shared mobile-build KPI strip — identical on the group home and the
 * full-history page so the numbers can never disagree between the two.
 *
 * Counts EVERY mobile release row (SCC-built and store-synced alike), never
 * groups. "Released" = status COMPLETED, which for mobile means the build
 * reached the store / went live (the live-gate holds builds INPROGRESS until
 * then).
 */
export function MobileBuildKpis({
  releases,
  windowLabel,
}: {
  releases: APRelease[];
  windowLabel?: string;
}) {
  const kpis = useMemo(() => {
    return {
      total: releases.length,
      active: releases.filter((r) => ['INPROGRESS', 'RESTARTING'].includes(r.status)).length,
      released: releases.filter((r) => r.status === 'COMPLETED').length,
      failed: releases.filter((r) =>
        ['ABORTED', 'USER_ABORTED', 'GCLT_ABORTED'].includes(r.status),
      ).length,
    };
  }, [releases]);

  const cards = [
    { label: `Total Builds${windowLabel ? ` (${windowLabel})` : ''}`, value: kpis.total, dot: 'bg-zinc-400' },
    { label: 'Active', value: kpis.active, dot: 'bg-amber-500' },
    { label: 'Released', value: kpis.released, dot: 'bg-emerald-500' },
    { label: 'Failed', value: kpis.failed, dot: 'bg-red-500' },
  ];

  return (
    <div className="grid grid-cols-2 md:grid-cols-4 gap-3 sm:gap-4">
      {cards.map((kpi) => (
        <div
          key={kpi.label}
          className="bg-white border border-zinc-200 rounded-xl px-4 py-3 sm:px-5 sm:py-4 flex flex-col justify-between min-h-[72px] sm:min-h-[80px]"
        >
          <span className="text-[10px] sm:text-[11px] font-medium text-zinc-500 uppercase tracking-wider">
            {kpi.label}
          </span>
          <div className="flex items-center gap-2 mt-1">
            <span className={cn('w-1.5 h-1.5 rounded-full', kpi.dot)} />
            <span className="text-xl sm:text-2xl font-bold text-zinc-900">{kpi.value}</span>
          </div>
        </div>
      ))}
    </div>
  );
}
