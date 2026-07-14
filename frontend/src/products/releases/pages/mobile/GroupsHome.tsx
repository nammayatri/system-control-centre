import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { Navigate, useNavigate, useSearchParams } from 'react-router-dom';
import { ArrowLeft, ChevronDown, ChevronLeft, ChevronRight, Plus, Search } from 'lucide-react';
import { useMobileApps, useMobileGroups, useReleases } from '../../hooks';
import type { APRelease, MobileGroupListItem, MobileGroupMemberLite, MobileGroupSummary } from '../../api';
import { BrandLogo } from '../../components/BrandLogo';
import { GroupStageChip, MEMBER_PHASE_CHIP } from '../../components/GroupStageChip';
import { MobileBuildKpis } from '../../components/MobileBuildKpis';
import { PlatformBadge } from '../../components/PlatformBadge';
import { StoreSyncBanner } from '../../components/StoreSync';
import { PermissionGate } from '../../../../core/auth/PermissionGate';
import { Button } from '../../../../shared/ui/button';
import { TableSkeleton } from '../../../../shared/ui/skeleton';
import { formatBuildCode, inFlightPhaseLabel } from '../../utils';
import { cn, formatDate } from '../../../../lib/utils';
import ListRelease, { MOBILE_STATUS_OPTIONS, TIME_RANGE_OPTIONS, getDateRange } from '../ListRelease';
import type { TimeRange } from '../ListRelease';

/**
 * Group-first mobile Releases home (fleet design §7a) — same table styling as
 * the classic releases list, but one row per RELEASE GROUP (plus actionable
 * store-detected builds). Rows only navigate; all actions (approve, dispatch,
 * promote…) live inside the group page. History swaps inline to the old flat
 * per-release table, which stays the audit surface.
 */

// /mobile/groups (the retired list page) redirects here; the console at
// /mobile/groups/:gid keeps its URL.
export function GroupsHomeRedirect() {
  return <Navigate to="/mobile/releases" replace />;
}

// Old /mobile/releases/history bookmarks land on the in-page history view.
export function MobileReleaseHistory() {
  return <Navigate to="/mobile/releases?view=history" replace />;
}

// surface value (customer/driver) -> operator vocabulary
const SURFACE_LABEL: Record<string, string> = { customer: 'consumer', driver: 'provider' };
const surfaceLabel = (s: string) => SURFACE_LABEL[s] ?? s;

// Phases where the build is actively moving — their chip dot pulses.
const IN_FLIGHT_PHASES = ['building', 'in_review', 'rolling_out'];

function MemberPhaseChip({ member }: { member: MobileGroupMemberLite }) {
  // A CREATED draft derives phase "building" but hasn't started — say so.
  const isDraft = member.status === 'CREATED';
  const base = MEMBER_PHASE_CHIP[member.phase] ?? MEMBER_PHASE_CHIP.building;
  const chip = isDraft
    ? {
        label: member.approved ? 'Approved · not dispatched' : 'Created',
        cls: 'bg-zinc-100 text-zinc-700 border-zinc-200',
      }
    : {
        // canonical badge label when the backend sent one (carries the live
        // rollout %, e.g. "Rolling out · 50%"); phase-map colors either way
        label:
          ['rolling_out', 'halted'].includes(member.phase) && member.displayLabel
            ? member.displayLabel
            : base.label,
        cls: base.cls,
      };
  const pulsing = !isDraft && IN_FLIGHT_PHASES.includes(member.phase);
  return (
    // Same shape/size as the shared Badge (rounded-md), so every chip on this
    // page reads as one family.
    <span
      className={cn(
        'inline-flex items-center gap-1.5 text-[10px] sm:text-[11px] font-medium uppercase tracking-wide border rounded-md px-2 py-0.5',
        chip.cls,
      )}
    >
      <span className={cn('w-1.5 h-1.5 rounded-full bg-current opacity-70', pulsing && 'status-pulse')} />
      {chip.label}
    </span>
  );
}

const waveLabel = (g: MobileGroupListItem): string => {
  if (g.label) return g.label;
  const first = g.members[0];
  if (!first) return g.groupId.slice(0, 8);
  const extra = g.members.length - 1;
  return `${first.app}${extra > 0 ? ` +${extra}` : ''}`;
};

// Group version cell. The lead member's FULL version+code is shown exactly like
// a single row ("3.3.26 +595"), so the real build code stays visible; any
// additional distinct builds surface as a SEPARATE pill count — never inline
// text like "+1 more", which read as a build code next to real "+595" codes.
const waveVersions = (
  members: MobileGroupMemberLite[],
): { lead: string; moreCount: number; full: string } => {
  const label = (m: MobileGroupMemberLite) =>
    `${m.version} ${formatBuildCode(m.versionCode)}`.trim();
  const withVer = members.filter((m) => m.version);
  if (withVer.length === 0) return { lead: '—', moreCount: 0, full: '' };
  const distinct = Array.from(new Set(withVer.map(label)));
  return { lead: label(withVer[0]), moreCount: distinct.length - 1, full: distinct.join(', ') };
};

// Group stage re-derivation — a faithful mirror of the backend
// deriveGroupSummary / effectivePhase (Lifecycle/GroupSummary.hs). The groups
// LIST query drops STORE_SYNC rows, so a store-sync member folded in here
// (augmentedGroups) is NOT reflected in the backend-supplied summary — a group
// whose only operator row is discarded but whose store row is ready-to-promote
// would wrongly read "Discarded". We recompute the stage over the FULL member
// set so the chip matches the rows. Keep in sync with the Haskell source.
const TERMINAL_PHASES = [
  'live', 'superseded', 'distributed', 'rejected', 'build_failed', 'aborted', 'user_aborted', 'discarded',
];
const ATTENTION_PHASES = ['rejected', 'build_failed', 'aborted', 'user_aborted', 'halted'];

function effectivePhase(status: string, phase: string): string {
  if (phase === 'aborted' && status === 'USER_ABORTED') return 'user_aborted';
  if (TERMINAL_PHASES.includes(phase)) return phase;
  switch (status) {
    case 'USER_ABORTED': return 'user_aborted';
    case 'ABORTED': return 'build_failed';
    case 'GCLT_ABORTED': return 'aborted';
    case 'DISCARDED': return 'discarded';
    default: return phase;
  }
}

function deriveGroupSummaryFE(members: MobileGroupMemberLite[]): MobileGroupSummary {
  const eff = members.map((m) => effectivePhase(m.status, m.phase));
  const live = members
    .map((m, i) => ({ m, p: eff[i] }))
    .filter((x) => !TERMINAL_PHASES.includes(x.p));
  const anyPhase = (p: string) => live.some((x) => x.p === p);
  let stage = 'done';
  let primaryVerb: string | null = null;
  if (live.some((x) => x.m.status === 'CREATED' && !x.m.approved)) { stage = 'approval'; primaryVerb = 'approve'; }
  else if (live.some((x) => x.m.status === 'CREATED' && x.m.approved)) { stage = 'dispatch'; primaryVerb = 'dispatch'; }
  else if (anyPhase('internal_held')) { stage = 'promote'; primaryVerb = 'promote'; }
  else if (live.some((x) => x.m.status !== 'CREATED' && x.p === 'building')) { stage = 'building'; }
  else if (anyPhase('in_review')) { stage = 'in_review'; }
  else if (anyPhase('approved')) { stage = 'releasing'; primaryVerb = 'release_or_rollout'; }
  else if (anyPhase('rolling_out') || anyPhase('halted')) { stage = 'rolling_out'; primaryVerb = 'rollout_controls'; }
  const counts: Record<string, number> = {};
  eff.forEach((p) => { counts[p] = (counts[p] ?? 0) + 1; });
  const attention = members.filter((_, i) => ATTENTION_PHASES.includes(eff[i]));
  return { stage, counts, attention, primaryVerb };
}

// Which History status-bucket a group MEMBER falls in (same vocabulary as
// MOBILE_STATUS_OPTIONS so this dropdown means the same thing everywhere).
function memberBucket(m: MobileGroupMemberLite): string {
  if (m.phase === 'rejected') return 'rejected';
  if (m.status === 'REVERTED') return 'reverted';
  if (
    ['ABORTED', 'USER_ABORTED', 'GCLT_ABORTED', 'DISCARDED'].includes(m.status) ||
    ['build_failed', 'aborted', 'user_aborted', 'discarded'].includes(m.phase)
  )
    return 'aborted';
  // ACTIVE store-lifecycle phase wins over the raw status: a store-synced build
  // sitting on the internal track reads status=COMPLETED but is "ready to
  // promote" (phase internal_held) — bucket it by the phase the badge shows, or
  // the filter would never surface it under "Ready to promote".
  if (m.phase === 'rolling_out' || m.phase === 'halted') return 'rollout';
  if (m.phase === 'internal_held') return 'promote';
  if (m.phase === 'in_review') return 'review';
  if (m.phase === 'approved') return 'approved';
  // Terminal store phases read status=INPROGRESS on store-synced rows (their
  // rollout is done/superseded, not the SCC status) — bucket by the phase the
  // badge shows, or a live/superseded row wrongly falls through to "building".
  if (['live', 'distributed', 'superseded'].includes(m.phase)) return 'completed';
  if (m.status === 'COMPLETED') return 'completed';
  return 'building'; // drafts + genuinely building (phase 'building' or empty)
}

// Same bucketing for a store-detected row (APRelease shape).
function storeBucket(r: APRelease): string {
  return memberBucket({
    releaseId: r.id,
    app: r.appGroup,
    surface: r.service,
    platform: r.env,
    version: r.new_version,
    phase: r.release_context?.display_phase ?? '',
    status: r.status,
    approved: r.is_approved === 1,
  });
}

// Is a store-detected row still workable (promote / watch review / manage a
// ramp)? Actionable rows sort above the pure mirrors.
function storeRowActionable(r: APRelease): boolean {
  const ph = r.release_context?.display_phase ?? '';
  if (ph === 'internal_held') return r.release_context?.promotable !== false;
  return ph === 'in_review' || ph === 'rolling_out' || ph === 'halted';
}

// EVERY store-sync/external row (mirrors included — nothing hidden),
// actionable first, then newest.
function storeItems(releases: APRelease[]): APRelease[] {
  return releases
    .filter((r) => r.release_manager === 'store-sync')
    .sort((a, b) => {
      const act = Number(storeRowActionable(b)) - Number(storeRowActionable(a));
      if (act !== 0) return act;
      return (b.date_created || '').localeCompare(a.date_created || '');
    });
}

export default function GroupsHome() {
  const navigate = useNavigate();
  // History is an in-page TOGGLE, not a navigation: the shell (title, banner,
  // KPI cards) stays mounted; only the table section below swaps.
  const [params, setParams] = useSearchParams();
  const showHistory = params.get('view') === 'history';
  // Pushed (not replaced) so the browser Back/Forward buttons walk the
  // groups ⇄ history toggle like real navigation.
  const setShowHistory = (on: boolean) => {
    const next = new URLSearchParams(params);
    if (on) next.set('view', 'history');
    else next.delete('view');
    setParams(next);
  };
  const [search, setSearch] = useState('');
  const [appFilter, setAppFilter] = useState('');
  const [surfaceFilter, setSurfaceFilter] = useState('');
  const [platformFilter, setPlatformFilter] = useState('');
  const [statusFilter, setStatusFilter] = useState('');
  // 'all_time' (default) shows every group and store row; the presets narrow.
  const [timeRange, setTimeRange] = useState<TimeRange | 'all_time'>('all_time');
  const [currentPage, setCurrentPage] = useState(1);
  const [itemsPerPage, setItemsPerPage] = useState(10);
  // Expanded group rows (member sub-rows shown inline — data is already in
  // the list payload, so expanding costs no fetch).
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const toggleExpanded = (gid: string) =>
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(gid)) next.delete(gid);
      else next.add(gid);
      return next;
    });

  // The selected range bounds finished groups + both tables; active groups are
  // always returned by the server regardless (in-flight work can't age out).
  // When any NON-date filter is set, the window widens to at least the last
  // 30 days — filtering for an app shouldn't miss its build because the date
  // dropdown happened to be on "Today".
  const filtersActive = !!(
    appFilter ||
    surfaceFilter ||
    platformFilter ||
    statusFilter ||
    search.trim()
  );
  const clearFilters = () => {
    setSearch('');
    setAppFilter('');
    setSurfaceFilter('');
    setPlatformFilter('');
    setStatusFilter('');
  };
  // The range the operator actually picked (used to CONSTRAIN what's shown).
  const selRange = useMemo(
    () =>
      timeRange === 'all_time'
        ? { from: new Date('2020-01-01T00:00:00Z'), to: new Date(Date.now() + 60_000) }
        : getDateRange(timeRange, '', ''),
    [timeRange],
  );
  // The range we FETCH: widened to ≥30d when filters are active, so a status
  // filter has enough rows to match. Display is still clamped to selRange below.
  const { fromIso, toIso } = useMemo(() => {
    if (filtersActive && timeRange !== 'all_time') {
      const wide = getDateRange('last_30_days', '', '');
      return {
        fromIso: new Date(Math.min(selRange.from.getTime(), wide.from.getTime())).toISOString(),
        toIso: new Date(Math.max(selRange.to.getTime(), wide.to.getTime())).toISOString(),
      };
    }
    return { fromIso: selRange.from.toISOString(), toIso: selRange.to.toISOString() };
  }, [selRange, filtersActive, timeRange]);
  const selFromMs = selRange.from.getTime();
  const selToMs = selRange.to.getTime();
  const withinSelected = (iso?: string) => {
    const t = new Date(iso ?? '').getTime();
    return Number.isNaN(t) || (t >= selFromMs && t <= selToMs);
  };
  const { data, isLoading, isError, refetch } = useMobileGroups(fromIso);
  const groups = useMemo(() => data?.groups ?? [], [data]);

  // Store items come from the existing releases window (client-filtered until
  // a dedicated endpoint exists — fleet doc §7a).
  const { data: releases = [], isLoading: releasesLoading } = useReleases(fromIso, toIso, 'mobile');
  const fromStore = useMemo(() => storeItems(releases), [releases]);
  // Fold store-sync rows that belong to an OPERATOR group (shared
  // release_group_id) INTO that group's member list. The backend groups query
  // omits store-sync members, so without this a 2-row group (e.g. a discarded
  // draft + its shipped store build) reads as a single-app row. Store rows in
  // no shown group stay standalone (they render as their own rows).
  const { augmentedGroups, standaloneStore } = useMemo(() => {
    const groupGids = new Set(groups.map((g) => g.groupId));
    const byGid = new Map<string, APRelease[]>();
    for (const r of fromStore) {
      const gid = r.release_context?.release_group_id;
      if (gid && groupGids.has(gid)) {
        const arr = byGid.get(gid) ?? [];
        arr.push(r);
        byGid.set(gid, arr);
      }
    }
    const toMember = (r: APRelease): MobileGroupMemberLite => ({
      releaseId: r.id,
      app: r.appGroup,
      surface: r.service,
      platform: r.env,
      version: r.new_version,
      versionCode: r.release_context?.version_code ?? null,
      phase: r.release_context?.display_phase ?? '',
      status: r.status,
      approved: r.is_approved === 1,
      rolloutPercent: r.release_context?.rollout_percent ?? null,
      displayLabel: r.release_context?.display_label ?? null,
    });
    const aug = groups.map((g) => {
      const extra = (byGid.get(g.groupId) ?? [])
        .filter((r) => !g.members.some((m) => m.releaseId === r.id))
        .map(toMember);
      if (!extra.length) return g;
      // Folding store-sync members changes the group's stage — the backend
      // summary never saw them (LIST drops STORE_SYNC), so recompute it here.
      const members = [...g.members, ...extra];
      return { ...g, members, summary: deriveGroupSummaryFE(members) };
    });
    const standalone = fromStore.filter((r) => {
      const gid = r.release_context?.release_group_id;
      return !(gid && groupGids.has(gid));
    });
    return { augmentedGroups: aug, standaloneStore: standalone };
  }, [groups, fromStore]);
  // One skeleton until BOTH sources are in — otherwise store rows pop in a
  // beat after the groups and the table visibly grows.
  const tableLoading = isLoading || releasesLoading;

  // KPI cards are ALL-TIME (every mobile build till today) — deliberately
  // independent of the date filter, which scopes only the tables below.
  const allTimeFromIso = useMemo(() => new Date('2020-01-01T00:00:00Z').toISOString(), []);
  const allTimeToIso = useMemo(() => new Date(Date.now() + 60_000).toISOString(), []);
  const { data: allTimeReleases = [] } = useReleases(allTimeFromIso, allTimeToIso, 'mobile');


  // The app filter lists EVERY catalog app (not just current group members),
  // so apps living inside groups or only on store rows are all filterable.
  const { data: catalogApps = [] } = useMobileApps();
  const appNames = useMemo(() => {
    const names = new Set<string>([
      ...catalogApps.map((a) => a.name),
      ...groups.flatMap((g) => g.members.map((m) => m.app)),
      ...fromStore.map((r) => r.appGroup),
    ]);
    return Array.from(names).sort();
  }, [catalogApps, groups, fromStore]);

  const visibleGroups = useMemo(() => {
    // Clamp to the SELECTED time range (the fetch window is wider so the status
    // filter can match, but the operator only wants their chosen window shown).
    let list = augmentedGroups.filter((g) => withinSelected(g.createdAt));
    if (appFilter) list = list.filter((g) => g.members.some((m) => m.app === appFilter));
    if (surfaceFilter) list = list.filter((g) => g.members.some((m) => m.surface === surfaceFilter));
    if (platformFilter) list = list.filter((g) => g.members.some((m) => m.platform === platformFilter));
    // A group matches a status when ANY member does — builds inside groups
    // stay findable; matching groups auto-expand below.
    if (statusFilter) list = list.filter((g) => g.members.some((m) => memberBucket(m) === statusFilter));
    if (search.trim()) {
      const q = search.trim().toLowerCase();
      list = list.filter(
        (g) =>
          waveLabel(g).toLowerCase().includes(q) ||
          g.members.some(
            (m) => m.app.toLowerCase().includes(q) || m.version.toLowerCase().includes(q),
          ),
      );
    }
    return list;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [augmentedGroups, appFilter, surfaceFilter, platformFilter, statusFilter, search, selFromMs, selToMs]);

  const visibleStore = useMemo(() => {
    let list = standaloneStore.filter((r) => withinSelected(r.date_created));
    if (appFilter) list = list.filter((r) => r.appGroup === appFilter);
    if (surfaceFilter) list = list.filter((r) => r.service === surfaceFilter);
    if (platformFilter) list = list.filter((r) => r.env === platformFilter);
    if (statusFilter) list = list.filter((r) => storeBucket(r) === statusFilter);
    if (search.trim()) {
      const q = search.trim().toLowerCase();
      list = list.filter(
        (r) => r.appGroup.toLowerCase().includes(q) || (r.new_version || '').toLowerCase().includes(q),
      );
    }
    return list;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [standaloneStore, appFilter, surfaceFilter, platformFilter, statusFilter, search, selFromMs, selToMs]);

  // One paginated sequence: groups and store-detected builds INTERLEAVED and
  // sorted newest-first by created date, so the latest release is always on top.
  type FeedRow = { kind: 'group'; g: MobileGroupListItem } | { kind: 'store'; r: APRelease };
  const allRows = useMemo<FeedRow[]>(() => {
    const rows: FeedRow[] = [
      ...visibleGroups.map((g) => ({ kind: 'group' as const, g })),
      ...visibleStore.map((r) => ({ kind: 'store' as const, r })),
    ];
    const dateOf = (row: FeedRow) =>
      new Date(row.kind === 'group' ? row.g.createdAt : row.r.date_created).getTime() || 0;
    return rows.sort((a, b) => dateOf(b) - dateOf(a));
  }, [visibleGroups, visibleStore]);
  const totalPages = Math.max(1, Math.ceil(allRows.length / itemsPerPage));
  const startIndex = (currentPage - 1) * itemsPerPage;
  const pageRows = allRows.slice(startIndex, startIndex + itemsPerPage);
  useEffect(() => {
    setCurrentPage(1);
  }, [search, appFilter, surfaceFilter, platformFilter, statusFilter, timeRange]);

  // Status filtering targets BUILDS: auto-expand the matching groups so the
  // matching members are visible, not hidden behind a chevron.
  useEffect(() => {
    if (!statusFilter) return;
    setExpanded(
      new Set(
        groups
          .filter((g) => g.members.some((m) => memberBucket(m) === statusFilter))
          .map((g) => g.groupId),
      ),
    );
  }, [statusFilter, groups]);

  return (
    <div className="flex flex-col flex-1 w-full space-y-4">
      <header className="flex items-start justify-between gap-4 flex-wrap">
        <div>
          <h1 className="text-lg sm:text-xl font-semibold text-zinc-900">Releases</h1>
          <p className="text-xs text-zinc-500 mt-1">
            One row per release group — open a group to approve, dispatch and promote its apps.
          </p>
        </div>
        <PermissionGate product="autopilot" permission="RELEASE_CREATE">
          <Button onClick={() => navigate('/mobile/releases/new')}>
            <Plus className="w-4 h-4" /> Create Release
          </Button>
        </PermissionGate>
      </header>

      <StoreSyncBanner />

      {/* All-time mobile-build KPIs (every build till today; real builds only)
          — constant across the date filter AND the groups/history toggle. */}
      <MobileBuildKpis releases={allTimeReleases} />

      {/* ONE fixed filter toolbar for both views — toggling history swaps only
          the table below; every filter here drives whichever table is shown. */}
      <div className="bg-white rounded-xl border border-zinc-200 px-4 py-3 sm:px-6 flex items-center gap-2 flex-wrap">
        <div className="relative">
          <Search className="w-4 h-4 absolute left-3 top-1/2 -translate-y-1/2 text-zinc-400" />
          <input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search releases / apps / versions…"
            className="pl-9 pr-3 py-2 text-sm border border-zinc-200 rounded-lg w-64 focus:outline-none focus:ring-2 focus:ring-zinc-300"
          />
        </div>
        <select
          value={appFilter}
          onChange={(e) => setAppFilter(e.target.value)}
          className="text-sm border border-zinc-200 rounded-lg px-3 py-2 bg-white text-zinc-700"
        >
          <option value="">All Apps</option>
          {appNames.map((a) => (
            <option key={a} value={a}>
              {a}
            </option>
          ))}
        </select>
        <select
          value={surfaceFilter}
          onChange={(e) => setSurfaceFilter(e.target.value)}
          className="text-sm border border-zinc-200 rounded-lg px-3 py-2 bg-white text-zinc-700"
        >
          <option value="">All Surfaces</option>
          <option value="customer">Consumer</option>
          <option value="driver">Provider</option>
        </select>
        <select
          value={platformFilter}
          onChange={(e) => setPlatformFilter(e.target.value)}
          className="text-sm border border-zinc-200 rounded-lg px-3 py-2 bg-white text-zinc-700"
        >
          <option value="">All Platforms</option>
          <option value="android">Android</option>
          <option value="ios">iOS</option>
        </select>
        <select
          value={statusFilter}
          onChange={(e) => setStatusFilter(e.target.value)}
          className="text-sm border border-zinc-200 rounded-lg px-3 py-2 bg-white text-zinc-700"
        >
          <option value="">All Statuses</option>
          {MOBILE_STATUS_OPTIONS.map((o) => (
            <option key={o.value} value={o.value}>
              {o.label}
            </option>
          ))}
        </select>
        <select
          value={timeRange}
          onChange={(e) => setTimeRange(e.target.value as TimeRange | 'all_time')}
          className="text-sm border border-zinc-200 rounded-lg px-3 py-2 bg-white text-zinc-700"
        >
          <option value="all_time">All time</option>
          {TIME_RANGE_OPTIONS.filter((o) => o.value !== 'custom').map((o) => (
            <option key={o.value} value={o.value}>
              {o.label}
            </option>
          ))}
        </select>
        <span className="ml-auto inline-flex items-center gap-4">
          <button
            onClick={() => setShowHistory(!showHistory)}
            className="text-xs text-zinc-500 hover:text-zinc-900 underline underline-offset-2 inline-flex items-center gap-1"
          >
            {showHistory ? (
              <>
                <ArrowLeft className="w-3.5 h-3.5" /> Release groups
              </>
            ) : (
              'Full history →'
            )}
          </button>
        </span>
      </div>

      {showHistory ? (
        <ListRelease
          slim
          slimFilters={{
            search,
            app: appFilter,
            platform: platformFilter,
            surface: surfaceFilter,
            status: statusFilter,
            fromIso,
            toIso,
          }}
        />
      ) : (
        <div className="bg-white rounded-xl border border-zinc-200">
          {isError ? (
            <div className="py-16 text-center space-y-3">
              <p className="text-sm text-zinc-600">
                Couldn't load release groups — the backend may be restarting.
              </p>
              <Button variant="secondary" size="sm" onClick={() => refetch()}>
                Retry
              </Button>
            </div>
          ) : tableLoading ? (
            <TableSkeleton rows={5} cols={10} />
          ) : visibleGroups.length === 0 && visibleStore.length === 0 ? (
            <div className="py-16 text-center space-y-3">
              <p className="text-sm text-zinc-400">
                {filtersActive
                  ? 'No releases match these filters.'
                  : 'No release groups in this window.'}
              </p>
              {filtersActive && (
                <Button variant="secondary" size="sm" onClick={clearFilters}>
                  Clear filters
                </Button>
              )}
            </div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-left whitespace-nowrap">
                <thead>
                  <tr className="bg-zinc-50 border-b border-zinc-200 text-[11px] text-zinc-500 font-medium uppercase tracking-wider">
                    <th className="py-3 px-4 w-10 hidden lg:table-cell">#</th>
                    <th className="py-3 px-4">App / Group</th>
                    <th className="py-3 px-4 hidden md:table-cell">Surface</th>
                    <th className="py-3 px-4">Platform</th>
                    <th className="py-3 px-4 hidden lg:table-cell">Apps</th>
                    <th className="py-3 px-4">Version</th>
                    <th className="py-3 px-4">Status</th>
                    <th className="py-3 px-4 hidden xl:table-cell">Release Manager</th>
                    <th className="py-3 px-4 hidden md:table-cell">Created At</th>
                    <th className="py-3 px-4">Actions</th>
                  </tr>
                </thead>
                <tbody className="text-sm">
                  {pageRows.map((row, idx) =>
                    row.kind === 'group' ? (
                      <GroupRow
                        key={row.g.groupId}
                        index={startIndex + idx + 1}
                        group={row.g}
                        zebra={idx % 2 === 1}
                        expanded={expanded.has(row.g.groupId)}
                        matchBucket={statusFilter || null}
                        onToggle={() => toggleExpanded(row.g.groupId)}
                        onOpen={() => navigate(`/mobile/groups/${row.g.groupId}`)}
                        onOpenMember={(rid) => navigate(`/mobile/releases/${rid}`)}
                      />
                    ) : (
                      <StoreItemRow
                        key={row.r.id}
                        index={startIndex + idx + 1}
                        release={row.r}
                        zebra={idx % 2 === 1}
                        // Consistent with group rows: open the group console (its
                        // singleton store-sync group), not the release summary.
                        onOpen={() => {
                          const gid = row.r.release_context?.release_group_id;
                          navigate(gid ? `/mobile/groups/${gid}` : `/mobile/releases/${row.r.id}`);
                        }}
                      />
                    ),
                  )}
                </tbody>
              </table>
            </div>
          )}

          {!isLoading && allRows.length > 0 && (
            <div className="px-3 sm:px-4 py-3 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 border-t border-zinc-100">
              <div className="flex items-center gap-3 flex-wrap">
                <span className="text-xs sm:text-sm text-zinc-500">
                  Showing {startIndex + 1}-{Math.min(startIndex + itemsPerPage, allRows.length)} of {allRows.length}
                </span>
                <select
                  value={itemsPerPage}
                  onChange={(e) => {
                    setItemsPerPage(Number(e.target.value));
                    setCurrentPage(1);
                  }}
                  className="border border-zinc-300 rounded-lg px-2 py-1 text-xs text-zinc-600 cursor-pointer focus:outline-none focus:ring-2 focus:ring-zinc-400"
                >
                  {[10, 25, 50].map((n) => (
                    <option key={n} value={n}>
                      {n} / page
                    </option>
                  ))}
                </select>
              </div>
              <div className="flex items-center gap-1">
                <button
                  onClick={() => setCurrentPage((p) => Math.max(1, p - 1))}
                  disabled={currentPage === 1}
                  className="h-9 w-9 flex items-center justify-center border border-zinc-300 rounded-lg hover:bg-zinc-50 disabled:opacity-40 disabled:pointer-events-none cursor-pointer transition-colors"
                  aria-label="Previous page"
                >
                  <ChevronLeft className="w-4 h-4" />
                </button>
                <span className="text-xs text-zinc-500 px-3 font-mono">
                  {currentPage} / {totalPages}
                </span>
                <button
                  onClick={() => setCurrentPage((p) => Math.min(totalPages, p + 1))}
                  disabled={currentPage === totalPages}
                  className="h-9 w-9 flex items-center justify-center border border-zinc-300 rounded-lg hover:bg-zinc-50 disabled:opacity-40 disabled:pointer-events-none cursor-pointer transition-colors"
                  aria-label="Next page"
                >
                  <ChevronRight className="w-4 h-4" />
                </button>
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

/**
 * Floating hover preview (GitHub-style hover card): shows the group's apps
 * after a short hover delay WITHOUT layout shift — inline hover-expansion
 * would push rows around under the cursor and misfire while scanning.
 * Read-only (pointer-events: none); interaction stays on click.
 */
function GroupHoverCard({
  group,
  anchor,
}: {
  group: MobileGroupListItem;
  anchor: { rowTop: number; rowBottom: number; left: number };
}) {
  const shown = group.members.slice(0, 6);
  // Measure the real card height after first paint, then pick the side —
  // estimates mis-flip for tall cards near the viewport edge.
  const cardRef = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState<{ top: number; above: boolean } | null>(null);
  useLayoutEffect(() => {
    const h = cardRef.current?.offsetHeight ?? 0;
    const overflows = anchor.rowBottom + h + 12 > window.innerHeight;
    const fitsAbove = anchor.rowTop - h - 12 > 0;
    const above = overflows && fitsAbove;
    setPos({ top: above ? anchor.rowTop - 6 : anchor.rowBottom + 6, above });
  }, [anchor]);
  return createPortal(
    <div
      ref={cardRef}
      className={cn(
        'fixed z-50 w-[400px] max-w-[calc(100vw-24px)] pointer-events-none',
        pos && 'animate-fadeInUp',
      )}
      style={{
        top: pos?.top ?? anchor.rowBottom + 6,
        left: anchor.left,
        transform: pos?.above ? 'translateY(-100%)' : undefined,
        visibility: pos ? 'visible' : 'hidden',
      }}
      role="tooltip"
    >
      <div className="rounded-xl border border-zinc-200 bg-white shadow-lg overflow-hidden border-l-[3px] border-l-violet-300">
        <div className="px-4 py-2 bg-zinc-50/80 border-b border-zinc-100 text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
          {waveLabel(group)} · {group.members.length} app{group.members.length === 1 ? '' : 's'}
        </div>
        <div className="divide-y divide-zinc-100">
          {shown.map((m) => (
            <div key={m.releaseId} className="flex items-center gap-3 px-4 py-2">
              <BrandLogo
                brand={m.app}
                surface={m.surface === 'driver' ? 'driver' : undefined}
                size="sm"
              />
              <span className="min-w-0">
                <span className="block text-sm font-medium text-zinc-800 truncate">{m.app}</span>
                <span className="block text-[11px] text-zinc-400">
                  {surfaceLabel(m.surface)} · {m.platform}
                </span>
              </span>
              <span className="ml-auto inline-flex items-center gap-2">
                <span className="font-mono text-[11px] text-zinc-600 bg-zinc-100 rounded-md px-1.5 py-0.5 whitespace-nowrap">
                  {m.version || '—'} {formatBuildCode(m.versionCode)}
                </span>
                <MemberPhaseChip member={m} />
              </span>
            </div>
          ))}
          {group.members.length > shown.length && (
            <div className="px-4 py-1.5 text-[11px] text-zinc-400">
              +{group.members.length - shown.length} more — expand the row to see all
            </div>
          )}
        </div>
      </div>
    </div>,
    document.body,
  );
}

function GroupRow({
  index,
  group,
  zebra,
  expanded,
  matchBucket = null,
  onToggle,
  onOpen,
  onOpenMember,
}: {
  index: number;
  group: MobileGroupListItem;
  zebra: boolean;
  expanded: boolean;
  // active status-filter bucket — matching members highlight in the panel
  matchBucket?: string | null;
  onToggle: () => void;
  onOpen: () => void;
  onOpenMember: (releaseId: string) => void;
}) {
  const { members } = group;
  const platforms = Array.from(new Set(members.map((m) => m.platform)));
  const uniqueApps = Array.from(new Set(members.map((m) => m.app)));
  const wv = waveVersions(members);
  const shown = members.slice(0, 3);
  const membersRowId = `group-members-${group.groupId}`;

  // Hover preview: opens after a 250ms dwell (no flicker while scanning),
  // anchored to the row via fixed positioning (immune to table overflow
  // clipping), flipped above when near the viewport bottom.
  const rowRef = useRef<HTMLTableRowElement>(null);
  const hoverTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [preview, setPreview] = useState<{ rowTop: number; rowBottom: number; left: number } | null>(
    null,
  );
  const cancelPreview = () => {
    if (hoverTimer.current) clearTimeout(hoverTimer.current);
    setPreview(null);
  };
  const schedulePreview = () => {
    // A single-app group has nothing extra to preview — skip the hover card.
    if (expanded || members.length <= 1) return;
    if (hoverTimer.current) clearTimeout(hoverTimer.current);
    hoverTimer.current = setTimeout(() => {
      const r = rowRef.current?.getBoundingClientRect();
      if (!r) return;
      setPreview({
        rowTop: r.top,
        rowBottom: r.bottom,
        left: Math.max(12, Math.min(r.left + 48, window.innerWidth - 420)),
      });
    }, 250);
  };
  useEffect(() => () => cancelPreview(), []);
  // The card is position:fixed — scrolling would leave it hovering over the
  // wrong row, so any scroll dismisses it.
  useEffect(() => {
    if (!preview) return;
    const onScroll = () => cancelPreview();
    window.addEventListener('scroll', onScroll, true);
    return () => window.removeEventListener('scroll', onScroll, true);
  }, [preview]);

  return (
    <>
    <tr
      ref={rowRef}
      onClick={() => {
        cancelPreview();
        onOpen();
      }}
      onMouseEnter={schedulePreview}
      onMouseLeave={cancelPreview}
      className={cn(
        'group/row transition-colors cursor-pointer',
        expanded
          ? 'bg-violet-50/40 hover:bg-violet-50/60'
          : cn('border-b border-zinc-100 hover:bg-zinc-50', zebra ? 'bg-zinc-50/50' : 'bg-white'),
        // Violet left edge marks a real group (multiple builds under one wave).
        members.length > 1 && '[box-shadow:inset_3px_0_0_0_#a78bfa]',
      )}
    >
      <td className="py-3 px-4 text-xs text-zinc-400 hidden lg:table-cell">{index}</td>
      <td className="py-3 px-4">
        <span className="inline-flex items-center gap-2 font-medium text-zinc-800">
          {/* Chevron only for multi-app groups. Single-app groups render no
              chevron AND no spacer, so their logo aligns with the store rows. */}
          {members.length > 1 && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                cancelPreview();
                onToggle();
              }}
              aria-expanded={expanded}
              aria-controls={membersRowId}
              aria-label={expanded ? 'Collapse apps in this group' : 'Expand apps in this group'}
              className={cn(
                'h-6 w-6 -ml-1 flex items-center justify-center rounded-md transition-all',
                expanded
                  ? 'bg-violet-100 text-violet-700 hover:bg-violet-200'
                  : 'text-zinc-400 hover:bg-zinc-200/60 hover:text-zinc-700',
              )}
            >
              <ChevronDown
                className={cn('w-4 h-4 transition-transform duration-200', !expanded && '-rotate-90')}
              />
            </button>
          )}
          <span className="flex -space-x-1.5">
            {shown.map((m) => (
              <span key={m.releaseId} className="rounded-full ring-1 ring-zinc-200 bg-white">
                <BrandLogo
                  brand={m.app}
                  surface={m.surface === 'driver' ? 'driver' : undefined}
                  size="sm"
                />
              </span>
            ))}
          </span>
          <span className="min-w-0">
            <span className="block truncate">{waveLabel(group)}</span>
            {uniqueApps.length > 1 && (
              <span
                className="block text-[11px] font-normal text-zinc-400 truncate max-w-[280px]"
                title={uniqueApps.join(', ')}
              >
                {uniqueApps.join(' · ')}
              </span>
            )}
          </span>
        </span>
      </td>
      <td className="py-3 px-4 text-xs text-zinc-600 hidden md:table-cell">
        {Array.from(new Set(members.map((m) => surfaceLabel(m.surface)))).join(' · ')}
      </td>
      <td className="py-3 px-4">
        <span className="inline-flex items-center gap-1.5">
          {platforms.map((p) => (
            <PlatformBadge key={p} platform={p} isMobile />
          ))}
        </span>
      </td>
      <td className="py-3 px-4 text-xs text-zinc-600 hidden lg:table-cell">{members.length}</td>
      <td className="py-3 px-4 text-xs text-zinc-600" title={wv.full}>
        <span className="font-mono">{wv.lead}</span>
        {wv.moreCount > 0 && (
          <span className="ml-1.5 inline-flex items-center rounded-full bg-zinc-100 text-zinc-500 px-1.5 py-px text-[10px] font-medium align-middle">
            +{wv.moreCount} more
          </span>
        )}
      </td>
      <td className="py-3 px-4">
        <GroupStageChip summary={group.summary} total={group.members.length} members={group.members} />
      </td>
      <td className="py-3 px-4 text-xs text-zinc-600 hidden xl:table-cell">{group.createdBy || '—'}</td>
      <td className="py-3 px-4 font-mono text-xs text-zinc-600 hidden md:table-cell">{formatDate(group.createdAt)}</td>
      <td className="py-3 px-4">
        <button
          onClick={(e) => {
            e.stopPropagation();
            onOpen();
          }}
          className="text-xs text-zinc-600 hover:text-zinc-900 underline"
        >
          Open
        </button>
      </td>
    </tr>

    {/* Floating hover preview — apps visible with no click, no layout shift */}
    {preview && !expanded && <GroupHoverCard group={group} anchor={preview} />}

    {/* Member panel: always mounted so open/close animates smoothly (grid
        height trick); read-only — group actions stay on the group page. Never
        opens for a single-app group (nothing to expand). */}
    {members.length > 1 && (
    <tr aria-hidden={!expanded} className={cn(!expanded && 'border-0')}>
      <td colSpan={10} className="p-0">
        <div id={membersRowId} className={cn('expand-panel', expanded && 'open')}>
          <div>
            <div className="mx-4 sm:mx-6 mb-3 mt-1 ml-12 sm:ml-14 rounded-xl border border-zinc-200 bg-white shadow-sm overflow-hidden border-l-[3px] border-l-violet-300">
              <div className="px-4 py-2 bg-zinc-50/80 border-b border-zinc-100 flex items-center justify-between">
                <span className="text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
                  Apps in this group · {members.length}
                </span>
                <span className="text-[10px] text-zinc-400">click an app for its release page</span>
              </div>
              {/* key retriggers the stagger animation on every open */}
              <div key={String(expanded)} className="divide-y divide-zinc-100">
                {members.map((m, i) => (
                  <button
                    key={m.releaseId}
                    type="button"
                    onClick={(e) => {
                      e.stopPropagation();
                      onOpenMember(m.releaseId);
                    }}
                    aria-label={`Open ${m.app} ${m.platform} release`}
                    className={cn(
                      'group/member w-full text-left flex items-center gap-3 px-4 py-2.5 cursor-pointer transition-colors hover:bg-violet-50/40',
                      'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-violet-400',
                      expanded && `animate-fadeInUp stagger-${Math.min(i + 1, 5)}`,
                      // the member the status filter matched
                      matchBucket != null &&
                        memberBucket(m) === matchBucket &&
                        'bg-violet-50/70 [box-shadow:inset_3px_0_0_0_#8b5cf6]',
                    )}
                  >
                    <BrandLogo
                      brand={m.app}
                      surface={m.surface === 'driver' ? 'driver' : undefined}
                      size="sm"
                    />
                    <span className="min-w-0">
                      <span className="block text-sm font-medium text-zinc-800 truncate">
                        {m.app}
                      </span>
                      <span className="block text-[11px] text-zinc-400">
                        {surfaceLabel(m.surface)}
                      </span>
                    </span>
                    <PlatformBadge platform={m.platform} isMobile />
                    <span className="ml-auto inline-flex items-center gap-3">
                      <span className="font-mono text-xs text-zinc-600 bg-zinc-100 rounded-md px-2 py-1">
                        {m.version || '—'} {formatBuildCode(m.versionCode)}
                      </span>
                      <MemberPhaseChip member={m} />
                      <span className="text-xs text-zinc-400 group-hover/member:text-violet-700 group-focus-visible/member:text-violet-700 transition-colors whitespace-nowrap">
                        Open →
                      </span>
                    </span>
                  </button>
                ))}
              </div>
            </div>
          </div>
        </div>
      </td>
    </tr>
    )}
    </>
  );
}

function StoreItemRow({
  index,
  release,
  zebra,
  onOpen,
}: {
  index: number;
  release: APRelease;
  zebra: boolean;
  onOpen: () => void;
}) {
  const ph = release.release_context?.display_phase ?? '';
  const promotable = ph === 'internal_held' && release.release_context?.promotable !== false;
  // Same truthful vocabulary/colors as the member badges; a non-promotable
  // internal build has been overtaken → Superseded.
  const stateChip = promotable
    ? { label: 'Ready to promote', cls: 'bg-violet-50 text-violet-800 border-violet-200' }
    : ph === 'internal_held'
      ? MEMBER_PHASE_CHIP.superseded
      : ['rolling_out', 'halted'].includes(ph) && release.release_context?.display_label
        ? // canonical label carries the live % ("Rolling out · 50%")
          { label: release.release_context.display_label, cls: (MEMBER_PHASE_CHIP[ph] ?? MEMBER_PHASE_CHIP.building).cls }
        : (MEMBER_PHASE_CHIP[ph] ?? {
            label: inFlightPhaseLabel(release),
            cls: 'bg-violet-50 text-violet-800 border-violet-200',
          });
  return (
    <tr
      onClick={onOpen}
      className={cn(
        'border-b border-zinc-100 hover:bg-zinc-50 transition-colors cursor-pointer',
        zebra ? 'bg-zinc-50/50' : 'bg-white',
      )}
    >
      <td className="py-3 px-4 text-xs text-zinc-400 hidden lg:table-cell">{index}</td>
      <td className="py-3 px-4">
        <span className="inline-flex items-center gap-2 font-medium text-zinc-800">
          <BrandLogo
            brand={release.appGroup}
            surface={release.service === 'driver' ? 'driver' : undefined}
            size="sm"
          />
          {release.appGroup}
        </span>
      </td>
      <td className="py-3 px-4 text-xs text-zinc-600 hidden md:table-cell">{surfaceLabel(release.service)}</td>
      <td className="py-3 px-4">
        <PlatformBadge platform={release.env} isMobile />
      </td>
      <td className="py-3 px-4 text-xs text-zinc-600 hidden lg:table-cell">1</td>
      <td className="py-3 px-4 font-mono text-xs text-zinc-600">
        {release.new_version} {formatBuildCode(release.release_context?.version_code)}
      </td>
      <td className="py-3 px-4">
        <span className="inline-flex items-center gap-1.5 flex-wrap">
          <span className="inline-flex items-center text-[10px] sm:text-[11px] font-medium uppercase tracking-wide border rounded-md px-2 py-0.5 bg-amber-50 text-amber-800 border-amber-200">
            From store
          </span>
          <span
            className={cn(
              'inline-flex items-center text-[10px] sm:text-[11px] font-medium uppercase tracking-wide border rounded-md px-2 py-0.5',
              stateChip.cls,
            )}
          >
            {stateChip.label}
          </span>
        </span>
      </td>
      <td className="py-3 px-4 text-xs text-zinc-600 hidden xl:table-cell">store-sync</td>
      <td className="py-3 px-4 font-mono text-xs text-zinc-600 hidden md:table-cell">{formatDate(release.date_created)}</td>
      <td className="py-3 px-4">
        <button
          onClick={(e) => {
            e.stopPropagation();
            onOpen();
          }}
          className="text-xs text-zinc-600 hover:text-zinc-900 underline"
        >
          Open
        </button>
      </td>
    </tr>
  );
}
