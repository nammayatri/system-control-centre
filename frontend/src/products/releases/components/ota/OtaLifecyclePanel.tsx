// Group-page OTA details expansion — the mockup's per-state lifecycle panels
// (docs/design/release-group-detail-mockup-v1.html): building → package ready →
// release created → live → failed, each with real data and real verbs. State
// derives from the row's push + release truth; nothing is invented.
import { useMemo, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Link } from 'react-router-dom';
import {
  ArrowClockwiseIcon,
  ArrowSquareOutIcon,
  CaretRightIcon,
  ChartBarIcon,
  CheckCircleIcon,
  CircleNotchIcon,
  FlagIcon,
  LockOpenIcon,
  PackageIcon,
  RocketLaunchIcon,
  TerminalWindowIcon,
  WarningCircleIcon,
  XCircleIcon,
} from '@phosphor-icons/react';
import { cn } from '../../../../lib/utils';
import { useConfirm } from '../../../../shared/ui/confirm-dialog';
import { AdoptionCard } from '../chime/AdoptionCard';
import { useMobileApps } from '../../hooks';
import {
  concludeOtaRelease,
  discardOtaRelease,
  rampOtaRelease,
} from '../../../airborne-ota/api';
import type { OtaRelease } from '../../../airborne-ota/types';
import { cancelOtaPush, type OtaPushRow } from '../../otaApi';
import type { OtaProvPkg } from '../../otaApi';
import {
  dimsOf,
  errMsg,
  pkgTagOf,
  pkgVersionOf,
  ProvenanceBadge,
  ReleaseId,
  statusOf,
  trafficOf,
  type ReleasablePkg,
} from './OtaPanel';
import { JobMatrix, TargetChips } from '../../pages/mobile/summary/OtaFlow';
import { fullStamp, shortDate } from '../../pages/mobile/summary/dates';

export interface OtaLifecyclePanelProps {
  /** Release state still on its first fetch — show a loader, not a wrong state. */
  loading?: boolean;
  /** Reason the native build's state blocks CREATING pushes/releases
   *  (draft/building/discarded/failed). Operate verbs stay live. */
  releaseBlocked?: string | null;
  groupId: string;
  appName: string;
  airborneAppRef: string;
  /** All group pushes for this (app, platform), newest first. */
  pushes: OtaPushRow[];
  /** Ongoing releases proven to be this build's. */
  ongoing: OtaRelease[];
  foreignOngoing: OtaRelease[];
  /** Full release list for the ref (history outcomes per package). */
  releases: OtaRelease[];
  eligiblePkgs: ReleasablePkg[];
  /** Full git-ledger verdicts for the shelf (ahead-by counts etc.). */
  prov?: OtaProvPkg[];
  /** Shelf packages NOT from this build — surfaced, never hidden. */
  foreignPkgCount?: number;
  perms: string[];
  canDispatch: boolean;
  nativeVersion: string | null;
  /** Open the composer for a package (Release / New release / Release again). */
  onRelease: (pkg: ReleasablePkg) => void;
  /** Open the composer in edit mode for a CREATED release. */
  onEdit: (release: OtaRelease, pkg: ReleasablePkg) => void;
  /** Re-dispatch a bundle push for this app (toolbar bump/runner settings). */
  onRetryPush: () => void;
  onChanged: () => void;
}

const eyebrowCls = 'text-[10px] uppercase tracking-widest font-bold text-zinc-500';

// The sole experiment variant a conclude/revert would pick — null = ambiguous.
const concludeVariant = (r: OtaRelease, revert: boolean): string | null => {
  const variants = r.experiment?.experiment_variants;
  const chosen = revert ? variants?.control : variants?.experimentals?.[0];
  if (!chosen) return null;
  if (!revert && (variants?.experimentals?.length ?? 0) > 1) return null;
  return chosen;
};

const runIdOf = (p: OtaPushRow): string =>
  p.externalRunId != null ? `#${p.externalRunId}` : (p.runUrl?.split('/').filter(Boolean).pop() ?? '');

export function OtaLifecyclePanel(props: OtaLifecyclePanelProps) {
  const {
    loading = false,
    releaseBlocked = null,
    groupId,
    airborneAppRef: ref,
    pushes,
    ongoing,
    foreignOngoing,
    releases,
    eligiblePkgs,
    prov = [],
    foreignPkgCount = 0,
    perms,
    canDispatch,
    onRelease,
    onEdit,
    onRetryPush,
    onChanged,
  } = props;
  const confirm = useConfirm();
  const { data: mobileApps = [] } = useMobileApps();
  const catalogRow = useMemo(() => mobileApps.find((a) => a.airborneAppRef === ref) ?? null, [mobileApps, ref]);
  const catalogPkg = catalogRow?.packageName ?? null;
  const can = (p: string) => perms.includes(p);
  const [busy, setBusy] = useState<string | null>(null);
  const [rampPct, setRampPct] = useState('');

  const latestPush = pushes[0];
  const livePush = latestPush && ['DISPATCHED', 'RUNNING'].includes(latestPush.status) ? latestPush : null;
  const created = ongoing.find((r) => statusOf(r) === 'CREATED');
  const live = ongoing.find((r) => statusOf(r) === 'INPROGRESS');
  const readyPkg = eligiblePkgs[0];

  const state = livePush
    ? 'building'
    : live
      ? 'live'
      : created
        ? 'created'
        : latestPush?.status === 'FAILED'
          ? 'failed'
          : readyPkg
            ? 'ready'
            : 'idle';

  const run = async (label: string, fn: () => Promise<unknown>) => {
    setBusy(label);
    try {
      await fn();
      toast.success(label);
      onChanged();
    } catch (e) {
      toast.error(errMsg(e, `${label} failed`));
    } finally {
      setBusy(null);
    }
  };

  const doRamp = (r: OtaRelease) => {
    const n = Number(rampPct);
    if (!Number.isFinite(n) || n < 0 || n > 50) {
      toast.error('Traffic must be 0–50 (100% only via Conclude)');
      return;
    }
    void run(`Ramped to ${n}%`, () =>
      rampOtaRelease(ref, r.id!, {
        trafficPercentage: n,
        changeReason: `via SCC mobile release ${groupId}`,
        expectedTrafficPercentage: trafficOf(r),
      }),
    );
  };

  const doConclude = async (r: OtaRelease, revert: boolean) => {
    const chosen = concludeVariant(r, revert);
    if (!chosen) {
      toast.error('Variant ambiguous — use the Airborne product page for this release');
      return;
    }
    const verb = revert ? 'Revert' : 'Conclude';
    const consequence = revert
      ? `The ramped cohort returns to the previous stable bundle. Target: release ${r.id} (pkg v${pkgVersionOf(r) ?? '?'}, ${trafficOf(r) ?? 0}% → stable)`
      : `This ships the bundle to 100% of matching devices. Target: release ${r.id} (pkg v${pkgVersionOf(r) ?? '?'}, ${trafficOf(r) ?? 0}% → 100%)`;
    if (!(await confirm({ title: `${verb} this release?`, description: consequence, variant: revert ? 'danger' : 'primary' })))
      return;
    void run(`${verb} done`, () =>
      concludeOtaRelease(ref, r.id!, { chosenVariant: chosen, changeReason: `${verb} via SCC mobile release ${groupId}` }),
    );
  };

  const doDiscard = async (r: OtaRelease) => {
    if (
      !(await confirm({
        title: 'Discard this release?',
        description: `It was never ramped — no device is affected. Target: release ${r.id} (pkg v${pkgVersionOf(r) ?? '?'}).`,
        variant: 'danger',
      }))
    )
      return;
    void run('Release discarded', () => discardOtaRelease(ref, r.id!));
  };

  const doCancelPush = async (p: OtaPushRow) => {
    if (
      !(await confirm({
        title: 'Cancel this push?',
        description: 'Cancels the GitHub CI run (best-effort) and marks the push failed, unblocking new OTA dispatches.',
        variant: 'danger',
      }))
    )
      return;
    void run('Push cancelled', () => cancelOtaPush(p.id));
  };

  // Latest release outcome for a package version — history badge truth.
  const pkgOutcome = (v: number): { label: string; cls: string } => {
    const rels = releases
      .filter((r) => pkgVersionOf(r) === v)
      .sort((a, b) => (b.created_at || '').localeCompare(a.created_at || ''));
    if (rels.length === 0) return { label: 'unreleased', cls: 'bg-zinc-100 border-zinc-200 text-zinc-500' };
    const st = statusOf(rels[0]);
    if (st === 'INPROGRESS')
      return { label: `${rels.length} release${rels.length > 1 ? 's' : ''} · live ${trafficOf(rels[0]) ?? 0}%`, cls: 'bg-emerald-50 border-emerald-200 text-emerald-700' };
    if (st === 'CONCLUDED')
      return { label: `${rels.length} release${rels.length > 1 ? 's' : ''} · concluded 100%`, cls: 'bg-emerald-50 border-emerald-200 text-emerald-700' };
    if (st === 'DISCARDED')
      return { label: `${rels.length} release${rels.length > 1 ? 's' : ''} · discarded`, cls: 'bg-red-50 border-red-200 text-red-600' };
    return { label: `${rels.length} release${rels.length > 1 ? 's' : ''} · ${st.toLowerCase()}`, cls: 'bg-sky-50 border-sky-200 text-sky-700' };
  };


  // Every release cut from a package — id chip, state, date. The truthful
  // "what did we actually release from this package" answer.
  const PkgReleases = ({ version }: { version: number }) => {
    const rels = releases
      .filter((r) => pkgVersionOf(r) === version)
      .sort((a, b) => (b.created_at || '').localeCompare(a.created_at || ''));
    if (rels.length === 0) return null;
    return (
      <div className="flex flex-col gap-1.5 mt-1.5 pl-3 border-l-2 border-zinc-100">
        {rels.map((rel) => {
          const st = statusOf(rel);
          return (
            <div key={rel.id} className="flex items-center gap-2 text-[10px] flex-wrap">
              <span
                className={cn(
                  'px-1.5 py-px rounded text-[8px] font-bold uppercase',
                  st === 'INPROGRESS'
                    ? 'bg-emerald-100 text-emerald-800'
                    : st === 'CONCLUDED'
                      ? 'bg-emerald-100 text-emerald-800'
                      : st === 'DISCARDED'
                        ? 'bg-zinc-100 text-zinc-600'
                        : 'bg-sky-100 text-sky-800',
                )}
              >
                {st === 'INPROGRESS' ? `Live ${trafficOf(rel) ?? 0}%` : st}
              </span>
              {rel.id && <ReleaseId id={rel.id} />}
              {rel.id && (
                <Link
                  to={`/airborne/${encodeURIComponent(ref)}/releases/${encodeURIComponent(rel.id)}`}
                  className="text-violet-600 hover:text-violet-900 cursor-pointer"
                  title="Open release in Airborne"
                >
                  <ArrowSquareOutIcon size={11} aria-hidden="true" />
                </Link>
              )}
              <TargetChips dims={dimsOf(rel)} />
              {rel.created_at && (
                <span className="font-mono text-zinc-400 ml-auto" title={fullStamp(rel.created_at)}>
                  {shortDate(rel.created_at)}
                </span>
              )}
            </div>
          );
        })}
      </div>
    );
  };

  const provFor = (v?: number): OtaProvPkg | undefined =>
    v == null
      ? undefined
      : (prov.find((x) => x.packageVersion === v) ??
        (() => {
          const rel = eligiblePkgs.find((pk) => pk.version === v)?.relation;
          return rel ? { packageVersion: v, relation: rel } : undefined;
        })());

  const bornFrom = (pkg: ReleasablePkg): OtaPushRow | undefined =>
    pushes.find((p) => p.id === pkg.pushId) ?? pushes.find((p) => p.packageVersion === pkg.version);

  if (loading) {
    return (
      <div className="flex items-center justify-center gap-2 py-8 text-[11px] text-zinc-500 font-medium">
        <CircleNotchIcon size={16} weight="bold" className="animate-spin text-violet-500" aria-hidden="true" />
        Loading release state…
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-3">
      {busy != null && (
        <div className="flex items-center gap-2 text-[11px] text-violet-600 font-medium">
          <CircleNotchIcon size={14} weight="bold" className="animate-spin" aria-hidden="true" /> Working…
        </div>
      )}
      {/* Foreign traffic warning — never hidden while devices are on it. */}
      {foreignOngoing.some((r) => statusOf(r) === 'INPROGRESS') && (
        <div className="flex items-center gap-2 rounded border border-amber-200 bg-amber-50/60 px-3 py-2 text-[11px] text-amber-800">
          <WarningCircleIcon size={14} weight="fill" className="text-amber-500 shrink-0" aria-hidden="true" />
          <span>
            <b>Foreign releases active.</b>{' '}
            {foreignOngoing.filter((r) => statusOf(r) === 'INPROGRESS').length} stray OTA release
            {foreignOngoing.filter((r) => statusOf(r) === 'INPROGRESS').length > 1 ? 's are' : ' is'} currently serving
            traffic from outside this build&apos;s lineage. Operate with care.
          </span>
          <Link
            to={`/airborne/${encodeURIComponent(ref)}`}
            className="ml-auto shrink-0 font-bold text-amber-700 hover:underline cursor-pointer"
          >
            Airborne ↗
          </Link>
        </div>
      )}

      {/* ═ BUILDING — bundle compiling in CI ═ */}
      {state === 'building' && livePush && (
        <div className="grid grid-cols-1 lg:grid-cols-12 gap-4 items-stretch">
          <div className="lg:col-span-7 bg-sky-50 rounded-lg border border-sky-200 p-4 relative overflow-hidden">
            <div className="absolute left-0 top-0 bottom-0 w-1 bg-sky-400" />
            <div className="flex justify-between items-center mb-3 ml-2">
              <span className="text-xs font-bold text-sky-800 font-mono">
                {livePush.finalVersion ?? `${livePush.requestedBump} push`}{' '}
                <span className="animate-pulse motion-reduce:animate-none">●</span>
              </span>
              <span className="flex items-center gap-2">
                {livePush.runUrl && (
                  <a href={livePush.runUrl} target="_blank" rel="noreferrer" className="text-[10px] text-sky-700 font-bold hover:underline cursor-pointer">
                    CI run ↗
                  </a>
                )}
                {canDispatch && (
                  <button
                    onClick={() => void doCancelPush(livePush)}
                    disabled={busy != null}
                    className="text-[10px] bg-sky-100 text-sky-800 px-1.5 py-0.5 rounded font-bold hover:bg-sky-200 cursor-pointer disabled:opacity-50"
                  >
                    Cancel
                  </button>
                )}
              </span>
            </div>
            {livePush.externalRunId == null ? (
              <div className="ml-2 flex items-center gap-2 text-[10px] text-zinc-500 font-medium">
                <CircleNotchIcon size={16} weight="bold" className="animate-spin text-zinc-400" aria-hidden="true" />
                ◌ Locating CI run… stages appear once the run is found (~30–60s after dispatch)
              </div>
            ) : (
              <JobMatrix pushId={livePush.id} live />
            )}
            <p className="ml-2 mt-3 text-[10px] text-sky-700 font-medium">
              Creates a new package when it lands — the push queue stays locked until then.
            </p>
          </div>
          <div className="lg:col-span-5 bg-white rounded-lg border border-zinc-200 p-4 flex flex-col gap-3">
            <span className={eyebrowCls}>How a bundle ships</span>
            <div className="flex items-center justify-between text-[9px] font-bold uppercase tracking-wide">
              <span className="flex flex-col items-center gap-1 text-sky-700">
                <span className="w-6 h-6 rounded-full bg-white border-[3px] border-sky-500 flex items-center justify-center"><span className="w-1.5 h-1.5 rounded-full bg-sky-500" /></span>
                Push
              </span>
              <span className="flex-1 h-px bg-zinc-200 mx-1" />
              <span className="flex flex-col items-center gap-1 text-zinc-400"><span className="w-6 h-6 rounded-full bg-zinc-100 border border-zinc-200" />Package</span>
              <span className="flex-1 h-px bg-zinc-200 mx-1" />
              <span className="flex flex-col items-center gap-1 text-zinc-400"><span className="w-6 h-6 rounded-full bg-zinc-100 border border-zinc-200" />Release</span>
              <span className="flex-1 h-px bg-zinc-200 mx-1" />
              <span className="flex flex-col items-center gap-1 text-zinc-400"><span className="w-6 h-6 rounded-full bg-zinc-100 border border-zinc-200" />Ramp</span>
              <span className="flex-1 h-px bg-zinc-200 mx-1" />
              <span className="flex flex-col items-center gap-1 text-zinc-400"><span className="w-6 h-6 rounded-full bg-zinc-100 border border-zinc-200" />Conclude</span>
            </div>
            {pushes.length > 1 && (
              <div className="mt-auto pt-3 border-t border-zinc-100">
                <span className={eyebrowCls}>Recent pushes</span>
                <div className="flex flex-col gap-1.5 mt-2 text-[10px]">
                  {pushes.slice(1, 3).map((p) => (
                    <div key={p.id} className="flex items-center gap-2">
                      <span className={cn('px-1 py-0.5 rounded font-bold uppercase text-[8px]', p.status === 'FAILED' ? 'bg-red-100 text-red-800' : 'bg-emerald-100 text-emerald-800')}>
                        {p.status === 'BUNDLE_PUSHED' ? 'Pushed' : p.status}
                      </span>
                      <span className="font-mono text-zinc-700 truncate">
                        {p.finalVersion ?? p.requestedBump}
                        {p.packageVersion != null ? ` · pkg v${p.packageVersion}` : ''}
                      </span>
                      <span className="text-zinc-400 ml-auto font-mono" title={fullStamp(p.dispatchedAt)}>{shortDate(p.dispatchedAt)}</span>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </div>
        </div>
      )}

      {/* ═ PACKAGE READY — nothing released yet ═ */}
      {state === 'ready' && readyPkg && (
        <div className="grid grid-cols-1 lg:grid-cols-12 gap-4 items-stretch">
          <div className="lg:col-span-7 bg-white rounded-lg border border-zinc-200 border-l-4 border-l-emerald-400 p-4 flex flex-col gap-3">
            <div className="flex items-center justify-between">
              <span className="text-[10px] font-bold uppercase tracking-widest text-emerald-600 flex items-center gap-1">
                <PackageIcon size={12} weight="fill" aria-hidden="true" /> Package ready · nothing released yet
              </span>
              <Link to={`/airborne/${encodeURIComponent(ref)}`} className="text-[10px] text-violet-600 hover:text-violet-900 font-bold cursor-pointer">
                Airborne ↗
              </Link>
            </div>
            <div className="flex items-center gap-3 flex-wrap">
              <span className="font-mono text-lg font-bold text-zinc-900">
                pkg v{readyPkg.version}
                {readyPkg.tag && <span className="text-zinc-400 font-medium text-sm"> · {readyPkg.tag}</span>}
              </span>
              <ProvenanceBadge prov={provFor(readyPkg.version)} push={bornFrom(readyPkg)} />
              {bornFrom(readyPkg) && (
                <span className="text-[10px] font-mono text-zinc-400" title={fullStamp(bornFrom(readyPkg)!.dispatchedAt)}>
                  born from run {runIdOf(bornFrom(readyPkg)!)}
                  {bornFrom(readyPkg)!.commitSha ? ` · commit ${bornFrom(readyPkg)!.commitSha!.slice(0, 7)}` : ''} ·{' '}
                  {shortDate(bornFrom(readyPkg)!.dispatchedAt)}
                </span>
              )}
            </div>
            {/* Package lineage rail — oldest → newest, current pinned */}
            {eligiblePkgs.length > 1 && (
              <div className="flex items-center gap-2 text-[10px] font-mono mt-1 flex-wrap">
                {[...eligiblePkgs.slice(1, 3)].reverse().map((pk) => {
                  const o = pkgOutcome(pk.version);
                  return (
                    <span key={pk.version} className="contents">
                      <span className={cn('flex items-center gap-1.5 border rounded px-2 py-1', o.cls)} title={o.label}>
                        v{pk.version}{' '}
                        <span className="text-[8px] uppercase font-sans font-bold opacity-80">{o.label.split('·').pop()?.trim()}</span>
                      </span>
                      <CaretRightIcon size={10} weight="bold" className="text-zinc-300" aria-hidden="true" />
                    </span>
                  );
                })}
                <span className="flex items-center gap-1.5 border-2 border-emerald-400 bg-emerald-50 rounded px-2 py-1 font-bold text-emerald-800 shadow-sm">
                  <span className="w-1.5 h-1.5 rounded-full bg-emerald-500 animate-pulse motion-reduce:animate-none" /> v{readyPkg.version}{' '}
                  <span className="text-[8px] uppercase font-sans font-bold">ready</span>
                </span>
              </div>
            )}
            <div className="flex items-center gap-2 mt-auto pt-2">
              <button
                onClick={() => onRelease(readyPkg)}
                disabled={!can('OTA_RELEASE_CREATE') || !!releaseBlocked}
                title={releaseBlocked ? `OTA release blocked — ${releaseBlocked}` : can('OTA_RELEASE_CREATE') ? undefined : 'Requires OTA_RELEASE_CREATE'}
                className="bg-violet-600 text-white px-4 py-2 text-[11px] font-bold rounded-lg shadow-sm hover:bg-violet-700 flex items-center gap-1.5 cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
              >
                <RocketLaunchIcon size={13} weight="fill" aria-hidden="true" /> Release…
              </button>
              {releaseBlocked ? (
                <span className="text-[10px] font-semibold text-red-500">blocked — {releaseBlocked}</span>
              ) : (
                <span className="text-[10px] text-zinc-400">opens the composer — pick targeting &amp; initial traffic (max 50%)</span>
              )}
            </div>
          </div>
          <div className="lg:col-span-5 bg-white rounded-lg border border-zinc-200 p-4 flex flex-col gap-2">
            <span className={eyebrowCls}>Package history · this build</span>
            <div className="flex flex-col divide-y divide-zinc-50 text-[10px]">
              {eligiblePkgs.slice(1, 5).map((pk) => {
                const o = pkgOutcome(pk.version);
                const born = bornFrom(pk);
                return (
                  <div key={pk.version} className="py-2">
                    <div className="flex items-center gap-2">
                    <span className="font-mono font-bold text-zinc-700">pkg v{pk.version}</span>
                    {pk.tag && <span className="font-mono text-zinc-400">{pk.tag}</span>}
                    <span className={cn('border px-1.5 py-px rounded text-[8px] font-bold uppercase', o.cls)}>{o.label}</span>
                    {born && (
                      <span className="font-mono text-zinc-400 ml-auto" title={fullStamp(born.dispatchedAt)}>{shortDate(born.dispatchedAt)}</span>
                    )}
                    <button
                      onClick={() => onRelease(pk)}
                      disabled={!can('OTA_RELEASE_CREATE') || !!releaseBlocked}
                      title={releaseBlocked ? `OTA release blocked — ${releaseBlocked}` : undefined}
                      className={cn('text-zinc-500 font-bold hover:text-zinc-900 cursor-pointer disabled:opacity-40', !born && 'ml-auto')}
                    >
                      New release
                    </button>
                    </div>
                    <PkgReleases version={pk.version} />
                  </div>
                );
              })}
              {eligiblePkgs.length === 1 && (
                <p className="py-2 text-zinc-400">No older packages from this build.</p>
              )}
            </div>
            <Link
              to={`/airborne/${encodeURIComponent(ref)}`}
              className="mt-auto text-center text-[10px] font-medium text-zinc-500 bg-zinc-100 hover:bg-zinc-200 rounded py-1.5 transition-colors cursor-pointer"
              title="Packages from other builds/branches — this build's page can't vouch for their lineage"
            >
              {foreignPkgCount > 0
                ? `Not from this build: ${foreignPkgCount} package${foreignPkgCount > 1 ? 's' : ''} · View in Airborne ↗`
                : 'View all packages in Airborne ↗'}
            </Link>
          </div>
        </div>
      )}

      {/* ═ RELEASE CREATED — targeting locked, not ramped ═ */}
      {state === 'created' && created && (
        <div className="grid grid-cols-1 lg:grid-cols-12 gap-4 items-stretch">
          <div className="lg:col-span-7 bg-white rounded-lg border border-zinc-200 border-l-4 border-l-sky-400 p-4 flex flex-col gap-3">
            <div className="flex items-center justify-between">
              <span className="text-[10px] font-bold uppercase tracking-widest text-sky-600 flex items-center gap-1">
                <FlagIcon size={12} weight="bold" aria-hidden="true" /> Release created · not ramped
              </span>
              {created.id && <ReleaseId id={created.id} />}
            </div>
            <div className="grid grid-cols-2 gap-3 font-mono text-xs">
              <div>
                <span className="block text-[10px] text-zinc-400 font-sans font-medium">Identity</span>
                <span className="font-bold text-violet-700">
                  pkg v{pkgVersionOf(created) ?? '?'}
                  {pkgTagOf(created) ? ` · ${pkgTagOf(created)}` : ''}
                </span>
              </div>
              <div>
                <span className="block text-[10px] text-zinc-400 font-sans font-medium mb-0.5">
                  Targeting <span className="normal-case">(locked at create)</span>
                </span>
                <span className="flex gap-1 flex-wrap">
                  <TargetChips dims={dimsOf(created)} />
                </span>
              </div>
            </div>
            <p className="text-[10px] text-zinc-500">Nothing serves yet — devices stay on stable until you ramp.</p>
            <div className="flex items-center gap-2 mt-auto pt-1 flex-wrap">
              <span className="flex items-center gap-1.5 bg-zinc-100 border border-zinc-200 rounded p-1.5">
                <input
                  type="number"
                  min={0}
                  max={50}
                  placeholder="%"
                  value={rampPct}
                  onChange={(e) => setRampPct(e.target.value)}
                  aria-label="Ramp percentage"
                  className="w-12 h-6 text-xs text-center border border-zinc-300 rounded font-mono outline-none bg-white"
                />
                <button
                  onClick={() => doRamp(created)}
                  disabled={!can('OTA_RELEASE_RAMP') || busy != null || !!releaseBlocked}
                  title={releaseBlocked ? `Ramping blocked — ${releaseBlocked}; discard is the way out` : undefined}
                  className="bg-violet-600 text-white font-bold text-[10px] px-2.5 py-1 rounded hover:bg-violet-700 cursor-pointer disabled:opacity-50"
                >
                  Ramp
                </button>
              </span>
              <button
                onClick={() =>
                  onEdit(created, { version: pkgVersionOf(created) ?? 0, tag: pkgTagOf(created) })
                }
                disabled={!can('OTA_RELEASE_CREATE') || !!releaseBlocked}
                title={releaseBlocked ? `Editing blocked — ${releaseBlocked}` : undefined}
                className="bg-white border border-zinc-200 text-zinc-700 px-3 py-1.5 text-[10px] font-bold rounded hover:bg-zinc-50 cursor-pointer disabled:opacity-50"
              >
                Edit
              </button>
              <button
                onClick={() => void doDiscard(created)}
                disabled={!can('OTA_RELEASE_DISCARD') || busy != null}
                className="bg-white border border-red-200 text-red-600 px-3 py-1.5 text-[10px] font-bold rounded hover:bg-red-50 cursor-pointer disabled:opacity-50"
              >
                Discard
              </button>
            </div>
            {releaseBlocked && (
              <p className="text-[10px] font-semibold text-red-500 mt-1.5">
                ramp/edit blocked — {releaseBlocked}; only Discard (or operating older releases) is available
              </p>
            )}
          </div>
          <div className="lg:col-span-5 bg-white rounded-lg border border-zinc-200 p-4 flex flex-col gap-2.5">
            <span className={eyebrowCls}>Before you ramp</span>
            <div className="flex flex-col gap-1.5 text-[10px]">
              {(() => {
                const rel = eligiblePkgs.find((pk) => pk.version === pkgVersionOf(created))?.relation;
                return rel === 'identical' || rel === 'ahead' ? (
                  <span className="flex items-center gap-1.5 text-emerald-700">
                    <CheckCircleIcon size={13} weight="fill" aria-hidden="true" /> Lineage proven — built from this build&apos;s
                    commit{rel === 'ahead' ? ' (plus newer commits)' : ''}
                  </span>
                ) : (
                  <span className="flex items-center gap-1.5 text-amber-600">
                    <WarningCircleIcon size={13} weight="fill" aria-hidden="true" /> Lineage unproven — no git verdict for this package
                  </span>
                );
              })()}
              {props.nativeVersion && (
                <span className="flex items-center gap-1.5 text-emerald-700">
                  <CheckCircleIcon size={13} weight="fill" aria-hidden="true" /> Native binary v{props.nativeVersion} is this build&apos;s
                  target
                </span>
              )}
              <span className="flex items-center gap-1.5 text-amber-600">
                <WarningCircleIcon size={13} weight="fill" aria-hidden="true" /> Analytics require Mixpanel — without it you ramp
                blind
              </span>
            </div>
            <div className="mt-auto pt-2 border-t border-zinc-100">
              <span className={eyebrowCls}>Suggested ladder</span>
              <div className="flex items-center gap-1.5 mt-1.5 font-mono text-[10px] text-zinc-600 flex-wrap">
                <span className="bg-zinc-100 border border-zinc-200 rounded px-2 py-0.5">1%</span>
                <CaretRightIcon size={10} weight="bold" className="text-zinc-300" aria-hidden="true" />
                <span className="bg-zinc-100 border border-zinc-200 rounded px-2 py-0.5">10%</span>
                <CaretRightIcon size={10} weight="bold" className="text-zinc-300" aria-hidden="true" />
                <span className="bg-zinc-100 border border-zinc-200 rounded px-2 py-0.5">50%</span>
                <CaretRightIcon size={10} weight="bold" className="text-zinc-300" aria-hidden="true" />
                <span className="bg-violet-100 border border-violet-200 text-violet-700 rounded px-2 py-0.5 font-bold">Conclude</span>
              </div>
            </div>
          </div>
        </div>
      )}

      {/* ═ LIVE — release control · job matrix · adoption analytics ═ */}
      {state === 'live' && live && (
        <div className="grid grid-cols-1 lg:grid-cols-12 gap-4 items-stretch">
          <div className="lg:col-span-4 bg-white rounded-lg border border-zinc-200 border-l-4 border-l-violet-400 p-4 flex flex-col gap-3">
            <div className="flex items-center justify-between">
              <span className="text-[10px] font-bold uppercase tracking-widest text-violet-600 flex items-center gap-1">
                <RocketLaunchIcon size={12} weight="fill" aria-hidden="true" /> Live release · this build
              </span>
              <Link
                to={`/airborne/${encodeURIComponent(ref)}${live.id ? `/releases/${encodeURIComponent(live.id)}` : ''}`}
                className="text-[10px] text-violet-600 hover:text-violet-900 font-bold cursor-pointer"
              >
                Airborne ↗
              </Link>
            </div>
            <div className="grid grid-cols-2 gap-3 font-mono text-xs">
              <div>
                <span className="block text-[10px] text-zinc-400 font-sans font-medium">Identity</span>
                <span className="font-bold text-violet-700">
                  pkg v{pkgVersionOf(live) ?? '?'}
                  {pkgTagOf(live) ? ` · ${pkgTagOf(live)}` : ''}
                </span>
              </div>
              <div>
                <span className="block text-[10px] text-zinc-400 font-sans font-medium">Traffic</span>
                <span className="font-bold text-emerald-600 text-lg leading-none">{trafficOf(live) ?? 0}%</span>
              </div>
              <div>
                <span className="block text-[10px] text-zinc-400 font-sans font-medium mb-0.5">Targeting</span>
                <span className="flex gap-1 flex-wrap">
                  <TargetChips dims={dimsOf(live)} />
                </span>
              </div>
              <div>
                <span className="block text-[10px] text-zinc-400 font-sans font-medium mb-0.5">Provenance</span>
                <ProvenanceBadge
                  prov={provFor(pkgVersionOf(live))}
                  push={pushes.find((p) => p.packageVersion === pkgVersionOf(live) && p.status === 'BUNDLE_PUSHED')}
                />
              </div>
            </div>
            {can('OTA_RELEASE_RAMP') && (
              <div className="bg-zinc-100 border border-zinc-200 rounded p-2 flex items-center justify-between gap-2 mt-auto">
                <span className="flex items-center gap-2">
                  <input
                    type="number"
                    min={0}
                    max={50}
                    placeholder="%"
                    value={rampPct}
                    onChange={(e) => setRampPct(e.target.value)}
                    aria-label="Ramp percentage"
                    className="w-12 h-6 text-xs text-center border border-zinc-300 rounded font-mono outline-none bg-white"
                  />
                  <button
                    onClick={() => doRamp(live)}
                    disabled={busy != null || !!releaseBlocked}
                    title={releaseBlocked ? `Ramping blocked — ${releaseBlocked}; wind down via Conclude/Revert` : undefined}
                    className="bg-white border border-zinc-300 text-zinc-700 font-bold text-[10px] px-2 py-0.5 rounded hover:bg-zinc-50 cursor-pointer disabled:opacity-50"
                  >
                    Ramp
                  </button>
                </span>
                <span className="text-[9px] text-zinc-400 text-right leading-tight">max 50% — 100% via Conclude</span>
              </div>
            )}
            {can('OTA_RELEASE_CONCLUDE') && (
              <div className="flex items-center gap-2">
                <button
                  onClick={() => void doConclude(live, false)}
                  disabled={busy != null}
                  className="flex-1 bg-violet-600 text-white px-3 py-2 text-[11px] font-bold rounded hover:bg-violet-700 cursor-pointer disabled:opacity-50"
                >
                  Conclude
                </button>
                <button
                  onClick={() => void doConclude(live, true)}
                  disabled={busy != null}
                  className="flex-1 bg-white border border-red-200 text-red-600 px-3 py-2 text-[11px] font-bold rounded hover:bg-red-50 cursor-pointer disabled:opacity-50"
                >
                  Revert to…
                </button>
              </div>
            )}
          </div>

          {/* CI workflow job matrix of the push that built this package */}
          <div className="lg:col-span-4 bg-white rounded-lg border border-zinc-200 p-4 flex flex-col gap-2.5">
            {(() => {
              const push = pushes.find((p) => p.packageVersion === pkgVersionOf(live));
              return (
                <>
                  <div className="flex items-center justify-between">
                    <span className={cn(eyebrowCls, 'flex items-center gap-1')}>
                      <TerminalWindowIcon size={12} weight="bold" className="text-violet-500" aria-hidden="true" /> Job Matrix
                    </span>
                    {push?.runUrl && (
                      <a href={push.runUrl} target="_blank" rel="noreferrer" className="text-[10px] text-blue-600 font-bold hover:underline cursor-pointer">
                        CI run ↗
                      </a>
                    )}
                  </div>
                  {push?.externalRunId != null ? (
                    <JobMatrix pushId={push.id} live={false} />
                  ) : (
                    <p className="text-[10px] text-zinc-400">
                      No SCC push recorded for this package — it may have been built outside this group.
                    </p>
                  )}
                  {push && (
                    <div className="mt-auto pt-2 border-t border-zinc-100 text-[9px] font-mono text-zinc-400 flex flex-col gap-0.5">
                      <span>
                        run <span className="text-zinc-600">{runIdOf(push)}</span>
                        {push.commitSha && (
                          <>
                            {' '}· commit <span className="text-zinc-600">{push.commitSha.slice(0, 7)}</span>
                          </>
                        )}
                      </span>
                      <span title={fullStamp(push.dispatchedAt)}>
                        pushed by <span className="text-zinc-600">{push.dispatchedBy}</span> · {shortDate(push.dispatchedAt)}
                      </span>
                    </div>
                  )}
                </>
              );
            })()}
          </div>

          <AdoptionCard
            className="lg:col-span-4"
            variant="panel"
            appId={catalogRow?.id ?? null}
            pkg={catalogPkg}
            version={pkgVersionOf(live) != null ? String(pkgVersionOf(live)) : (pkgTagOf(live) ?? null)}
          />
        </div>
      )}

      {/* ═ FAILED — push post-mortem + recovery ═ */}
      {state === 'failed' && latestPush && (
        <div className="grid grid-cols-1 lg:grid-cols-12 gap-4 items-stretch">
          <div className="lg:col-span-7 bg-red-50 rounded-lg border border-red-200 p-4 flex flex-col gap-3">
            <div className="flex items-center justify-between">
              <span className="text-[10px] font-bold uppercase tracking-widest text-red-600 flex items-center gap-1">
                <XCircleIcon size={12} weight="fill" aria-hidden="true" /> Push failed · no package produced
              </span>
              {latestPush.runUrl && (
                <a href={latestPush.runUrl} target="_blank" rel="noreferrer" className="text-[10px] text-red-600 font-bold hover:underline cursor-pointer">
                  CI logs ↗
                </a>
              )}
            </div>
            {latestPush.error && (
              <pre className="bg-red-950 text-red-200 p-2.5 rounded text-[10px] font-mono overflow-x-auto whitespace-pre-wrap">{latestPush.error}</pre>
            )}
            {latestPush.externalRunId != null && <JobMatrix pushId={latestPush.id} live={false} defaultOpen={false} />}
            <div className="flex items-center gap-2 mt-auto pt-1">
              <button
                onClick={onRetryPush}
                disabled={!canDispatch || busy != null}
                title={canDispatch ? 'Dispatch a fresh bundle push with the toolbar settings' : 'Requires MOBILE_DISPATCH'}
                className="bg-zinc-900 text-white px-3.5 py-1.5 text-[10px] font-bold rounded-lg hover:bg-zinc-800 flex items-center gap-1.5 cursor-pointer disabled:opacity-50"
              >
                <ArrowClockwiseIcon size={12} weight="bold" aria-hidden="true" /> Retry push
              </button>
              <span className="text-[10px] text-zinc-500">a runner-pool switch (toolbar) often clears infra failures</span>
            </div>
          </div>
          <div className="lg:col-span-5 bg-white rounded-lg border border-zinc-200 p-4 flex flex-col gap-2.5">
            <span className="flex items-center gap-1.5 text-[10px] font-bold text-emerald-700">
              <LockOpenIcon size={13} weight="fill" aria-hidden="true" /> Queue unblocked — the failure released the push lock.
            </span>
            {readyPkg && (
              <div className="pt-1">
                <span className={eyebrowCls}>Last good package</span>
                <div className="flex items-center gap-2 mt-1.5 text-[10px]">
                  <span className="font-mono font-bold text-zinc-700">pkg v{readyPkg.version}</span>
                  {readyPkg.tag && <span className="font-mono text-zinc-400">{readyPkg.tag}</span>}
                  <span className={cn('border px-1.5 py-px rounded text-[8px] font-bold uppercase', pkgOutcome(readyPkg.version).cls)}>
                    {pkgOutcome(readyPkg.version).label}
                  </span>
                  <button
                    onClick={() => onRelease(readyPkg)}
                    disabled={!can('OTA_RELEASE_CREATE') || !!releaseBlocked}
                    title={releaseBlocked ? `OTA release blocked — ${releaseBlocked}` : undefined}
                    className="ml-auto text-zinc-500 font-bold hover:text-zinc-900 cursor-pointer disabled:opacity-40"
                  >
                    Release again
                  </button>
                </div>
                <PkgReleases version={readyPkg.version} />
              </div>
            )}
            <div className="mt-auto pt-2 border-t border-zinc-100">
              <span className={eyebrowCls}>Push history</span>
              <div className="flex flex-col gap-1.5 mt-2 text-[10px]">
                {pushes.slice(0, 3).map((p) => (
                  <div key={p.id} className="flex items-center gap-2">
                    <span className={cn('px-1 py-0.5 rounded font-bold uppercase text-[8px]', p.status === 'FAILED' ? 'bg-red-100 text-red-800' : p.status === 'BUNDLE_PUSHED' ? 'bg-emerald-100 text-emerald-800' : 'bg-amber-100 text-amber-800')}>
                      {p.status === 'BUNDLE_PUSHED' ? 'Pushed' : p.status}
                    </span>
                    <span className="font-mono text-zinc-700 truncate">
                      {p.finalVersion ?? p.requestedBump}
                      {p.error ? ` · ${p.error.slice(0, 32)}${p.error.length > 32 ? '…' : ''}` : ''}
                    </span>
                    <span className="text-zinc-400 ml-auto font-mono" title={fullStamp(p.dispatchedAt)}>{shortDate(p.dispatchedAt)}</span>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </div>
      )}

      {/* ═ IDLE ═ */}
      {state === 'idle' && (
        <p className="text-[11px] text-zinc-500 border border-dashed border-zinc-200 rounded px-3 py-2.5">
          No OTA activity from this build yet — <b>Push bundle</b> compiles one.
          {foreignPkgCount > 0 && (
            <>
              {' '}
              {foreignPkgCount} package{foreignPkgCount > 1 ? 's' : ''} from other builds exist in this namespace —{' '}
              <Link
                to={`/airborne/${encodeURIComponent(ref)}`}
                className="font-bold text-violet-600 hover:underline cursor-pointer"
              >
                view in Airborne ↗
              </Link>
              .
            </>
          )}
        </p>
      )}
    </div>
  );
}

