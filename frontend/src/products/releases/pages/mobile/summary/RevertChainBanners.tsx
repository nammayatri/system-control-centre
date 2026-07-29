import type { CSSProperties } from 'react';
import { Link } from 'react-router-dom';
import { LinkIcon, WarningCircleIcon } from '@phosphor-icons/react';
import type { APRelease } from '../../../api';

/**
 * v4 revert-chain banners: violet = this row IS a revert of an earlier build;
 * amber = this row HAS BEEN reverted by a newer one. Renders nothing when the
 * release is not part of a revert chain.
 */
export function RevertChainBanners({ release }: { release: APRelease }) {
  const revertsTarget = release.revertsReleaseId || null;
  const revertedByTarget = release.metadata?.reverted_by || null;
  if (!revertsTarget && !revertedByTarget) return null;

  return (
    <div className="flex flex-col gap-2 mb-4 stagger-item" style={{ '--index': 0 } as CSSProperties}>
      {revertsTarget && (
        <div className="bg-violet-50/80 border border-violet-100 text-violet-800 py-2.5 px-4 rounded-lg text-sm flex items-center justify-between gap-3 flex-wrap">
          <div className="flex items-center gap-2 font-medium flex-wrap">
            <LinkIcon size={14} weight="bold" className="text-violet-500 shrink-0" aria-hidden="true" />
            This row explicitly reverts prior build{' '}
            <span className="font-mono bg-violet-100 px-1 py-0.5 rounded text-xs">
              {revertsTarget.slice(0, 8)}
            </span>
            {release.commitSha && (
              <span className="text-violet-600 text-xs">
                · built from commit <span className="font-mono">{release.commitSha.slice(0, 7)}</span>
              </span>
            )}
          </div>
          <Link
            to={`/mobile/releases/${revertsTarget}`}
            className="text-xs font-bold text-violet-700 hover:text-violet-900 shrink-0 cursor-pointer"
          >
            View origin
          </Link>
        </div>
      )}
      {revertedByTarget && (
        <div className="bg-amber-50/80 border border-amber-100 text-amber-800 py-2.5 px-4 rounded-lg text-sm flex items-center justify-between gap-3 flex-wrap">
          <div className="flex items-center gap-2 font-medium flex-wrap">
            <WarningCircleIcon size={14} weight="bold" className="text-amber-500 shrink-0" aria-hidden="true" />
            This release was subsequently reverted by{' '}
            <span className="font-mono bg-amber-100 px-1 py-0.5 rounded text-xs">
              {String(revertedByTarget).slice(0, 8)}
            </span>
          </div>
          <Link
            to={`/mobile/releases/${revertedByTarget}`}
            className="text-xs font-bold text-amber-700 hover:text-amber-900 shrink-0 cursor-pointer"
          >
            View revert
          </Link>
        </div>
      )}
    </div>
  );
}
