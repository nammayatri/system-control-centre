// Group-page OTA section in the page's own grammar: select rows → verb from
// the toolbar (same as the builds table above it). One row per capable
// (app, platform); expand a row for the full per-app card (history, metrics,
// attach/cancel). Toolbar verbs run sequentially over the selection with
// per-app verdicts, mirroring the native bulk actions.
import { Fragment, useMemo, useState } from 'react';
import { useQueries } from '@tanstack/react-query';
import { toast } from 'sonner';
import {
  ArrowSquareOutIcon,
  CircleNotchIcon,
  CaretDownIcon,
  CaretRightIcon,
  LockKeyIcon,
  RocketLaunchIcon,
  UploadSimpleIcon,
} from '@phosphor-icons/react';
import { Link } from 'react-router-dom';
import { Button } from '../../../../shared/ui/button';
import { Spinner } from '../../../../shared/ui/spinner';
import {
  Dialog,
  DialogBody,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '../../../../shared/ui/dialog';
import { useConfirm } from '../../../../shared/ui/confirm-dialog';
import { BrandLogo } from '../BrandLogo';
import {
  concludeOtaRelease,
  discardOtaRelease,
  fetchOtaPackages,
  fetchOtaReleases,
  rampOtaRelease,
} from '../../../airborne-ota/api';
import { useOtaAccess } from '../../../airborne-ota/hooks';
import type { OtaRelease } from '../../../airborne-ota/types';
import {
  dispatchGroupOta,
  releaseOtaPackage,
  releaseOtaPush,
  resolveOtaProvenance,
  OTA_RUNNER_POOLS,
  type OtaCapableApp,
  type OtaGroupResp,
  type OtaOngoingConflict,
  type OtaPushRow,
  type OtaReleaseReq,
} from '../../otaApi';
import {
  OtaReleaseComposer,
  OtaSupersedeDialog,
  dimsLabel,
  dimsOf,
  errMsg,
  pkgTagOf,
  pkgVersionOf,
  respData,
  statusOf,
  trafficOf,
  type ReleasablePkg,
} from './OtaPanel';
import { OtaFlow } from '../../pages/mobile/summary/OtaFlow';
import { OtaLifecyclePanel } from './OtaLifecyclePanel';

const keyOf = (c: { appName: string; platform: string }) => `${c.appName}|${c.platform}`;


// Mockup square badges (design family: OtaFlow's PUSH_BADGE/REL_BADGE).
const REL_BADGE: Record<string, string> = {
  CREATED: 'bg-sky-100 text-sky-800',
  INPROGRESS: 'bg-emerald-100 text-emerald-800',
  CONCLUDED: 'bg-emerald-100 text-emerald-800',
  DISCARDED: 'bg-zinc-100 text-zinc-600',
};
const PUSH_BADGE: Record<string, string> = {
  DISPATCHED: 'text-sky-800 bg-sky-100',
  RUNNING: 'text-amber-800 bg-amber-100',
  BUNDLE_PUSHED: 'text-emerald-800 bg-emerald-100',
  FAILED: 'text-red-800 bg-red-100',
};

interface RowData {
  capable: OtaCapableApp;
  sourceRef: string | null;
  latestPush?: OtaPushRow;
  /** Ongoing releases PROVEN to come from this build (link row → this group). */
  ongoing: OtaRelease[];
  /** Ongoing namespace releases NOT from this build — context, never targets. */
  foreignOngoing: OtaRelease[];
  releasesError: boolean;
  /** Release state still on its first fetch — the row shows a spinner. */
  releasesLoading: boolean;
  perms: string[];
  /** This-build packages (proven lineage or SCC push), newest first. */
  eligiblePkgs: ReleasablePkg[];
}

export function OtaSection({
  groupId,
  ota,
  sourceRefFor,
  releaseIdFor,
  nativeVersionFor,
  canDispatchFor,
  unmapped = [],
  onChanged,
}: {
  groupId: string;
  ota: OtaGroupResp;
  sourceRefFor: (app: string, platform: string) => string | null;
  /** Tracker row id per (app, platform) — anchors build-level provenance. */
  releaseIdFor: (app: string, platform: string) => string | null;
  /** Native build version per (app, platform) — for the R7 seed rule. */
  nativeVersionFor: (app: string, platform: string) => string | null;
  /** Per-(app, platform) MOBILE_DISPATCH — unified per-app grants. */
  canDispatchFor: (app: string, platform: string) => boolean;
  /** Group members with NO airborne app — rendered inert with the reason. */
  unmapped?: { appName: string; platform: string; surface: string }[];
  onChanged: () => void;
}) {
  const confirm = useConfirm();
  const access = useOtaAccess();
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [bump, setBump] = useState<'patch' | 'minor' | 'major'>('patch');
  const [notifySlack, setNotifySlack] = useState(true);
  const [runner, setRunner] = useState<string>('ios-debug');
  const [busyVerb, setBusyVerb] = useState<string | null>(null);
  const [rampOpen, setRampOpen] = useState(false);
  const [rampPct, setRampPct] = useState('10');
  const [composer, setComposer] = useState<{
    row: RowData;
    pkg: ReleasablePkg;
    editing?: { releaseId: string; lockedDims: Record<string, unknown> };
  } | null>(null);
  const [conflict, setConflict] = useState<{
    row: RowData;
    pkg: ReleasablePkg;
    req: OtaReleaseReq;
    ongoing: OtaOngoingConflict['ongoing'];
  } | null>(null);

  // Live release state per capable ref — queryKeys shared with OtaPanel, so
  // the expanded card and this table never fetch twice.
  const refs = ota.capableApps.map((c) => c.airborneAppRef);
  const releaseQs = useQueries({
    queries: refs.map((ref) => ({
      queryKey: ['mobile-ota-releases', ref],
      queryFn: () => fetchOtaReleases(ref, { page: 1, count: 30 }),
      retry: false,
      refetchInterval: 15_000,
    })),
  });

  // Package shelves per ref (shared queryKey with the details card).
  const packagesQs = useQueries({
    queries: refs.map((ref) => ({
      queryKey: ['mobile-ota-packages', ref],
      queryFn: () => fetchOtaPackages(ref, { page: 1, count: 8 }),
      retry: false,
      staleTime: 30_000,
    })),
  });

  // Same relation-aware partition as the details card (queryKeys shared with
  // useOtaProvenance, so panel + table read one cache).
  const provQs = useQueries({
    queries: ota.capableApps.map((c, i) => {
      const releases = releaseQs[i]?.data?.data ?? [];
      const reqs: Array<{ version: number; tag?: string }> = [];
      const seen = new Set<number>();
      for (const r of releases.filter((x) => ['CREATED', 'INPROGRESS'].includes(statusOf(x)))) {
        const v = pkgVersionOf(r);
        if (v == null || seen.has(v)) continue;
        seen.add(v);
        const t = r.package?.tag;
        reqs.push({ version: v, tag: typeof t === 'string' ? t : undefined });
      }
      for (const pk of packagesQs[i]?.data?.data ?? []) {
        if (typeof pk.version !== 'number' || seen.has(pk.version)) continue;
        seen.add(pk.version);
        reqs.push({ version: pk.version, tag: typeof pk.tag === 'string' ? pk.tag : undefined });
      }
      const versionsKey = reqs.map((x) => x.version).sort((a, b) => a - b).join(',');
      return {
        queryKey: ['mobile-ota-prov', groupId, c.airborneAppRef, versionsKey],
        queryFn: () => resolveOtaProvenance(groupId, c.airborneAppRef, reqs),
        enabled: reqs.length > 0,
        retry: false,
        staleTime: 5 * 60_000,
      };
    }),
  });

  const rows: RowData[] = useMemo(
    () =>
      ota.capableApps.map((c, i) => {
        const releases = releaseQs[i]?.data?.data ?? [];
        const allOngoing = releases.filter((r) => ['CREATED', 'INPROGRESS'].includes(statusOf(r)));
        const relOf = (v?: number) =>
          v == null
            ? undefined
            : provQs[i]?.data?.packages.find((x) => x.packageVersion === v)?.relation;
        const isMine = (r: OtaRelease) => {
          const rel = relOf(pkgVersionOf(r));
          return (
            rel === 'identical' ||
            rel === 'ahead' ||
            ota.links.some(
              (l) =>
                l.airborneAppRef === c.airborneAppRef &&
                l.airborneReleaseId === r.id &&
                l.groupId === groupId,
            )
          );
        };
        const pushFor = (v: number) =>
          ota.rows.find(
            (x) =>
              x.appName === c.appName &&
              x.platform === c.platform &&
              x.packageVersion === v &&
              x.status === 'BUNDLE_PUSHED',
          );
        const eligiblePkgs: ReleasablePkg[] = (packagesQs[i]?.data?.data ?? [])
          .filter((pk): pk is typeof pk & { version: number } => typeof pk.version === 'number')
          .filter((pk) => {
            const rel = relOf(pk.version);
            return rel === 'identical' || rel === 'ahead' || !!pushFor(pk.version);
          })
          .map((pk) => ({
            version: pk.version,
            tag: typeof pk.tag === 'string' ? pk.tag : undefined,
            pushId: pushFor(pk.version)?.id,
            relation: relOf(pk.version),
          }))
          .sort((a, b) => b.version - a.version);
        return {
          capable: c,
          sourceRef: sourceRefFor(c.appName, c.platform),
          latestPush: ota.rows.find((p) => p.appName === c.appName && p.platform === c.platform),
          ongoing: allOngoing.filter(isMine),
          foreignOngoing: allOngoing.filter((r) => !isMine(r)),
          releasesError: !!releaseQs[i]?.isError,
          releasesLoading: !!releaseQs[i]?.isLoading,
          perms:
            access.data?.apps.find((a) => a.appRef === c.airborneAppRef)?.permissions ?? [],
          eligiblePkgs,
        };
      }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [ota, access.data, sourceRefFor, ...releaseQs.map((q) => q.data), ...provQs.map((q) => q.data), ...packagesQs.map((q) => q.data)],
  );

  const selRows = rows.filter((r) => selected.has(keyOf(r.capable)));
  const toggle = (k: string) =>
    setSelected((s) => {
      const n = new Set(s);
      if (n.has(k)) n.delete(k);
      else n.add(k);
      return n;
    });
  const toggleAll = () =>
    setSelected((s) =>
      s.size === rows.length ? new Set() : new Set(rows.map((r) => keyOf(r.capable))),
    );

  // ── toolbar verbs ─────────────────────────────────────────────────

  // The single ongoing release a bulk verb targets — this build's only;
  // foreign namespace releases are never bulk targets. Ambiguity = skip loudly.
  const soleOngoing = (r: RowData): OtaRelease | string => {
    if (r.ongoing.length === 0)
      return r.foreignOngoing.length > 0
        ? 'no ongoing release from this build (namespace has unrelated activity — see Details)'
        : 'no ongoing release';
    if (r.ongoing.length > 1) return 'multiple ongoing releases — expand the row';
    return r.ongoing[0];
  };

  // Per-row verb eligibility (null = doable). These drive BOTH the toolbar
  // disabled state (a verb enables only when every selected row can take it)
  // and the batch skip guard.
  const pushWhy = (r: RowData): string | null =>
    !canDispatchFor(r.capable.appName, r.capable.platform)
      ? 'no MOBILE_DISPATCH grant for this app'
      : !r.capable.pushEligible
        ? (r.capable.ineligibleReason ?? 'not eligible')
        : null;
  const rampWhy = (r: RowData): string | null => {
    // Blocked builds can only wind DOWN — conclude/revert/discard stay live.
    if (r.capable.releaseBlocked) return `OTA blocked — ${r.capable.releaseBlocked}`;
    const s = soleOngoing(r);
    if (typeof s === 'string') return s;
    if (!r.perms.includes('OTA_RELEASE_RAMP')) return 'no RAMP permission';
    return null;
  };
  const concludeWhy =
    (revert: boolean) =>
    (r: RowData): string | null => {
      const s = soleOngoing(r);
      if (typeof s === 'string') return s;
      if (statusOf(s) !== 'INPROGRESS') return 'not ramped (use Discard)';
      if (!r.perms.includes('OTA_RELEASE_CONCLUDE')) return 'no CONCLUDE permission';
      if (!concludeVariant(s, revert)) return 'variant ambiguous — use Airborne page';
      return null;
    };
  const discardWhy = (r: RowData): string | null => {
    const s = soleOngoing(r);
    if (typeof s === 'string') return s;
    if (statusOf(s) !== 'CREATED') return 'already ramped (Conclude or Revert instead)';
    if (!r.perms.includes('OTA_RELEASE_DISCARD')) return 'no DISCARD permission';
    return null;
  };

  // Toolbar state: disabled unless every selected row can take the verb; the
  // tooltip names the blockers so a disabled button is never a mystery.
  const verbState = (why: (r: RowData) => string | null) => {
    if (busyVerb) return { disabled: true, title: undefined };
    if (selRows.length === 0) return { disabled: true, title: 'Select apps first' };
    const blockers = selRows
      .map((r) => ({ r, w: why(r) }))
      .filter((t): t is { r: RowData; w: string } => !!t.w);
    if (blockers.length > 0)
      return {
        disabled: true,
        title: blockers
          .map((t) => `${t.r.capable.appName}/${t.r.capable.platform}: ${t.w}`)
          .join('\n'),
      };
    return { disabled: false, title: undefined };
  };

  const runBatch = async (
    verb: string,
    eligible: (r: RowData) => string | null, // null = ok, string = skip reason
    describe: (r: RowData) => string,
    act: (r: RowData) => Promise<void>,
  ) => {
    const targets = selRows.map((r) => ({ r, why: eligible(r) }));
    const go = targets.filter((t) => !t.why);
    const skipped = targets.filter((t) => t.why);
    if (go.length === 0) {
      toast.error(`No selected app is eligible to ${verb.toLowerCase()}`);
      return;
    }
    const ok = await confirm({
      title: `${verb} ${go.length} release${go.length > 1 ? 's' : ''}?`,
      description:
        go.map((t) => describe(t.r)).join('\n') +
        (skipped.length
          ? `\n\nSkipped: ${skipped.map((t) => `${t.r.capable.appName}/${t.r.capable.platform} (${t.why})`).join('; ')}`
          : ''),
      variant: verb === 'Conclude' ? 'primary' : 'danger',
    });
    if (!ok) return;
    setBusyVerb(verb);
    let done = 0;
    for (const t of go) {
      try {
        await act(t.r);
        done++;
      } catch (e) {
        toast.error(`${t.r.capable.appName}/${t.r.capable.platform}: ${errMsg(e, 'failed')}`);
      }
    }
    setBusyVerb(null);
    toast.success(`${verb}: ${done}/${go.length} done`);
    onChanged();
  };

  const doPush = async () => {
    // CI takes apps × platforms as a cross-product; the selection must form a
    // full grid or the dispatch would build unselected combinations.
    const apps = [...new Set(selRows.map((r) => r.capable.appName))];
    const plats = [...new Set(selRows.map((r) => r.capable.platform))];
    const gridOk = apps.every((a) =>
      plats.every(
        (p) =>
          selRows.some((r) => r.capable.appName === a && r.capable.platform === p) ||
          !rows.some((r) => r.capable.appName === a && r.capable.platform === p),
      ),
    );
    if (!gridOk) {
      toast.error(
        'Selection must form a full app × platform grid (the CI matrix builds every combination)',
      );
      return;
    }
    const ineligible = selRows.filter((r) => !r.capable.pushEligible);
    if (ineligible.length > 0) {
      toast.error(
        `Not pushable: ${ineligible
          .map((r) => `${r.capable.appName}/${r.capable.platform} (${r.capable.ineligibleReason ?? 'not eligible'})`)
          .join('; ')}`,
      );
      return;
    }
    setBusyVerb('Push');
    try {
      const res = await dispatchGroupOta(groupId, {
        versionBump: bump,
        apps,
        platforms: plats,
        notifySlack,
        runner,
      });
      toast.success(`OTA bundle push dispatched (${bump}) — ${res.dispatched} app(s)`);
      setSelected(new Set());
      onChanged();
    } catch (e) {
      toast.error(errMsg(e, 'dispatch failed'));
    } finally {
      setBusyVerb(null);
    }
  };

  // Single-app re-dispatch (the failed-state "Retry push" verb) — same
  // workflow inputs as the toolbar push, scoped to one (app, platform).
  const doPushFor = async (r: RowData) => {
    if (busyVerb) return;
    setBusyVerb('Push');
    try {
      await dispatchGroupOta(groupId, {
        versionBump: bump,
        apps: [r.capable.appName],
        platforms: [r.capable.platform],
        notifySlack,
        runner,
      });
      toast.success(`OTA bundle push dispatched (${bump}) — ${r.capable.appName} ${r.capable.platform}`);
      onChanged();
    } catch (e) {
      toast.error(errMsg(e, 'dispatch failed'));
    } finally {
      setBusyVerb(null);
    }
  };

  const doRampBatch = async (pct: number) => {
    setRampOpen(false);
    await runBatch(
      'Ramp',
      rampWhy,
      (r) => {
        const rel = soleOngoing(r) as OtaRelease;
        return `${r.capable.appName}/${r.capable.platform}: ${trafficOf(rel) ?? 0}% → ${pct}% (pkg v${pkgVersionOf(rel) ?? '?'}, ${rel.id})`;
      },
      async (r) => {
        const rel = soleOngoing(r) as OtaRelease;
        await rampOtaRelease(r.capable.airborneAppRef, rel.id!, {
          trafficPercentage: pct,
          changeReason: `via SCC mobile release ${groupId}`,
          expectedTrafficPercentage: trafficOf(rel),
        });
      },
    );
  };

  const concludeVariant = (rel: OtaRelease, revert: boolean): string | null => {
    const v = rel.experiment?.experiment_variants;
    const chosen = revert ? v?.control : v?.experimentals?.[0];
    if (!chosen || (!revert && (v?.experimentals?.length ?? 0) > 1)) return null;
    return chosen;
  };

  const doConcludeBatch = (revert: boolean) =>
    runBatch(
      revert ? 'Revert' : 'Conclude',
      concludeWhy(revert),
      (r) => {
        const rel = soleOngoing(r) as OtaRelease;
        return `${r.capable.appName}/${r.capable.platform}: pkg v${pkgVersionOf(rel) ?? '?'} at ${trafficOf(rel) ?? 0}% → ${revert ? 'back to stable' : '100%'} (${rel.id})`;
      },
      async (r) => {
        const rel = soleOngoing(r) as OtaRelease;
        await concludeOtaRelease(r.capable.airborneAppRef, rel.id!, {
          chosenVariant: concludeVariant(rel, revert)!,
          changeReason: `${revert ? 'Revert' : 'Conclude'} via SCC mobile release ${groupId}`,
        });
      },
    );

  const doDiscardBatch = () =>
    runBatch(
      'Discard',
      discardWhy,
      (r) => {
        const rel = soleOngoing(r) as OtaRelease;
        return `${r.capable.appName}/${r.capable.platform}: pkg v${pkgVersionOf(rel) ?? '?'} — never ramped, no device affected (${rel.id})`;
      },
      async (r) => {
        const rel = soleOngoing(r) as OtaRelease;
        await discardOtaRelease(r.capable.airborneAppRef, rel.id!);
      },
    );

  // Release… enables for one selected app with ≥1 this-build package —
  // never for a build whose state blocks OTA creation (draft/building/failed).
  const releaseTarget =
    selRows.length === 1 &&
    selRows[0].eligiblePkgs.length > 0 &&
    !selRows[0].capable.releaseBlocked &&
    selRows[0].perms.includes('OTA_RELEASE_CREATE')
      ? selRows[0]
      : null;

  const submitRelease = async (row: RowData, pkg: ReleasablePkg, req: OtaReleaseReq) => {
    try {
      const res = pkg.pushId
        ? await releaseOtaPush(pkg.pushId, req)
        : await releaseOtaPackage(groupId, {
            airborneAppRef: row.capable.airborneAppRef,
            packageVersion: pkg.version,
            packageTag: pkg.tag,
            ...req,
          });
      toast.success(
        res.firstRelease
          ? 'Bootstrap release created (auto-concluded upstream)'
          : res.ramped
            ? `Release created and ramped to ${req.initialTrafficPercent}%`
            : 'Release created',
      );
      setComposer(null);
      setConflict(null);
      onChanged();
    } catch (e) {
      const data = respData(e) as Partial<OtaOngoingConflict> | undefined;
      if (data?.code === 'ONGOING_RELEASE_EXISTS') {
        setConflict({ row, pkg, req, ongoing: data.ongoing ?? [] });
      } else {
        toast.error(errMsg(e, 'release failed'));
      }
    }
  };

  const pushState = (() => {
    if (ota.activePush)
      return {
        disabled: true,
        title: `An OTA push is active (group ${ota.activePush.groupId}, by ${ota.activePush.dispatchedBy})`,
      };
    return verbState(pushWhy);
  })();

  return (
    <div className="bg-white rounded-xl border border-zinc-200 border-l-[6px] border-l-violet-500 overflow-hidden shadow-[0_4px_12px_-4px_rgba(0,0,0,0.05)]">
      {/* Toolbar — push form + selection verbs (violet OTA identity) */}
      <div className="flex items-center gap-2 flex-wrap px-4 py-3 border-b border-violet-100 bg-violet-50/50">
        <span className="inline-flex items-center gap-1 bg-violet-100 text-violet-800 border border-violet-200 text-[9px] px-1.5 py-0.5 rounded font-bold uppercase tracking-wider shadow-sm">
          <RocketLaunchIcon size={11} weight="fill" className="text-violet-600" aria-hidden="true" /> OTA
        </span>
        <label
          className="inline-flex items-center gap-1.5 text-[11px] text-zinc-600"
          title="Semver bump for the bundle version the CI assigns"
        >
          Bump
          <select
            value={bump}
            onChange={(e) => setBump(e.target.value as typeof bump)}
            className="rounded-md border border-zinc-300 px-2 py-1.5 text-xs text-zinc-800"
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
            className="rounded-md border border-zinc-300 px-2 py-1.5 text-xs text-zinc-800"
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
            className="rounded border-zinc-300 accent-zinc-900"
          />
          Notify Slack
        </label>
        <Button
          size="sm"
          className="bg-zinc-900 text-white border-zinc-900 enabled:hover:bg-zinc-800 disabled:bg-zinc-100 disabled:text-zinc-400 disabled:border-zinc-200"
          disabled={pushState.disabled}
          onClick={doPush}
          title={pushState.title}
        >
          {pushState.disabled && ota.activePush ? (
            <LockKeyIcon size={13} weight="bold" className="mr-1" aria-hidden="true" />
          ) : (
            <UploadSimpleIcon size={13} weight="bold" className="mr-1" aria-hidden="true" />
          )}
          {busyVerb === 'Push'
            ? 'Dispatching…'
            : pushState.disabled && ota.activePush
              ? 'Queue locked'
              : 'Push bundle'}
        </Button>
        <div className="h-5 w-px bg-violet-200/70 mx-1" />
        <Button
          size="sm"
          variant="secondary"
          disabled={!releaseTarget || busyVerb !== null}
          onClick={() =>
            releaseTarget && setComposer({ row: releaseTarget, pkg: releaseTarget.eligiblePkgs[0] })
          }
          title={
            releaseTarget
              ? undefined
              : selRows.length !== 1
                ? 'Select exactly one app'
                : 'Selected app has no this-build package (push a bundle first) or lacks OTA_RELEASE_CREATE'
          }
        >
          Release
        </Button>
        <Button
          size="sm"
          variant="secondary"
          disabled={verbState(rampWhy).disabled}
          title={verbState(rampWhy).title}
          onClick={() => setRampOpen(true)}
        >
          Ramp
        </Button>
        <Button
          size="sm"
          variant="secondary"
          disabled={verbState(concludeWhy(false)).disabled}
          title={verbState(concludeWhy(false)).title}
          onClick={() => void doConcludeBatch(false)}
        >
          Conclude
        </Button>
        <Button
          size="sm"
          variant="secondary"
          className="text-red-600 border-red-200 enabled:hover:bg-red-50"
          disabled={verbState(concludeWhy(true)).disabled}
          title={verbState(concludeWhy(true)).title}
          onClick={() => void doConcludeBatch(true)}
        >
          Revert
        </Button>
        <Button
          size="sm"
          variant="secondary"
          className="text-red-600 border-red-200 enabled:hover:bg-red-50"
          disabled={verbState(discardWhy).disabled}
          title={verbState(discardWhy).title}
          onClick={() => void doDiscardBatch()}
        >
          Discard
        </Button>
        <span className="ml-auto inline-flex items-center gap-3">
          {(busyVerb != null ||
            releaseQs.some((q) => q.isFetching) ||
            packagesQs.some((q) => q.isFetching)) && (
            <span className="inline-flex items-center gap-1.5 text-[11px] text-violet-600 font-medium">
              <CircleNotchIcon size={13} weight="bold" className="animate-spin" aria-hidden="true" />
              {busyVerb ? `${busyVerb}…` : 'syncing…'}
            </span>
          )}
          {ota.activePush && (
            <span className="text-[11px] text-amber-700">
              push active · group {ota.activePush.groupId.slice(0, 8)} · {ota.activePush.dispatchedBy}
            </span>
          )}
        </span>
      </div>

      {/* Table */}
      <table className="w-full hidden md:table">
        <thead>
          <tr className="text-left text-[11px] font-bold uppercase tracking-wider text-zinc-500 bg-zinc-50 border-b border-zinc-200">
            <th className="pl-4 py-2 w-10">
              <input
                type="checkbox"
                checked={selected.size === rows.length && rows.length > 0}
                onChange={toggleAll}
                className="rounded border-zinc-300 accent-zinc-900"
              />
            </th>
            <th className="py-2">App</th>
            <th className="py-2">Ongoing release</th>
            <th className="py-2">Latest push</th>
            <th className="py-2 pr-4 w-20"></th>
          </tr>
        </thead>
        <tbody className="divide-y divide-zinc-100">
          {rows.map((r) => {
            const k = keyOf(r.capable);
            const isSel = selected.has(k);
            const isExp = expanded.has(k);
            const rel = r.ongoing[0];
            return (
              <Fragment key={k}>
                <tr
                  className={`text-sm cursor-pointer ${isSel ? 'bg-zinc-100/70' : 'hover:bg-zinc-50'}`}
                  onClick={() => toggle(k)}
                >
                  <td className="pl-4 py-2.5">
                    <input
                      type="checkbox"
                      checked={isSel}
                      onChange={() => toggle(k)}
                      onClick={(e) => e.stopPropagation()}
                      className="rounded border-zinc-300 accent-zinc-900"
                    />
                  </td>
                  <td className="py-2.5">
                    <div className="flex items-center gap-2">
                      <BrandLogo brand={r.capable.appName} size="sm" />
                      <span className="font-medium text-zinc-900">{r.capable.appName}</span>
                      <span className="text-xs text-zinc-600">{r.capable.platform}</span>
                      {r.capable.releaseBlocked ? (
                        <span
                          className="text-[10px] font-semibold text-red-500"
                          title={`${r.capable.releaseBlocked} — OTA push/release disabled for this build; ongoing releases can still be operated`}
                        >
                          ⚠ OTA blocked · {r.capable.releaseBlocked}
                        </span>
                      ) : !r.capable.pushEligible ? (
                        <span
                          className="text-[10px] text-zinc-600"
                          title={r.capable.ineligibleReason}
                        >
                          ⓘ no push
                        </span>
                      ) : null}
                    </div>
                  </td>
                  <td className="py-2.5">
                    {r.releasesError ? (
                      <span className="text-xs text-zinc-600">airborne unreachable</span>
                    ) : !r.perms.includes('OTA_VIEW') ? (
                      <span className="text-xs text-zinc-600">no access</span>
                    ) : r.releasesLoading ? (
                      <Spinner size="sm" label="loading…" />
                    ) : r.ongoing.length === 0 ? (
                      r.foreignOngoing.some((x) => statusOf(x) === 'INPROGRESS') ? (
                        <span
                          className="text-xs text-amber-700"
                          title="A release NOT from this build is serving traffic in this app's namespace — see Details"
                        >
                          ⚠ unrelated release serving traffic
                        </span>
                      ) : (
                        <span className="text-xs text-zinc-600">— stable serves all</span>
                      )
                    ) : (
                      <div className="flex items-center gap-2 flex-wrap">
                        <span
                          className={`px-1.5 py-0.5 rounded text-[9px] font-bold uppercase ${REL_BADGE[statusOf(rel)] ?? 'bg-zinc-100 text-zinc-600'}`}
                        >
                          {statusOf(rel) === 'INPROGRESS' ? `Live ${trafficOf(rel) ?? 0}%` : statusOf(rel) === 'CREATED' ? 'Created · not ramped' : statusOf(rel)}
                        </span>
                        <span className="text-xs font-mono font-semibold text-zinc-800">
                          pkg v{pkgVersionOf(rel) ?? '?'}
                        </span>
                        {pkgTagOf(rel) && (
                          <span className="text-[11px] font-mono text-zinc-600">{pkgTagOf(rel)}</span>
                        )}
                        {rel.id && (
                          <Link
                            to={`/airborne/${encodeURIComponent(r.capable.airborneAppRef)}/releases/${encodeURIComponent(rel.id)}`}
                            onClick={(e) => e.stopPropagation()}
                            className="text-violet-600 hover:text-violet-800"
                            title={`Open release ${rel.id} in Airborne`}
                          >
                            <ArrowSquareOutIcon size={12} aria-hidden="true" />
                          </Link>
                        )}
                        <span className="text-[11px] text-zinc-600">{dimsLabel(dimsOf(rel))}</span>
                        {r.ongoing.length > 1 && (
                          <span className="text-[11px] text-amber-600">
                            +{r.ongoing.length - 1} more
                          </span>
                        )}
                      </div>
                    )}
                  </td>
                  <td className="py-2.5">
                    {r.latestPush ? (
                      <div className="flex items-center gap-2">
                        <span className={`px-1.5 py-0.5 rounded text-[9px] font-bold uppercase ${PUSH_BADGE[r.latestPush.status]}`}>
                          {r.latestPush.status}
                        </span>
                        {r.latestPush.packageVersion != null && (
                          <span className="text-xs font-mono text-zinc-700">
                            pkg v{r.latestPush.packageVersion}
                          </span>
                        )}
                        {r.latestPush.runUrl && (
                          <a
                            href={r.latestPush.runUrl}
                            target="_blank"
                            rel="noreferrer"
                            onClick={(e) => e.stopPropagation()}
                            className="text-[11px] text-violet-600 hover:underline"
                          >
                            CI ↗
                          </a>
                        )}
                      </div>
                    ) : (
                      <span className="text-xs text-zinc-600">—</span>
                    )}
                  </td>
                  <td className="py-2.5 pr-4 text-right">
                    <button
                      onClick={(e) => {
                        e.stopPropagation();
                        setExpanded((s) => {
                          const n = new Set(s);
                          if (n.has(k)) n.delete(k);
                          else n.add(k);
                          return n;
                        });
                      }}
                      className="inline-flex items-center gap-0.5 text-xs text-zinc-600 hover:text-zinc-900"
                    >
                      {isExp ? <CaretDownIcon size={13} weight="bold" aria-hidden="true" /> : <CaretRightIcon size={13} weight="bold" aria-hidden="true" />}
                      Details
                    </button>
                  </td>
                </tr>
                {isExp && (
                  <tr>
                    <td colSpan={5} className="p-4 bg-zinc-50/60">
                      <OtaLifecyclePanel
                        loading={r.releasesLoading}
                        releaseBlocked={r.capable.releaseBlocked ?? null}
                        prov={provQs[refs.indexOf(r.capable.airborneAppRef)]?.data?.packages ?? []}
                        foreignPkgCount={
                          (packagesQs[refs.indexOf(r.capable.airborneAppRef)]?.data?.data ?? []).filter(
                            (pk) =>
                              typeof pk.version === 'number' &&
                              !r.eligiblePkgs.some((e) => e.version === pk.version),
                          ).length
                        }
                        groupId={groupId}
                        appName={r.capable.appName}
                        platform={r.capable.platform}
                        airborneAppRef={r.capable.airborneAppRef}
                        pushes={ota.rows.filter(
                          (p) => p.appName === r.capable.appName && p.platform === r.capable.platform,
                        )}
                        ongoing={r.ongoing}
                        foreignOngoing={r.foreignOngoing}
                        releases={releaseQs[refs.indexOf(r.capable.airborneAppRef)]?.data?.data ?? []}
                        eligiblePkgs={r.eligiblePkgs}
                        perms={r.perms}
                        canDispatch={canDispatchFor(r.capable.appName, r.capable.platform)}
                        nativeVersion={nativeVersionFor(r.capable.appName, r.capable.platform)}
                        onRelease={(pkg) => setComposer({ row: r, pkg })}
                        onEdit={(rel, pkg) =>
                          rel.id && setComposer({ row: r, pkg, editing: { releaseId: rel.id, lockedDims: dimsOf(rel) } })
                        }
                        onRetryPush={() => void doPushFor(r)}
                        onChanged={onChanged}
                      />
                    </td>
                  </tr>
                )}
              </Fragment>
            );
          })}
        </tbody>
      </table>

      {/* Unmapped apps footer (desktop) — the mockup's compact "not OTA-capable"
          line, instead of inert table rows. */}
      {unmapped.length > 0 && (
        <div className="hidden md:block bg-zinc-50 border-t border-zinc-100 px-4 py-2 text-[10px] text-zinc-600 font-medium">
          Not OTA-capable:{' '}
          {unmapped.map((u, i) => (
            <span key={`${u.appName}|${u.platform}`}>
              {i > 0 && ' · '}
              <span className="font-mono text-zinc-700">
                {u.appName} {u.platform}
              </span>
            </span>
          ))}
          {unmapped.every((u) => u.surface === 'driver')
            ? ' — airborne is not available for provider apps.'
            : ' — no Airborne app mapped (set “OTA ref” in Mobile Apps admin).'}
        </div>
      )}

      {/* Mobile fallback: the cards */}
      <div className="md:hidden p-3 space-y-3">
        {rows.map((r) => (
          <OtaFlow
            key={keyOf(r.capable)}
            groupId={groupId}
            releaseId={releaseIdFor(r.capable.appName, r.capable.platform) ?? ''}
            appName={r.capable.appName}
            platform={r.capable.platform}
            airborneAppRef={r.capable.airborneAppRef}
            sourceRef={r.sourceRef}
            nativeVersion={nativeVersionFor(r.capable.appName, r.capable.platform)}
            buildSuperseded={r.capable.superseded}
            pushEligible={r.capable.pushEligible}
            ineligibleReason={r.capable.ineligibleReason}
            releaseBlocked={r.capable.releaseBlocked ?? null}
            pushes={ota.rows}
            links={ota.links}
            activePush={ota.activePush ?? null}
            canDispatch={canDispatchFor(r.capable.appName, r.capable.platform)}
            onChanged={onChanged}
          />
        ))}
        {unmapped.map((u) => (
          <div
            key={`${u.appName}|${u.platform}`}
            className="flex items-center gap-2 rounded-lg border border-zinc-200 bg-zinc-50 px-3 py-2 text-xs text-zinc-600 opacity-70"
          >
            <BrandLogo brand={u.appName} surface={u.surface === 'driver' ? 'driver' : undefined} size="sm" />
            <span className="font-medium text-zinc-600">{u.appName}</span>
            <span className="text-zinc-600">{u.platform}</span>
            <span className="ml-auto">
              {u.surface === 'driver' ? 'no OTA (provider)' : 'no airborne app mapped'}
            </span>
          </div>
        ))}
      </div>

      {/* Ramp % dialog */}
      {rampOpen && (
        <Dialog open onOpenChange={(o) => !o && setRampOpen(false)}>
          <DialogContent size="sm">
            <DialogHeader>
              <DialogTitle>Ramp selected releases</DialogTitle>
            </DialogHeader>
            <DialogBody className="space-y-2">
              <div className="flex items-center gap-2">
                <input
                  type="number"
                  min={0}
                  max={50}
                  value={rampPct}
                  onChange={(e) => setRampPct(e.target.value)}
                  className="w-24 rounded border border-zinc-300 px-2 py-1 text-sm"
                  autoFocus
                />
                <span className="text-xs text-zinc-600">
                  % of matching devices (0–50; 100% only via Conclude)
                </span>
              </div>
              <p className="text-[11px] text-zinc-600">
                Applies to each selected app's single ongoing release; apps with none (or several)
                are skipped and listed in the confirmation.
              </p>
            </DialogBody>
            <DialogFooter>
              <Button variant="outline" onClick={() => setRampOpen(false)}>
                Cancel
              </Button>
              <Button
                onClick={() => {
                  const n = Number(rampPct);
                  if (!Number.isFinite(n) || n < 0 || n > 50) {
                    toast.error('Traffic must be 0–50');
                    return;
                  }
                  void doRampBatch(n);
                }}
              >
                Ramp
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      )}

      {composer && (
        <OtaReleaseComposer
          appRef={composer.row.capable.airborneAppRef}
          appName={composer.row.capable.appName}
          platform={composer.row.capable.platform}
          initial={composer.pkg}
          pkgs={composer.row.eligiblePkgs.length > 0 ? composer.row.eligiblePkgs : [composer.pkg]}
          nativeVersion={nativeVersionFor(composer.row.capable.appName, composer.row.capable.platform)}
          nudgeVersionTarget={composer.row.capable.superseded}
          firstRelease={
            composer.row.perms.includes('OTA_VIEW') &&
            !composer.row.releasesError &&
            (releaseQs[refs.indexOf(composer.row.capable.airborneAppRef)]?.data?.data ?? [])
              .length === 0
          }
          firstReleaseUnknown={composer.row.releasesError}
          ongoing={[...composer.row.ongoing, ...composer.row.foreignOngoing]}
          maxKnownPkg={Math.max(
            0,
            ...(releaseQs[refs.indexOf(composer.row.capable.airborneAppRef)]?.data?.data ?? []).map(
              (r) => pkgVersionOf(r) ?? 0,
            ),
          )}
          editing={composer.editing}
          onClose={() => setComposer(null)}
          onSubmit={(pkg, req) => void submitRelease(composer.row, pkg, req)}
          onSaved={() => {
            setComposer(null);
            onChanged();
          }}
        />
      )}

      {conflict && (
        <OtaSupersedeDialog
          appRef={conflict.row.capable.airborneAppRef}
          groupId={groupId}
          conflict={conflict.ongoing}
          releases={
            releaseQs[refs.indexOf(conflict.row.capable.airborneAppRef)]?.data?.data ?? []
          }
          onClose={() => setConflict(null)}
          onResolved={() => void submitRelease(conflict.row, conflict.pkg, conflict.req)}
        />
      )}
    </div>
  );
}
