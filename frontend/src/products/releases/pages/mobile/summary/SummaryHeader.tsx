import type { ReactNode } from 'react';
import { Link } from 'react-router-dom';
import {
  ArrowsClockwiseIcon,
  ArrowSquareOutIcon,
  ArrowUUpLeftIcon,
  CaretRightIcon,
  ChartBarIcon,
  FireIcon,
  GitBranchIcon,
  NetworkIcon,
  XCircleIcon,
} from '@phosphor-icons/react';
import { cn } from '../../../../../lib/utils';
import { BrandLogo } from '../../../components/BrandLogo';
import { versionWithBuild } from '../../../utils';
import type { APRelease, RolloutDetail } from '../../../api';
import type { AppCatalogEntry } from '../../../types';
import { SCENARIO_PILL, type Scenario } from './scenario';

const KIBANA_URL = import.meta.env.VITE_KIBANA_URL || '';
const KIALI_URL = import.meta.env.VITE_KIALI_URL || '';
const GRAFANA_URL = import.meta.env.VITE_GRAFANA_URL || '';

export interface SummaryHeaderProps {
  release: APRelease;
  scenario: Scenario;
  /** Canonical status text — store-derived when live, display_label/status otherwise. */
  statusLabel: string;
  rollout?: RolloutDetail;
  crashlyticsUrl: string;
  /** Catalog row for this app — its packageName gates the Crashlytics version suffix. */
  matchedApp?: AppCatalogEntry;
  /** Mutually-exclusive, state-gated action buttons (right-aligned). */
  actions: ReactNode;
  /** Store-cache freshness, from rdSyncedSecondsAgo (null = unknown). */
  syncedSecondsAgo?: number | null;
  onRefresh: () => void;
  refreshSpinning: boolean;
}

const syncedText = (s: number) =>
  s < 60 ? `synced ${Math.floor(s)}s ago` : s < 3600 ? `synced ${Math.floor(s / 60)}m ago` : `synced ${Math.floor(s / 3600)}h ago`;

/**
 * v4 header (docs/design/mobile-release-summary-mockup-v4.html): breadcrumb +
 * freshness row, then the identity row — logo, app · surface, big mono
 * version, scenario-colored status pill, divider-separated metadata chips,
 * actions right. Pure presentation.
 */
export function SummaryHeader({
  release,
  scenario,
  statusLabel,
  rollout,
  crashlyticsUrl,
  matchedApp,
  actions,
  syncedSecondsAgo,
  onRefresh,
  refreshSpinning,
}: SummaryHeaderProps) {
  const pill = SCENARIO_PILL[scenario];
  const track = rollout?.rdStoreTrack;
  const isRevert = release.release_context?.revert === 1 || !!release.revertsReleaseId;
  const isDebug = release.release_context?.build_type === 'debug';

  return (
    <div className="mb-4 sm:mb-5">
      {/* Breadcrumb & freshness */}
      <div className="flex items-center justify-between w-full mb-2 text-xs flex-wrap gap-y-1">
        <div className="flex items-center gap-2 font-medium text-zinc-500 shrink-0">
          <Link to="/mobile/releases" className="hover:text-zinc-900 transition-colors duration-150 cursor-pointer">
            Releases
          </Link>
          <CaretRightIcon size={10} aria-hidden="true" />
          <span>{release.env || ''}</span>
          <CaretRightIcon size={10} aria-hidden="true" />
          <span className="font-mono text-zinc-700 bg-zinc-100 px-1.5 py-0.5 rounded truncate max-w-[160px] sm:max-w-[240px]">
            {release.release_tag || release.id}
          </span>
        </div>
        <div className="flex items-center gap-2">
          {syncedSecondsAgo != null && <span className="text-zinc-400">{syncedText(syncedSecondsAgo)}</span>}
          <button
            onClick={onRefresh}
            className="text-zinc-500 hover:text-zinc-900 cursor-pointer p-1 -m-1 rounded focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-zinc-300"
            title="Refresh"
            aria-label="Refresh"
          >
            <ArrowsClockwiseIcon size={14} className={refreshSpinning ? 'animate-spin' : ''} aria-hidden="true" />
          </button>
        </div>
      </div>

      {/* Identity & status row */}
      <div className="flex flex-col md:flex-row md:items-center justify-between w-full gap-4">
        <div className="flex flex-wrap items-center gap-4">
          <BrandLogo
            brand={release.appGroup || ''}
            surface={release.service === 'driver' ? 'driver' : undefined}
            size="lg"
          />

          <div className="flex flex-col">
            <div className="flex items-center gap-2">
              <h1 className="text-lg font-bold leading-none tracking-tight text-zinc-900">
                {release.appGroup || 'Release'}
              </h1>
              {release.service && <span className="text-zinc-400 font-medium text-sm">· {release.service}</span>}
            </div>
            <div className="flex items-center gap-3 mt-1 flex-wrap">
              {versionWithBuild(release) && (
                <span className="font-mono text-xl font-bold tracking-tight text-zinc-900">
                  v{release.new_version}{' '}
                  {release.release_context?.version_code != null && (
                    <span className="text-zinc-400 font-medium">+{release.release_context.version_code}</span>
                  )}
                </span>
              )}
              {/* Canonical status pill — scenario colors, pulsing dot while in flight */}
              <span
                className={cn(
                  'inline-flex items-center gap-1.5 border px-2.5 py-0.5 rounded-full text-xs font-bold uppercase tracking-wider',
                  pill.box,
                )}
              >
                {scenario === 'failed' ? (
                  <XCircleIcon size={12} weight="bold" aria-hidden="true" />
                ) : pill.dot ? (
                  <span className={cn('w-2 h-2 rounded-full animate-pulse-slow motion-reduce:animate-none', pill.dot)} />
                ) : null}
                <span>{statusLabel}</span>
              </span>
            </div>
          </div>

          {/* Secondary track / metadata chips */}
          <div className="hidden lg:flex items-center gap-2 ml-4 border-l border-zinc-200 pl-4 h-8">
            {track === 'production' && (
              <span className="bg-green-100 text-green-800 text-[10px] font-bold px-2 py-0.5 rounded uppercase tracking-wide">
                Production
              </span>
            )}
            {track === 'testflight' && (
              <span className="bg-zinc-900 text-white text-[10px] font-bold px-2 py-0.5 rounded uppercase tracking-wide">
                TestFlight
              </span>
            )}
            {track === 'internal' && (
              <span className="bg-blue-100 text-blue-800 text-[10px] font-bold px-2 py-0.5 rounded uppercase tracking-wide">
                Internal
              </span>
            )}
            {isRevert && (
              <span className="bg-amber-100 text-amber-800 text-[10px] font-bold px-2 py-0.5 rounded uppercase tracking-wide flex items-center gap-1">
                <ArrowUUpLeftIcon size={11} weight="bold" aria-hidden="true" /> Revert
              </span>
            )}
            {isDebug && (
              <span className="bg-amber-100 text-amber-800 text-[10px] font-bold px-2 py-0.5 rounded uppercase tracking-wide">
                Debug
              </span>
            )}
            {release.sourceRef && (
              <span
                className="bg-zinc-100 text-zinc-600 font-mono text-[11px] px-2 py-0.5 rounded flex items-center gap-1"
                title={`Source branch: ${release.sourceRef}`}
              >
                <GitBranchIcon size={12} className="text-zinc-400" aria-hidden="true" /> {release.sourceRef}
              </span>
            )}
            {!isDebug && (
              <a
                href={crashlyticsUrl}
                target="_blank"
                rel="noopener noreferrer"
                className="bg-orange-50 text-orange-600 border border-orange-200 text-[11px] font-bold px-2 py-0.5 rounded flex items-center gap-1 hover:bg-orange-100 transition-colors cursor-pointer"
                title={
                  matchedApp?.packageName
                    ? `Crashlytics — ${versionWithBuild(release) || release.appGroup}`
                    : 'Crashlytics'
                }
              >
                <FireIcon weight="fill" size={12} aria-hidden="true" /> Crashlytics
                <ArrowSquareOutIcon size={11} className="opacity-70" aria-hidden="true" />
              </a>
            )}
            {KIBANA_URL && (
              <a href={KIBANA_URL} target="_blank" rel="noopener" className="text-[11px] text-zinc-500 border border-zinc-200 rounded px-2 py-0.5 hover:bg-zinc-50 inline-flex items-center gap-1">
                <ArrowSquareOutIcon size={11} aria-hidden="true" /> Logs
              </a>
            )}
            {KIALI_URL && (
              <a href={KIALI_URL} target="_blank" rel="noopener" className="text-[11px] text-zinc-500 border border-zinc-200 rounded px-2 py-0.5 hover:bg-zinc-50 inline-flex items-center gap-1">
                <NetworkIcon size={11} aria-hidden="true" /> Mesh
              </a>
            )}
            {GRAFANA_URL && (
              <a href={GRAFANA_URL} target="_blank" rel="noopener" className="text-[11px] text-zinc-500 border border-zinc-200 rounded px-2 py-0.5 hover:bg-zinc-50 inline-flex items-center gap-1">
                <ChartBarIcon size={11} aria-hidden="true" /> Metrics
              </a>
            )}
          </div>
        </div>

        {/* Header actions: mutually exclusive by state (page enforces) */}
        <div className="flex items-center gap-2 w-full md:w-auto shrink-0 mt-2 md:mt-0 flex-wrap md:justify-end">
          {actions}
        </div>
      </div>
    </div>
  );
}
