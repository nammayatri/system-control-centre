import { useMemo } from 'react';
import type { APRelease } from '../api';
import { cn } from '../../../lib/utils';

/**
 * The mobile-build KPI strip. Counts EVERY mobile release row (SCC-built and
 * store-synced alike), never groups. Buckets come from the caller's `bucketOf`
 * — GroupsHome passes its storeBucket, the SAME function the status filter
 * uses — so a card's count always equals the rows its click filters to.
 * Cards are buttons: click applies that status filter, click again (or Total)
 * clears it.
 */
const CARDS: { key: string; label: string; dot: string; hint: string }[] = [
  {
    key: 'building',
    label: 'Building',
    dot: 'bg-amber-500',
    hint: 'Drafts and builds running on GitHub — not yet on a store track.',
  },
  {
    key: 'promote',
    label: 'Ready to Promote',
    dot: 'bg-violet-500',
    hint: 'Built and held — waiting on you to promote to store review.',
  },
  {
    key: 'review',
    label: 'In Review',
    dot: 'bg-sky-500',
    hint: 'Submitted and sitting in store review.',
  },
  {
    key: 'approved',
    label: 'Approved · Held',
    dot: 'bg-emerald-500',
    hint: 'Passed review, held — waiting for you to release.',
  },
  {
    key: 'rollout',
    label: 'Rolling Out',
    dot: 'bg-blue-500',
    hint: 'Staged rollout in progress (or halted mid-rollout).',
  },
  {
    key: 'aborted',
    label: 'Failed',
    dot: 'bg-red-500',
    hint: 'Ended without shipping: build failures, aborts and discards.',
  },
];

export function MobileBuildKpis({
  releases,
  windowLabel,
  bucketOf,
  active = '',
  onSelect,
}: {
  releases: APRelease[];
  windowLabel?: string;
  // The SAME bucket fn the list's status filter uses (GroupsHome.storeBucket).
  bucketOf: (r: APRelease) => string;
  active?: string;
  onSelect?: (statusKey: string) => void;
}) {
  const counts = useMemo(() => {
    const c: Record<string, number> = {};
    for (const r of releases) {
      const b = bucketOf(r);
      c[b] = (c[b] ?? 0) + 1;
    }
    return c;
  }, [releases, bucketOf]);

  const clickable = !!onSelect;
  const card = (opts: {
    key: string;
    label: string;
    dot: string;
    hint: string;
    value: number;
    isActive: boolean;
    onClick?: () => void;
  }) => (
    <button
      key={opts.key}
      type="button"
      title={clickable ? `${opts.hint}\nClick to filter the list.` : opts.hint}
      onClick={opts.onClick}
      disabled={!clickable}
      className={cn(
        'bg-white border rounded-xl px-4 py-3 sm:px-5 sm:py-4 flex flex-col justify-between min-h-[72px] sm:min-h-[80px] text-left transition-colors',
        opts.isActive ? 'border-violet-400 ring-2 ring-violet-200' : 'border-zinc-200',
        clickable && !opts.isActive && 'hover:border-zinc-300 hover:bg-zinc-50/50 cursor-pointer',
      )}
    >
      <span className="text-[10px] sm:text-[11px] font-medium text-zinc-500 uppercase tracking-wider">
        {opts.label}
      </span>
      <div className="flex items-center gap-2 mt-1">
        <span className={cn('w-1.5 h-1.5 rounded-full', opts.dot)} />
        <span className="text-xl sm:text-2xl font-bold text-zinc-900">{opts.value}</span>
      </div>
    </button>
  );

  return (
    <div className="grid grid-cols-2 sm:grid-cols-3 xl:grid-cols-6 gap-3 sm:gap-4">
      {CARDS.map((c) =>
        card({
          ...c,
          value: counts[c.key] ?? 0,
          isActive: active === c.key,
          onClick: onSelect ? () => onSelect(active === c.key ? '' : c.key) : undefined,
        }),
      )}
    </div>
  );
}
