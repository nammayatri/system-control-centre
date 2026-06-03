import { useMemo } from 'react';
import { Link } from 'react-router-dom';
import { Layers, Smartphone, Apple, Cpu } from 'lucide-react';
import { useReleases } from '../../hooks';
import { TableSkeleton } from '../../../../shared/ui/skeleton';
import { Button } from '../../../../shared/ui/button';
import { formatDate } from '../../../../lib/utils';
import type { APRelease } from '../../api';

/**
 * All Release Groups — the listing page sibling to
 * `/mobile/groups/:groupId` (the detail page). Aggregates every mobile
 * release in the configured time window by its `release_group_id` and
 * renders one row per group.
 *
 * Why client-side aggregation: there's no backend endpoint that lists
 * groups directly; a "group" is just `DISTINCT release_context.release_group_id`
 * over the mobile release rows. For MVP-volume releases this is fine
 * (24h window, ~tens of rows). If group volume ever exceeds the page-size
 * worth, add a server-side `GET /releases/mobile/groups` endpoint and
 * swap the data source — none of the UI has to change.
 */

// Pull the release_group_id out of a normalized release. Same extractor as
// ReleaseGroupDetail (intentionally duplicated rather than shared so this
// file is independent — small enough that the duplication isn't painful).
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

const PlatformIcon = ({ platform }: { platform: string }) =>
  platform === 'ios' ? (
    <Apple className="w-3.5 h-3.5 text-zinc-500" />
  ) : (
    <Cpu className="w-3.5 h-3.5 text-emerald-600" />
  );

interface GroupSummary {
  groupId: string;
  releaseCount: number;
  apps: string[];
  platforms: Set<'android' | 'ios'>;
  statuses: Record<string, number>;
  earliestCreated: string;
  latestUpdated: string;
}

export default function ReleaseGroupsList() {
  // Same 24h window as ReleaseGroupDetail — keeps the listing predictable
  // and bounded. Older groups can still be navigated to by URL if you have
  // the UUID, but they won't show up here without widening the window.
  const fromIso = useMemo(
    () => new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString(),
    [],
  );
  const toIso = useMemo(() => new Date(Date.now() + 60_000).toISOString(), []);
  const {
    data: releases = [],
    isLoading,
    error,
  } = useReleases(fromIso, toIso, 'mobile');

  // Aggregate releases → groups. One pass, keyed by groupId.
  const groups: GroupSummary[] = useMemo(() => {
    const m = new Map<string, GroupSummary>();
    for (const r of releases) {
      const gid = extractGroupId(r);
      if (!gid) continue;
      let g = m.get(gid);
      if (!g) {
        g = {
          groupId: gid,
          releaseCount: 0,
          apps: [],
          platforms: new Set(),
          statuses: {},
          earliestCreated: r.date_created || '',
          latestUpdated: r.date_created || '',
        };
        m.set(gid, g);
      }
      g.releaseCount += 1;
      if (r.appGroup && !g.apps.includes(r.appGroup)) g.apps.push(r.appGroup);
      if (r.env === 'android' || r.env === 'ios') g.platforms.add(r.env);
      const status = r.status || 'UNKNOWN';
      g.statuses[status] = (g.statuses[status] ?? 0) + 1;
      if (r.date_created && r.date_created < g.earliestCreated) {
        g.earliestCreated = r.date_created;
      }
      if (r.date_created && r.date_created > g.latestUpdated) {
        g.latestUpdated = r.date_created;
      }
    }
    // Newest groups first.
    return Array.from(m.values()).sort((a, b) =>
      b.latestUpdated.localeCompare(a.latestUpdated),
    );
  }, [releases]);

  // Short status pill text — "3 CREATED · 1 COMPLETED" etc. Sorted to keep
  // the most useful states first.
  const STATUS_ORDER = [
    'CREATED',
    'INPROGRESS',
    'COMPLETED',
    'ABORTED',
    'USER_ABORTED',
    'DISCARDED',
  ];
  const summaryStatuses = (statuses: Record<string, number>): string =>
    Object.entries(statuses)
      .sort(
        (a, b) =>
          (STATUS_ORDER.indexOf(a[0]) === -1 ? 99 : STATUS_ORDER.indexOf(a[0])) -
          (STATUS_ORDER.indexOf(b[0]) === -1 ? 99 : STATUS_ORDER.indexOf(b[0])),
      )
      .map(([s, n]) => `${n} ${s}`)
      .join(' · ');

  return (
    <div className="max-w-7xl mx-auto p-4 sm:p-6 space-y-4">
      <header className="flex items-start justify-between gap-4">
        <div>
          <h1 className="text-lg sm:text-xl font-semibold text-zinc-900 flex items-center gap-2">
            <Layers className="w-5 h-5 text-violet-600" />
            Release Groups
          </h1>
          <p className="text-xs text-zinc-500 mt-1">
            Every mobile release created in the last 24 h, aggregated by its
            release group. Each group is one click of "Create" — sibling apps
            dispatched together share the same group id and matrix run.
          </p>
        </div>
        <Link to="/mobile/releases/new">
          <Button>New Mobile Release</Button>
        </Link>
      </header>

      {error && (
        <div className="rounded-lg border border-rose-200 bg-rose-50 p-3 text-xs text-rose-900">
          Couldn't load releases: {String((error as Error).message ?? error)}
        </div>
      )}

      <div className="bg-white rounded-xl border border-zinc-200 overflow-hidden">
        {isLoading ? (
          <div className="p-4">
            <TableSkeleton rows={4} cols={4} />
          </div>
        ) : groups.length === 0 ? (
          <div className="p-12 text-center">
            <Smartphone className="w-10 h-10 text-zinc-300 mx-auto mb-3" />
            <p className="text-sm font-medium text-zinc-700">No release groups yet</p>
            <p className="text-xs text-zinc-500 mt-1">
              Created mobile releases will appear here, grouped by dispatch.
            </p>
          </div>
        ) : (
          <table className="w-full">
            <thead className="bg-zinc-50 border-b border-zinc-200">
              <tr className="text-left text-[11px] font-semibold text-zinc-600 uppercase tracking-wider">
                <th className="py-3 px-4">Group</th>
                <th className="py-3 px-4">Apps</th>
                <th className="py-3 px-4">Platforms</th>
                <th className="py-3 px-4">Statuses</th>
                <th className="py-3 px-4">Created</th>
              </tr>
            </thead>
            <tbody className="text-sm divide-y divide-zinc-100">
              {groups.map((g) => (
                <tr
                  key={g.groupId}
                  className="hover:bg-zinc-50 cursor-pointer"
                  onClick={() => {
                    // Navigate by full row click. Each anchor inside the
                    // cells uses Link so middle-click / cmd-click still
                    // opens in a new tab.
                    window.location.assign(`/mobile/groups/${g.groupId}`);
                  }}
                >
                  <td className="py-3 px-4 font-mono text-xs">
                    <Link
                      to={`/mobile/groups/${g.groupId}`}
                      onClick={(e) => e.stopPropagation()}
                      className="inline-flex items-center gap-1.5 text-blue-700 hover:underline"
                    >
                      <Layers className="w-3.5 h-3.5" />
                      <span className="truncate max-w-[260px]">{g.groupId}</span>
                    </Link>
                    <span className="block text-[11px] text-zinc-400 mt-0.5 font-sans">
                      {g.releaseCount} release{g.releaseCount === 1 ? '' : 's'}
                    </span>
                  </td>
                  <td className="py-3 px-4 text-xs text-zinc-700">
                    {g.apps.join(', ') || '-'}
                  </td>
                  <td className="py-3 px-4">
                    <div className="flex items-center gap-2">
                      {Array.from(g.platforms).map((p) => (
                        <span
                          key={p}
                          className="inline-flex items-center gap-1 text-[11px] text-zinc-600"
                        >
                          <PlatformIcon platform={p} />
                          {p}
                        </span>
                      ))}
                    </div>
                  </td>
                  <td className="py-3 px-4 text-[11px] text-zinc-600">
                    {summaryStatuses(g.statuses)}
                  </td>
                  <td className="py-3 px-4 font-mono text-[11px] text-zinc-500 whitespace-nowrap">
                    {g.earliestCreated ? formatDate(g.earliestCreated) : '-'}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}
