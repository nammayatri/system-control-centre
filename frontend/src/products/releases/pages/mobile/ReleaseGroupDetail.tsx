import { useEffect, useMemo, useState } from 'react';
import { Link, useParams, useNavigate } from 'react-router-dom';
import { ArrowLeft, CheckCircle2, Send, Smartphone, Apple, Cpu, Info } from 'lucide-react';
import { useReleases, useDispatchMobileReleases } from '../../hooks';
import { approveRelease } from '../../api';
import { useAuth } from '../../../../core/auth/AuthContext';
import { ReleaseStatusBadge } from '../../components/ReleaseStatusBadge';
import { versionWithBuild } from '../../utils';
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
      return {
        label: 'In progress',
        tone: 'blue',
        sub: `${inProgress} dispatching · ${completed} done`,
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

  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const allChecked = groupReleases.length > 0 && groupReleases.every((r) => selectedIds.has(r.id));

  const toggleAll = () => {
    setSelectedIds(allChecked ? new Set() : new Set(groupReleases.map((r) => r.id)));
  };

  const toggleOne = (id: string) => {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
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
      toast.success(
        `Dispatched ${resp.dispatches.length} workflow${resp.dispatches.length === 1 ? '' : 's'}`,
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
        </header>

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
                      <input
                        type="checkbox"
                        checked={allChecked}
                        onChange={toggleAll}
                        className="rounded border-zinc-300 accent-zinc-900"
                      />
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
                          <input
                            type="checkbox"
                            checked={checked}
                            onChange={() => toggleOne(r.id)}
                            className="rounded border-zinc-300 accent-zinc-900"
                          />
                        </td>
                        <td className="py-3 px-4 font-medium text-zinc-800">{r.appGroup}</td>
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
                      <input
                        type="checkbox"
                        checked={checked}
                        onChange={() => toggleOne(r.id)}
                        className="mt-1 rounded border-zinc-300 accent-zinc-900"
                      />
                      <div className="min-w-0 flex-1">
                        <div className="text-sm font-medium text-zinc-900 truncate">
                          {r.appGroup}
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
