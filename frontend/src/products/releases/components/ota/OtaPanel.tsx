// Per-(app, platform) OTA card (docs/OTA_MOBILE_RELEASE_INTEGRATION.md Part 2).
// Mounted on ReleaseGroupDetail (one per capable app) and ReleaseSummary (one).
// Release state is ALWAYS read live from the airborne BFF — nothing cached in
// SCC; push rows/links come from the group OTA endpoint. Release verbs are
// gated by the caller's per-ref airborne grants (/airborne/access), NOT by
// PermissionsContext (its isAdmin short-circuit spans products).
import { useMemo, useState, type ReactNode } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Copy, ExternalLink, GitBranch, Loader2, Package, RefreshCw, Rocket, Upload } from 'lucide-react';
import { Link } from 'react-router-dom';
import { cn } from '../../../../lib/utils';
import { BrandLogo } from '../BrandLogo';
import { mobileApi } from '../../api';
import {
  Dialog,
  DialogBody,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '../../../../shared/ui/dialog';
import { Button } from '../../../../shared/ui/button';
import { Spinner } from '../../../../shared/ui/spinner';
import { useConfirm } from '../../../../shared/ui/confirm-dialog';
import {
  concludeOtaRelease,
  discardOtaRelease,
  fetchOtaAdoption,
  fetchOtaDimensions,
  fetchOtaRelease,
  updateOtaRelease,
  fetchOtaFailures,
  fetchOtaPackageDetail,
  fetchOtaPackages,
  fetchOtaReleases,
  rampOtaRelease,
} from '../../../airborne-ota/api';
import { useOtaAccess } from '../../../airborne-ota/hooks';
import type { OtaRelease } from '../../../airborne-ota/types';
import {
  abandonOtaPush,
  adoptOtaBranch,
  attachOtaPackage,
  dispatchGroupOta,
  fetchOtaPushJobs,
  releaseOtaPackage,
  releaseOtaPush,
  resolveOtaProvenance,
  useOtaProvenance,
  OTA_RUNNER_POOLS,
  type OtaLinkRow,
  type OtaOngoingConflict,
  type OtaProvPkg,
  type OtaPushRow,
  type OtaRelation,
  type OtaRunJob,
  type OtaReleaseReq,
} from '../../otaApi';

// ── helpers ─────────────────────────────────────────────────────────

export const statusOf = (r: OtaRelease): string =>
  String(r.experiment?.status ?? '').toUpperCase();

export const trafficOf = (r: OtaRelease): number | undefined => r.experiment?.traffic_percentage;

export const pkgVersionOf = (r: OtaRelease): number | undefined => {
  const v = r.experiment?.package_version ?? r.package?.version;
  return typeof v === 'number' ? v : undefined;
};

// The human version string ("0.0.155") from the release's package tag.
export const pkgTagOf = (r: OtaRelease): string | undefined => {
  const t = r.package?.tag;
  return typeof t === 'string' && t ? t : undefined;
};

// The airborne package NAME on the release (when upstream provides one) —
// richer identity than "pkg vN" alone.
export const pkgNameOf = (r: OtaRelease): string | undefined => {
  const n = r.package?.name;
  return typeof n === 'string' && n.trim() ? n : undefined;
};

export const dimsOf = (r: OtaRelease): Record<string, unknown> =>
  (r as { dimensions?: Record<string, unknown> }).dimensions ?? {};

export const dimsLabel = (dims: Record<string, unknown> | undefined): string => {
  const entries = Object.entries(dims ?? {});
  if (entries.length === 0) return 'all devices';
  return entries.map(([k, v]) => `${k}: ${String(v)}`).join(' · ');
};

export const PUSH_CHIP: Record<OtaPushRow['status'], string> = {
  DISPATCHED: 'bg-sky-50 text-sky-700 border-sky-200',
  RUNNING: 'bg-amber-50 text-amber-700 border-amber-200',
  BUNDLE_PUSHED: 'bg-emerald-50 text-emerald-700 border-emerald-200',
  FAILED: 'bg-red-50 text-red-700 border-red-200',
};

export const REL_CHIP: Record<string, string> = {
  CREATED: 'bg-sky-50 text-sky-700 border-sky-200',
  INPROGRESS: 'bg-violet-50 text-violet-700 border-violet-200',
  CONCLUDED: 'bg-emerald-50 text-emerald-700 border-emerald-200',
  DISCARDED: 'bg-zinc-100 text-zinc-600 border-zinc-200',
};

export function Chip({ label, cls }: { label: string; cls: string }) {
  return (
    <span
      className={`inline-flex items-center rounded-full border px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide ${cls}`}
    >
      {label}
    </span>
  );
}

function SectionLabel({ children }: { children: ReactNode }) {
  return (
    <div className="text-[10px] font-bold uppercase tracking-wider text-zinc-600">{children}</div>
  );
}

// Airborne release ids are long superposition ids — show a copyable mono chip
// so the operator always knows exactly WHICH release a verb will act on.
export function ReleaseId({ id }: { id: string }) {
  return (
    <button
      onClick={() => {
        void navigator.clipboard.writeText(id);
        toast.success('Release id copied');
      }}
      title={`${id} — click to copy`}
      className="inline-flex items-center gap-1 rounded border border-zinc-200 bg-zinc-50 px-1.5 py-0.5 text-[11px] font-mono text-zinc-600 hover:border-zinc-300 hover:text-zinc-900"
    >
      {id.length > 14 ? `${id.slice(0, 6)}…${id.slice(-6)}` : id}
      <Copy className="h-3 w-3 text-zinc-600" />
    </button>
  );
}

// Evidence-based provenance badge (doc §11b): git ancestry first, SCC's own
// push/link log as fallback when the ledger has no answer.
export function ProvenanceBadge({
  prov,
  push,
  link,
}: {
  prov?: OtaProvPkg;
  push?: OtaPushRow;
  link?: OtaLinkRow;
}) {
  const cls = (c: string) =>
    `inline-flex items-center rounded-full border px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide ${c}`;
  const rel = prov?.relation;
  if (rel === 'identical')
    return (
      <span
        className={cls('border-emerald-200 bg-emerald-50 text-emerald-700')}
        title={`Built from exactly this build's commit${prov?.commitSha ? ` (${prov.commitSha.slice(0, 9)})` : ''}`}
      >
        this build · exact
      </span>
    );
  if (rel === 'ahead')
    return (
      <span
        className={cls('border-emerald-200 bg-emerald-50 text-emerald-700')}
        title={`Built from this build's commit plus ${prov?.aheadBy ?? '?'} newer commit(s)${prov?.commitSha ? ` (${prov.commitSha.slice(0, 9)})` : ''}`}
      >
        this branch · +{prov?.aheadBy ?? '?'}
      </span>
    );
  if (rel === 'behind')
    return (
      <span
        className={cls('border-amber-200 bg-amber-50 text-amber-800')}
        title={`Built from an ancestor ${prov?.behindBy ?? '?'} commit(s) BEFORE this build's commit`}
      >
        older than build · −{prov?.behindBy ?? '?'}
      </span>
    );
  if (rel === 'diverged')
    return (
      <span
        className={cls('border-zinc-200 bg-zinc-50 text-zinc-600')}
        title="Different line of development — provably not this build's lineage"
      >
        different lineage
      </span>
    );
  if (push)
    return (
      <span
        className={cls('border-emerald-200 bg-emerald-50 text-emerald-700')}
        title={`SCC pushed this from ${push.sourceRef}${push.commitSha ? ` @ ${push.commitSha}` : ''} by ${push.dispatchedBy}`}
      >
        this build{push.commitSha ? ` · ${push.commitSha.slice(0, 7)}` : ''}
      </span>
    );
  if (link)
    return (
      <span
        className={cls('border-violet-200 bg-violet-50 text-violet-700')}
        title={`Created via SCC from ${link.sourceRef} (group ${link.groupLabel || link.groupId})`}
      >
        from {link.groupLabel || `group ${link.groupId.slice(0, 8)}`}
      </span>
    );
  return (
    <span
      className={cls('border-zinc-200 bg-zinc-50 text-zinc-600')}
      title="No git tag or SCC record identifies this package's source commit"
    >
      unknown provenance
    </span>
  );
}

/** A package the current build may release: proven lineage, or an SCC push. */
export interface ReleasablePkg {
  version: number;
  tag?: string;
  pushId?: string;
  relation?: OtaRelation;
}

// §11b branch picker — search-first: type/search any branch, adopt it, and
// the server verifies containment of the build commit. Not contained (e.g.
// squash-merge rewrote the sha) ⇒ explicit warning + "Adopt anyway".
export function OtaBranchPicker({
  groupId,
  appRef,
  onClose,
  onAdopted,
}: {
  groupId: string;
  appRef: string;
  onClose: () => void;
  onAdopted: () => void;
}) {
  const [search, setSearch] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [mismatch, setMismatch] = useState<{ branch: string; relation: string } | null>(null);
  // Anchor only (empty package list) — no branch scanning on open.
  const anchorQ = useQuery({
    queryKey: ['mobile-ota-anchor', groupId, appRef],
    queryFn: () => resolveOtaProvenance(groupId, appRef, []),
    retry: false,
    staleTime: 5 * 60_000,
  });
  const branchesQ = useQuery({
    queryKey: ['mobile-ota-branch-search', search],
    queryFn: () => mobileApi.listBranches(search || undefined),
    retry: false,
    staleTime: 30_000,
  });
  const branches = branchesQ.data ?? [];

  const adopt = async (branch: string, ack = false) => {
    setBusy(branch);
    try {
      await adoptOtaBranch(groupId, appRef, branch, ack);
      toast.success(`Source branch set to ${branch}`);
      onAdopted();
      onClose();
    } catch (e) {
      const data = respData(e) as { code?: string; relation?: string } | undefined;
      if (data?.code === 'BRANCH_NOT_CONTAINING') {
        setMismatch({ branch, relation: data.relation ?? 'diverged' });
      } else {
        toast.error(errMsg(e, 'could not adopt branch'));
      }
      setBusy(null);
    }
  };

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent size="md">
        <DialogHeader>
          <DialogTitle>Pick the source branch</DialogTitle>
        </DialogHeader>
        <DialogBody className="space-y-2">
          <p className="text-xs text-zinc-600">
            Search any branch; on adopt, SCC verifies it contains this build's commit
            {anchorQ.data?.anchor.commitSha && (
              <span className="font-mono text-zinc-600"> {anchorQ.data.anchor.commitSha.slice(0, 9)}</span>
            )}
            . A branch that doesn't contain it gets a warning, not a silent pass.
          </p>
          <input
            value={search}
            onChange={(e) => {
              setSearch(e.target.value);
              setMismatch(null);
            }}
            placeholder="Search branches… (e.g. main, release/…)"
            autoFocus
            className="w-full rounded border border-zinc-300 px-2 py-1.5 text-sm"
          />
          {mismatch && (
            <div className="rounded border border-amber-300 bg-amber-50 px-3 py-2 text-xs text-amber-900">
              <b>{mismatch.branch}</b> does not contain this build's commit ({mismatch.relation}).
              This is normal after a squash-merge — the original sha survives on no branch — but it
              can also mean the wrong branch. Adopt only if you know this is where the build's code
              lives.
              <div className="mt-1.5">
                <Button
                  size="sm"
                  variant="danger"
                  disabled={busy !== null}
                  onClick={() => adopt(mismatch.branch, true)}
                >
                  {busy === mismatch.branch ? 'Adopting…' : `Adopt ${mismatch.branch} anyway`}
                </Button>
              </div>
            </div>
          )}
          {branchesQ.isLoading ? (
            <p className="text-xs text-zinc-600">Loading branches…</p>
          ) : branches.length === 0 ? (
            <p className="text-xs text-zinc-600">No branches match.</p>
          ) : (
            <div className="max-h-64 overflow-y-auto divide-y divide-zinc-100 border border-zinc-200 rounded">
              {branches.slice(0, 30).map((b) => (
                <div key={b.name} className="flex items-center gap-2 px-3 py-1.5">
                  <span className="text-xs font-mono text-zinc-800 truncate">{b.name}</span>
                  <span className="ml-auto" />
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={busy !== null}
                    onClick={() => adopt(b.name)}
                  >
                    {busy === b.name ? 'Verifying…' : 'Adopt'}
                  </Button>
                </div>
              ))}
            </div>
          )}
        </DialogBody>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

export interface OtaPanelProps {
  groupId: string;
  appName: string;
  platform: string;
  airborneAppRef: string;
  /** null ⇒ store-sync row: operate-only, push hidden. */
  sourceRef: string | null;
  pushEligible: boolean;
  ineligibleReason?: string;
  pushes: OtaPushRow[];
  links: OtaLinkRow[];
  activePush?: { groupId: string; dispatchedBy: string } | null;
  canDispatch: boolean;
  /** Native build version (e.g. "3.3.17") — seeds the R7 version-dimension rule. */
  nativeVersion?: string | null;
  /** True when a page-level "Set source branch" banner already exists (group
      page) — suppresses the card's own duplicate prompt. */
  hideBranchPrompt?: boolean;
  /** True when the card is embedded under a row that already shows the app
      logo + name (group-page Details expansion) — drops the duplicate. */
  hideIdentity?: boolean;
  /** Build was superseded on the store — composer pre-seeds version
      targeting so straggler hotfixes stay scoped to this build. */
  buildSuperseded?: boolean;
  onChanged: () => void;
}

export function OtaPanel(props: OtaPanelProps) {
  const {
    groupId,
    appName,
    platform,
    airborneAppRef: ref,
    sourceRef,
    pushEligible,
    ineligibleReason,
    pushes,
    links,
    activePush,
    canDispatch,
    nativeVersion,
    hideBranchPrompt,
    hideIdentity,
    buildSuperseded,
    onChanged,
  } = props;
  const qc = useQueryClient();
  const confirm = useConfirm();
  const access = useOtaAccess();
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

  // Ongoing releases can reference packages older than the 8-item shelf page
  // (e.g. pkg v1); fetch their detail once for the version string + tag —
  // which also lets the provenance resolver give them a real verdict.
  const missingTagVersions = useMemo(() => {
    const onShelf = new Set(
      (packagesQ.data?.data ?? [])
        .map((pk) => pk.version)
        .filter((v): v is number => typeof v === 'number'),
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
  const provOf = (v?: number): OtaProvPkg | undefined =>
    v == null ? undefined : provQ.data?.packages.find((p) => p.packageVersion === v);

  // A release belongs to THIS build when git proves its package's commit is
  // the build's commit or a descendant of it — or when SCC's own link row
  // says this group created it (covers unknown-provenance edge).
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
  // Foreign visibility is status-sensitive: INPROGRESS = serving devices NOW
  // (must stay visible); CREATED = inert — the create-time preflight/supersede
  // dialog owns it, so the card doesn't nag about it.
  const foreignServing = foreignOngoing.filter((r) => statusOf(r) === 'INPROGRESS');
  const foreignInert = foreignOngoing.filter((r) => statusOf(r) !== 'INPROGRESS');
  const maxKnownPkg = Math.max(0, ...releases.map((r) => pkgVersionOf(r) ?? 0));

  // Releasable = proven lineage (identical/ahead) or an SCC push of this
  // group. Everything else is context, collapsed away.
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
        .map((pk) => ({
          ...pk,
          pushId: pushFor(pk.version)?.id,
          relation: provOf(pk.version)?.relation,
        }))
        .sort((a, b) => b.version - a.version),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [shelfPkgs, provQ.data, myPushes],
  );
  const foreignPkgs = shelfPkgs.filter((pk) => !isEligible(pk.version));
  // Version string for a release: its own package.tag, else the shelf's.
  const tagFor = (r: OtaRelease): string | undefined => {
    const v = pkgVersionOf(r);
    return (
      pkgTagOf(r) ??
      shelfPkgs.find((pk) => pk.version === v)?.tag ??
      (v != null ? pkgTagsQ.data?.[v] : undefined)
    );
  };

  const [composerFor, setComposerFor] = useState<ReleasablePkg | null>(null);
  const [editRelease, setEditRelease] = useState<{ releaseId: string; pkg: ReleasablePkg; lockedDims: Record<string, unknown> } | null>(null);
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
  // Event-log expand state per push row; unset = default (latest open).
  const [pushToggles, setPushToggles] = useState<Record<string, boolean>>({});
  const [branchPickerOpen, setBranchPickerOpen] = useState(false);

  const invalidate = () => {
    qc.invalidateQueries({ queryKey: ['mobile-ota-releases', ref] });
    onChanged();
  };

  const dispatchMut = useMutation({
    mutationFn: () =>
      dispatchGroupOta(groupId, {
        versionBump: bump,
        apps: [appName],
        platforms: [platform],
        notifySlack,
        runner,
      }),
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

  const pushDisabledReason = !sourceRef
    ? 'Imported from store — no source branch to build from'
    : !pushEligible
      ? (ineligibleReason ?? 'Not eligible')
      : activePush
        ? `An OTA push is active (group ${activePush.groupId}, by ${activePush.dispatchedBy})`
        : !canDispatch
          ? 'Requires MOBILE_DISPATCH'
          : null;

  return (
    <div className="rounded-lg border border-zinc-200 bg-white border-l-[3px] border-l-violet-300">
      <div className="flex items-center justify-between px-4 py-3 border-b border-zinc-100 bg-zinc-50 rounded-t-lg">
        <div className="flex items-center gap-2 min-w-0">
          {!hideIdentity && (
            <>
              <BrandLogo brand={appName} size="sm" />
              <span className="text-sm font-semibold text-zinc-900 truncate">{appName}</span>
              <span className="text-xs text-zinc-600">{platform}</span>
            </>
          )}
          <span className="inline-flex items-center gap-1 rounded-full border border-violet-200 bg-violet-50 px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide text-violet-700">
            <Rocket className="h-3 w-3" /> OTA
          </span>
          <button
            onClick={() => {
              void navigator.clipboard.writeText(ref);
              toast.success('App ref copied');
            }}
            title={`${ref} — click to copy`}
            className="text-[11px] text-zinc-600 font-mono truncate hidden sm:inline hover:text-zinc-600"
          >
            {ref}
          </button>
        </div>
        <button
          onClick={() => {
            releasesQ.refetch();
            onChanged();
          }}
          className="text-zinc-600 hover:text-zinc-700"
          title="Refresh"
        >
          <RefreshCw className={`h-3.5 w-3.5 ${releasesQ.isFetching ? 'animate-spin' : ''}`} />
        </button>
      </div>

      <div className="p-4 space-y-4">
        {/* Store-sync rows: the missing source branch is a build-level fact.
            On the group page the page-level banner owns this prompt; the
            card shows it only when mounted standalone (release summary). */}
        {!sourceRef && !hideBranchPrompt && (
          <div className="flex items-center gap-2 rounded-md border border-sky-200 bg-sky-50/60 px-3 py-2">
            <span className="text-[11px] text-sky-900">
              Imported from store — no source branch known
              {provQ.data?.anchor?.commitSha && (
                <>
                  {' '}
                  (build commit{' '}
                  <span className="font-mono">{provQ.data.anchor.commitSha.slice(0, 9)}</span>{' '}
                  recovered)
                </>
              )}
              . Bundle pushes need a branch.
            </span>
            <span className="ml-auto" />
            {provQ.data?.anchor?.commitSha ? (
              <Button size="sm" variant="outline" onClick={() => setBranchPickerOpen(true)}>
                Set source branch
              </Button>
            ) : (
              <span className="text-[11px] text-sky-700">no anchor commit — branch cannot be verified</span>
            )}
          </div>
        )}

        {/* Ongoing releases (live) — this build's only */}
        <SectionLabel>Ongoing release · this build</SectionLabel>
        {!hasView ? (
          <p className="text-xs text-zinc-600">
            You don't have airborne access for this app — push status only.
          </p>
        ) : releasesQ.isError ? (
          <p className="text-xs text-zinc-600">Airborne unreachable — release state unavailable.</p>
        ) : releasesQ.isLoading ? (
          <div className="border border-dashed border-zinc-200 rounded-md px-3 py-2.5">
            <Spinner size="sm" label="Loading release state…" />
          </div>
        ) : ongoing.length === 0 ? (
          <p className="text-xs text-zinc-600 border border-dashed border-zinc-200 rounded-md px-3 py-2.5">
            No ongoing OTA release from this build.
          </p>
        ) : (
          <div className="space-y-2">
            {ongoing.map((r) => {
              const st = statusOf(r);
              const link = myLinks.find((l) => l.airborneReleaseId === r.id);
              const provenance = link
                ? link.groupId === groupId
                  ? `from this release · ${link.createdBy}`
                  : `from ${link.groupLabel || `group ${link.groupId.slice(0, 8)}`} · ${link.sourceRef} · ${link.createdBy}`
                : 'created outside SCC';
              const createdAt = r.created_at ? new Date(r.created_at).toLocaleString() : null;
              return (
                <div
                  key={r.id}
                  className={`rounded-md border p-3 ${st === 'INPROGRESS' ? 'border-violet-200 bg-violet-50/30' : 'border-sky-200 bg-sky-50/30'}`}
                >
                  <div className="flex items-center gap-2 flex-wrap">
                    <Chip label={st} cls={REL_CHIP[st] ?? 'bg-zinc-100 text-zinc-600 border-zinc-200'} />
                    {pkgVersionOf(r) != null && (
                      <span className="text-xs font-semibold font-mono text-zinc-800">
                        pkg v{pkgVersionOf(r)}
                      </span>
                    )}
                    {tagFor(r) && (
                      <span className="text-[11px] font-mono text-zinc-600">{tagFor(r)}</span>
                    )}
                    {pkgNameOf(r) && (
                      <span
                        className="text-[11px] font-mono text-zinc-600 truncate max-w-[220px]"
                        title={pkgNameOf(r)}
                      >
                        {pkgNameOf(r)}
                      </span>
                    )}
                    {r.id && <ReleaseId id={r.id} />}
                    {r.id && (
                      <Link
                        to={`/airborne/${encodeURIComponent(ref)}/releases/${encodeURIComponent(r.id)}`}
                        className="inline-flex items-center gap-1 text-[11px] text-violet-600 hover:underline"
                        title="Open in Airborne"
                      >
                        <ExternalLink className="h-3 w-3" />
                      </Link>
                    )}
                    {st === 'INPROGRESS' && (
                      <span className="ml-auto text-lg font-bold text-violet-700 tabular-nums">
                        {trafficOf(r) ?? 0}%
                      </span>
                    )}
                  </div>
                  <div className="flex items-center gap-2 flex-wrap mt-1.5 text-[11px] text-zinc-600">
                    <span>
                      targets <span className="text-zinc-700">{dimsLabel(dimsOf(r))}</span>
                    </span>
                    {createdAt && <span>· created {createdAt}</span>}
                    <span className="ml-auto text-zinc-600">{provenance}</span>
                  </div>
                  <OtaMetricsRow appRef={ref} releaseId={r.id} enabled={st === 'INPROGRESS'} />
                  <div className="flex items-center gap-2 mt-2">
                    {can('OTA_RELEASE_RAMP') &&
                      (rampFor === r.id ? (
                        <span className="inline-flex items-center gap-1">
                          <span className="text-[11px] text-zinc-600">{trafficOf(r) ?? 0}% →</span>
                          <input
                            type="number"
                            min={0}
                            max={50}
                            value={rampPct}
                            onChange={(e) => setRampPct(e.target.value)}
                            className="w-16 rounded border border-zinc-300 px-1.5 py-0.5 text-xs"
                          />
                          <Button
                            size="sm"
                            onClick={() => {
                              const n = Number(rampPct);
                              if (!Number.isFinite(n) || n < 0 || n > 50) {
                                toast.error('Traffic must be 0–50 (100% only via Conclude)');
                                return;
                              }
                              doRamp(r.id!, n, trafficOf(r));
                            }}
                          >
                            Set
                          </Button>
                          <Button size="sm" variant="ghost" onClick={() => setRampFor(null)}>
                            ✕
                          </Button>
                        </span>
                      ) : (
                        <Button size="sm" variant="outline" onClick={() => setRampFor(r.id!)}>
                          Ramp
                        </Button>
                      ))}
                    {st === 'INPROGRESS' && can('OTA_RELEASE_CONCLUDE') && (
                      <>
                        <Button size="sm" variant="outline" onClick={() => doConclude(r, false)}>
                          Conclude
                        </Button>
                        <Button size="sm" variant="outline" onClick={() => doConclude(r, true)}>
                          Revert
                        </Button>
                      </>
                    )}
                    {st === 'CREATED' && can('OTA_RELEASE_CREATE') && (
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() =>
                          r.id &&
                          setEditRelease({
                            releaseId: r.id,
                            pkg: {
                              version: pkgVersionOf(r) ?? 0,
                              tag: tagFor(r),
                            },
                            lockedDims: dimsOf(r),
                          })
                        }
                      >
                        Edit
                      </Button>
                    )}
                    {st === 'CREATED' && can('OTA_RELEASE_DISCARD') && (
                      <Button size="sm" variant="outline" onClick={() => doDiscard(r)}>
                        Discard
                      </Button>
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        )}

        {/* Foreign releases SERVING TRAFFIC — never hidden (devices are on
            them right now). Inert foreign releases live in the collapsed
            "not from this build" line; the supersede dialog owns them. */}
        {hasView && !releasesQ.isError && foreignServing.length > 0 && (
          <details className="rounded-md border border-amber-200/70 bg-amber-50/30 px-3 py-2" open>
            <summary className="cursor-pointer select-none text-[11px] text-amber-800">
              ⚠ {foreignServing.length} release{foreignServing.length > 1 ? 's' : ''} <b>not from
              this build</b> {foreignServing.length > 1 ? 'are' : 'is'} serving traffic in this
              app's namespace right now
            </summary>
            <div className="mt-2 space-y-2">
              {foreignServing.map((r) => {
                const st = statusOf(r);
                const link = myLinks.find((l) => l.airborneReleaseId === r.id);
                return (
                  <div key={r.id} className="rounded border border-zinc-200 bg-white p-2.5">
                    <div className="flex items-center gap-2 flex-wrap text-[11px] text-zinc-600">
                      <Chip
                        label={st}
                        cls={REL_CHIP[st] ?? 'bg-zinc-100 text-zinc-600 border-zinc-200'}
                      />
                      {pkgVersionOf(r) != null && (
                        <span className="font-mono">pkg v{pkgVersionOf(r)}</span>
                      )}
                      {tagFor(r) && <span className="font-mono text-zinc-600">{tagFor(r)}</span>}
                      {st === 'INPROGRESS' && <span>{trafficOf(r) ?? 0}%</span>}
                      <span>{dimsLabel(dimsOf(r))}</span>
                      {r.id && <ReleaseId id={r.id} />}
                      {r.id && (
                        <Link
                          to={`/airborne/${encodeURIComponent(ref)}/releases/${encodeURIComponent(r.id)}`}
                          className="text-violet-600 hover:underline"
                          title="Open in Airborne"
                        >
                          <ExternalLink className="h-3 w-3" />
                        </Link>
                      )}
                      <span className="ml-auto text-zinc-600">
                        {link
                          ? `from ${link.groupLabel || `group ${link.groupId.slice(0, 8)}`} · ${link.sourceRef}`
                          : `created outside SCC${r.created_at ? ` · ${new Date(r.created_at).toLocaleDateString()}` : ''}`}
                      </span>
                    </div>
                    <div className="flex items-center gap-2 mt-1.5">
                      {st === 'CREATED' && can('OTA_RELEASE_DISCARD') && (
                        <Button size="sm" variant="ghost" onClick={() => doDiscard(r)}>
                          Discard
                        </Button>
                      )}
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
                      <span className="text-[10px] text-zinc-600">
                        operate with care — this build's page can't vouch for what it serves
                      </span>
                    </div>
                  </div>
                );
              })}
            </div>
          </details>
        )}

        {/* Bundle pushes — compact timeline: rows collapse to one line; only
            an actively-running push starts open; a failed row shows its
            reason inline without expanding. */}
        {myPushes.length > 0 && <SectionLabel>Bundle pushes</SectionLabel>}
        {myPushes.length > 0 && (
          <div className="rounded-md border border-zinc-200 divide-y divide-zinc-100">
            {myPushes.map((p, i) => {
              const isLatest = i === 0;
              const active = ['DISPATCHED', 'RUNNING'].includes(p.status);
              // Expansion holds the CI step matrix, build details, and latest-push
              // actions. A push with none of those (e.g. a dispatch that failed
              // before CI started) gets no caret — the row already says it all.
              const expandable =
                p.externalRunId != null ||
                p.packageVersion != null ||
                p.commitSha != null ||
                p.resolvedVia != null ||
                (isLatest && (p.status === 'BUNDLE_PUSHED' || active));
              const isOpen = expandable && (pushToggles[p.id] ?? active);
              // One status-colored edge per push scopes the ROW + its expanded
              // block as a single unit — without it, an expanded push and the
              // next row visually merge into one card.
              const edge =
                {
                  DISPATCHED: 'border-l-sky-400',
                  RUNNING: 'border-l-amber-400',
                  BUNDLE_PUSHED: 'border-l-emerald-400',
                  FAILED: 'border-l-red-400',
                }[p.status] ?? 'border-l-zinc-200';
              return (
                <div key={p.id} className={`border-l-2 ${edge}`}>
                  <button
                    type="button"
                    onClick={() =>
                      expandable && setPushToggles((t) => ({ ...t, [p.id]: !isOpen }))
                    }
                    className={`w-full min-w-0 flex flex-wrap items-center gap-2 px-3 py-2 text-left transition-colors ${expandable ? 'hover:bg-zinc-50' : 'cursor-default'}`}
                  >
                    <span className="text-[10px] text-zinc-600 w-3">
                      {expandable ? (isOpen ? '▼' : '▶') : ''}
                    </span>
                    <span className="text-[11px] font-mono text-zinc-600 whitespace-nowrap">
                      {new Date(p.dispatchedAt).toLocaleString()}
                    </span>
                    <Chip label={p.status} cls={PUSH_CHIP[p.status]} />
                    <span className="text-xs font-mono text-zinc-800">
                      {p.finalVersion ??
                        (p.packageVersion != null ? `pkg v${p.packageVersion}` : 'bundle push')}
                    </span>
                    <span className="text-[11px] text-zinc-600 truncate">
                      {p.requestedBump} · {p.sourceRef} · by {p.dispatchedBy}
                    </span>
                    {/* The failure reason lives HERE, once. Short reasons sit
                        inline right (beside CI run); only long ones take a
                        wrapped full-width line so they can't stretch the row. */}
                    <span className="ml-auto inline-flex items-center gap-2 min-w-0">
                      {p.status === 'FAILED' && p.error && p.error.length <= 60 && (
                        <span className="min-w-0 truncate text-[11px] italic text-red-600">
                          {p.error}
                        </span>
                      )}
                      {p.runUrl && (
                        <a
                          href={p.runUrl}
                          target="_blank"
                          rel="noreferrer"
                          onClick={(e) => e.stopPropagation()}
                          className="inline-flex items-center gap-1 text-[11px] text-violet-600 hover:underline whitespace-nowrap"
                        >
                          CI run <ExternalLink className="h-3 w-3" />
                        </a>
                      )}
                    </span>
                    {p.status === 'FAILED' && p.error && p.error.length > 60 && (
                      <span className="basis-full min-w-0 pl-5 text-[11px] italic text-red-600 whitespace-normal break-words">
                        {p.error}
                      </span>
                    )}
                  </button>
                  {isOpen && (
                    <div className="px-3 pb-3 pt-1 bg-zinc-50 space-y-2">
                      {/* Pre-binding window: the workflow was dispatched but GH
                          gives us nothing to correlate — convergence finds and
                          binds the run ~30–60s in. Explain the blank instead of
                          showing a bare Abandon. */}
                      {p.status === 'DISPATCHED' && p.externalRunId == null && (
                        <div className="flex items-center gap-2 text-[11px] text-zinc-600">
                          <Loader2 className="h-3.5 w-3.5 animate-spin text-zinc-500" />
                          Locating CI run… stages appear once the run is found (~30–60s after
                          dispatch).
                        </div>
                      )}
                      {/* Job matrix — live while building, result view after. */}
                      <OtaRunJobs pushId={p.id} show={p.externalRunId != null} live={active} />
                      <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-[11px] text-zinc-600">
                        {p.packageVersion != null && (
                          <span>
                            package <span className="font-mono text-zinc-700">v{p.packageVersion}</span>
                          </span>
                        )}
                        {p.commitSha && (
                          <span>
                            commit <span className="font-mono">{p.commitSha.slice(0, 9)}</span>
                          </span>
                        )}
                        {p.resolvedVia && <span>resolved via {p.resolvedVia}</span>}
                      </div>
                      {isLatest && (
                        <div className="flex items-center gap-2">
                          {p.status === 'BUNDLE_PUSHED' &&
                            p.packageVersion != null &&
                            can('OTA_RELEASE_CREATE') && (
                              <Button
                                size="sm"
                                onClick={() =>
                                  setComposerFor({
                                    version: p.packageVersion!,
                                    tag: p.finalVersion ?? undefined,
                                    pushId: p.id,
                                  })
                                }
                              >
                                <Package className="h-3.5 w-3.5 mr-1" /> Release
                              </Button>
                            )}
                          {p.status === 'BUNDLE_PUSHED' &&
                            p.packageVersion == null &&
                            canDispatch &&
                            (attachFor === p.id ? (
                              <span className="inline-flex items-center gap-1">
                                <input
                                  type="number"
                                  placeholder="pkg version"
                                  value={attachVersion}
                                  onChange={(e) => setAttachVersion(e.target.value)}
                                  className="w-24 rounded border border-zinc-300 px-1.5 py-0.5 text-xs"
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
                              <Button size="sm" variant="outline" onClick={() => setAttachFor(p.id)}>
                                Attach package
                              </Button>
                            ))}
                          {active && canDispatch && (
                            <Button
                              size="sm"
                              variant="outline"
                              onClick={async () => {
                                if (
                                  !(await confirm({
                                    title: 'Abandon this push?',
                                    description:
                                      'Marks it failed and unblocks new OTA dispatches. The CI run itself is not cancelled.',
                                    variant: 'danger',
                                  }))
                                )
                                  return;
                                try {
                                  await abandonOtaPush(p.id);
                                  toast.success('Push abandoned');
                                  onChanged();
                                } catch (e) {
                                  toast.error(errMsg(e, 'abandon failed'));
                                }
                              }}
                            >
                              Abandon
                            </Button>
                          )}
                        </div>
                      )}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}

        {/* Package shelf — the create surface. Only THIS BUILD's packages
            (proven lineage, or an SCC push of this group) are shown; the rest
            of the namespace collapses below, context not clutter. */}
        {hasView && (eligiblePkgs.length > 0 || foreignPkgs.length > 0 || foreignInert.length > 0) && (
          <>
            <div className="flex items-center justify-between">
              <SectionLabel>Releasable packages · this build</SectionLabel>
              <Link
                to={`/airborne/${encodeURIComponent(ref)}`}
                className="inline-flex items-center gap-1 text-[11px] text-violet-600 hover:text-violet-800"
                title="Full package & release history in the Airborne dashboard"
              >
                Open in Airborne <ExternalLink className="h-3 w-3" />
              </Link>
            </div>
            {packagesQ.isLoading || provQ.isLoading ? (
              <div className="border border-dashed border-zinc-200 rounded-md px-3 py-2.5">
                <Spinner size="sm" label="Loading packages…" />
              </div>
            ) : eligiblePkgs.length === 0 ? (
              <p className="text-xs text-zinc-600 border border-dashed border-zinc-200 rounded-md px-3 py-2.5">
                No packages from this build yet — Push bundle creates one.
              </p>
            ) : (
              (() => {
                const relRow = (r: OtaRelease, compact = false) => {
                  const st = statusOf(r);
                  const l = myLinks.find((x) => x.airborneReleaseId === r.id);
                  return (
                    <div
                      key={r.id}
                      className={cn(
                        'flex items-center gap-2 flex-wrap text-[11px] rounded-md border border-zinc-100 px-2.5 py-1.5',
                        compact ? 'bg-white' : 'bg-zinc-50/60',
                      )}
                    >
                      <Chip
                        label={st}
                        cls={REL_CHIP[st] ?? 'bg-zinc-100 text-zinc-600 border-zinc-200'}
                      />
                      {st === 'INPROGRESS' && (
                        <span className="font-semibold text-violet-700">{trafficOf(r) ?? 0}%</span>
                      )}
                      {pkgNameOf(r) && (
                        <span
                          className="font-mono text-zinc-600 truncate max-w-[180px]"
                          title={pkgNameOf(r)}
                        >
                          {pkgNameOf(r)}
                        </span>
                      )}
                      <span className="text-zinc-600">
                        targets <span className="text-zinc-700">{dimsLabel(dimsOf(r))}</span>
                      </span>
                      {r.id && <span className="text-zinc-600">release</span>}
                      {r.id && <ReleaseId id={r.id} />}
                      {r.id && (
                        <Link
                          to={`/airborne/${encodeURIComponent(ref)}/releases/${encodeURIComponent(r.id)}`}
                          className="text-violet-600 hover:text-violet-800"
                          title="Open in Airborne"
                        >
                          <ExternalLink className="h-3 w-3" />
                        </Link>
                      )}
                      <span className="ml-auto text-zinc-600">
                        {l ? `from ${l.groupLabel || `group ${l.groupId.slice(0, 8)}`}` : 'outside SCC'}
                        {r.created_at ? ` · ${new Date(r.created_at).toLocaleDateString()}` : ''}
                      </span>
                      {/* Metrics keep accruing after conclude (events stay keyed
                          to the release id) — post-ship adoption is visible here. */}
                      <div className="w-full">
                        <OtaMetricsRow
                          appRef={ref}
                          releaseId={r.id}
                          enabled={st === 'INPROGRESS' || st === 'CONCLUDED'}
                        />
                      </div>
                    </div>
                  );
                };
                const renderPkg = (pk: ReleasablePkg, compact = false) => {
                  const push = pk.pushId ? myPushes.find((x) => x.id === pk.pushId) : undefined;
                  const link = myLinks.find((l) => l.packageVersion === pk.version);
                  // Every airborne release cut from this package, newest first;
                  // only the latest shows — the rest fold into a details line.
                  const pkgRels = releases
                    .filter((r) => pkgVersionOf(r) === pk.version)
                    .sort((a, b) => (b.created_at || '').localeCompare(a.created_at || ''));
                  return (
                    <div key={pk.version} className={compact ? 'px-3 py-1.5' : 'px-3 py-2.5'}>
                      <div className="flex items-center gap-2">
                        <span
                          className={cn(
                            'font-mono font-semibold',
                            compact ? 'text-[11px] text-zinc-600' : 'text-xs text-zinc-800',
                          )}
                        >
                          pkg v{pk.version}
                        </span>
                        {pk.tag && <span className="text-[11px] font-mono text-zinc-600">{pk.tag}</span>}
                        <ProvenanceBadge prov={provOf(pk.version)} push={push} link={link} />
                        <span className="ml-auto" />
                        {can('OTA_RELEASE_CREATE') && (
                          <Button
                            size="sm"
                            variant={compact ? 'ghost' : 'outline'}
                            onClick={() => setComposerFor(pk)}
                            title={
                              pkgRels.length > 0
                                ? 'Create another release from this package (pick its own dimensions)'
                                : undefined
                            }
                          >
                            {pkgRels.length > 0 ? 'New release' : 'Release'}
                          </Button>
                        )}
                      </div>
                      {/* All-or-none per package: the current card lists every
                          release; history packages fold ALL of theirs behind
                          one line — never a shown-one/hidden-rest split. */}
                      {pkgRels.length > 0 &&
                        (compact ? (
                          <details className="mt-1.5 text-[11px]">
                            <summary className="cursor-pointer text-zinc-600 select-none hover:text-zinc-600">
                              {pkgRels.length} release{pkgRels.length > 1 ? 's' : ''}
                            </summary>
                            <div className="mt-1 space-y-1">
                              {pkgRels.map((r) => relRow(r, true))}
                            </div>
                          </details>
                        ) : (
                          <div className="mt-2 space-y-1.5">
                            {pkgRels.map((r) => relRow(r, false))}
                          </div>
                        ))}
                    </div>
                  );
                };
                return (
                  <>
                    {/* Latest package: the one full-weight card. */}
                    <div className="rounded-md border border-zinc-200 bg-white shadow-sm">
                      {renderPkg(eligiblePkgs[0])}
                    </div>
                    {/* Older packages: visually subordinate — muted wash,
                        smaller type, quiet buttons — history, not options. */}
                    {eligiblePkgs.length > 1 && (
                      <details className="text-xs">
                        <summary className="cursor-pointer text-zinc-600 select-none hover:text-zinc-600">
                          History · {eligiblePkgs.length - 1} older package
                          {eligiblePkgs.length - 1 > 1 ? 's' : ''} from this build
                        </summary>
                        <div className="mt-1.5 rounded-md border border-zinc-100 bg-zinc-50/60 divide-y divide-zinc-100">
                          {eligiblePkgs.slice(1).map((pk) => renderPkg(pk, true))}
                        </div>
                      </details>
                    )}
                  </>
                );
              })()
            )}
            {/* Foreign packages/inert releases don't render here — the
                header's "Open in Airborne" link is the path to them. Foreign
                SERVING releases still get the amber warning above. */}
            {(foreignPkgs.length > 0 || foreignInert.length > 0) && (
              <Link
                to={`/airborne/${encodeURIComponent(ref)}`}
                className="inline-flex items-center gap-1 text-xs text-zinc-600 hover:text-zinc-600"
                title="Packages and inactive releases from other builds — view in the Airborne dashboard"
              >
                Not from this build:{' '}
                {foreignPkgs.length > 0 &&
                  `${foreignPkgs.length} package${foreignPkgs.length > 1 ? 's' : ''}`}
                {foreignPkgs.length > 0 && foreignInert.length > 0 && ' · '}
                {foreignInert.length > 0 &&
                  `${foreignInert.length} inactive release${foreignInert.length > 1 ? 's' : ''}`}{' '}
                — view in Airborne <ExternalLink className="h-3 w-3" />
              </Link>
            )}
          </>
        )}

        {/* New push — labeled bottom bar */}
        <div className="flex items-center gap-3 flex-wrap border-t border-zinc-100 pt-3">
          <span className="text-[10px] font-bold uppercase tracking-wider text-zinc-600">
            New push
          </span>
          <label
            className="inline-flex items-center gap-1.5 text-[11px] text-zinc-600"
            title="Semver bump for the bundle version the CI assigns"
          >
            Bump
            <select
              value={bump}
              onChange={(e) => setBump(e.target.value as typeof bump)}
              className="rounded border border-zinc-300 px-1.5 py-1 text-xs text-zinc-800"
              disabled={!!pushDisabledReason}
            >
              <option value="patch">patch</option>
              <option value="minor">minor</option>
              <option value="major">major</option>
            </select>
          </label>
          <label
            className="inline-flex items-center gap-1.5 text-[11px] text-zinc-600"
            title="CI runner pool the bundle build runs on"
          >
            Runner
            <select
              value={runner}
              onChange={(e) => setRunner(e.target.value)}
              className="rounded border border-zinc-300 px-1.5 py-1 text-xs text-zinc-800"
              disabled={!!pushDisabledReason}
            >
              {OTA_RUNNER_POOLS.map((r) => (
                <option key={r} value={r}>
                  {r}
                </option>
              ))}
            </select>
          </label>
          <label
            className="inline-flex items-center gap-1.5 text-[11px] text-zinc-600 cursor-pointer"
            title="Post the bundle build result to the mobile Slack channel"
          >
            <input
              type="checkbox"
              checked={notifySlack}
              onChange={(e) => setNotifySlack(e.target.checked)}
              disabled={!!pushDisabledReason}
              className="rounded border-zinc-300 accent-zinc-900"
            />
            Notify Slack
          </label>
          <Button
            size="sm"
            className="bg-[#EAFCF5] border-emerald-200 text-emerald-900 enabled:hover:bg-[#D9F7EA] enabled:active:bg-emerald-100"
            disabled={!!pushDisabledReason || dispatchMut.isPending}
            onClick={() => dispatchMut.mutate()}
            title={pushDisabledReason ?? undefined}
          >
            <Upload className="h-3.5 w-3.5 mr-1" />
            {dispatchMut.isPending ? 'Dispatching…' : 'Push bundle'}
          </Button>
          {sourceRef && (
            <span
              className="inline-flex items-center gap-1 text-[11px] text-zinc-600 font-mono border border-zinc-200 rounded px-1.5 py-0.5"
              title={`Bundles build from branch: ${sourceRef}`}
            >
              <GitBranch className="w-3 h-3 text-zinc-600" /> {sourceRef}
            </span>
          )}
          {pushDisabledReason && (
            <span className="text-[11px] text-zinc-600">{pushDisabledReason}</span>
          )}
        </div>

        {/* History */}
        {(myPushes.length > 1 || myLinks.length > 0) && (
          <details className="text-xs">
            <summary className="cursor-pointer text-zinc-600 select-none">
              Push & release history ({myPushes.length + myLinks.length})
            </summary>
            <div className="mt-2 space-y-1">
              {myPushes.map((p) => (
                <div key={p.id} className="flex items-center gap-2 text-[11px] text-zinc-600">
                  <Chip label={p.status} cls={PUSH_CHIP[p.status]} />
                  <span className="font-mono">
                    {p.packageVersion != null ? `pkg v${p.packageVersion}` : '—'}
                  </span>
                  {p.finalVersion && <span className="font-mono text-zinc-600">{p.finalVersion}</span>}
                  <span className="text-zinc-600">
                    {p.requestedBump} · {p.dispatchedBy} · {new Date(p.dispatchedAt).toLocaleString()}
                  </span>
                </div>
              ))}
              {myLinks.map((l) => {
                const live = releases.find((r) => r.id === l.airborneReleaseId);
                return (
                  <div key={l.linkId} className="flex items-center gap-2 text-[11px] text-zinc-600">
                    <Chip
                      label={live ? statusOf(live) : 'RELEASE'}
                      cls={(live && REL_CHIP[statusOf(live)]) || 'bg-zinc-100 text-zinc-600 border-zinc-200'}
                    />
                    <span className="font-mono">pkg v{l.packageVersion}</span>
                    <ReleaseId id={l.airborneReleaseId} />
                    <span className="text-zinc-600">{dimsLabel(l.dimensions)}</span>
                    <span className="text-zinc-600">
                      {l.groupId === groupId ? 'this release' : (l.groupLabel ?? l.groupId)} ·{' '}
                      {l.createdBy}
                    </span>
                  </div>
                );
              })}
            </div>
          </details>
        )}
      </div>

      {branchPickerOpen && (
        <OtaBranchPicker
          groupId={groupId}
          appRef={ref}
          onClose={() => setBranchPickerOpen(false)}
          onAdopted={onChanged}
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

// ── decision metrics (honest empty when analytics unconfigured) ─────

/** CI job matrix of a push's run — polls while live, stays as the result
    view once finished. Each job expands to its steps; running/failed jobs
    start expanded so the point of interest is visible without a click. */
function OtaRunJobs({ pushId, show, live }: { pushId: string; show: boolean; live: boolean }) {
  const q = useQuery({
    // v2: response gained per-job `steps`; new key discards any cached
    // step-less response from earlier in the session.
    queryKey: ['mobile-ota-push-jobs', 'v2', pushId],
    queryFn: () => fetchOtaPushJobs(pushId),
    enabled: show,
    refetchInterval: live ? 10_000 : false,
    staleTime: live ? 0 : 60_000,
    retry: false,
  });
  const [jobToggles, setJobToggles] = useState<Record<string, boolean>>({});
  if (!show || !q.data?.jobs?.length) return null;
  // CI status → a DOT color + short lowercase label (deliberately unlike the
  // package/release pill Chips: no pill, no border, small text).
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
  const dotCls: Record<Tone, string> = {
    ok: 'bg-emerald-500',
    run: 'bg-amber-500 animate-pulse',
    wait: 'bg-zinc-300',
    skip: 'bg-zinc-200',
    fail: 'bg-rose-500',
  };
  const textCls: Record<Tone, string> = {
    ok: 'text-emerald-600',
    run: 'text-amber-600',
    wait: 'text-zinc-600',
    skip: 'text-zinc-600',
    fail: 'text-rose-600',
  };
  const durationOf = (x: { startedAt?: string; completedAt?: string }): string | null => {
    if (!x.startedAt) return null;
    const end = x.completedAt ? new Date(x.completedAt).getTime() : Date.now();
    const secs = Math.max(0, Math.round((end - new Date(x.startedAt).getTime()) / 1000));
    return secs < 90 ? `${secs}s` : `${Math.round(secs / 60)}m`;
  };
  return (
    <div className="mt-2 rounded-md border border-zinc-100 divide-y divide-zinc-50">
      {q.data.jobs.map((j) => {
        const jt = toneOf(j);
        const steps = j.steps ?? [];
        // The failing step IS the reason — GitHub's jobs API gives no message.
        const failedStep = steps.find((st) => st.conclusion === 'failure');
        const interesting = j.status !== 'completed' || (j.conclusion !== 'success' && j.conclusion !== 'skipped');
        const open = jobToggles[j.name] ?? interesting;
        return (
          <div key={j.name}>
            <button
              type="button"
              onClick={() => setJobToggles((t) => ({ ...t, [j.name]: !open }))}
              className="w-full flex items-center gap-2 px-2.5 py-1.5 text-[11px] text-left hover:bg-zinc-50 transition-colors"
            >
              <span className="text-[9px] text-zinc-600 w-2.5">
                {steps.length > 0 ? (open ? '▼' : '▶') : ''}
              </span>
              <span className={cn('inline-block h-2 w-2 rounded-full shrink-0', dotCls[jt.tone])} />
              <span className="font-medium text-zinc-700">{j.name}</span>
              <span className={cn('uppercase tracking-wide text-[10px] font-semibold', textCls[jt.tone])}>
                {jt.label}
              </span>
              {durationOf(j) && <span className="text-zinc-600">{durationOf(j)}</span>}
              {/* Failure reason inline — the step that broke it. */}
              {failedStep && (
                <span className="text-rose-600 truncate">· failed at “{failedStep.name}”</span>
              )}
            </button>
            {/* The job's steps — where a failure actually happened. */}
            {open && steps.length > 0 && (
              <div className="pb-1.5">
                {steps.map((st, i) => {
                  const stt = toneOf(st);
                  return (
                    <div
                      key={`${i}-${st.name}`}
                      className="flex items-center gap-2 pl-9 pr-2.5 py-0.5 text-[11px]"
                    >
                      <span className={cn('inline-block h-1.5 w-1.5 rounded-full shrink-0', dotCls[stt.tone])} />
                      <span
                        className={cn(
                          'truncate',
                          stt.tone === 'skip' || stt.tone === 'wait' ? 'text-zinc-600' : 'text-zinc-600',
                          stt.tone === 'fail' && 'text-rose-700 font-medium',
                        )}
                      >
                        {st.name}
                      </span>
                      {durationOf(st) && <span className="text-zinc-600">{durationOf(st)}</span>}
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

function OtaMetricsRow({
  appRef,
  releaseId,
  enabled,
}: {
  appRef: string;
  releaseId?: string;
  enabled: boolean;
}) {
  // Anchor the 7d window once per mount so query keys stay stable.
  const [range] = useState(() => {
    const end = Date.now();
    return { start: end - 7 * 86_400_000, end };
  });
  const adoptionQ = useQuery({
    queryKey: ['mobile-ota-adoption', appRef, releaseId],
    queryFn: () =>
      fetchOtaAdoption(appRef, {
        interval: 'DAY',
        start_date: String(range.start),
        end_date: String(range.end),
        date: String(range.end),
        release_id: releaseId,
      }),
    enabled: enabled && !!releaseId,
    retry: false,
    staleTime: 60_000,
  });
  const failuresQ = useQuery({
    queryKey: ['mobile-ota-metrics', appRef, releaseId],
    queryFn: () => fetchOtaFailures(appRef, { days: 7, release_id: releaseId }),
    enabled: enabled && !!releaseId,
    retry: false,
    staleTime: 60_000,
  });
  if (!enabled) return null;
  const buckets =
    (adoptionQ.data as { data?: { time_breakdown?: Array<Record<string, unknown>> } } | undefined)
      ?.data?.time_breakdown ?? [];
  const num = (v: unknown) => (typeof v === 'number' ? v : 0);
  const sum = (k: string) => buckets.reduce((acc, b) => acc + num(b[k]), 0);
  const downloads = sum('download_success');
  const applied = sum('apply_success');
  const rollbacks = sum('rollbacks_initiated');
  const failures = (failuresQ.data as { total_failures?: number } | undefined)?.total_failures;
  const haveAdoption = !adoptionQ.isError && buckets.length > 0;
  const haveFailures = !failuresQ.isError && failures != null;
  // Analytics unconfigured / unreachable ⇒ render nothing, not zeros.
  if (!haveAdoption && !haveFailures) return null;
  const fmt = (n: number) => (n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n));
  const bad = rollbacks + (failures ?? 0);
  return (
    <div className="text-[11px] text-zinc-600 mt-1">
      7d:{' '}
      {haveAdoption && (
        <>
          downloads <span className="text-zinc-700">{fmt(downloads)}</span> · applied{' '}
          <span className="text-zinc-700">{fmt(applied)}</span> ·{' '}
        </>
      )}
      rollbacks/failures{' '}
      <span className={bad > 0 ? 'text-red-600 font-semibold' : 'text-zinc-700'}>{fmt(bad)}</span>
      {bad > 0 && ' — a rising count means Revert'}
    </div>
  );
}

// ── composer ────────────────────────────────────────────────────────

export function OtaReleaseComposer({
  appRef,
  appName,
  platform,
  initial,
  pkgs,
  nativeVersion,
  nudgeVersionTarget,
  editing,
  onSaved,
  firstRelease,
  firstReleaseUnknown,
  ongoing,
  maxKnownPkg,
  onClose,
  onSubmit,
}: {
  appRef: string;
  appName: string;
  platform: string;
  /** Preselected package (the row the user clicked). */
  initial: ReleasablePkg;
  /** All releasable (this-build) packages, newest first — the selector. */
  pkgs: ReleasablePkg[];
  /** Native build version — offers the R7 version-targeting seed rule. */
  nativeVersion?: string | null;
  /** Superseded build: pre-seed the version dimension and require an explicit
      confirm to release untargeted (old-branch JS must not serve everyone). */
  nudgeVersionTarget?: boolean;
  /** Edit-before-ramp: update an existing CREATED release (targeting locked). */
  editing?: { releaseId: string; lockedDims: Record<string, unknown> };
  onSaved?: () => void;
  firstRelease: boolean;
  firstReleaseUnknown: boolean;
  ongoing: OtaRelease[];
  maxKnownPkg: number;
  onClose: () => void;
  onSubmit: (pkg: ReleasablePkg, req: OtaReleaseReq) => void;
}) {
  const [selPkg, setSelPkg] = useState<ReleasablePkg>(initial);
  const [rules, setRules] = useState<Array<{ dim: string; value: string }>>([]);
  const [traffic, setTraffic] = useState('0');
  const [showAdvanced, setShowAdvanced] = useState(false);
  const [bootTimeout, setBootTimeout] = useState('0');
  const [rcTimeout, setRcTimeout] = useState('0');
  const [propertiesText, setPropertiesText] = useState('');
  const [lazy, setLazy] = useState<string[]>([]);
  const [submitting, setSubmitting] = useState(false);

  // Edit mode: prefill config/split from the live release detail, once.
  const [prefilled, setPrefilled] = useState(false);
  const detailQ = useQuery({
    queryKey: ['mobile-ota-release-detail', appRef, editing?.releaseId],
    queryFn: () => fetchOtaRelease(appRef, editing!.releaseId),
    enabled: !!editing,
    retry: false,
  });
  if (editing && detailQ.data && !prefilled) {
    setPrefilled(true);
    const cfg = detailQ.data.config;
    if (typeof cfg?.boot_timeout === 'number') setBootTimeout(String(cfg.boot_timeout));
    if (typeof cfg?.release_config_timeout === 'number') setRcTimeout(String(cfg.release_config_timeout));
    if (cfg?.properties && Object.keys(cfg.properties).length > 0)
      setPropertiesText(JSON.stringify(cfg.properties, null, 2));
    const relPkg = (detailQ.data as { package?: { lazy?: unknown[] } }).package;
    if (Array.isArray(relPkg?.lazy))
      setLazy(relPkg.lazy.filter((k): k is string => typeof k === 'string' && k.includes('@')));
  }

  const dimsQ = useQuery({
    queryKey: ['mobile-ota-dims', appRef],
    queryFn: () => fetchOtaDimensions(appRef, { page: 1, count: 100 }),
    retry: false,
    staleTime: 60_000,
  });
  const pkgQ = useQuery({
    queryKey: ['mobile-ota-pkg', appRef, selPkg.version],
    queryFn: () => fetchOtaPackageDetail(appRef, `version:${selPkg.version}`),
    retry: false,
  });
  const dimNames: string[] = (dimsQ.data?.data ?? [])
    .map((d: { dimension?: string }) => d.dimension ?? '')
    .filter(Boolean);
  // Superseded build: seed the version rule once the vocabulary loads, so the
  // straggler-hotfix path (targeted at THIS build's version) is the default.
  const [autoSeeded, setAutoSeeded] = useState(false);
  const seedDim = dimNames.find((d) => /version/i.test(d));
  if (
    nudgeVersionTarget &&
    !editing &&
    !firstRelease &&
    !autoSeeded &&
    seedDim &&
    nativeVersion &&
    rules.length === 0
  ) {
    setAutoSeeded(true);
    setRules([{ dim: seedDim, value: nativeVersion }]);
  }
  const pkgFiles: string[] = (pkgQ.data?.files ?? []).filter(
    (f: unknown): f is string => typeof f === 'string',
  );

  const isDowngrade = selPkg.version < maxKnownPkg;
  const reqDims = Object.fromEntries(
    rules.filter((r) => r.dim && r.value.trim()).map((r) => [r.dim, r.value.trim()]),
  );
  // Upstream only rejects EXACT duplicates; warn on overlap client-side.
  const overlaps = ongoing.some((o) => {
    const od = dimsOf(o);
    const keys = Object.keys(reqDims);
    const oKeys = Object.keys(od);
    if (keys.length === oKeys.length && keys.every((k) => String(od[k]) === reqDims[k])) return false; // exact = handled by preflight
    return keys.some((k) => k in od) || oKeys.length === 0 || keys.length === 0;
  });

  const submit = () => {
    const n = Number(traffic);
    if (!firstRelease && (!Number.isFinite(n) || n < 0 || n > 50)) {
      toast.error('Initial traffic must be 0–50 (100% only via Conclude)');
      return;
    }
    // Superseded build + no targeting = old-branch JS served to EVERY device,
    // including newer natives it was never built against. Deliberate only.
    if (
      nudgeVersionTarget &&
      !editing &&
      !firstRelease &&
      Object.keys(reqDims).length === 0 &&
      !window.confirm(
        'This build was superseded — an untargeted release serves ALL devices, including newer app versions this bundle was not built against. Release untargeted anyway?',
      )
    ) {
      return;
    }
    if (rules.some((r) => r.value.includes(';'))) {
      toast.error("Dimension values must not contain ';'");
      return;
    }
    let properties: Record<string, unknown> | undefined;
    if (propertiesText.trim()) {
      try {
        const parsed = JSON.parse(propertiesText);
        if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error();
        properties = parsed;
      } catch {
        toast.error('Properties must be a JSON object');
        return;
      }
    }
    setSubmitting(true);
    if (editing) {
      const important = pkgFiles.filter((f) => !lazy.includes(f));
      void updateOtaRelease(appRef, editing.releaseId, {
        config: {
          boot_timeout: Number(bootTimeout) || 0,
          release_config_timeout: Number(rcTimeout) || 0,
          ...(properties ? { properties } : {}),
        },
        package_id: `version:${selPkg.version}`,
        package: { important, lazy },
        ...(Object.keys(editing.lockedDims).length > 0
          ? { dimensions: editing.lockedDims as Record<string, unknown> }
          : {}),
      })
        .then(() => {
          toast.success('Release updated');
          onSaved?.();
        })
        .catch((e) => {
          toast.error(errMsg(e, 'update failed'));
          setSubmitting(false);
        });
      return;
    }
    onSubmit(selPkg, {
      dimensions: firstRelease || Object.keys(reqDims).length === 0 ? undefined : reqDims,
      initialTrafficPercent: firstRelease || n === 0 ? undefined : n,
      config:
        Number(bootTimeout) || Number(rcTimeout) || properties
          ? {
              bootTimeout: Number(bootTimeout) || 0,
              releaseConfigTimeout: Number(rcTimeout) || 0,
              properties,
            }
          : undefined,
      lazyFiles: lazy.length > 0 ? lazy : undefined,
    });
  };

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent size="xl">
        <DialogHeader>
          <DialogTitle>
            {editing ? 'Edit release' : 'Release OTA bundle'} — {appName} · {platform}
          </DialogTitle>
        </DialogHeader>
        <DialogBody className="space-y-4">
          <div>
            <div className="text-xs font-semibold text-zinc-700 mb-1">Package</div>
            <div className="flex items-center gap-2">
              <select
                value={selPkg.version}
                onChange={(e) => {
                  const v = Number(e.target.value);
                  const next = pkgs.find((x) => x.version === v);
                  if (next) {
                    setSelPkg(next);
                    setLazy([]);
                  }
                }}
                className="rounded border border-zinc-300 px-2 py-1.5 text-sm font-mono"
              >
                {pkgs.map((x) => (
                  <option key={x.version} value={x.version}>
                    pkg v{x.version}
                    {x.tag ? ` · ${x.tag}` : ''}
                  </option>
                ))}
              </select>
              {selPkg.relation === 'identical' && (
                <span className="text-[11px] text-emerald-700">this build · exact</span>
              )}
              {selPkg.relation === 'ahead' && (
                <span className="text-[11px] text-emerald-700">this branch · newer fixes</span>
              )}
              {selPkg.pushId && !selPkg.relation && (
                <span className="text-[11px] text-emerald-700">pushed by SCC</span>
              )}
            </div>
          </div>
          {firstReleaseUnknown && (
            <p className="text-xs text-amber-700 bg-amber-50 border border-amber-200 rounded p-2">
              Could not load the release history — cannot tell whether this is the app's first
              release. Retry before submitting.
            </p>
          )}
          {firstRelease && (
            <p className="text-xs text-sky-800 bg-sky-50 border border-sky-200 rounded p-2">
              <b>Bootstrap release:</b> this is the app's first OTA release. It must be untargeted
              and auto-concludes upstream (a known upstream quirk can leave it INPROGRESS@50 —
              conclude it manually if so).
            </p>
          )}
          {isDowngrade && (
            <p className="text-xs text-amber-800 bg-amber-50 border border-amber-200 rounded p-2">
              <b>Older than current:</b> pkg v{selPkg.version} is older than the newest known
              release (v{maxKnownPkg}). Releasing it is a rollback.
            </p>
          )}

          {editing && (
            <p className="text-[11px] text-zinc-600 border border-zinc-200 rounded p-2">
              Targeting is locked while editing:{' '}
              <span className="text-zinc-700">{dimsLabel(editing.lockedDims)}</span> — supersede
              (discard + recreate) to retarget.
            </p>
          )}
          {!firstRelease && !editing && (
            <div>
              <div className="text-xs font-semibold text-zinc-700 mb-1">Targeting</div>
              {rules.map((r, i) => (
                <div key={i} className="flex items-center gap-2 mb-1">
                  <select
                    value={r.dim}
                    onChange={(e) =>
                      setRules(rules.map((x, j) => (j === i ? { ...x, dim: e.target.value } : x)))
                    }
                    className="rounded border border-zinc-300 px-1.5 py-1 text-xs"
                  >
                    <option value="">dimension…</option>
                    {dimNames.map((d) => (
                      <option key={d} value={d}>
                        {d}
                      </option>
                    ))}
                  </select>
                  <input
                    value={r.value}
                    onChange={(e) =>
                      setRules(rules.map((x, j) => (j === i ? { ...x, value: e.target.value } : x)))
                    }
                    placeholder="value"
                    className="rounded border border-zinc-300 px-1.5 py-1 text-xs flex-1"
                  />
                  <button
                    onClick={() => setRules(rules.filter((_, j) => j !== i))}
                    className="text-zinc-600 hover:text-red-600 text-xs"
                  >
                    ✕
                  </button>
                </div>
              ))}
              <Button size="sm" variant="outline" onClick={() => setRules([...rules, { dim: '', value: '' }])}>
                + add rule
              </Button>
              {(() => {
                // R7: airborne has no native-version gating — offer to opt in
                // via the workspace's version dimension, seeded from this build.
                const verDim = dimNames.find((d) => /version/i.test(d));
                const already = verDim && rules.some((r) => r.dim === verDim);
                return verDim && nativeVersion && !already ? (
                  <Button
                    size="sm"
                    variant="ghost"
                    className="ml-1"
                    onClick={() => setRules([...rules, { dim: verDim, value: nativeVersion }])}
                  >
                    + target this build's version ({nativeVersion})
                  </Button>
                ) : null;
              })()}
              <p className="text-[11px] text-zinc-600 mt-1">Empty targeting = all devices.</p>
              {overlaps && Object.keys(reqDims).length > 0 && (
                <p className="text-[11px] text-amber-700 mt-1">
                  ⚠ Overlaps an ongoing release's targeting — Superposition decides which wins on
                  shared devices. Airborne will not reject this.
                </p>
              )}
            </div>
          )}

          {!firstRelease && !editing && (
            <div>
              <div className="text-xs font-semibold text-zinc-700 mb-1">Initial traffic</div>
              <div className="flex items-center gap-2">
                <input
                  type="number"
                  min={0}
                  max={50}
                  value={traffic}
                  onChange={(e) => setTraffic(e.target.value)}
                  className="w-20 rounded border border-zinc-300 px-1.5 py-1 text-xs"
                />
                <span className="text-[11px] text-zinc-600">
                  % of matching devices (0–50; 100% only via Conclude later)
                </span>
              </div>
            </div>
          )}

          <p className="text-[11px] text-zinc-600 border border-zinc-200 rounded p-2">
            ⓘ This release reaches <b>all</b> devices matching the targeting, on every installed app
            version — airborne has no native-version gating. Bundle ↔ native compatibility is your
            responsibility.
          </p>

          <button
            onClick={() => setShowAdvanced(!showAdvanced)}
            className="text-xs text-zinc-600 underline"
          >
            {showAdvanced ? 'Hide advanced' : 'Advanced (timeouts, properties, lazy files)'}
          </button>
          {showAdvanced && (
            <div className="space-y-2">
              <div className="flex items-center gap-3">
                <label className="text-xs text-zinc-600">
                  boot_timeout{' '}
                  <input
                    type="number"
                    value={bootTimeout}
                    onChange={(e) => setBootTimeout(e.target.value)}
                    className="w-24 rounded border border-zinc-300 px-1.5 py-0.5 text-xs ml-1"
                  />
                </label>
                <label className="text-xs text-zinc-600">
                  release_config_timeout{' '}
                  <input
                    type="number"
                    value={rcTimeout}
                    onChange={(e) => setRcTimeout(e.target.value)}
                    className="w-24 rounded border border-zinc-300 px-1.5 py-0.5 text-xs ml-1"
                  />
                </label>
              </div>
              <div>
                <div className="text-xs text-zinc-600 mb-1">Config properties (JSON object)</div>
                <textarea
                  value={propertiesText}
                  onChange={(e) => setPropertiesText(e.target.value)}
                  rows={3}
                  className="w-full rounded border border-zinc-300 px-2 py-1 text-xs font-mono"
                  placeholder="{}"
                />
              </div>
              {pkgFiles.length > 0 && (
                <div>
                  <div className="text-xs text-zinc-600 mb-1">
                    Lazy files ({lazy.length} of {pkgFiles.length} — everything else is important)
                  </div>
                  <div className="max-h-32 overflow-y-auto border border-zinc-200 rounded p-1">
                    {pkgFiles.map((f) => (
                      <label key={f} className="flex items-center gap-1.5 text-[11px] text-zinc-600 py-0.5">
                        <input
                          type="checkbox"
                          checked={lazy.includes(f)}
                          onChange={(e) =>
                            setLazy(e.target.checked ? [...lazy, f] : lazy.filter((x) => x !== f))
                          }
                        />
                        <span className="font-mono truncate">{f}</span>
                      </label>
                    ))}
                  </div>
                </div>
              )}
            </div>
          )}
        </DialogBody>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button onClick={submit} disabled={submitting || firstReleaseUnknown}>
            {submitting ? (editing ? 'Saving…' : 'Creating…') : editing ? 'Save changes' : 'Create release'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

// ── supersede dialog (status-aware, Part 2.4) ───────────────────────

export function OtaSupersedeDialog({
  appRef,
  groupId,
  conflict,
  releases,
  onClose,
  onResolved,
}: {
  appRef: string;
  groupId: string;
  conflict: OtaOngoingConflict['ongoing'];
  releases: OtaRelease[];
  onClose: () => void;
  onResolved: () => void;
}) {
  const [busy, setBusy] = useState(false);
  const target = conflict[0];
  const live = releases.find((r) => r.id === target?.airborneReleaseId);
  const st = (target?.status ?? '').toUpperCase();

  const resolve = async (action: 'discard' | 'conclude' | 'revert') => {
    if (!target) return;
    setBusy(true);
    try {
      if (action === 'discard') {
        await discardOtaRelease(appRef, target.airborneReleaseId);
      } else {
        const variants = live?.experiment?.experiment_variants;
        const chosen = action === 'revert' ? variants?.control : variants?.experimentals?.[0];
        if (!chosen || (action === 'conclude' && (variants?.experimentals?.length ?? 0) > 1)) {
          toast.error('Variant ambiguous — resolve this release from the Airborne product page');
          setBusy(false);
          return;
        }
        await concludeOtaRelease(appRef, target.airborneReleaseId, {
          chosenVariant: chosen,
          changeReason: `supersede via SCC mobile release ${groupId}`,
        });
      }
      toast.success('Ongoing release resolved — creating the new one…');
      onResolved();
    } catch (e) {
      toast.error(errMsg(e, 'could not resolve the ongoing release'));
      setBusy(false);
    }
  };

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent size="md">
        <DialogHeader>
          <DialogTitle>An ongoing release is in the way</DialogTitle>
        </DialogHeader>
        <DialogBody className="space-y-3">
          {target && (
            <div className="text-xs text-zinc-700">
              <Chip
                label={st}
                cls={REL_CHIP[st] ?? 'bg-zinc-100 text-zinc-600 border-zinc-200'}
              />{' '}
              {target.packageVersion != null && <>pkg v{target.packageVersion} · </>}
              {target.trafficPercentage != null && <>{target.trafficPercentage}% · </>}
              {dimsLabel(target.dimensions)} <ReleaseId id={target.airborneReleaseId} />
              {target.link && (
                <div className="text-[11px] text-zinc-600 mt-1">
                  from {target.link.groupLabel || target.link.groupId} · {target.link.sourceRef} ·{' '}
                  {target.link.createdBy}
                </div>
              )}
            </div>
          )}
          <p className="text-xs text-zinc-600">
            An ongoing release already targets this exact dimension set. Choose what happens to it
            first:
          </p>
          <div className="space-y-2">
            {st === 'CREATED' ? (
              <Button size="sm" disabled={busy} onClick={() => resolve('discard')}>
                Discard it — it was never ramped; no device is affected
              </Button>
            ) : (
              <>
                <Button size="sm" disabled={busy} onClick={() => resolve('conclude')} className="w-full justify-start">
                  Conclude it — ships it to 100% first; devices then move to the new release when it
                  ramps
                </Button>
                <Button
                  size="sm"
                  variant="outline"
                  disabled={busy}
                  onClick={() => resolve('revert')}
                  className="w-full justify-start"
                >
                  Revert it — its ramped cohort returns to stable before the new release
                </Button>
              </>
            )}
          </div>
        </DialogBody>
        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={busy}>
            Cancel
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

// ── error plumbing ──────────────────────────────────────────────────

export function respData(e: unknown): unknown {
  return (e as { response?: { data?: unknown } })?.response?.data;
}

export function errMsg(e: unknown, fallback: string): string {
  const data = respData(e) as { message?: string } | undefined;
  return data?.message || (e as Error)?.message || fallback;
}
