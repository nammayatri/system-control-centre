import { useEffect, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import {
  ArrowUpRightIcon,
  CircleNotchIcon,
  GitBranchIcon,
  GithubLogoIcon,
  SparkleIcon,
  TagIcon,
} from '@phosphor-icons/react';
import { fetchReleaseProvenance } from '../../../otaApi';
import { OtaBranchPicker } from '../../../components/ota/OtaPanel';
import type { APRelease, RolloutEvent } from '../../../api';
import type { AppCatalogEntry, LatestBuild } from '../../../types';
import { MobileChangelogAiSummary, useChangelogAiRange } from '../../../components/MobileChangelogAiSummary';
import { cn } from '../../../../../lib/utils';
import { formatBuildCode } from '../../../utils';
import { fullStamp, shortDate } from './dates';

/**
 * v4 info cards for the mobile release summary left column (docs/design/
 * mobile-release-summary-mockup-v4.html): ProvenanceCard, ChangelogCard and
 * WorkflowStagesCard. Purely presentational; every value is a real release
 * field — no invented data.
 */

// Workflow-stage events the mobile workflow is known to log; the filter is
// permissive (MB_/MOBILE_ prefixes) so new backend labels appear automatically.
const MOBILE_LABELS = new Set([
  'GH_DISPATCHED',
  'RUN_ID_RESOLVED',
  'MATRIX_JOB_UPDATED',
  'STORE_SUBMITTED',
  'TAG_PUSHED',
  'BUILD_STARTED',
  'BUILD_COMPLETED',
  'MOBILE_RELEASE_CREATED',
]);

export const stageEventsOf = (events: RolloutEvent[]) =>
  events
    .filter((e) => MOBILE_LABELS.has(e.label) || e.label?.startsWith('MB_') || e.label?.startsWith('MOBILE_'))
    .sort((a, b) => a.timestamp.localeCompare(b.timestamp));

// Workflow breadcrumbs live in either release_context or metadata depending on
// row vintage — read defensively from both (parity with the old page).
export const breadcrumbsOf = (release: APRelease) => {
  const ctx = (release.release_context ?? {}) as Record<string, any>;
  const meta = (release.metadata ?? {}) as Record<string, any>;
  return {
    ghRunUrl: (meta.github_run_url || meta.gh_run_url || meta.expected_run_url || ctx.github_run_url || ctx.expected_run_url) as string | undefined,
    // GitHub run id — the BE serializes external_run_id into release_context
    // once ResolveRunId binds the run; with the repo it yields the run URL.
    externalRunId: ctx.external_run_id as string | undefined,
    matrixJobStatus: (meta.matrix_job_status || ctx.matrix_job_status || ctx.mb_matrix_job_status) as string | undefined,
    tagPushed: (meta.tag_pushed || ctx.tag_pushed || ctx.mbc_tag_pushed) as string | undefined,
    githubRepo: (meta.github_repo || ctx.github_repo) as string | undefined,
  };
};

/** The GitHub Actions run URL for a release row, when resolvable. */
export const ghRunUrlOf = (release: APRelease, repo?: string): string | undefined => {
  const b = breadcrumbsOf(release);
  if (b.ghRunUrl) return b.ghRunUrl;
  const r = repo || b.githubRepo;
  return b.externalRunId && r ? `https://github.com/${r}/actions/runs/${b.externalRunId}` : undefined;
};

const FieldLabel = ({ children }: { children: React.ReactNode }) => (
  <span className="text-[11px] text-zinc-500 font-medium">{children}</span>
);


/** base → head chips for the AI summary eyebrow — reads the panel's cache. */
function AiRangeChips({ release, base = 'production', head }: { release: APRelease; base?: string; head?: string }) {
  const { baseRef, headRef, compareUrl } = useChangelogAiRange(
    release.appGroup,
    release.service,
    release.env,
    head ?? release.sourceRef ?? '',
    release.new_version ?? '',
    release.env === 'ios'
      ? ''
      : release.release_context?.version_code != null
        ? String(release.release_context.version_code)
        : '',
    base,
  );
  if (!baseRef) return null;
  return (
    <span className="inline-flex items-center gap-1.5 text-[10px] font-mono text-zinc-500 min-w-0">
      <span className="bg-white/80 border border-violet-100 rounded px-1.5 py-0.5 text-zinc-600 max-w-52 truncate" title={baseRef}>
        {baseRef}
      </span>
      <span className="text-zinc-400">→</span>
      <span className="bg-white/80 border border-violet-100 rounded px-1.5 py-0.5 text-zinc-600 max-w-40 truncate" title={headRef ?? undefined}>
        {headRef}
      </span>
      {compareUrl && (
        <a
          href={compareUrl}
          target="_blank"
          rel="noreferrer"
          title="Open this commit range on GitHub"
          className="font-sans font-bold text-violet-600 hover:underline cursor-pointer"
        >
          compare ↗
        </a>
      )}
    </span>
  );
}


// Track-aware latest-build chip (debug amber · production emerald · else blue).
function LatestBuildChip({ build, label }: { build: LatestBuild; label: string }) {
  const track = build.track ?? label;
  const cls =
    label === 'debug'
      ? 'bg-amber-50 border-amber-200 text-amber-800'
      : track === 'production'
        ? 'bg-emerald-50 border-emerald-200 text-emerald-800'
        : 'bg-blue-50 border-blue-200 text-blue-800';
  return (
    <span
      className={cn('border font-mono text-[10px] px-2 py-0.5 rounded', cls)}
      title={build.completedAt ? fullStamp(build.completedAt) : undefined}
    >
      {label === 'debug' ? 'debug' : (track ?? 'release')} · v{build.version}
      {build.versionCode != null && <span className="opacity-70"> {formatBuildCode(build.versionCode)}</span>}
      {build.completedAt && <span className="opacity-60 ml-1">{shortDate(build.completedAt)}</span>}
    </span>
  );
}

/* ── Build Identity & Provenance ─────────────────────────────────────── */

export function ProvenanceCard({
  release,
  events,
  matchedApp,
  index = 0,
}: {
  release: APRelease;
  events: RolloutEvent[];
  matchedApp?: AppCatalogEntry;
  index?: number;
}) {
  const { tagPushed, githubRepo: bcRepo } = breadcrumbsOf(release);
  const githubRepo = bcRepo || matchedApp?.githubRepo;
  const ghRunUrl = ghRunUrlOf(release, githubRepo);
  const qc = useQueryClient();
  const [branchPickerOpen, setBranchPickerOpen] = useState(false);
  // Missing commit (store-observed row): recover it from the build tag once —
  // the server NULL-only backfills the column, so this resolves at most once.
  const provQ = useQuery({
    queryKey: ['mobile-release-prov', release.id],
    queryFn: () => fetchReleaseProvenance(release.id),
    enabled: !release.commitSha,
    retry: false,
    staleTime: 5 * 60_000,
  });
  const sha = release.commitSha || provQ.data?.commitSha || undefined;
  const shaRecovering = !release.commitSha && provQ.isLoading;
  // Branch may be auto-resolved server-side (CI-run head_branch) in the same
  // round trip — show it live, no reload needed.
  const branch = release.sourceRef || provQ.data?.sourceRef || undefined;
  // The resolve NULL-only backfills commit_sha/source_ref onto the row —
  // refresh the release object so the whole page (OTA gate, header) updates.
  useEffect(() => {
    if (
      (provQ.data?.commitSha && !release.commitSha) ||
      (provQ.data?.sourceRef && !release.sourceRef)
    )
      void qc.invalidateQueries({ queryKey: ['release', release.id] });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [provQ.data]);
  const stage = stageEventsOf(events);
  const started = stage.find((e) => e.label === 'BUILD_STARTED')?.timestamp;
  const completed = stage.find((e) => e.label === 'BUILD_COMPLETED')?.timestamp;
  const builtMins =
    started && completed
      ? Math.max(1, Math.round((new Date(completed).getTime() - new Date(started).getTime()) / 60000))
      : null;
  const manager = release.release_manager || '-';
  const initials = manager
    .split(/[\s._@]+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0]?.toUpperCase())
    .join('');
  const approver = release.approved_by && release.approved_by !== manager ? release.approved_by : null;

  return (
    <div className="card-surface p-6 stagger-item" style={{ '--index': index } as React.CSSProperties}>
      <p className="eyebrow mb-4">Build Identity &amp; Provenance</p>
      <div className="grid grid-cols-1 md:grid-cols-2 gap-x-8 gap-y-6">
        <div className="flex flex-col gap-1">
          <FieldLabel>Source Baseline Commit</FieldLabel>
          <div className="flex items-center gap-2 text-sm font-mono text-zinc-800">
            <GithubLogoIcon size={16} weight="bold" aria-hidden="true" />
            {shaRecovering ? (
              <span className="flex items-center gap-1.5 text-zinc-400 text-xs font-sans">
                <CircleNotchIcon size={13} weight="bold" className="animate-spin" aria-hidden="true" />
                recovering from build tag…
              </span>
            ) : sha && githubRepo ? (
              <a
                href={`https://github.com/${githubRepo}/commit/${sha}`}
                target="_blank"
                rel="noopener"
                className="cursor-pointer hover:underline text-blue-600"
              >
                {sha.slice(0, 7)}
              </a>
            ) : (
              <span title={!sha ? 'Not recoverable from the tag ledger' : undefined}>
                {sha ? sha.slice(0, 7) : '-'}
              </span>
            )}
          </div>
        </div>
        <div className="flex flex-col gap-1">
          <FieldLabel>Workflow Run Entity</FieldLabel>
          {ghRunUrl ? (
            <a
              href={ghRunUrl}
              target="_blank"
              rel="noopener"
              className="flex items-center gap-2 text-sm text-blue-600 font-mono hover:underline cursor-pointer min-w-0"
            >
              <span className="truncate">#{ghRunUrl.split('/').filter(Boolean).pop()}</span>
              <ArrowUpRightIcon size={12} weight="bold" className="shrink-0" aria-hidden="true" />
            </a>
          ) : release.release_context?.display_phase === 'building' &&
            (release.release_context as Record<string, any>)?.dispatch_id ? (
            // SCC-dispatched, but GitHub hasn't listed the run yet (ResolveRunId
            // pending) — store-sync rows never get a run, so they keep the dash.
            <span className="flex items-center gap-1.5 text-xs text-zinc-400 font-sans">
              <CircleNotchIcon size={13} weight="bold" className="animate-spin" aria-hidden="true" />
              resolving run…
            </span>
          ) : (
            <span className="text-sm text-zinc-400 font-mono">-</span>
          )}
        </div>
        <div className="flex flex-col gap-1">
          <FieldLabel>Release Manager Operator</FieldLabel>
          <div className="flex items-center gap-2 text-sm text-zinc-800 min-w-0">
            <span className="w-5 h-5 rounded-full bg-zinc-200 flex items-center justify-center text-[10px] font-bold text-zinc-600 shrink-0">
              {initials || '?'}
            </span>
            <span className="truncate">{manager}</span>
            {approver && <span className="text-xs text-zinc-400 truncate">· approved by {approver}</span>}
          </div>
        </div>
        <div className="flex flex-col gap-1">
          <FieldLabel>Timeline Execution</FieldLabel>
          <div className="flex items-center gap-2 text-sm text-zinc-800 font-mono">
            {release.date_created ? (
              <span title={fullStamp(release.date_created)}>Created {shortDate(release.date_created)}</span>
            ) : (
              '-'
            )}
            {builtMins != null && ` · Built ${builtMins}m`}
          </div>
        </div>
        <div className="flex flex-col gap-1">
          <FieldLabel>Source Branch</FieldLabel>
          <div className="flex items-center gap-2 text-sm font-mono text-zinc-800 min-w-0">
            <GitBranchIcon size={14} className="text-zinc-400 shrink-0" aria-hidden="true" />
            {branch ? (
              <span className="truncate">{branch}</span>
            ) : shaRecovering ? (
              <span className="flex items-center gap-1.5 text-zinc-400 text-xs font-sans">
                <CircleNotchIcon size={13} weight="bold" className="animate-spin" aria-hidden="true" />
                resolving from CI run…
              </span>
            ) : (
              <button
                type="button"
                onClick={() => setBranchPickerOpen(true)}
                className="text-blue-600 hover:underline cursor-pointer text-xs font-sans font-medium"
              >
                pick branch{sha ? '' : ' (commit unknown)'}
              </button>
            )}
          </div>
        </div>
        <div className="flex flex-col gap-1">
          <FieldLabel>Pushed Tag</FieldLabel>
          {tagPushed ? (
            <a
              href={githubRepo ? `https://github.com/${githubRepo}/releases/tag/${encodeURIComponent(tagPushed)}` : undefined}
              target="_blank"
              rel="noopener"
              className={cn(
                'flex items-center gap-2 text-sm font-mono min-w-0',
                githubRepo ? 'text-blue-600 hover:underline cursor-pointer' : 'text-zinc-800',
              )}
            >
              <TagIcon size={14} className="text-zinc-400 shrink-0" aria-hidden="true" />
              <span className="truncate">{tagPushed}</span>
              {githubRepo && <ArrowUpRightIcon size={12} weight="bold" className="shrink-0" aria-hidden="true" />}
            </a>
          ) : (
            <span className="text-sm text-zinc-400 font-mono">-</span>
          )}
        </div>
      </div>
      {matchedApp && (matchedApp.latestReleaseBuild || matchedApp.latestDebugBuild) && (
        <div className="mt-5 pt-4 border-t border-zinc-100 flex items-center gap-2 flex-wrap">
          <span className="eyebrow">Latest builds</span>
          {matchedApp.latestReleaseBuild && (
            <LatestBuildChip build={matchedApp.latestReleaseBuild} label="release" />
          )}
          {matchedApp.latestDebugBuild && (
            <LatestBuildChip build={matchedApp.latestDebugBuild} label="debug" />
          )}
        </div>
      )}
      {branchPickerOpen && (
        <OtaBranchPicker
          releaseId={release.id}
          onClose={() => setBranchPickerOpen(false)}
          onAdopted={() => {
            void qc.invalidateQueries({ queryKey: ['release', release.id] });
            void qc.invalidateQueries({ queryKey: ['mobile-release-prov', release.id] });
          }}
        />
      )}
    </div>
  );
}

/* ── Changelog · auto-generated from PRs ─────────────────────────────── */

const TAG_CHIP: Record<string, string> = {
  fix: 'bg-emerald-100 text-emerald-700',
  feat: 'bg-blue-100 text-blue-700',
  perf: 'bg-violet-100 text-violet-700',
  chore: 'bg-zinc-100 text-zinc-600',
  refactor: 'bg-zinc-100 text-zinc-600',
  docs: 'bg-zinc-100 text-zinc-600',
};

export function ChangelogCard({ release, index = 0 }: { release: APRelease; index?: number }) {
  const raw: string | undefined =
    release.change_log || (release.release_context as Record<string, any> | undefined)?.change_log;
  const lines = (raw ?? '')
    .split('\n')
    .map((l) => l.replace(/^[-*•\s]+/, '').trim())
    .filter(Boolean);
  // Store-observed rows have no meaningful branch range — their changelog is
  // previous-build-tag → this-build-tag from the ledger (both real commits).
  // No previous tag resolvable → no AI summary at all (never a wrong range).
  const storeSync = release.mode === 'STORE_SYNC' || release.release_manager === 'store-sync';
  const thisTag = breadcrumbsOf(release).tagPushed;
  const prevQ = useQuery({
    queryKey: ['mobile-release-prov', release.id],
    queryFn: () => fetchReleaseProvenance(release.id),
    enabled: storeSync && !!thisTag,
    retry: false,
    staleTime: 5 * 60_000,
  });
  const prevTag = prevQ.data?.previousTag;
  const aiRange = storeSync
    ? prevTag && thisTag
      ? { base: `ref:${prevTag}`, head: thisTag }
      : null
    : release.sourceRef
      ? { base: 'production', head: release.sourceRef }
      : null;
  if (lines.length === 0 && !aiRange && !(storeSync && thisTag && prevQ.isLoading)) return null;

  return (
    <div className="card-surface p-6 stagger-item" style={{ '--index': index } as React.CSSProperties}>
      <p className="eyebrow mb-4">Changelog &middot; Auto-generated from PRs</p>
      {lines.length > 0 ? (
        <ul className="flex flex-col gap-2.5">
          {lines.map((line, i) => {
            const tag = /^(fix|feat|perf|chore|refactor|docs)\b/i.exec(line)?.[1]?.toLowerCase();
            return (
              <li key={i} className="flex gap-2 items-start">
                {tag ? (
                  <span
                    className={cn(
                      'text-[9px] font-bold px-1.5 py-0.5 rounded uppercase mt-0.5 shrink-0',
                      TAG_CHIP[tag] ?? 'bg-zinc-100 text-zinc-600',
                    )}
                  >
                    {tag}
                  </span>
                ) : (
                  <span className="w-1.5 h-1.5 rounded-full bg-zinc-300 mt-1.5 shrink-0" aria-hidden="true" />
                )}
                <span className="text-zinc-700 font-mono text-xs leading-relaxed wrap-break-word min-w-0">{line}</span>
              </li>
            );
          })}
        </ul>
      ) : (
        <p className="text-xs text-zinc-400">No changelog recorded for this build.</p>
      )}

      {storeSync && thisTag && prevQ.isLoading && (
        <div className="mt-4 flex items-center gap-2 text-xs text-zinc-400">
          <CircleNotchIcon size={13} weight="bold" className="animate-spin" aria-hidden="true" />
          resolving previous build for changelog…
        </div>
      )}
      {aiRange && (
        <div className="mt-4 bg-violet-50/60 border border-violet-100 rounded-lg p-3">
          <div className="flex items-center justify-between gap-2 flex-wrap">
            <span className="text-[9px] font-bold uppercase tracking-wider text-violet-600 flex items-center gap-1">
              <SparkleIcon size={10} weight="fill" aria-hidden="true" /> AI summary
            </span>
            <AiRangeChips release={release} base={aiRange.base} head={aiRange.head} />
          </div>
          <div className="mt-1">
            {/* versionCode mirrors the create-time AI-summary cache key: iOS is
                keyed with '' (workflow assigns the code); Android uses the code. */}
            <MobileChangelogAiSummary
              app={release.appGroup}
              surface={release.service}
              platform={release.env}
              branch={aiRange.head}
              base={aiRange.base}
              versionName={release.new_version}
              versionCode={
                release.env === 'ios'
                  ? ''
                  : release.release_context?.version_code != null
                    ? String(release.release_context.version_code)
                    : ''
              }
              defaultCollapsed
            />
          </div>
        </div>
      )}
    </div>
  );
}
