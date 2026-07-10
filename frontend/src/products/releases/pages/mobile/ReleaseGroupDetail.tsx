import { useEffect, useMemo, useState } from 'react';
import { Link, useParams, useNavigate } from 'react-router-dom';
import { ArrowLeft, CheckCircle2, Link2, Send, Smartphone, Apple, Cpu, Info } from 'lucide-react';
import { useReleases, useDispatchMobileReleases } from '../../hooks';
import { approveRelease } from '../../api';
import { useAuth } from '../../../../core/auth/AuthContext';
import { ReleaseStatusBadge } from '../../components/ReleaseStatusBadge';
import { BrandLogo } from '../../components/BrandLogo';
import { versionWithBuild, inFlightPhaseLabel } from '../../utils';
import { Button } from '../../../../shared/ui/button';
import { TableSkeleton } from '../../../../shared/ui/skeleton';
import { cn } from '../../../../lib/utils';
import { toast } from 'sonner';
import type { APRelease } from '../../api';

// Mobile rows reuse the legacy tracker columns: appGroup=app name,
// service=surface, env=platform. See backend insertMobileTracker for the
// origin of this mapping.
const PlatformIcon = ({ platform }: { platform: string }) =>
  platform === 'ios'
    ? <Apple className="w-4 h-4 text-zinc-500" />
    : <Cpu className="w-4 h-4 text-emerald-600" />;

// Mirrors the backend dispatch grouping (Handlers/Release.hs): consumer rows
// share one GH run per (surface, platform); provider (driver) rows additionally
// split by (version, destination) — their workflow takes one version_name per run.
function runKeyOf(r: APRelease): string {
  return r.service === 'driver'
    ? `${r.service}|${r.env}|${r.new_version}|${r.release_context?.destination ?? ''}`
    : `${r.service}|${r.env}`;
}

// Pull the release_group_id out of the normalized release_context, with a
// metadata fallback for any older rows where the field was stashed elsewhere.
function extractGroupId(release: APRelease): string | null {
  const ctx = release.release_context;
  if (ctx && typeof ctx.release_group_id === 'string') {
    return ctx.release_group_id;
  }
  const meta: any = (release as any).metadata;
  if (meta && typeof meta === 'object' && typeof meta.release_group_id === 'string') {
    return meta.release_group_id;
  }
  return null;
}

export default function ReleaseGroupDetail() {
  const { groupId } = useParams<{ groupId: string }>();
  const navigate = useNavigate();
  const { user } = useAuth();

  // Pull a 24h window of mobile releases. The default 60s polling on
  // useReleases is overridden below by a focused refetch when actions fire.
  const fromIso = useMemo(() => new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString(), []);
  const toIso = useMemo(() => new Date(Date.now() + 60_000).toISOString(), []);
  const { data: releases = [], isLoading, refetch } = useReleases(fromIso, toIso, 'mobile');

  // Filter by groupId when the backend exposes release_group_id.
  // If nothing matches (current state of the API) fall back to "no rows" so
  // we don't accidentally render unrelated releases in this view.
  const groupReleases = useMemo(() => {
    if (!groupId) return [];
    return releases.filter((r) => extractGroupId(r) === groupId);
  }, [releases, groupId]);

  const groupingMissing = !isLoading && releases.length > 0 && groupReleases.length === 0;

  // Group-level summary state. Surfaces "is everything approved / dispatched /
  // completed" without forcing the user to count badges across rows. Derived
  // entirely from the per-row `status` + `is_approved` fields.
  //
  //   - All COMPLETED  → "Completed"          (green)
  //   - All terminal w/ any non-COMPLETED → "Failed"  (red — Aborted/Discarded mix)
  //   - Any INPROGRESS → "In progress"        (blue)
  //   - All CREATED + all approved → "Approved" (emerald) — ready to dispatch
  //   - Some approved  → "Partially approved" (amber, with count)
  //   - None approved  → "Pending approval"   (zinc)
  type GroupState = {
    label: string;
    tone: 'emerald' | 'blue' | 'green' | 'red' | 'amber' | 'zinc';
    sub?: string;
  };
  const groupState: GroupState | null = useMemo(() => {
    if (groupReleases.length === 0) return null;
    const total = groupReleases.length;
    const completed = groupReleases.filter((r) => r.status === 'COMPLETED').length;
    const inProgress = groupReleases.filter((r) => r.status === 'INPROGRESS').length;
    const created = groupReleases.filter((r) => r.status === 'CREATED').length;
    const approved = groupReleases.filter((r) => r.is_approved === 1).length;
    const terminal = groupReleases.filter((r) =>
      ['COMPLETED', 'ABORTED', 'USER_ABORTED', 'DISCARDED', 'REVERTED'].includes(r.status),
    ).length;

    if (completed === total) {
      return { label: 'Completed', tone: 'green', sub: `${total}/${total}` };
    }
    if (terminal === total) {
      return { label: 'Failed', tone: 'red', sub: `${completed}/${total} completed` };
    }
    if (inProgress > 0) {
      // Word in-flight rows by their store phase, not "in progress" — a row
      // stays INPROGRESS through review/rollout until it goes live.
      const buckets = new Map<string, number>();
      for (const r of groupReleases) {
        if (r.status !== 'INPROGRESS') continue;
        const label = inFlightPhaseLabel(r);
        buckets.set(label, (buckets.get(label) ?? 0) + 1);
      }
      // Every in-flight row in the same phase (and nothing else pending) →
      // the phase IS the group state; mixed phases fall back to "In progress".
      if (buckets.size === 1 && inProgress + completed === total) {
        const phase = Array.from(buckets.keys())[0];
        return {
          label: phase.charAt(0).toUpperCase() + phase.slice(1),
          tone: 'blue',
          sub: completed > 0 ? `${inProgress} in flight · ${completed} done` : `${inProgress}/${total}`,
        };
      }
      const parts = Array.from(buckets.entries()).map(([label, n]) => `${n} ${label}`);
      return {
        label: 'In progress',
        tone: 'blue',
        sub: `${parts.join(' · ')} · ${completed} done`,
      };
    }
    if (created === total && approved === total) {
      return { label: 'Approved · ready to dispatch', tone: 'emerald', sub: `${total}/${total}` };
    }
    if (approved > 0) {
      return {
        label: 'Partially approved',
        tone: 'amber',
        sub: `${approved}/${total} approved`,
      };
    }
    return { label: 'Pending approval', tone: 'zinc', sub: `0/${total} approved` };
  }, [groupReleases]);

  // Tailwind class map keyed by tone — keeps the JSX below readable.
  const toneClasses: Record<GroupState['tone'], string> = {
    emerald: 'bg-emerald-50 text-emerald-800 border-emerald-200',
    blue: 'bg-blue-50 text-blue-800 border-blue-200',
    green: 'bg-green-50 text-green-800 border-green-200',
    red: 'bg-rose-50 text-rose-800 border-rose-200',
    amber: 'bg-amber-50 text-amber-800 border-amber-200',
    zinc: 'bg-zinc-50 text-zinc-700 border-zinc-200',
  };

  // Only CREATED rows can be approved/dispatched (mirrors the backend
  // validateForDispatch guard) — dispatched rows are monitor-only here.
  const isActionable = (r: APRelease) => r.status === 'CREATED';
  const actionableRows = useMemo(() => groupReleases.filter(isActionable), [groupReleases]);
  const hasActionable = actionableRows.length > 0;

  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const allChecked = hasActionable && actionableRows.every((r) => selectedIds.has(r.id));

  // The 5s poll can move a selected row past CREATED — drop it from the
  // selection so the buttons never target a row the backend would reject.
  useEffect(() => {
    setSelectedIds((prev) => {
      const valid = new Set(actionableRows.map((r) => r.id));
      const next = new Set(Array.from(prev).filter((id) => valid.has(id)));
      return next.size === prev.size ? prev : next;
    });
  }, [actionableRows]);

  const toggleAll = () => {
    setSelectedIds(allChecked ? new Set() : new Set(actionableRows.map((r) => r.id)));
  };

  const toggleOne = (id: string) => {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  // Live preview of what THIS selection dispatches as ("3 apps → 1 build run"),
  // so the one-vs-many-runners consequence is visible BEFORE the click.
  const dispatchPreview = useMemo(() => {
    if (selectedIds.size === 0) return null;
    const rows = groupReleases.filter((r) => selectedIds.has(r.id));
    const runs = new Map<string, APRelease[]>();
    for (const r of rows) {
      const k = runKeyOf(r);
      runs.set(k, [...(runs.get(k) ?? []), r]);
    }
    const parts = Array.from(runs.entries()).map(([k, rs]) => {
      const platform = k.split('|')[1];
      return rs.length > 1 ? `${platform} ×${rs.length} shared` : `${platform} ×1`;
    });
    return { apps: rows.length, runs: runs.size, parts };
  }, [groupReleases, selectedIds]);

  // Rows dispatched together carry the same dispatch_id = one shared GH run.
  // Count the company per run so the chip explains the abort blast radius.
  const runMates = useMemo(() => {
    const counts = new Map<string, number>();
    for (const r of groupReleases) {
      const did = r.release_context?.dispatch_id;
      if (did) counts.set(did, (counts.get(did) ?? 0) + 1);
    }
    return counts;
  }, [groupReleases]);
  const sharedRunCount = (r: APRelease) => {
    const did = r.release_context?.dispatch_id;
    return did ? runMates.get(did) ?? 0 : 0;
  };

  const dispatchMutation = useDispatchMobileReleases();
  const [approving, setApproving] = useState(false);

  const onApproveSelected = async () => {
    const ids = Array.from(selectedIds);
    if (ids.length === 0) return;
    setApproving(true);
    const approver = user?.email || 'local_admin';
    let okCount = 0;
    const failures: string[] = [];
    for (const id of ids) {
      try {
        await approveRelease(id, approver);
        okCount++;
      } catch (err: any) {
        failures.push(`${id}: ${err?.response?.data?.message || err.message || 'failed'}`);
      }
    }
    setApproving(false);
    if (okCount > 0) toast.success(`Approved ${okCount} release${okCount === 1 ? '' : 's'}`);
    if (failures.length > 0) toast.error(`Failed: ${failures.length}`);
    void refetch();
  };

  const onDispatchSelected = async () => {
    const ids = Array.from(selectedIds);
    if (ids.length === 0) return;
    try {
      const resp = await dispatchMutation.mutateAsync(ids);
      const nRuns = resp.dispatches.length;
      toast.success(
        `Dispatched ${ids.length} app${ids.length === 1 ? '' : 's'} in ${nRuns} build run${nRuns === 1 ? '' : 's'}`,
      );
      void refetch();
    } catch {
      // hook handles error toast
    }
  };

  // Re-poll every 5s while the page is open — picks up status transitions
  // (CREATED → INPROGRESS → COMPLETED) without forcing the user to refresh.
  // Note: useReleases also polls on its own at 60s; this overlay gives us a
  // tighter cadence for the in-progress view.
  useEffect(() => {
    const t = setInterval(() => { void refetch(); }, 5000);
    return () => clearInterval(t);
  }, [refetch]);

  return (
    <div className="flex flex-col flex-1 w-full pb-12">
      <div className="flex items-center gap-2 mb-4">
        <Link
          to="/mobile/releases"
          className="inline-flex items-center gap-1 text-sm text-zinc-600 hover:text-zinc-900"
        >
          <ArrowLeft className="w-4 h-4" /> Mobile releases
        </Link>
      </div>

      <div className="bg-white rounded-xl border border-zinc-200">
        <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100 flex flex-wrap items-center justify-between gap-3">
          <div className="min-w-0">
            <h1 className="text-base sm:text-lg font-semibold text-zinc-900 flex items-center gap-2 flex-wrap">
              <Smartphone className="w-4 h-4 text-violet-600" />
              Release group
              {groupState && (
                <span
                  className={cn(
                    'inline-flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-wider border rounded-full px-2.5 py-0.5',
                    toneClasses[groupState.tone],
                  )}
                  // The aggregate state pill — see groupState computation above.
                  // Shows "Approved · ready to dispatch" once every row in
                  // the group is approved (CREATED + is_approved=1). Once
                  // dispatched, transitions through "In progress" → "Completed".
                >
                  {groupState.label}
                  {groupState.sub && (
                    <span className="font-normal normal-case tracking-normal text-[10px] opacity-80">
                      · {groupState.sub}
                    </span>
                  )}
                </span>
              )}
            </h1>
            <p className="text-xs text-zinc-500 mt-0.5 font-mono truncate">{groupId}</p>
          </div>
          {/* Bulk actions only exist while something is still dispatchable —
              a fully dispatched group is monitor-only. */}
          {hasActionable && (
            <div className="flex flex-wrap gap-2">
              <Button
                variant="secondary"
                size="sm"
                onClick={onApproveSelected}
                loading={approving}
                disabled={selectedIds.size === 0}
              >
                <CheckCircle2 className="w-4 h-4" /> Approve selected ({selectedIds.size})
              </Button>
              <Button
                size="sm"
                onClick={onDispatchSelected}
                loading={dispatchMutation.isPending}
                disabled={selectedIds.size === 0}
              >
                <Send className="w-4 h-4" /> Dispatch selected ({selectedIds.size})
              </Button>
            </div>
          )}
        </header>

        {/* Dispatch preview: teaches the one-vs-many-runs semantics at selection
            time — apps selected TOGETHER share one GitHub run per platform. */}
        {dispatchPreview && (
          <div className="px-4 py-2.5 sm:px-6 border-b border-blue-100 bg-blue-50/60 text-xs text-blue-900 flex flex-wrap items-center gap-x-2 gap-y-1">
            <Send className="w-3.5 h-3.5 shrink-0" />
            <span className="font-semibold">
              {dispatchPreview.apps} app{dispatchPreview.apps === 1 ? '' : 's'} selected →{' '}
              {dispatchPreview.runs} build run{dispatchPreview.runs === 1 ? '' : 's'}
            </span>
            <span className="text-blue-700">({dispatchPreview.parts.join(' · ')})</span>
            <span className="text-blue-700/80">
              — apps in a shared run build together, each at its own version;
              un-selected apps stay here and dispatch later as a separate run.
            </span>
          </div>
        )}

        {groupingMissing && (
          <div className="px-4 py-3 sm:px-6 border-b border-amber-200 bg-amber-50 text-amber-800 text-xs flex gap-2 items-start">
            <Info className="w-4 h-4 mt-0.5 shrink-0" />
            <span>
              No releases match this group ID. The list endpoint may not yet
              expose <code>release_context.release_group_id</code> for mobile
              rows — try opening this page right after creating a group, or
              contact the backend team if this persists.
            </span>
          </div>
        )}

        {isLoading ? (
          <TableSkeleton rows={4} cols={6} />
        ) : groupReleases.length === 0 ? (
          <div className="py-16 text-center text-zinc-400 text-sm">
            No releases in this group.
          </div>
        ) : (
          <>
            <div className="hidden md:block overflow-x-auto">
              <table className="w-full text-left whitespace-nowrap">
                <thead>
                  <tr className="bg-zinc-50 border-b border-zinc-200 text-[11px] text-zinc-500 font-medium uppercase tracking-wider">
                    <th className="py-3 px-4 w-10">
                      {hasActionable && (
                        <input
                          type="checkbox"
                          checked={allChecked}
                          onChange={toggleAll}
                          className="rounded border-zinc-300 accent-zinc-900"
                        />
                      )}
                    </th>
                    <th className="py-3 px-4">App</th>
                    <th className="py-3 px-4">Surface</th>
                    <th className="py-3 px-4">Platform</th>
                    <th className="py-3 px-4">Version</th>
                    <th className="py-3 px-4">Status</th>
                    <th className="py-3 px-4">Actions</th>
                  </tr>
                </thead>
                <tbody className="text-sm">
                  {groupReleases.map((r, idx) => {
                    const checked = selectedIds.has(r.id);
                    return (
                      <tr
                        key={r.id}
                        className={cn(
                          'border-b border-zinc-100 hover:bg-zinc-50 transition-colors',
                          idx % 2 === 1 ? 'bg-zinc-50' : 'bg-white',
                        )}
                      >
                        <td className="py-3 px-4">
                          {isActionable(r) && (
                            <input
                              type="checkbox"
                              checked={checked}
                              onChange={() => toggleOne(r.id)}
                              className="rounded border-zinc-300 accent-zinc-900"
                            />
                          )}
                        </td>
                        <td className="py-3 px-4 font-medium text-zinc-800">
                          <span className="inline-flex items-center gap-2">
                            <BrandLogo brand={r.appGroup} surface={r.service === 'driver' ? 'driver' : undefined} size="sm" />
                            {r.appGroup}
                          </span>
                        </td>
                        <td className="py-3 px-4 text-xs text-zinc-600">{r.service}</td>
                        <td className="py-3 px-4">
                          <span className="inline-flex items-center gap-1.5 text-xs text-zinc-600">
                            <PlatformIcon platform={r.env} /> {r.env}
                          </span>
                        </td>
                        <td className="py-3 px-4 font-mono text-xs text-zinc-600">{versionWithBuild(r)}</td>
                        <td className="py-3 px-4">
                          <div className="flex items-center gap-1.5 flex-wrap">
                            <ReleaseStatusBadge release={r} />
                            {r.is_approved === 1 && (
                              <span className="rounded px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-emerald-700 text-white">
                                APPROVED
                              </span>
                            )}
                            {sharedRunCount(r) > 1 && (
                              <span
                                className="inline-flex items-center gap-1 rounded-full border border-blue-200 bg-blue-50 px-2 py-0.5 text-[10px] font-medium text-blue-700"
                                title="Dispatched together: these apps build in ONE GitHub run — aborting one cancels the run for every app still building."
                              >
                                <Link2 className="w-3 h-3" /> shared run · {sharedRunCount(r)}
                              </span>
                            )}
                          </div>
                        </td>
                        <td className="py-3 px-4">
                          <button
                            onClick={() => navigate(`/mobile/releases/${r.id}`)}
                            className="text-xs text-zinc-600 hover:text-zinc-900 underline"
                          >
                            Open
                          </button>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>

            {/* Mobile cards */}
            <div className="md:hidden divide-y divide-zinc-100">
              {groupReleases.map((r) => {
                const checked = selectedIds.has(r.id);
                return (
                  <div key={r.id} className="p-4">
                    <div className="flex items-start gap-3">
                      {isActionable(r) && (
                        <input
                          type="checkbox"
                          checked={checked}
                          onChange={() => toggleOne(r.id)}
                          className="mt-1 rounded border-zinc-300 accent-zinc-900"
                        />
                      )}
                      <div className="min-w-0 flex-1">
                        <div className="flex items-center gap-2 text-sm font-medium text-zinc-900">
                          <BrandLogo brand={r.appGroup} surface={r.service === 'driver' ? 'driver' : undefined} size="sm" />
                          <span className="truncate">{r.appGroup}</span>
                        </div>
                        <div className="text-xs text-zinc-500 mt-0.5">
                          {r.service} ·{' '}
                          <span className="inline-flex items-center gap-1">
                            <PlatformIcon platform={r.env} /> {r.env}
                          </span>
                        </div>
                        <div className="flex items-center gap-1.5 flex-wrap mt-2">
                          <ReleaseStatusBadge release={r} />
                          {r.is_approved === 1 && (
                            <span className="rounded px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-emerald-700 text-white">
                              APPROVED
                            </span>
                          )}
                          {sharedRunCount(r) > 1 && (
                            <span
                              className="inline-flex items-center gap-1 rounded-full border border-blue-200 bg-blue-50 px-2 py-0.5 text-[10px] font-medium text-blue-700"
                              title="Dispatched together: these apps build in ONE GitHub run — aborting one cancels the run for every app still building."
                            >
                              <Link2 className="w-3 h-3" /> shared run · {sharedRunCount(r)}
                            </span>
                          )}
                        </div>
                        <div className="text-[11px] text-zinc-500 font-mono mt-2">
                          {versionWithBuild(r)}
                        </div>
                      </div>
                    </div>
                  </div>
                );
              })}
            </div>
          </>
        )}
      </div>
    </div>
  );
}
