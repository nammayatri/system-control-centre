import { useMemo } from 'react';
import { FunnelSimpleIcon, XIcon } from '@phosphor-icons/react';
import type { APRelease } from '../api';
import { useAuth } from '../../../core/auth/AuthContext';
import { cn } from '../../../lib/utils';

/**
 * The pipeline tiles (v4: docs/design/mobile-releases-home-mockup-v1.html).
 * Counts EVERY mobile release row (SCC-built and store-synced alike), never
 * groups. Buckets come from the caller's `bucketOf` — GroupsHome passes its
 * storeBucket, the SAME function the status filter uses — so a tile's count
 * always equals the rows its click filters to. Click applies the filter,
 * click again clears it.
 */
const CARDS: {
  key: string;
  label: string;
  dot: string;
  pulse?: boolean;
  danger?: boolean;
  hint: string;
}[] = [
  {
    key: 'building',
    label: 'Building',
    dot: 'bg-amber-500',
    hint: 'Drafts and builds running on GitHub — not yet on a store track.',
  },
  {
    key: 'promote',
    label: 'Ready to promote',
    dot: 'bg-blue-500',
    hint: 'Built and held — waiting on you to promote to store review.',
  },
  {
    key: 'review',
    label: 'In review',
    dot: 'bg-violet-500',
    pulse: true,
    hint: 'Submitted and sitting in store review.',
  },
  {
    key: 'approved',
    label: 'Approved · held',
    dot: 'bg-emerald-400',
    hint: 'Passed review, held — waiting for you to release.',
  },
  {
    key: 'rollout',
    label: 'Rolling out',
    dot: 'bg-emerald-500',
    pulse: true,
    hint: 'Staged rollout in progress (or halted mid-rollout).',
  },
  {
    key: 'aborted',
    label: 'Failed',
    dot: 'bg-red-500',
    danger: true,
    hint: 'Ended without shipping: build failures, aborts and discards.',
  },
];

export function MobileBuildKpis({
  releases,
  bucketOf,
  active = '',
  onSelect,
}: {
  releases: APRelease[];
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

  // Debug deployments have no store lifecycle — the four store tiles are
  // permanently 0 there. Building + Failed are the real debug signals.
  const { buildType } = useAuth();
  const debugDeploy = buildType === 'debug';
  const cards = debugDeploy ? CARDS.filter((c) => c.key === 'building' || c.key === 'aborted') : CARDS;

  const clickable = !!onSelect;
  return (
    <section>
      <div
        className={cn(
          'grid gap-3',
          debugDeploy ? 'grid-cols-2 sm:max-w-md' : 'grid-cols-2 sm:grid-cols-3 xl:grid-cols-6',
        )}
      >
        {cards.map((c) => {
          const value = counts[c.key] ?? 0;
          const isActive = active === c.key;
          return (
            <button
              key={c.key}
              type="button"
              title={clickable ? `${c.hint}\nClick to filter the list.` : c.hint}
              onClick={onSelect ? () => onSelect(isActive ? '' : c.key) : undefined}
              disabled={!clickable}
              className={cn(
                'card-surface p-4 text-left relative group transition-all',
                clickable && 'cursor-pointer',
                isActive
                  ? 'shadow-[0_0_0_3px_rgba(124,58,237,0.15)]'
                  : clickable &&
                      'hover:-translate-y-px hover:shadow-[0_0_0_3px_rgba(124,58,237,0.08),0_4px_12px_-6px_rgba(0,0,0,0.12)]',
              )}
              style={{ borderColor: isActive ? '#7c3aed' : '#d4d4d8' }}
            >
              {clickable && !isActive && (
                <FunnelSimpleIcon
                  size={14}
                  weight="bold"
                  className={cn(
                    'absolute top-2.5 right-2.5 text-zinc-300 transition-colors',
                    c.danger ? 'group-hover:text-red-400' : 'group-hover:text-violet-500',
                  )}
                  aria-hidden="true"
                />
              )}
              {isActive && (
                <span className="absolute top-2 right-2 inline-flex items-center gap-1 bg-violet-600 text-white text-[9px] font-bold px-1.5 py-0.5 rounded-full">
                  filtering <XIcon size={9} weight="bold" aria-hidden="true" />
                </span>
              )}
              <span className={cn('eyebrow', c.danger && 'text-red-500')} style={c.danger ? { color: '#ef4444' } : undefined}>
                {c.label}
              </span>
              <div className="flex items-center gap-2 mt-1.5">
                <span
                  className={cn(
                    'w-2 h-2 rounded-full',
                    c.dot,
                    c.pulse && value > 0 && 'animate-pulse-slow motion-reduce:animate-none',
                  )}
                />
                <span className={cn('text-2xl font-bold font-mono', c.danger ? 'text-red-600' : 'text-zinc-900')}>
                  {value}
                </span>
              </div>
            </button>
          );
        })}
      </div>
      {clickable && (
        <p className="text-[10px] text-zinc-400 mt-1.5 px-1">
          Click a tile to filter the list below — click again to clear.
        </p>
      )}
    </section>
  );
}
