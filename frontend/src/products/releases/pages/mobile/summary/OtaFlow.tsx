// v4 OTA rail (docs/design/mobile-release-summary-mockup-v4.html, right
// column). Data + verbs ported from components/ota/OtaPanel.tsx — release
// state is ALWAYS read live from the airborne BFF, push rows/links come from
// the group OTA endpoint, and release verbs are gated by per-ref airborne
// grants (useOtaAccess), NOT PermissionsContext.
import { useMemo, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Link } from 'react-router-dom';
import {
  ArrowSquareOutIcon,
  CaretDownIcon,
  CaretRightIcon,
  ChartBarIcon,
  CircleNotchIcon,
  GitBranchIcon,
  LockKeyIcon,
  RocketLaunchIcon,
  TerminalWindowIcon,
  UploadSimpleIcon,
  WarningCircleIcon,
  WarningIcon,
} from '@phosphor-icons/react';
import { cn } from '../../../../../lib/utils';
import { Button } from '../../../../../shared/ui/button';
import { Spinner } from '../../../../../shared/ui/spinner';
import { useConfirm } from '../../../../../shared/ui/confirm-dialog';
import {
  concludeOtaRelease,
  discardOtaRelease,
  fetchOtaPackageDetail,
  fetchOtaPackages,
  fetchOtaReleases,
  rampOtaRelease,
} from '../../../../airborne-ota/api';
import { useOtaAccess } from '../../../../airborne-ota/hooks';
import { chimeApi } from '../../../api';
import { AdoptionCard } from '../../../components/chime/AdoptionCard';
import { useMobileApps } from '../../../hooks';
import type { OtaRelease } from '../../../../airborne-ota/types';
import {
  cancelOtaPush,
  attachOtaPackage,
  dispatchGroupOta,
  fetchOtaPushJobs,
  releaseOtaPackage,
  releaseOtaPush,
  fetchReleaseProvenance,
  useOtaProvenance,
  OTA_RUNNER_POOLS,
  type OtaLinkRow,
  type OtaOngoingConflict,
  type OtaProvPkg,
  type OtaPushRow,
  type OtaReleaseReq,
} from '../../../otaApi';
import {
  dimsOf,
  errMsg,
  OtaBranchPicker,
  OtaReleaseComposer,
  OtaSupersedeDialog,
  pkgNameOf,
  pkgTagOf,
  pkgVersionOf,
  ProvenanceBadge,
  ReleaseId,
  respData,
  statusOf,
  trafficOf,
  type ReleasablePkg,
} from '../../../components/ota/OtaPanel';
import { fullStamp, shortDate } from './dates';

export interface OtaFlowProps {
  groupId: string;
  /** Tracker row id — anchors build-level provenance (commit recovery, branch adopt). */
  releaseId: string;
  appName: string;
  platform: string;
  airborneAppRef: string;
  /** null ⇒ store-sync row: operate-only, push hidden. */
  sourceRef: string | null;
  /** Reason the build's state (draft/building/discarded/failed) blocks
   *  creating pushes/releases; operate verbs stay live. */
  releaseBlocked?: string | null;
  pushEligible: boolean;
  ineligibleReason?: string;
  pushes: OtaPushRow[];
  links: OtaLinkRow[];
  activePush?: { groupId: string; dispatchedBy: string } | null;
  canDispatch: boolean;
  /** Native build version (e.g. "3.3.17") — header line + composer's R7 rule. */
  nativeVersion?: string | null;
  /** Build replaced on the store — composer pre-seeds version targeting. */
  buildSuperseded?: boolean;
  onChanged: () => void;
}

const eyebrowCls = 'text-[10px] uppercase tracking-widest font-bold text-zinc-500';

// "27/07, 16:50" — compact history timestamp.
const shortStamp = (iso: string) =>
  new Date(iso).toLocaleString(undefined, { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' });

const PUSH_EDGE: Record<OtaPushRow['status'], string> = {
  DISPATCHED: 'border-l-sky-500',
  RUNNING: 'border-l-amber-500',
  BUNDLE_PUSHED: 'border-l-emerald-500',
  FAILED: 'border-l-red-500',
};

const PUSH_BADGE: Record<OtaPushRow['status'], string> = {
  DISPATCHED: 'text-sky-800 bg-sky-100',
  RUNNING: 'text-amber-800 bg-amber-100',
  BUNDLE_PUSHED: 'text-emerald-800 bg-emerald-100',
  FAILED: 'text-red-800 bg-red-100',
};

const REL_BADGE: Record<string, string> = {
  CREATED: 'bg-sky-100 text-sky-800',
  INPROGRESS: 'bg-emerald-100 text-emerald-800',
  CONCLUDED: 'bg-emerald-100 text-emerald-800',
  DISCARDED: 'bg-zinc-100 text-zinc-600',
};


/** Targeting dimensions as dark mono chips — "all devices" when unscoped. */
export function TargetChips({ dims }: { dims: Record<string, unknown> }) {
  const entries = Object.entries(dims);
  if (entries.length === 0) {
    return (
      <span className="bg-zinc-100 border border-zinc-200 text-zinc-800 font-mono text-[9px] font-semibold px-1.5 py-px rounded whitespace-nowrap">
        all devices
      </span>
    );
  }
  return (
    <>
      {entries.map(([k, v]) => (
        <span
          key={k}
          className="bg-zinc-100 border border-zinc-200 text-zinc-800 font-mono text-[9px] font-semibold px-1.5 py-px rounded whitespace-nowrap"
          title={`${k}: ${String(v)}`}
        >
          {k}: {String(v)}
        </span>
      ))}
    </>
  );
}

export function OtaFlow(props: OtaFlowProps) {
  const {
    groupId,
    releaseId,
    appName,
    platform,
    airborneAppRef: ref,
    sourceRef,
    releaseBlocked = null,
    pushEligible,
    ineligibleReason,
    pushes,
    links,
    activePush,
    canDispatch,
    nativeVersion,
    buildSuperseded,
    onChanged,
  } = props;
  const qc = useQueryClient();
  const confirm = useConfirm();
  const access = useOtaAccess();
  const { data: mobileApps = [] } = useMobileApps();
  const catalogPkg = useMemo(
    () => mobileApps.find((a) => a.airborneAppRef === ref)?.packageName ?? null,
    [mobileApps, ref],
  );
  const perms = useMemo(
    () => access.data?.apps.find((a) => a.appRef === ref)?.permissions ?? [],
    [access.data, ref],
  );
  const hasView = perms.includes('OTA_VIEW');
  const can = (p: string) => perms.includes(p);

  const myPushes = useMemo(
    () => pushes.filter((p) => p.appName === appName && p.platform === platform),
    [pushes, appName, platform],
  );
  const myLinks = useMemo(() => links.filter((l) => l.airborneAppRef === ref), [links, ref]);

  // Live release state — never cached in SCC (Decision C).
  const releasesQ = useQuery({
    queryKey: ['mobile-ota-releases', ref],
    queryFn: () => fetchOtaReleases(ref, { page: 1, count: 30 }),
    enabled: hasView,
    retry: false,
    refetchInterval: 15_000,
  });

  // Shelf of recent packages in this app's namespace — the create surface.
  const packagesQ = useQuery({
    queryKey: ['mobile-ota-packages', ref],
    queryFn: () => fetchOtaPackages(ref, { page: 1, count: 8 }),
    enabled: hasView,
    retry: false,
    staleTime: 30_000,
  });
  const releases = releasesQ.data?.data ?? [];
  const allOngoing = releases.filter((r) => ['CREATED', 'INPROGRESS'].includes(statusOf(r)));

  // Ongoing releases can reference packages older than the 8-item shelf page;
  // fetch their detail once for the version string + tag so provenance can rule.
  const missingTagVersions = useMemo(() => {
    const onShelf = new Set(
      (packagesQ.data?.data ?? []).map((pk) => pk.version).filter((v): v is number => typeof v === 'number'),
    );
    const out: number[] = [];
    for (const r of allOngoing) {
      const v = pkgVersionOf(r);
      if (v != null && !onShelf.has(v) && !pkgTagOf(r) && !out.includes(v)) out.push(v);
    }
    return out;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [packagesQ.data, releasesQ.data]);
  const pkgTagsQ = useQuery({
    queryKey: ['mobile-ota-pkgtags', ref, missingTagVersions.join(',')],
    queryFn: async () => {
      const entries = await Promise.all(
        missingTagVersions.map(async (v) => {
          try {
            const d = await fetchOtaPackageDetail(ref, `version:${v}`);
            return [v, typeof d.tag === 'string' && d.tag ? d.tag : undefined] as const;
          } catch {
            return [v, undefined] as const;
          }
        }),
      );
      return Object.fromEntries(entries) as Record<number, string | undefined>;
    },
    enabled: hasView && missingTagVersions.length > 0,
    retry: false,
    staleTime: 5 * 60_000,
  });

  // Git-tag-ledger provenance (doc §11b): shelf ∪ ongoing packages, resolved
  // against this build's anchor commit. Verdicts are immutable ⇒ long staleTime.
  const provReqs = useMemo(() => {
    const byVersion = new Map<number, { version: number; tag?: string }>();
    for (const p of packagesQ.data?.data ?? []) {
      if (typeof p.version === 'number')
        byVersion.set(p.version, { version: p.version, tag: typeof p.tag === 'string' ? p.tag : undefined });
    }
    for (const r of allOngoing) {
      const v = pkgVersionOf(r);
      if (v != null && !byVersion.has(v))
        byVersion.set(v, { version: v, tag: pkgTagOf(r) ?? pkgTagsQ.data?.[v] });
    }
    return [...byVersion.values()];
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [packagesQ.data, releasesQ.data, pkgTagsQ.data]);
  const provQ = useOtaProvenance(groupId, ref, provReqs, hasView);
  // Build-level anchor for a row with no source branch — needs neither OTA
  // view nor packages (shared cache with the branch-picker dialog).
  const anchorQ = useQuery({
    queryKey: ['mobile-release-prov', releaseId],
    queryFn: () => fetchReleaseProvenance(releaseId),
    enabled: !sourceRef && !!releaseId,
    retry: false,
    staleTime: 5 * 60_000,
  });
  const anchorSha = anchorQ.data?.commitSha ?? provQ.data?.anchor?.commitSha;
  const provOf = (v?: number): OtaProvPkg | undefined =>
    v == null ? undefined : provQ.data?.packages.find((p) => p.packageVersion === v);

  // A release belongs to THIS build when git proves its package's commit is the
  // build's commit or a descendant — or SCC's own link row says so.
  const isMine = (r: OtaRelease) => {
    const rel = provOf(pkgVersionOf(r))?.relation;
    return (
      rel === 'identical' ||
      rel === 'ahead' ||
      myLinks.some((l) => l.airborneReleaseId === r.id && l.groupId === groupId)
    );
  };
  const ongoing = allOngoing.filter(isMine);
  const foreignOngoing = allOngoing.filter((r) => !ongoing.includes(r));
  // INPROGRESS foreign = serving devices NOW (must stay visible); CREATED
  // foreign is inert — the supersede dialog owns it.
  const foreignServing = foreignOngoing.filter((r) => statusOf(r) === 'INPROGRESS');
  const foreignInert = foreignOngoing.filter((r) => statusOf(r) !== 'INPROGRESS');
  const maxKnownPkg = Math.max(0, ...releases.map((r) => pkgVersionOf(r) ?? 0));

  const shelfPkgs = useMemo(() => {
    const out: Array<{ version: number; tag?: string }> = [];
    for (const pk of packagesQ.data?.data ?? []) {
      if (typeof pk.version === 'number')
        out.push({ version: pk.version, tag: typeof pk.tag === 'string' ? pk.tag : undefined });
    }
    return out;
  }, [packagesQ.data]);
  const pushFor = (v: number): OtaPushRow | undefined =>
    myPushes.find((x) => x.packageVersion === v && x.status === 'BUNDLE_PUSHED');
  const isEligible = (v: number): boolean => {
    const rel = provOf(v)?.relation;
    return rel === 'identical' || rel === 'ahead' || !!pushFor(v);
  };
  const eligiblePkgs: ReleasablePkg[] = useMemo(
    () =>
      shelfPkgs
        .filter((pk) => isEligible(pk.version))
        .map((pk) => ({ ...pk, pushId: pushFor(pk.version)?.id, relation: provOf(pk.version)?.relation }))
        .sort((a, b) => b.version - a.version),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [shelfPkgs, provQ.data, myPushes],
  );
  const foreignPkgs = shelfPkgs.filter((pk) => !isEligible(pk.version));
  const tagFor = (r: OtaRelease): string | undefined => {
    const v = pkgVersionOf(r);
    return pkgTagOf(r) ?? shelfPkgs.find((pk) => pk.version === v)?.tag ?? (v != null ? pkgTagsQ.data?.[v] : undefined);
  };

  const [composerFor, setComposerFor] = useState<ReleasablePkg | null>(null);
  const [editRelease, setEditRelease] = useState<{
    releaseId: string;
    pkg: ReleasablePkg;
    lockedDims: Record<string, unknown>;
  } | null>(null);
  const [conflict, setConflict] = useState<{
    pkg: ReleasablePkg;
    req: OtaReleaseReq;
    ongoing: OtaOngoingConflict['ongoing'];
  } | null>(null);
  const [bump, setBump] = useState<'patch' | 'minor' | 'major'>('patch');
  const [notifySlack, setNotifySlack] = useState(true);
  const [runner, setRunner] = useState<string>('ios-debug');
  const [rampFor, setRampFor] = useState<string | null>(null);
  const [rampPct, setRampPct] = useState('10');
  const [attachFor, setAttachFor] = useState<string | null>(null);
  const [attachVersion, setAttachVersion] = useState('');
  const [historyToggles, setHistoryToggles] = useState<Record<string, boolean>>({});
  const [historyOpen, setHistoryOpen] = useState(false);
  const [branchPickerOpen, setBranchPickerOpen] = useState(false);

  const invalidate = () => {
    qc.invalidateQueries({ queryKey: ['mobile-ota-releases', ref] });
    onChanged();
  };

  const dispatchMut = useMutation({
    mutationFn: () =>
      dispatchGroupOta(groupId, { versionBump: bump, apps: [appName], platforms: [platform], notifySlack, runner }),
    onSuccess: () => {
      toast.success(`OTA bundle push dispatched (${bump})`);
      onChanged();
    },
    onError: (e: unknown) => toast.error(errMsg(e, 'dispatch failed')),
  });

  const doRamp = async (releaseId: string, pct: number, expected?: number) => {
    try {
      await rampOtaRelease(ref, releaseId, {
        trafficPercentage: pct,
        changeReason: `via SCC mobile release ${groupId}`,
        expectedTrafficPercentage: expected,
      });
      toast.success(`Ramped to ${pct}%`);
      setRampFor(null);
      invalidate();
    } catch (e) {
      toast.error(errMsg(e, 'ramp failed'));
    }
  };

  // Conclude ships to 100%; revert concludes choosing the CONTROL variant so
  // the ramped cohort returns to stable. Auto-selects the sole variant.
  const doConclude = async (r: OtaRelease, revert: boolean) => {
    const variants = r.experiment?.experiment_variants;
    const chosen = revert ? variants?.control : variants?.experimentals?.[0];
    if (!chosen || (!revert && (variants?.experimentals?.length ?? 0) > 1)) {
      toast.error('Variant ambiguous — use the Airborne product page for this release');
      return;
    }
    const verb = revert ? 'Revert' : 'Conclude';
    const target = `release ${r.id} (pkg v${pkgVersionOf(r) ?? '?'}, ${trafficOf(r) ?? 0}% → ${revert ? 'stable' : '100%'})`;
    const consequence = revert
      ? `The ramped cohort returns to the previous stable bundle. Target: ${target}`
      : `This ships the bundle to 100% of matching devices. Target: ${target}`;
    if (!(await confirm({ title: `${verb} this release?`, description: consequence, variant: revert ? 'danger' : 'primary' })))
      return;
    try {
      await concludeOtaRelease(ref, r.id!, {
        chosenVariant: chosen,
        changeReason: `${verb} via SCC mobile release ${groupId}`,
      });
      toast.success(`${verb} done`);
      invalidate();
    } catch (e) {
      toast.error(errMsg(e, `${verb.toLowerCase()} failed`));
    }
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
    try {
      await discardOtaRelease(ref, r.id!);
      toast.success('Release discarded');
      invalidate();
    } catch (e) {
      toast.error(errMsg(e, 'discard failed'));
    }
  };

  const submitRelease = async (pkg: ReleasablePkg, req: OtaReleaseReq) => {
    try {
      const res = pkg.pushId
        ? await releaseOtaPush(pkg.pushId, req)
        : await releaseOtaPackage(groupId, {
            airborneAppRef: ref,
            packageVersion: pkg.version,
            packageTag: pkg.tag,
            ...req,
          });
      toast.success(
        res.firstRelease
          ? 'Bootstrap release created (auto-concluded upstream)'
          : res.ramped
            ? `Release created and ramped to ${req.initialTrafficPercent}%`
            : 'Release created' + (req.initialTrafficPercent ? ' — ramp failed, use the Ramp button' : ''),
      );
      setComposerFor(null);
      setConflict(null);
      invalidate();
    } catch (e: unknown) {
      const data = respData(e) as Partial<OtaOngoingConflict> | undefined;
      if (data?.code === 'ONGOING_RELEASE_EXISTS') {
        setConflict({ pkg, req, ongoing: data.ongoing ?? [] });
      } else {
        toast.error(errMsg(e, 'release failed'));
      }
    }
  };

  const pushDisabledReason = releaseBlocked
    ? `OTA blocked — ${releaseBlocked}`
    : !sourceRef
    ? 'Imported from store — no source branch to build from'
    : !pushEligible
      ? (ineligibleReason ?? 'Not eligible')
      : activePush
        ? `Push active · by ${activePush.dispatchedBy} · auto-serialized`
        : !canDispatch
          ? 'Requires MOBILE_DISPATCH'
          : null;

  // The in-flight push (drives the CI runner control's live view).
  const livePush = myPushes.find((p) => ['DISPATCHED', 'RUNNING'].includes(p.status));

  return (
    <div className="flex flex-col bg-white rounded-xl border border-zinc-200 border-l-[6px] border-l-violet-500 overflow-hidden shadow-[0_4px_12px_-4px_rgba(0,0,0,0.05)] relative">
      {/* Violet tinted header zone */}
      <div className="bg-violet-50/50 p-4 border-b border-violet-100 relative overflow-hidden">
        <div className="relative z-10 w-full">
          <div className="flex justify-between items-center w-full">
            <span className="flex items-center gap-2 min-w-0">
              <span className="bg-violet-100 text-violet-800 border border-violet-200 text-[9px] px-1.5 py-0.5 rounded font-bold uppercase tracking-wider flex items-center gap-1 shadow-sm shrink-0">
                <RocketLaunchIcon size={11} weight="fill" aria-hidden="true" /> OTA Bundle Target
              </span>
              <span className="font-mono text-[10px] text-zinc-800 truncate" title={`Airborne app mapping: ${ref}`}>
                {ref}
              </span>
            </span>
            <Link
              to={`/airborne/${encodeURIComponent(ref)}`}
              className="text-[10px] text-violet-600 hover:text-violet-900 font-bold flex items-center gap-1 cursor-pointer"
            >
              Open in Airborne <ArrowSquareOutIcon size={10} weight="bold" aria-hidden="true" />
            </Link>
          </div>
          <h3 className="text-xs font-bold text-zinc-900 mt-3 tracking-tight">Over-the-air JS bundles</h3>
          <p className="text-[11px] text-zinc-500 mt-0.5 leading-tight">
            Ships into installed native binary{' '}
            <span className="font-mono bg-white px-1 rounded shadow-sm border border-zinc-100 text-[10px]">
              v{nativeVersion}
            </span>
          </p>
        </div>
      </div>

      {/* Build-state gate: draft/building/discarded/failed builds cannot
          create pushes/releases; operating ongoing releases stays allowed. */}
      {releaseBlocked && (
        <div className="bg-red-50 border-b border-red-200 px-4 py-2.5 border-l-4 border-l-red-400">
          <p className="text-[10px] font-bold text-red-800 uppercase tracking-wide flex items-baseline gap-1">
            <WarningIcon size={11} weight="fill" aria-hidden="true" /> OTA disabled for this build
          </p>
          <p className="text-[11px] text-red-900 mt-0.5 leading-tight">
            {releaseBlocked} — no shippable artifact to attach bundles to. Ongoing releases from
            earlier builds can still be operated.
          </p>
        </div>
      )}
      {/* Imported-from-store: no source branch — pushes need one (§11b). */}
      {!sourceRef && (
        <div className="bg-orange-50 border-b border-orange-200 px-4 py-3 border-l-4 border-l-orange-400">
          <p className="text-[10px] font-bold text-orange-800 uppercase tracking-wide mb-1 flex items-baseline gap-1">
            <WarningIcon size={11} weight="fill" aria-hidden="true" /> Imported From Store
          </p>
          {anchorQ.isLoading ? (
            <div className="flex items-center gap-2 text-[11px] text-orange-800">
              <CircleNotchIcon size={13} weight="bold" className="animate-spin shrink-0" aria-hidden="true" />
              Recovering build commit from the tag ledger…
            </div>
          ) : (
            <>
              <p className="text-[11px] text-orange-900 mb-2 leading-tight">
                No source branch known for compilation
                {anchorSha && (
                  <>
                    {' '}
                    (build commit <span className="font-mono">{anchorSha.slice(0, 9)}</span> recovered)
                  </>
                )}
                . Set a verified origin branch to push bundles.
              </p>
              {anchorSha ? (
                <button
                  type="button"
                  onClick={() => setBranchPickerOpen(true)}
                  className="w-full bg-white border border-orange-200 text-orange-900 text-xs font-mono rounded px-2 py-1.5 outline-none shadow-sm cursor-pointer flex items-center justify-between gap-2 hover:bg-orange-50/50"
                >
                  <span>commit {anchorSha.slice(0, 9)} (recovered) — pick source branch</span>
                  <CaretDownIcon size={12} weight="bold" aria-hidden="true" />
                </button>
              ) : (
                <span className="text-[11px] text-orange-700">no anchor commit — branch cannot be verified</span>
              )}
            </>
          )}
        </div>
      )}

      {/* Foreign releases serving traffic — never hidden. */}
      {hasView && !releasesQ.isError && foreignServing.length > 0 && (
        <div className="px-4 pt-3 flex">
          <details className="flex-1 bg-amber-50/50 border border-amber-200 text-amber-800 rounded p-2 text-[10px]">
            <summary className="flex gap-2 items-start cursor-pointer select-none">
              <WarningCircleIcon size={14} weight="fill" className="text-amber-500 mt-0.5 shrink-0" aria-hidden="true" />
              <span>
                <span className="font-bold">Foreign releases active.</span>{' '}
                <span className="text-amber-700">
                  {foreignServing.length} stray OTA release{foreignServing.length > 1 ? 's are' : ' is'} currently
                  serving traffic from outside this build&apos;s lineage. Operate with care.
                </span>
              </span>
            </summary>
            <div className="mt-2 space-y-2">
              {foreignServing.map((r) => {
                const st = statusOf(r);
                const link = myLinks.find((l) => l.airborneReleaseId === r.id);
                return (
                  <div key={r.id} className="rounded border border-amber-200 bg-white p-2 text-[10px] text-zinc-600">
                    <div className="flex items-center gap-2 flex-wrap">
                      <span className={cn('px-1 py-0.5 rounded font-bold uppercase text-[8px]', REL_BADGE[st] ?? 'bg-zinc-100 text-zinc-600')}>
                        {st}
                      </span>
                      {pkgVersionOf(r) != null && <span className="font-mono">pkg v{pkgVersionOf(r)}</span>}
                      {tagFor(r) && <span className="font-mono">{tagFor(r)}</span>}
                      <span className="font-bold text-violet-700">{trafficOf(r) ?? 0}%</span>
                      <TargetChips dims={dimsOf(r)} />
                      {r.id && <ReleaseId id={r.id} />}
                      <span className="ml-auto text-zinc-400">
                        {link
                          ? `from ${link.groupLabel || `group ${link.groupId.slice(0, 8)}`} · ${link.sourceRef}`
                          : `created outside SCC${r.created_at ? ` · ${new Date(r.created_at).toLocaleDateString()}` : ''}`}
                      </span>
                    </div>
                    <div className="flex items-center gap-2 mt-1.5">
                      {st === 'INPROGRESS' && can('OTA_RELEASE_CONCLUDE') && (
                        <>
                          <Button size="sm" variant="ghost" onClick={() => doConclude(r, false)}>
                            Conclude
                          </Button>
                          <Button size="sm" variant="ghost" onClick={() => doConclude(r, true)}>
                            Revert
                          </Button>
                        </>
                      )}
                      {st === 'CREATED' && can('OTA_RELEASE_DISCARD') && (
                        <Button size="sm" variant="ghost" onClick={() => doDiscard(r)}>
                          Discard
                        </Button>
                      )}
                    </div>
                  </div>
                );
              })}
            </div>
          </details>
        </div>
      )}

      {/* Scrollable inner matrix */}
      <div className="p-4 flex flex-col gap-6">
        {/* 1. Active ongoing release cards — this build's only */}
        {access.isLoading ? (
          <div className="border border-dashed border-zinc-200 rounded px-3 py-2.5">
            <Spinner size="sm" label="Loading OTA view…" />
          </div>
        ) : !hasView ? (
          <p className="text-[11px] text-zinc-500 border border-dashed border-zinc-200 rounded px-3 py-2.5">
            You don&apos;t have airborne access for this app — push status only.
          </p>
        ) : releasesQ.isError ? (
          <p className="text-[11px] text-zinc-500 border border-dashed border-zinc-200 rounded px-3 py-2.5">
            Airborne unreachable — release state unavailable.
          </p>
        ) : releasesQ.isLoading ? (
          <div className="border border-dashed border-zinc-200 rounded px-3 py-2.5">
            <Spinner size="sm" label="Loading release state…" />
          </div>
        ) : ongoing.length === 0 ? (
          <p className="text-[11px] text-zinc-500 border border-dashed border-zinc-200 rounded px-3 py-2.5">
            No ongoing OTA release from this build.
          </p>
        ) : (
          ongoing.map((r) => {
            const st = statusOf(r);
            const live = st === 'INPROGRESS';
            const link = myLinks.find((l) => l.airborneReleaseId === r.id);
            const provenance = link
              ? link.groupId === groupId
                ? `this release · ${link.createdBy}`
                : `${link.groupLabel || `group ${link.groupId.slice(0, 8)}`} · ${link.createdBy}`
              : 'created outside SCC';
            return (
              <div key={r.id} className="flex flex-col border border-zinc-200 rounded-lg overflow-hidden shadow-sm">
                <div className="bg-zinc-50 p-2.5 border-b border-zinc-200 flex items-center justify-between">
                  <span
                    className={cn(
                      'flex items-center gap-1.5 text-[9px] uppercase font-bold px-1.5 py-0.5 rounded shadow-sm border',
                      live
                        ? 'bg-emerald-100 border-emerald-200 text-emerald-800'
                        : 'bg-sky-100 border-sky-200 text-sky-800',
                    )}
                  >
                    <span
                      className={cn(
                        'w-1.5 h-1.5 rounded-full',
                        live ? 'bg-emerald-500 shadow-[0_0_4px_#10b981]' : 'bg-sky-500',
                      )}
                    />
                    {live ? 'Live Release' : 'Created · not ramped'}
                  </span>
                  <span
                    className="font-mono text-[10px] text-zinc-600"
                    title={r.created_at ? fullStamp(r.created_at) : undefined}
                  >
                    {r.created_at ? shortDate(r.created_at) : ''}
                  </span>
                </div>

                <div className="p-3 bg-white font-mono text-xs flex flex-col gap-2">
                  <div className="flex justify-between items-center pb-2 border-b border-zinc-100 gap-2">
                    <span className="text-zinc-500 text-[11px] font-sans shrink-0">Identity</span>
                    <span className="font-bold text-violet-700 bg-violet-50 px-1 py-0.5 rounded truncate" title={pkgNameOf(r)}>
                      pkg v{pkgVersionOf(r) ?? '?'}
                      {tagFor(r) ? ` · ${tagFor(r)}` : ''}
                    </span>
                  </div>
                  {live && (
                    <div className="flex justify-between items-center pb-2 border-b border-zinc-100">
                      <span className="text-zinc-500 text-[11px] font-sans">Traffic Ramp</span>
                      <span className="font-bold text-emerald-600">{trafficOf(r) ?? 0}%</span>
                    </div>
                  )}
                  <div className="flex justify-between items-center pb-2 border-b border-zinc-100 gap-2">
                    <span className="text-zinc-500 text-[11px] font-sans shrink-0">Targeting</span>
                    <span className="flex items-center gap-1 flex-wrap justify-end min-w-0">
                      <TargetChips dims={dimsOf(r)} />
                    </span>
                  </div>
                  <div className="flex justify-between items-center text-[10px] gap-2">
                    <span className="text-zinc-400 font-sans shrink-0">Provenance</span>
                    <span className="text-zinc-500 text-right flex items-center gap-1 flex-wrap justify-end">
                      <ProvenanceBadge
                        prov={provOf(pkgVersionOf(r))}
                        push={pkgVersionOf(r) != null ? pushFor(pkgVersionOf(r)!) : undefined}
                        link={link}
                      />
                      · {provenance}
                    </span>
                  </div>
                  <div className="flex items-center gap-1.5 text-[10px]">
                    {r.id && <ReleaseId id={r.id} />}
                    {r.id && (
                      <Link
                        to={`/airborne/${encodeURIComponent(ref)}/releases/${encodeURIComponent(r.id)}`}
                        className="text-violet-600 hover:text-violet-900 font-sans font-bold cursor-pointer"
                        title="Open in Airborne"
                      >
                        <ArrowSquareOutIcon size={12} aria-hidden="true" />
                      </Link>
                    )}
                  </div>
                </div>

                {live && (
                  <AdoptionCard
                    className="px-3 pb-3"
                    variant="compact"
                    appRef={ref}
                    pkg={catalogPkg}
                    os={platform === 'ios' ? 'ios' : 'android'}
                    version={pkgVersionOf(r) != null ? String(pkgVersionOf(r)) : (pkgTagOf(r) ?? null)}
                  />
                )}

                {/* Ramp control — serving releases AND created ones (first ramp
                    is what starts serving; parity with the group panel). */}
                {can('OTA_RELEASE_RAMP') && (
                  <div className="px-3 pb-3">
                    <div className="bg-zinc-100 border border-zinc-200 rounded p-2 flex items-center justify-between gap-2">
                      <div className="flex items-center gap-2">
                        <input
                          type="number"
                          min={0}
                          max={50}
                          placeholder="%"
                          value={rampFor === r.id ? rampPct : ''}
                          onFocus={() => setRampFor(r.id!)}
                          onChange={(e) => {
                            setRampFor(r.id!);
                            setRampPct(e.target.value);
                          }}
                          aria-label="Ramp percentage"
                          className="w-14 h-6 text-xs text-center border border-zinc-300 rounded font-mono focus:ring-1 focus:ring-violet-400 outline-none bg-white"
                        />
                      </div>
                      <span className={cn('text-[9px] text-right leading-tight', releaseBlocked ? 'text-red-500 font-semibold' : 'text-zinc-400')}>
                        {releaseBlocked ? `ramp blocked — ${releaseBlocked}` : 'max 50% — 100% only via Conclude'}
                      </span>
                    </div>
                  </div>
                )}

                {/* Complete verb set (OTA disjoint) — Ramp is a full-size
                    segment like its siblings; the % input lives in the bar
                    above. Conclude/Revert appear only once serving (live). */}
                {(() => {
                  const rampVerb = can('OTA_RELEASE_RAMP') && (
                    <button
                      type="button"
                      disabled={!!releaseBlocked}
                      title={
                        releaseBlocked
                          ? `Ramping blocked — ${releaseBlocked}${live ? '; wind down via Conclude/Revert' : '; discard is the way out'}`
                          : undefined
                      }
                      onClick={() => {
                        const n = Number(rampFor === r.id ? rampPct : NaN);
                        if (!Number.isFinite(n) || n < 0 || n > 50) {
                          toast.error('Traffic must be 0–50 (100% only via Conclude)');
                          return;
                        }
                        void doRamp(r.id!, n, trafficOf(r));
                      }}
                      className="col-span-1 py-2.5 bg-violet-600 text-white font-semibold text-xs transition-colors hover:bg-violet-700 disabled:opacity-50 cursor-pointer disabled:cursor-default"
                    >
                      Ramp
                    </button>
                  );
                  return live && can('OTA_RELEASE_CONCLUDE') ? (
                    <div
                      className={cn(
                        'grid gap-px bg-zinc-200 mt-auto border-t border-zinc-200',
                        rampVerb ? 'grid-cols-3' : 'grid-cols-2',
                      )}
                    >
                      {rampVerb}
                      <button
                        type="button"
                        onClick={() => doConclude(r, false)}
                        className="col-span-1 py-2.5 bg-zinc-50 text-violet-700 font-semibold text-xs transition-colors hover:bg-violet-50 cursor-pointer"
                      >
                        Conclude
                      </button>
                      <button
                        type="button"
                        onClick={() => doConclude(r, true)}
                        className="col-span-1 py-2.5 bg-zinc-50 text-red-600 font-semibold text-xs transition-colors hover:bg-red-50 cursor-pointer"
                      >
                        Revert To…
                      </button>
                    </div>
                  ) : !live ? (
                    <div
                      className={cn(
                        'grid gap-px bg-zinc-200 mt-auto border-t border-zinc-200',
                        rampVerb ? 'grid-cols-3' : 'grid-cols-2',
                      )}
                    >
                      {rampVerb}
                      <button
                        type="button"
                        disabled={!can('OTA_RELEASE_CREATE') || !!releaseBlocked}
                        title={releaseBlocked ? `Editing blocked — ${releaseBlocked}; discard is the way out` : undefined}
                        onClick={() =>
                          r.id &&
                          setEditRelease({
                            releaseId: r.id,
                            pkg: { version: pkgVersionOf(r) ?? 0, tag: tagFor(r) },
                            lockedDims: dimsOf(r),
                          })
                        }
                        className="col-span-1 py-2.5 bg-zinc-50 text-zinc-700 font-semibold text-xs transition-colors hover:bg-zinc-100 disabled:opacity-50 cursor-pointer disabled:cursor-default"
                      >
                        Edit
                      </button>
                      <button
                        type="button"
                        disabled={!can('OTA_RELEASE_DISCARD')}
                        onClick={() => doDiscard(r)}
                        className="col-span-1 py-2.5 bg-zinc-50 text-red-600 font-semibold text-xs transition-colors hover:bg-red-50 disabled:opacity-50 cursor-pointer disabled:cursor-default"
                      >
                        Discard
                      </button>
                    </div>
                  ) : null;
                })()}
              </div>
            );
          })
        )}


        {/* 2. Releasable packages (stacked lineage) */}
        {hasView && !releasesQ.isError && (
          <div>
            <p className={cn(eyebrowCls, 'mb-2')}>Releasable Packages</p>
            {packagesQ.isLoading || provQ.isLoading ? (
              <div className="border border-dashed border-zinc-200 rounded px-3 py-2.5">
                <Spinner size="sm" label="Loading packages…" />
              </div>
            ) : eligiblePkgs.length === 0 ? (
              <p className="text-[11px] text-zinc-500 border border-dashed border-zinc-200 rounded px-3 py-2.5">
                No packages from this build yet — a bundle push creates one.
              </p>
            ) : (
              <div className="border border-zinc-200 rounded text-[11px] overflow-hidden drop-shadow-sm">
                {eligiblePkgs.slice(0, 1).map((pk) => {
                  const push = pk.pushId ? myPushes.find((x) => x.id === pk.pushId) : undefined;
                  const link = myLinks.find((l) => l.packageVersion === pk.version);
                  const pkgRels = releases
                    .filter((r) => pkgVersionOf(r) === pk.version)
                    .sort((a, b) => (b.created_at || '').localeCompare(a.created_at || ''));
                  return (
                    <div key={pk.version} className="flex flex-col bg-white border-b border-zinc-200">
                      <div className="bg-zinc-50 p-2 flex justify-between items-center border-b border-zinc-100 gap-2">
                        <span className="font-mono font-bold text-zinc-800">
                          pkg v{pk.version} {pk.tag && <span className="font-normal text-zinc-400">· {pk.tag}</span>}
                        </span>
                        <span className="flex items-center gap-1.5">
                          <AdoptionInline appRef={ref} pkg={catalogPkg} os={platform === 'ios' ? 'ios' : 'android'} version={String(pk.version)} />
                          <ProvenanceBadge prov={provOf(pk.version)} push={push} link={link} />
                        </span>
                      </div>
                      {pkgRels.map((rel) => {
                        const st = statusOf(rel);
                        return (
                          <div
                            key={rel.id}
                            className="p-2 pl-4 border-l-2 border-emerald-500 ml-3 my-2 bg-zinc-50/50 flex flex-col gap-1 rounded-r"
                          >
                            <div className="flex justify-between items-center w-full gap-2">
                              <span className="font-mono text-zinc-600 flex items-center gap-1 min-w-0">
                                {rel.id && <ReleaseId id={rel.id} />}
                                <span className={cn('text-[9px] px-1 rounded font-bold', REL_BADGE[st] ?? 'bg-zinc-100 text-zinc-600')}>
                                  {st === 'INPROGRESS' ? `Live ${trafficOf(rel) ?? 0}%` : st}
                                </span>
                              </span>
                              {st === 'CREATED' && can('OTA_RELEASE_CREATE') && (
                                <button
                                  type="button"
                                  onClick={() =>
                                    rel.id &&
                                    setEditRelease({
                                      releaseId: rel.id,
                                      pkg: { version: pk.version, tag: pk.tag },
                                      lockedDims: dimsOf(rel),
                                    })
                                  }
                                  className="text-[10px] text-purple-600 font-bold hover:underline cursor-pointer"
                                >
                                  Edit
                                </button>
                              )}
                            </div>
                            <span className="flex items-center gap-1 flex-wrap text-[9px] text-zinc-700 font-medium">
                              <TargetChips dims={dimsOf(rel)} />
                              {rel.created_at && (
                                <span title={fullStamp(rel.created_at)}>· {shortDate(rel.created_at)}</span>
                              )}
                            </span>
                          </div>
                        );
                      })}
                      <div className="p-2 border-t border-zinc-100 bg-white items-center flex justify-between">
                        <span className="text-[10px] text-zinc-400">
                          {pkgRels.length === 0 ? 'No releases from this package yet.' : 'No other active releases.'}
                        </span>
                        {can('OTA_RELEASE_CREATE') && !releaseBlocked && (
                          <button
                            type="button"
                            onClick={() => setComposerFor(pk)}
                            className="bg-white border border-zinc-200 text-zinc-600 px-2 py-1 rounded shadow-sm font-semibold hover:bg-zinc-50 cursor-pointer"
                          >
                            {pkgRels.length > 0 ? 'New Release' : 'Release'}
                          </button>
                        )}
                      </div>
                    </div>
                  );
                })}
                {eligiblePkgs.length > 1 && (
                  <details className="bg-white border-b border-zinc-200">
                    <summary className="p-1.5 text-center text-[10px] font-medium text-zinc-500 cursor-pointer hover:bg-zinc-50 select-none">
                      History · {eligiblePkgs.length - 1} older package{eligiblePkgs.length - 1 > 1 ? 's' : ''} from
                      this build
                    </summary>
                    <div className="flex flex-col gap-1.5 p-2 bg-white">
                      {eligiblePkgs.slice(1).map((pk) => {
                        const newest = releases
                          .filter((r) => pkgVersionOf(r) === pk.version)
                          .sort((a, b) => (b.created_at || '').localeCompare(a.created_at || ''))[0];
                        return (
                        <div key={pk.version} className="bg-zinc-50/60 border border-zinc-100 rounded-md px-2.5 py-1.5 flex flex-col gap-1">
                        <div className="flex items-center gap-2">
                          <span className="font-mono text-[11px] text-zinc-600 font-semibold">pkg v{pk.version}</span>
                          {pk.tag && <span className="font-mono text-[10px] text-zinc-400">{pk.tag}</span>}
                          <ProvenanceBadge
                            prov={provOf(pk.version)}
                            push={pk.pushId ? myPushes.find((x) => x.id === pk.pushId) : undefined}
                            link={myLinks.find((l) => l.packageVersion === pk.version)}
                          />
                          <span className="ml-auto" />
                          <AdoptionInline appRef={ref} pkg={catalogPkg} os={platform === 'ios' ? 'ios' : 'android'} version={String(pk.version)} />
                          {can('OTA_RELEASE_CREATE') && !releaseBlocked && (
                            <button
                              type="button"
                              onClick={() => setComposerFor(pk)}
                              className="text-[10px] text-zinc-500 font-semibold hover:text-zinc-800 cursor-pointer"
                            >
                              Release
                            </button>
                          )}
                        </div>
                        {newest && (
                          <span className="flex items-center gap-1 flex-wrap text-[9px] text-zinc-600 font-medium">
                            <span className={cn('px-1 rounded font-bold', REL_BADGE[statusOf(newest)] ?? 'bg-zinc-100 text-zinc-600')}>
                              {statusOf(newest)}
                            </span>
                            <TargetChips dims={dimsOf(newest)} />
                            {newest.created_at && <span title={fullStamp(newest.created_at)}>· {shortDate(newest.created_at)}</span>}
                          </span>
                        )}
                        </div>
                        );
                      })}
                    </div>
                  </details>
                )}
                {(foreignPkgs.length > 0 || foreignInert.length > 0) && (
                  <Link
                    to={`/airborne/${encodeURIComponent(ref)}`}
                    className="block bg-zinc-100 p-1.5 text-center text-[10px] font-medium text-zinc-500 cursor-pointer hover:bg-zinc-200 transition-colors"
                    title="Packages and inactive releases from other builds — view in the Airborne dashboard"
                  >
                    Not from this build:{' '}
                    {foreignPkgs.length > 0 && `${foreignPkgs.length} package${foreignPkgs.length > 1 ? 's' : ''}`}
                    {foreignPkgs.length > 0 && foreignInert.length > 0 && ' · '}
                    {foreignInert.length > 0 &&
                      `${foreignInert.length} inactive release${foreignInert.length > 1 ? 's' : ''}`}{' '}
                    · View in Airborne ↗
                  </Link>
                )}
              </div>
            )}
          </div>
        )}

        <hr className="border-zinc-200 border-dashed" />

        {/* 3. Bundle push / CI runner control */}
        <div>
          <div className="flex justify-between items-end mb-2">
            <p className={cn(eyebrowCls, 'flex items-center gap-1')}>
              <TerminalWindowIcon size={12} weight="bold" className="text-violet-500" aria-hidden="true" /> CI Runner
              Control
            </p>
          </div>

          {/* Pre-binding push state */}
          {livePush && livePush.status === 'DISPATCHED' && livePush.externalRunId == null && (
            <div className="mb-4 border border-zinc-200 bg-zinc-50 rounded p-2.5 shadow-sm flex items-center gap-2 border-l-[3px] border-l-zinc-300">
              <CircleNotchIcon size={16} weight="bold" className="animate-spin text-zinc-400 shrink-0" aria-hidden="true" />
              <span className="text-[10px] text-zinc-500 font-medium leading-tight">
                ◌ Locating CI run… stages appear once the run is found (~30–60s after dispatch)
              </span>
            </div>
          )}

          {/* Live push with a bound run — job matrix */}
          {livePush && livePush.externalRunId != null && (
            <div className="mb-4 border border-sky-200 bg-sky-50 rounded p-3 overflow-hidden shadow-sm relative">
              <div className="absolute left-0 top-0 bottom-0 w-1 bg-sky-400 z-10" />
              <div className="flex justify-between items-center mb-3 ml-2">
                <span className="text-xs font-bold text-sky-800 font-mono">
                  {livePush.finalVersion ?? `${livePush.requestedBump} bump`} push{' '}
                  <span className="animate-pulse motion-reduce:animate-none">●</span>
                </span>
                <span className="flex items-center gap-2">
                  {livePush.runUrl && (
                    <a
                      href={livePush.runUrl}
                      target="_blank"
                      rel="noreferrer"
                      className="text-[10px] text-sky-700 font-bold hover:underline cursor-pointer"
                    >
                      CI run ↗
                    </a>
                  )}
                  {canDispatch && (
                    <button
                      type="button"
                      onClick={async () => {
                        if (
                          !(await confirm({
                            title: 'Cancel this push?',
                            description:
                              'Cancels the GitHub CI run (best-effort) and marks the push failed, unblocking new OTA dispatches.',
                            variant: 'danger',
                          }))
                        )
                          return;
                        try {
                          await cancelOtaPush(livePush.id);
                          toast.success('Push cancelled');
                          onChanged();
                        } catch (e) {
                          toast.error(errMsg(e, 'cancel failed'));
                        }
                      }}
                      className="text-[10px] bg-sky-100 text-sky-800 px-1.5 py-0.5 rounded font-bold hover:bg-sky-200 cursor-pointer"
                    >
                      Cancel
                    </button>
                  )}
                </span>
              </div>
              <JobMatrix pushId={livePush.id} live />
            </div>
          )}

          {/* Push form */}
          <div className="flex flex-col gap-2 bg-zinc-50 p-3 rounded border border-zinc-100">
            <div className="flex items-center gap-2">
              <select
                value={bump}
                onChange={(e) => setBump(e.target.value as typeof bump)}
                disabled={!!pushDisabledReason}
                aria-label="Version bump"
                className="flex-1 bg-white border border-zinc-200 text-zinc-800 text-[11px] rounded px-2 py-2 outline-none font-medium shadow-sm transition-all focus:ring-2 focus:ring-violet-200 focus:border-violet-400 disabled:opacity-60"
              >
                <option value="patch">Patch bump (auto)</option>
                <option value="minor">Minor bump</option>
                <option value="major">Major bump</option>
              </select>
              <select
                value={runner}
                onChange={(e) => setRunner(e.target.value)}
                disabled={!!pushDisabledReason}
                aria-label="CI runner pool"
                className="w-24 bg-white border border-zinc-200 text-zinc-500 font-mono text-[10px] rounded px-2 py-2 outline-none shadow-sm disabled:opacity-60"
              >
                {OTA_RUNNER_POOLS.map((rn) => (
                  <option key={rn} value={rn}>
                    {rn}
                  </option>
                ))}
              </select>
            </div>
            <label className="flex items-center gap-2 pl-1 py-1 cursor-pointer">
              <input
                type="checkbox"
                checked={notifySlack}
                onChange={(e) => setNotifySlack(e.target.checked)}
                disabled={!!pushDisabledReason}
                className="rounded border-zinc-300 accent-violet-600 w-3 h-3 cursor-pointer"
              />
              <span className="text-[10px] text-zinc-600 font-medium">Notify #releases Slack</span>
            </label>

            {activePush ? (
              <button
                type="button"
                disabled
                title={pushDisabledReason ?? undefined}
                className="w-full py-2 bg-zinc-100 text-zinc-400 border border-zinc-200 rounded font-bold text-xs flex justify-center items-center gap-2 cursor-not-allowed"
              >
                <LockKeyIcon size={13} weight="bold" aria-hidden="true" /> Queue Locked
              </button>
            ) : (
              <button
                type="button"
                disabled={!!pushDisabledReason || dispatchMut.isPending}
                title={pushDisabledReason ?? undefined}
                onClick={() => dispatchMut.mutate()}
                className="w-full py-2 bg-zinc-900 text-white rounded font-bold text-xs flex justify-center items-center gap-2 enabled:hover:bg-zinc-800 transition-all shadow-sm disabled:bg-zinc-100 disabled:text-zinc-400 disabled:border disabled:border-zinc-200 cursor-pointer disabled:cursor-not-allowed"
              >
                <UploadSimpleIcon size={13} weight="bold" aria-hidden="true" />
                {dispatchMut.isPending ? 'Dispatching…' : 'Compile & Push Bundle'}
              </button>
            )}

            {pushDisabledReason && !activePush && (
              <span className="text-[10px] text-zinc-500">{pushDisabledReason}</span>
            )}
            {sourceRef && (
              <span
                className="bg-zinc-100 text-zinc-600 font-mono text-[9px] px-1.5 py-0.5 rounded self-start mt-1 border border-zinc-200 inline-flex items-center gap-1"
                title={`Bundles build from branch: ${sourceRef}`}
              >
                <GitBranchIcon size={10} aria-hidden="true" /> tgt: {sourceRef}
              </span>
            )}
          </div>
        </div>

        {/* 4. Push history */}
        {myPushes.length > 0 && (
          <div className="border-t border-dashed border-zinc-200 pt-4 pb-1">
            <button
              type="button"
              onClick={() => setHistoryOpen((o) => !o)}
              aria-expanded={historyOpen}
              className={cn(eyebrowCls, 'mb-1 flex items-center gap-1.5 cursor-pointer hover:text-zinc-700 transition-colors')}
            >
              {historyOpen ? (
                <CaretDownIcon size={10} weight="bold" aria-hidden="true" />
              ) : (
                <CaretRightIcon size={10} weight="bold" aria-hidden="true" />
              )}
              Push History · {myPushes.length}
            </button>
            {historyOpen && (
            <div className="flex flex-col gap-2 mt-2">
              {myPushes.map((p) => {
                const active = ['DISPATCHED', 'RUNNING'].includes(p.status);
                const expandable = p.externalRunId != null || p.packageVersion != null || p.commitSha != null;
                const isOpen = expandable && (historyToggles[p.id] ?? p.status === 'FAILED');
                return (
                  <div
                    key={p.id}
                    className={cn(
                      'bg-white border border-zinc-200 border-l-2 rounded text-[10px] shadow-sm flex flex-col',
                      PUSH_EDGE[p.status],
                    )}
                  >
                    <button
                      type="button"
                      onClick={() => expandable && setHistoryToggles((t) => ({ ...t, [p.id]: !isOpen }))}
                      className={cn(
                        'p-2 flex items-center gap-2 whitespace-nowrap overflow-hidden text-left w-full',
                        expandable ? 'cursor-pointer hover:bg-zinc-50' : 'cursor-default',
                        isOpen && 'border-b border-zinc-100',
                      )}
                    >
                      <span className="text-zinc-500 shrink-0" title={fullStamp(p.dispatchedAt)}>{shortStamp(p.dispatchedAt)}</span>
                      <span className={cn('px-1 py-0.5 rounded font-bold uppercase text-[8px] shrink-0', PUSH_BADGE[p.status])}>
                        {p.status}
                      </span>
                      <span className="font-mono text-zinc-800 shrink-0">
                        {p.finalVersion ?? (p.packageVersion != null ? `pkg v${p.packageVersion}` : '—')}
                      </span>
                      <span className="text-zinc-300">·</span>
                      <span className="text-zinc-600 shrink-0">{p.requestedBump}</span>
                      <span className="text-zinc-300">·</span>
                      <span className="font-mono text-zinc-600 truncate">{p.sourceRef}</span>
                      <span className="text-zinc-300">·</span>
                      <span className="text-zinc-500 truncate min-w-0">by {p.dispatchedBy}</span>
                      {p.runUrl && (
                        <>
                          <span className="text-zinc-300 shrink-0">·</span>
                          <a
                            href={p.runUrl}
                            target="_blank"
                            rel="noreferrer"
                            onClick={(e) => e.stopPropagation()}
                            className="text-blue-600 font-bold hover:underline shrink-0 cursor-pointer"
                          >
                            CI run ↗
                          </a>
                        </>
                      )}
                    </button>
                    {p.status === 'FAILED' && p.error && (
                      <div className={cn('p-2 bg-red-50 text-red-700 italic', isOpen ? 'border-b border-red-100' : 'rounded-b')}>
                        {p.error}
                      </div>
                    )}
                    {isOpen && (
                      <div className="p-2 bg-zinc-50 rounded-b">
                        {p.status === 'DISPATCHED' && p.externalRunId == null && (
                          <div className="flex items-center gap-2 text-[10px] text-zinc-500 mb-1">
                            <CircleNotchIcon size={13} weight="bold" className="animate-spin text-zinc-400" aria-hidden="true" />
                            Locating CI run… stages appear once the run is found.
                          </div>
                        )}
                        {p.externalRunId != null && <JobMatrix pushId={p.id} live={active} />}
                        <div className="flex flex-wrap items-center gap-x-3 gap-y-1 mt-1.5 pt-1.5 border-t border-zinc-200 text-zinc-400 font-mono">
                          {p.packageVersion != null && <span>pkg v{p.packageVersion}</span>}
                          {p.commitSha && <span>commit {p.commitSha.slice(0, 9)}</span>}
                          {p.resolvedVia && <span className="font-sans">resolved via {p.resolvedVia}</span>}
                        </div>
                        {/* Push landed without a package id — attach it manually. */}
                        {p.status === 'BUNDLE_PUSHED' &&
                          p.packageVersion == null &&
                          canDispatch &&
                          (attachFor === p.id ? (
                            <span className="inline-flex items-center gap-1 mt-1.5">
                              <input
                                type="number"
                                placeholder="pkg version"
                                value={attachVersion}
                                onChange={(e) => setAttachVersion(e.target.value)}
                                className="w-24 rounded border border-zinc-300 px-1.5 py-0.5 text-xs bg-white"
                              />
                              <Button
                                size="sm"
                                onClick={async () => {
                                  try {
                                    await attachOtaPackage(p.id, Number(attachVersion));
                                    toast.success('Package attached');
                                    setAttachFor(null);
                                    onChanged();
                                  } catch (e) {
                                    toast.error(errMsg(e, 'attach failed'));
                                  }
                                }}
                              >
                                Attach
                              </Button>
                              <Button size="sm" variant="ghost" onClick={() => setAttachFor(null)}>
                                ✕
                              </Button>
                            </span>
                          ) : (
                            <Button size="sm" variant="outline" className="mt-1.5" onClick={() => setAttachFor(p.id)}>
                              Attach package
                            </Button>
                          ))}
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
            )}
          </div>
        )}
      </div>

      {branchPickerOpen && (
        <OtaBranchPicker
          releaseId={releaseId}
          onClose={() => setBranchPickerOpen(false)}
          onAdopted={() => {
            void qc.invalidateQueries({ queryKey: ['release', releaseId] });
            void qc.invalidateQueries({ queryKey: ['mobile-release-prov', releaseId] });
            onChanged();
          }}
        />
      )}

      {editRelease && (
        <OtaReleaseComposer
          appRef={ref}
          appName={appName}
          platform={platform}
          initial={editRelease.pkg}
          pkgs={eligiblePkgs.length > 0 ? eligiblePkgs : [editRelease.pkg]}
          nativeVersion={nativeVersion}
          editing={{ releaseId: editRelease.releaseId, lockedDims: editRelease.lockedDims }}
          firstRelease={false}
          firstReleaseUnknown={false}
          ongoing={allOngoing}
          maxKnownPkg={maxKnownPkg}
          onClose={() => setEditRelease(null)}
          onSubmit={() => undefined}
          onSaved={() => {
            setEditRelease(null);
            invalidate();
          }}
        />
      )}

      {composerFor && (
        <OtaReleaseComposer
          appRef={ref}
          appName={appName}
          platform={platform}
          initial={composerFor}
          pkgs={eligiblePkgs.length > 0 ? eligiblePkgs : [composerFor]}
          nativeVersion={nativeVersion}
          nudgeVersionTarget={buildSuperseded}
          firstRelease={hasView && !releasesQ.isError && releases.length === 0}
          firstReleaseUnknown={releasesQ.isError}
          ongoing={allOngoing}
          maxKnownPkg={maxKnownPkg}
          onClose={() => setComposerFor(null)}
          onSubmit={(pkg, req) => submitRelease(pkg, req)}
        />
      )}

      {conflict && (
        <OtaSupersedeDialog
          appRef={ref}
          groupId={groupId}
          conflict={conflict.ongoing}
          releases={releases}
          onClose={() => setConflict(null)}
          onResolved={() => submitRelease(conflict.pkg, conflict.req)}
        />
      )}
    </div>
  );
}

/** CI job matrix in the mockup's mono-terminal style — polls while live. */
export function JobMatrix({ pushId, live, defaultOpen = true }: { pushId: string; live: boolean; defaultOpen?: boolean }) {
  const q = useQuery({
    queryKey: ['mobile-ota-push-jobs', 'v2', pushId],
    queryFn: () => fetchOtaPushJobs(pushId),
    refetchInterval: live ? 10_000 : false,
    staleTime: live ? 0 : 60_000,
    retry: false,
  });
  const [jobToggles, setJobToggles] = useState<Record<string, boolean>>({});
  if (q.isLoading)
    return (
      <div className="flex items-center gap-2 pl-4 ml-2 text-[10px] text-zinc-500 font-medium">
        <CircleNotchIcon size={13} weight="bold" className="animate-spin text-zinc-400" aria-hidden="true" />
        Loading CI jobs…
      </div>
    );
  if (!q.data?.jobs?.length) return null;
  type Tone = 'ok' | 'run' | 'wait' | 'skip' | 'fail';
  const toneOf = (x: { status: string; conclusion?: string }): { tone: Tone; label: string } => {
    if (x.status !== 'completed')
      return x.status === 'queued' || x.status === 'pending'
        ? { tone: 'wait', label: 'queued' }
        : { tone: 'run', label: 'running' };
    if (x.conclusion === 'success') return { tone: 'ok', label: 'passed' };
    if (x.conclusion === 'skipped') return { tone: 'skip', label: 'skipped' };
    return { tone: 'fail', label: x.conclusion ?? 'failed' };
  };
  const glyph: Record<Tone, { ch: string; cls: string }> = {
    ok: { ch: '●', cls: 'text-emerald-500' },
    run: { ch: '○', cls: 'text-sky-500 animate-pulse motion-reduce:animate-none' },
    wait: { ch: '○', cls: 'text-zinc-300' },
    skip: { ch: '○', cls: 'text-zinc-300' },
    fail: { ch: '✗', cls: 'text-red-500' },
  };
  const durationOf = (x: { startedAt?: string; completedAt?: string }): string | null => {
    if (!x.startedAt) return null;
    const end = x.completedAt ? new Date(x.completedAt).getTime() : Date.now();
    const secs = Math.max(0, Math.round((end - new Date(x.startedAt).getTime()) / 1000));
    return secs < 90 ? `${secs}s` : `${Math.round(secs / 60)}m`;
  };
  return (
    <div className="pl-4 border-l-2 border-zinc-300 ml-2 text-[10px] font-mono text-zinc-600 flex flex-col gap-1.5">
      {q.data.jobs.map((j) => {
        const jt = toneOf(j);
        const steps = j.steps ?? [];
        const failedStep = steps.find((st) => st.conclusion === 'failure');
        const interesting = j.status !== 'completed' || (j.conclusion !== 'success' && j.conclusion !== 'skipped');
        const open = jobToggles[j.name] ?? (defaultOpen && interesting);
        return (
          <div key={j.name} className="flex flex-col gap-1">
            <button
              type="button"
              onClick={() => steps.length > 0 && setJobToggles((t) => ({ ...t, [j.name]: !open }))}
              className={cn(
                'flex gap-2 items-center text-left',
                jt.tone === 'wait' || jt.tone === 'skip' ? 'opacity-50' : '',
                steps.length > 0 ? 'cursor-pointer' : 'cursor-default',
              )}
            >
              <span className={glyph[jt.tone].cls}>{glyph[jt.tone].ch}</span>
              <span
                className={cn(
                  jt.tone === 'run' && 'font-bold text-sky-800',
                  jt.tone === 'fail' && 'font-bold text-red-800',
                  jt.tone === 'ok' && 'text-zinc-800',
                )}
              >
                {j.name}
              </span>
              <span className={cn(jt.tone === 'run' && 'text-sky-600', jt.tone === 'fail' && 'text-red-600', jt.tone === 'ok' && 'text-zinc-400')}>
                {jt.tone === 'run' && durationOf(j) ? `running ${durationOf(j)}` : (durationOf(j) ?? jt.label)}
                {jt.tone === 'fail' && failedStep ? ` · "${failedStep.name}"` : ''}
              </span>
            </button>
            {open && steps.length > 0 && (
              <div className="flex flex-col gap-1 pl-4">
                {steps.map((st, i) => {
                  const stt = toneOf(st);
                  return (
                    <div
                      key={`${i}-${st.name}`}
                      className={cn('flex gap-2 items-center', (stt.tone === 'wait' || stt.tone === 'skip') && 'opacity-50')}
                    >
                      <span className={cn(glyph[stt.tone].cls, 'text-[8px]')}>{glyph[stt.tone].ch}</span>
                      <span className={cn('truncate', stt.tone === 'fail' && 'font-bold text-red-800')}>{st.name}</span>
                      <span className="text-zinc-400">{durationOf(st) ?? (stt.tone === 'skip' ? 'skipped' : '')}</span>
                    </div>
                  );
                })}
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

/** 7-day adoption metrics — honest dashed empty when analytics is absent. */

/** Inline active-users chip for one package version — same cache family as
 * AdoptionCard; renders nothing when Chime has no record (rows stay clean). */
function AdoptionInline({
  appRef,
  pkg,
  os,
  version,
}: {
  appRef: string;
  pkg: string | null;
  os: 'android' | 'ios';
  version: string | null;
}) {
  const q = useQuery({
    queryKey: ['chime-adoption', appRef, pkg, version, os],
    queryFn: () => chimeApi.adoption(appRef, { pkg: pkg!, version: version!, os }),
    enabled: !!pkg && !!version,
    retry: false,
    staleTime: 60_000,
  });
  const a = q.data?.data;
  if (!a || a.recorded === false || a.active_users == null) return null;
  const windowLabel = a.window_hours % 24 === 0 ? `${a.window_hours / 24} days` : `${a.window_hours}h`;
  return (
    <span
      className="font-mono text-[9px] bg-violet-50 border border-violet-200 text-violet-700 px-1.5 py-px rounded whitespace-nowrap"
      title={`~${a.active_users.toLocaleString()} active users on v${version} in the last ${windowLabel} (Chime HLL, ~1%)`}
    >
      ~{a.active_users.toLocaleString()} users
    </span>
  );
}
