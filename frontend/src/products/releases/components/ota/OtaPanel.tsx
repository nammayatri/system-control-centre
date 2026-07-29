// Per-(app, platform) OTA card (docs/OTA_MOBILE_RELEASE_INTEGRATION.md Part 2).
// Mounted on ReleaseGroupDetail (one per capable app) and ReleaseSummary (one).
// Release state is ALWAYS read live from the airborne BFF — nothing cached in
// SCC; push rows/links come from the group OTA endpoint. Release verbs are
// gated by the caller's per-ref airborne grants (/airborne/access), NOT by
// PermissionsContext (its isAdmin short-circuit spans products).
import { useMemo, useState, type ReactNode } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { BarChart3,
  Copy,
  ExternalLink,
  Package,
  SquareTerminal,
} from 'lucide-react';
import { Link } from 'react-router-dom';
import { cn } from '../../../../lib/utils';
import { mobileApi } from '../../api';
import { Dialog,
  DialogBody,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '../../../../shared/ui/dialog';
import { Button } from '../../../../shared/ui/button';
import { Spinner } from '../../../../shared/ui/spinner';
import { concludeOtaRelease,
  discardOtaRelease,
  fetchOtaDimensions,
  fetchOtaRelease,
  updateOtaRelease,
  fetchOtaPackageDetail,
} from '../../../airborne-ota/api';
import type { OtaRelease } from '../../../airborne-ota/types';
import { adoptOtaBranch,
  releaseOtaPackage,
  releaseOtaPush,
  resolveOtaProvenance,
  type OtaLinkRow,
  type OtaOngoingConflict,
  type OtaProvPkg,
  type OtaPushRow,
  type OtaRelation,
  type OtaReleaseReq,
} from '../../otaApi';

import { fullStamp, shortDate } from '../../pages/mobile/summary/dates';

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
        title={`Built from this build's commit${prov?.aheadBy != null ? ` plus ${prov.aheadBy} newer commit(s)` : ' plus newer commits'}${prov?.commitSha ? ` (${prov.commitSha.slice(0, 9)})` : ''}`}
      >
        this branch{prov?.aheadBy != null ? ` · +${prov.aheadBy}` : ' · newer'}
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
            <div className="text-[10px] uppercase tracking-widest font-bold text-zinc-500 mb-1.5">Package</div>
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
                className="bg-white border border-zinc-200 rounded-lg px-3 py-2 text-sm font-mono font-bold text-zinc-800 shadow-sm outline-none focus:ring-2 focus:ring-violet-200 focus:border-violet-400 cursor-pointer"
              >
                {pkgs.map((x) => (
                  <option key={x.version} value={x.version}>
                    pkg v{x.version}
                    {x.tag ? ` · ${x.tag}` : ''}
                  </option>
                ))}
              </select>
              {selPkg.relation === 'identical' && (
                <span className="inline-flex items-center rounded-full border px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide border-emerald-200 bg-emerald-50 text-emerald-700">this build · exact</span>
              )}
              {selPkg.relation === 'ahead' && (
                <span className="inline-flex items-center rounded-full border px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide border-emerald-200 bg-emerald-50 text-emerald-700">this branch · newer fixes</span>
              )}
              {selPkg.pushId && !selPkg.relation && (
                <span className="inline-flex items-center rounded-full border px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide border-emerald-200 bg-emerald-50 text-emerald-700">pushed by SCC</span>
              )}
            </div>
          </div>
          {firstReleaseUnknown && (
            <p className="text-xs text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2.5">
              Could not load the release history — cannot tell whether this is the app's first
              release. Retry before submitting.
            </p>
          )}
          {firstRelease && (
            <p className="text-xs text-sky-800 bg-sky-50 border border-sky-200 rounded-lg px-3 py-2.5">
              <b>Bootstrap release:</b> this is the app's first OTA release. It must be untargeted
              and auto-concludes upstream (a known upstream quirk can leave it INPROGRESS@50 —
              conclude it manually if so).
            </p>
          )}
          {isDowngrade && (
            <p className="text-xs text-amber-800 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2.5">
              <b>Older than current:</b> pkg v{selPkg.version} is older than the newest known
              release (v{maxKnownPkg}). Releasing it is a rollback.
            </p>
          )}

          {editing && (
            <p className="text-[11px] text-zinc-600 bg-zinc-50 border border-zinc-200 rounded-lg px-3 py-2.5">
              Targeting is locked while editing:{' '}
              <span className="text-zinc-700">{dimsLabel(editing.lockedDims)}</span> — supersede
              (discard + recreate) to retarget.
            </p>
          )}
          {!firstRelease && !editing && (
            <div>
              <div className="text-[10px] uppercase tracking-widest font-bold text-zinc-500 mb-1.5">Targeting</div>
              {rules.map((r, i) => (
                <div key={i} className="flex items-center gap-2 mb-1">
                  <select
                    value={r.dim}
                    onChange={(e) =>
                      setRules(rules.map((x, j) => (j === i ? { ...x, dim: e.target.value } : x)))
                    }
                    className="bg-white border border-zinc-200 rounded-lg px-2.5 py-1.5 text-xs font-medium shadow-sm outline-none focus:ring-2 focus:ring-violet-200 cursor-pointer"
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
                    className="bg-white border border-zinc-200 rounded-lg px-2.5 py-1.5 text-xs font-mono shadow-sm outline-none focus:ring-2 focus:ring-violet-200 focus:border-violet-400 flex-1"
                  />
                  <button
                    onClick={() => setRules(rules.filter((_, j) => j !== i))}
                    className="text-zinc-400 hover:text-red-600 text-xs cursor-pointer px-1"
                  >
                    ✕
                  </button>
                </div>
              ))}
              <button
                onClick={() => setRules([...rules, { dim: '', value: '' }])}
                className="px-3 py-1.5 text-xs font-bold rounded-lg border border-zinc-200 bg-white text-zinc-700 shadow-sm hover:bg-zinc-50 transition-colors cursor-pointer active:scale-[0.98]"
              >
                + add rule
              </button>
              {(() => {
                // R7: airborne has no native-version gating — offer to opt in
                // via the workspace's version dimension, seeded from this build.
                const verDim = dimNames.find((d) => /version/i.test(d));
                const already = verDim && rules.some((r) => r.dim === verDim);
                return verDim && nativeVersion && !already ? (
                  <button
                    onClick={() => setRules([...rules, { dim: verDim, value: nativeVersion }])}
                    className="ml-2 px-3 py-1.5 text-xs font-bold rounded-lg border border-violet-200 bg-violet-50 text-violet-700 shadow-sm hover:bg-violet-100 transition-colors cursor-pointer active:scale-[0.98]"
                  >
                    + target this build's version ({nativeVersion})
                  </button>
                ) : null;
              })()}
              <p className="text-[11px] text-zinc-600 mt-1">Empty targeting = all devices.</p>
              {overlaps && Object.keys(reqDims).length > 0 && (
                <p className="text-[11px] text-amber-800 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2 mt-2">
                  ⚠ Overlaps an ongoing release's targeting — Superposition decides which wins on
                  shared devices. Airborne will not reject this.
                </p>
              )}
            </div>
          )}

          {!firstRelease && !editing && (
            <div>
              <div className="text-[10px] uppercase tracking-widest font-bold text-zinc-500 mb-1.5">Initial traffic</div>
              <div className="flex items-center gap-2">
                <input
                  type="number"
                  min={0}
                  max={50}
                  value={traffic}
                  onChange={(e) => setTraffic(e.target.value)}
                  className="w-20 bg-white border border-zinc-200 rounded-lg px-2.5 py-1.5 text-sm font-mono font-bold text-zinc-800 shadow-sm outline-none focus:ring-2 focus:ring-violet-200 focus:border-violet-400"
                />
                <span className="text-[11px] text-zinc-600">
                  % of matching devices (0–50; 100% only via Conclude later)
                </span>
              </div>
            </div>
          )}

          <p className="text-[11px] text-zinc-600 bg-zinc-50 border border-zinc-100 rounded-lg px-3 py-2.5 leading-relaxed">
            ⓘ This release reaches <b>all</b> devices matching the targeting, on every installed app
            version — airborne has no native-version gating. Bundle ↔ native compatibility is your
            responsibility.
          </p>

          <button
            onClick={() => setShowAdvanced(!showAdvanced)}
            className="text-xs font-bold text-zinc-500 hover:text-zinc-800 underline underline-offset-2 cursor-pointer"
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
                    className="w-24 bg-white border border-zinc-200 rounded-lg px-2 py-1 text-xs font-mono shadow-sm outline-none focus:ring-2 focus:ring-violet-200 ml-1.5"
                  />
                </label>
                <label className="text-xs text-zinc-600">
                  release_config_timeout{' '}
                  <input
                    type="number"
                    value={rcTimeout}
                    onChange={(e) => setRcTimeout(e.target.value)}
                    className="w-24 bg-white border border-zinc-200 rounded-lg px-2 py-1 text-xs font-mono shadow-sm outline-none focus:ring-2 focus:ring-violet-200 ml-1.5"
                  />
                </label>
              </div>
              <div>
                <div className="text-xs text-zinc-600 mb-1">Config properties (JSON object)</div>
                <textarea
                  value={propertiesText}
                  onChange={(e) => setPropertiesText(e.target.value)}
                  rows={3}
                  className="w-full bg-white border border-zinc-200 rounded-lg px-3 py-2 text-xs font-mono shadow-sm outline-none focus:ring-2 focus:ring-violet-200 focus:border-violet-400"
                  placeholder="{}"
                />
              </div>
              {pkgFiles.length > 0 && (
                <div>
                  <div className="text-xs text-zinc-600 mb-1">
                    Lazy files ({lazy.length} of {pkgFiles.length} — everything else is important)
                  </div>
                  <div className="max-h-40 overflow-y-auto border border-zinc-200 rounded-lg divide-y divide-zinc-50 bg-white shadow-sm">
                    {pkgFiles.map((f) => (
                      <label key={f} className="flex items-center gap-2 text-[11px] text-zinc-600 px-2.5 py-1.5 hover:bg-zinc-50 cursor-pointer">
                        <input
                          type="checkbox"
                          checked={lazy.includes(f)}
                          onChange={(e) =>
                            setLazy(e.target.checked ? [...lazy, f] : lazy.filter((x) => x !== f))
                          }
                          className="rounded border-zinc-300 accent-violet-600"
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
          <Button
            onClick={submit}
            disabled={submitting || firstReleaseUnknown}
            className="bg-violet-600 border-violet-600 text-white enabled:hover:bg-violet-700 enabled:active:bg-violet-800"
          >
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

  // Blockers: the preflight payload when present; otherwise (upstream-400
  // backstop carries no detail) derive them from the live release list — the
  // dialog must always NAME what's in the way.
  type Blocker = {
    id: string;
    status: string;
    pkg?: number;
    tag?: string;
    traffic?: number;
    dims: Record<string, unknown>;
    createdAt?: string;
    from?: string;
  };
  const blockers: Blocker[] =
    conflict.length > 0
      ? conflict.map((t) => {
          const liveRel = releases.find((r) => r.id === t.airborneReleaseId);
          return {
            id: t.airborneReleaseId,
            status: (t.status ?? '').toUpperCase(),
            pkg: t.packageVersion ?? (liveRel ? pkgVersionOf(liveRel) : undefined),
            tag: liveRel ? pkgTagOf(liveRel) : undefined,
            traffic: t.trafficPercentage ?? (liveRel ? trafficOf(liveRel) : undefined),
            dims: (t.dimensions as Record<string, unknown> | undefined) ?? (liveRel ? dimsOf(liveRel) : {}),
            createdAt: liveRel?.created_at,
            from: t.link ? `${t.link.groupLabel || t.link.groupId} · ${t.link.sourceRef} · ${t.link.createdBy}` : undefined,
          };
        })
      : releases
          .filter((r) => ['CREATED', 'INPROGRESS'].includes(statusOf(r)))
          .map((r) => ({
            id: r.id ?? '',
            status: statusOf(r),
            pkg: pkgVersionOf(r),
            tag: pkgTagOf(r),
            traffic: trafficOf(r),
            dims: dimsOf(r),
            createdAt: r.created_at,
            from: undefined,
          }));

  const resolve = async (action: 'discard' | 'conclude' | 'revert', b: Blocker) => {
    setBusy(true);
    try {
      if (action === 'discard') {
        await discardOtaRelease(appRef, b.id);
      } else {
        const liveRel = releases.find((r) => r.id === b.id);
        const variants = liveRel?.experiment?.experiment_variants;
        const chosen = action === 'revert' ? variants?.control : variants?.experimentals?.[0];
        if (!chosen || (action === 'conclude' && (variants?.experimentals?.length ?? 0) > 1)) {
          toast.error('Variant ambiguous — resolve this release from the Airborne product page');
          setBusy(false);
          return;
        }
        await concludeOtaRelease(appRef, b.id, {
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
          <p className="text-xs text-zinc-600">
            Airborne allows <b>one ongoing release at a time here</b> — resolve the blocker below
            and the new release is created right after.
          </p>
          {blockers.length === 0 && (
            <p className="text-xs text-zinc-500 border border-dashed border-zinc-200 rounded px-3 py-2.5">
              Upstream reported an ongoing release but none is visible from here — resolve it in the{' '}
              <Link to={`/airborne/${encodeURIComponent(appRef)}`} className="font-bold text-violet-600 hover:underline">
                Airborne dashboard ↗
              </Link>
              .
            </p>
          )}
          {blockers.map((b) => (
            <div key={b.id} className="rounded-lg border border-zinc-200 bg-zinc-50/60 p-3 space-y-2.5">
              <div className="flex items-center justify-between gap-2 text-[9px] font-bold uppercase tracking-widest text-zinc-500">
                <span>{b.status === 'CREATED' ? 'Created but never released' : 'Still rolling out'}</span>
                {b.createdAt && (
                  <span className="font-mono normal-case tracking-normal text-zinc-400" title={fullStamp(b.createdAt)}>
                    since {shortDate(b.createdAt)}
                  </span>
                )}
              </div>
              <div className="flex items-center gap-2 flex-wrap text-xs">
                <span
                  className={cn(
                    'px-1.5 py-0.5 rounded text-[9px] font-bold uppercase',
                    b.status === 'INPROGRESS' ? 'bg-emerald-100 text-emerald-800' : 'bg-sky-100 text-sky-800',
                  )}
                >
                  {b.status === 'INPROGRESS' ? `Live ${b.traffic ?? 0}%` : 'Created · not ramped'}
                </span>
                {b.pkg != null && (
                  <span className="font-mono font-bold text-zinc-800">
                    pkg v{b.pkg}
                    {b.tag && <span className="text-zinc-400 font-medium"> · {b.tag}</span>}
                  </span>
                )}
                <ReleaseId id={b.id} />
                <span className="flex items-center gap-1 flex-wrap">
                  {Object.entries(b.dims).length === 0 ? (
                    <span className="bg-zinc-100 border border-zinc-200 text-zinc-800 font-mono text-[9px] font-semibold px-1.5 py-px rounded">
                      all devices
                    </span>
                  ) : (
                    Object.entries(b.dims).map(([k, v]) => (
                      <span
                        key={k}
                        className="bg-zinc-100 border border-zinc-200 text-zinc-800 font-mono text-[9px] font-semibold px-1.5 py-px rounded"
                      >
                        {k}: {String(v)}
                      </span>
                    ))
                  )}
                </span>
                {b.from && <span className="basis-full text-[11px] text-zinc-500">from {b.from}</span>}
              </div>
              <div className="space-y-2">
                {b.status === 'CREATED' ? (
                  <button
                    disabled={busy}
                    onClick={() => resolve('discard', b)}
                    className="w-full text-left rounded-lg border border-zinc-200 bg-white p-3 hover:bg-zinc-50 hover:border-zinc-300 transition-colors cursor-pointer disabled:opacity-50"
                  >
                    <span className="block text-xs font-bold text-zinc-800">Discard it</span>
                    <span className="block text-[11px] text-zinc-500 mt-0.5 whitespace-normal leading-relaxed">
                      It was never ramped — no device is affected.
                    </span>
                  </button>
                ) : (
                  <>
                    <button
                      disabled={busy}
                      onClick={() => resolve('conclude', b)}
                      className="w-full text-left rounded-lg border border-violet-200 bg-violet-50/60 p-3 hover:bg-violet-50 hover:border-violet-300 transition-colors cursor-pointer disabled:opacity-50"
                    >
                      <span className="block text-xs font-bold text-violet-800">Conclude it</span>
                      <span className="block text-[11px] text-violet-700/80 mt-0.5 whitespace-normal leading-relaxed">
                        Ships it to 100% first; devices then move to the new release when it ramps.
                      </span>
                    </button>
                    <button
                      disabled={busy}
                      onClick={() => resolve('revert', b)}
                      className="w-full text-left rounded-lg border border-red-200 bg-red-50/60 p-3 hover:bg-red-50 hover:border-red-300 transition-colors cursor-pointer disabled:opacity-50"
                    >
                      <span className="block text-xs font-bold text-red-700">Revert it</span>
                      <span className="block text-[11px] text-red-600/80 mt-0.5 whitespace-normal leading-relaxed">
                        Its ramped cohort returns to stable before the new release.
                      </span>
                    </button>
                  </>
                )}
              </div>
            </div>
          ))}
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
