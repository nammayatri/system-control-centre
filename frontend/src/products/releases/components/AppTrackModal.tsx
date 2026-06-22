import { useState } from 'react';
import { Apple, Cpu } from 'lucide-react';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogBody,
} from '../../../shared/ui/dialog';
import { Badge } from '../../../shared/ui/badge';
import { cn } from '../../../lib/utils';
import type { PlatformBlock, TrackCell } from '../api';
import { deriveStoreBadge, formatRolloutPercent, activeRolloutOf, type TrackKind } from './storeBadge';
import { RolloutBar } from './RolloutBar';

type PlatformName = 'android' | 'ios';

interface AppTrackModalProps {
  open: boolean;
  onClose: () => void;
  appLabel: string;
  /** "Consumer" | "Driver" — shown in the header subtitle. */
  surface?: string;
  platform: PlatformName;
  block: PlatformBlock;
}

type TabKey = 'production' | 'secondary';

// iOS's second tab is TestFlight, Android's is Internal Testing. The label +
// which TrackCell it reads from both key off the platform.
const secondaryLabel = (platform: PlatformName) =>
  platform === 'ios' ? 'TestFlight' : 'Internal Testing';

const secondaryCell = (platform: PlatformName, block: PlatformBlock): TrackCell | null =>
  platform === 'ios' ? block.testflight : block.internal;

function PlatformIcon({ platform }: { platform: PlatformName }) {
  return platform === 'ios'
    ? <Apple className="w-4 h-4 text-zinc-500" />
    : <Cpu className="w-4 h-4 text-emerald-600" />;
}

function TrackBody({ cell, track }: { cell: TrackCell | null; track: TrackKind }) {
  const badge = deriveStoreBadge(cell, track);
  const ar = activeRolloutOf(cell);

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
        <div>
          <div className="text-[10px] font-medium uppercase tracking-wider text-zinc-400">Version</div>
          <div className="font-mono text-sm text-zinc-900">
            {cell?.version ?? '—'}
            {cell?.buildCode != null && (
              <span className="text-zinc-400 ml-1">+{cell.buildCode}</span>
            )}
          </div>
        </div>
        <div>
          <div className="text-[10px] font-medium uppercase tracking-wider text-zinc-400">Status</div>
          <div className="mt-0.5">
            <Badge variant={badge.variant}>{badge.label}</Badge>
          </div>
        </div>
        <div>
          <div className="text-[10px] font-medium uppercase tracking-wider text-zinc-400">Rollout</div>
          <div className="font-mono text-sm text-zinc-900">
            {cell?.rolloutPercent != null ? `${formatRolloutPercent(cell.rolloutPercent)}%` : '—'}
          </div>
        </div>
      </div>

      {ar && (
        <div>
          <div className="mb-1.5 text-[10px] font-medium uppercase tracking-wider text-zinc-400">
            {ar.halted ? 'Rollout · halted' : 'Rollout progress'}
          </div>
          <RolloutBar pct={ar.pct} halted={ar.halted} />
        </div>
      )}

      <div>
        <div className="text-[10px] font-medium uppercase tracking-wider text-zinc-400 mb-1.5">
          Release notes
        </div>
        {cell?.releaseNotes ? (
          <div className="rounded-lg border border-zinc-200 bg-zinc-50 px-3 py-2.5 text-sm text-zinc-700 whitespace-pre-wrap leading-relaxed max-h-64 overflow-y-auto">
            {cell.releaseNotes}
          </div>
        ) : (
          <div className="rounded-lg border border-dashed border-zinc-200 px-3 py-2.5 text-sm text-zinc-400">
            No release notes
          </div>
        )}
      </div>
    </div>
  );
}

/**
 * Detail modal for one app's tracks on a single platform. Opens entirely
 * client-side from the already-loaded card object — it makes NO request. Tabs
 * switch between Production and the platform's secondary track (TestFlight on
 * iOS, Internal Testing on Android).
 */
export function AppTrackModal({ open, onClose, appLabel, surface, platform, block }: AppTrackModalProps) {
  const [tab, setTab] = useState<TabKey>('production');
  const cell = tab === 'production' ? block.production : secondaryCell(platform, block);
  const track: TrackKind = tab === 'production' ? 'production' : platform === 'ios' ? 'testflight' : 'internal';

  const tabs: { key: TabKey; label: string }[] = [
    { key: 'production', label: 'Production' },
    { key: 'secondary', label: secondaryLabel(platform) },
  ];

  return (
    <Dialog open={open} onOpenChange={(o) => { if (!o) onClose(); }}>
      <DialogContent size="lg">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <PlatformIcon platform={platform} />
            {appLabel}
          </DialogTitle>
          <div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-zinc-500">
            <span>{platform === 'ios' ? 'iOS' : 'Android'}</span>
            {surface && (
              <>
                <span className="text-zinc-300">·</span>
                <span>{surface}</span>
              </>
            )}
            {block.bundleId && (
              <>
                <span className="text-zinc-300">·</span>
                <span className="font-mono">{block.bundleId}</span>
              </>
            )}
          </div>
        </DialogHeader>

        <DialogBody>
          <div className="flex items-center gap-1.5 mb-4" role="tablist">
            {tabs.map((t) => (
              <button
                key={t.key}
                type="button"
                role="tab"
                aria-selected={tab === t.key}
                onClick={() => setTab(t.key)}
                className={cn(
                  'h-8 px-3 rounded-full text-xs font-medium border cursor-pointer transition-colors duration-150',
                  tab === t.key
                    ? 'bg-zinc-900 text-white border-zinc-900'
                    : 'bg-white text-zinc-600 border-zinc-300 hover:bg-zinc-50',
                )}
              >
                {t.label}
              </button>
            ))}
          </div>

          <TrackBody cell={cell} track={track} />
        </DialogBody>
      </DialogContent>
    </Dialog>
  );
}
