import React, { useEffect, useMemo, useRef, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { ArrowDown, ArrowUp, Calendar, ChevronDown, ChevronLeft, ChevronRight, Copy, Plus, Search, X } from 'lucide-react';
import { Button } from '../../../../shared/ui/button';
import { PermissionGate } from '../../../../core/auth/PermissionGate';
import { fetchGroupRuns, groupVersionLabel, groupVersions } from '../../api';
import type { GroupRun, GroupRunState } from '../../api';
import { GroupStateBadge } from './GroupReleaseDetail';
import { TIME_RANGE_OPTIONS, getDateRange } from '../ListRelease';
import type { TimeRange } from '../ListRelease';
import { cn } from '../../../../lib/utils';
import { toast } from 'sonner';

const STATES: { value: GroupRunState; label: string }[] = [
  { value: 'PENDING_APPROVAL', label: 'Awaiting approval' },
  { value: 'RUNNING', label: 'Running' },
  { value: 'HALTED', label: 'Halted' },
  { value: 'COMPLETED', label: 'Completed' },
  { value: 'ABORTED', label: 'Aborted' },
];

const selectCls = 'border border-zinc-300 rounded-lg px-3 h-9 text-sm text-zinc-600 bg-white cursor-pointer focus:outline-none focus:ring-2 focus:ring-zinc-400';

const doneCount = (r: GroupRun) =>
  r.steps.filter(s => s.state === 'SKIPPED' || s.releaseStatus === 'COMPLETED').length;

const haystack = (r: GroupRun) =>
  [
    r.bundleName, r.env, r.createdBy, r.description, groupVersions(r).join(' '),
    ...r.steps.map(s => `${s.appGroup} ${s.service}`),
  ].join(' ').toLowerCase();

const GroupReleases: React.FC = () => {
  const navigate = useNavigate();
  const { data: runs = [], isLoading } = useQuery({
    queryKey: ['release-groups'],
    queryFn: fetchGroupRuns,
    refetchInterval: 10000,
  });

  const [search, setSearch] = useState('');
  const [state, setState] = useState('');
  const [bundle, setBundle] = useState('');
  const [timeRange, setTimeRange] = useState<TimeRange>('last_7_days');
  const [customFrom, setCustomFrom] = useState('');
  const [customTo, setCustomTo] = useState('');
  const [showDatePicker, setShowDatePicker] = useState(false);
  const datePickerRef = useRef<HTMLDivElement>(null);
  const [newestFirst, setNewestFirst] = useState(true);
  const [pageSize, setPageSize] = useState(10);
  const [page, setPage] = useState(1);

  const bundles = useMemo(() => [...new Set(runs.map(r => r.bundleName))].sort(), [runs]);
  const dateRange = useMemo(() => getDateRange(timeRange, customFrom, customTo), [timeRange, customFrom, customTo]);

  useEffect(() => {
    const onDown = (e: MouseEvent) => {
      if (datePickerRef.current && !datePickerRef.current.contains(e.target as Node)) setShowDatePicker(false);
    };
    document.addEventListener('mousedown', onDown);
    return () => document.removeEventListener('mousedown', onDown);
  }, []);

  const handleCustomApply = () => {
    if (!customFrom || !customTo) return;
    const from = new Date(customFrom);
    const to = new Date(customTo);
    if (from > to) { toast.error('Start date cannot be after end date'); return; }
    if ((to.getTime() - from.getTime()) / 86400000 > 30) { toast.error('Custom range cannot exceed 30 days'); return; }
    setTimeRange('custom');
    setShowDatePicker(false);
  };

  const formatDateRange = () => {
    const f: Intl.DateTimeFormatOptions = { month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' };
    return `${dateRange.from.toLocaleString('en-US', f)} - ${dateRange.to.toLocaleString('en-US', f)}`;
  };

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    const rows = runs.filter(r =>
      (!state || r.state === state) &&
      (!bundle || r.bundleName === bundle) &&
      (() => { const t = new Date(r.createdAt).getTime(); return t >= dateRange.from.getTime() && t <= dateRange.to.getTime(); })() &&
      (!q || haystack(r).includes(q)));
    const dir = newestFirst ? -1 : 1;
    return rows.sort((a, b) => dir * (new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime()));
  }, [runs, search, state, bundle, dateRange, newestFirst]);

  const totalPages = Math.max(1, Math.ceil(filtered.length / pageSize));
  useEffect(() => { setPage(1); }, [search, state, bundle, dateRange, newestFirst, pageSize]);
  const cur = Math.min(page, totalPages);
  const start = (cur - 1) * pageSize;
  const rows = filtered.slice(start, start + pageSize);

  return (
    <div className="space-y-4 pb-12">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold text-zinc-900">Group releases</h1>
          <p className="text-sm text-zinc-500">Bundles released together, stage by stage.</p>
        </div>
        <PermissionGate product="autopilot" permission="RELEASE_CREATE">
          <Link to="/backend/group-releases/new">
            <Button><Plus className="w-4 h-4" /> New group release</Button>
          </Link>
        </PermissionGate>
      </div>

      <div className="bg-white rounded-xl border border-zinc-200">
        <div className="p-4 flex flex-wrap items-center gap-3 border-b border-zinc-100">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-zinc-400" />
            <input
              type="text"
              placeholder="Search bundle, version, service…"
              value={search}
              onChange={e => setSearch(e.target.value)}
              className="pl-9 pr-4 h-9 w-64 border border-zinc-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent"
            />
          </div>
          <div className="relative" ref={datePickerRef}>
            <button onClick={() => setShowDatePicker(v => !v)} className="flex items-center gap-2 border border-zinc-300 rounded-lg px-3 h-9 bg-white hover:bg-zinc-50 text-sm text-zinc-600 cursor-pointer transition-colors duration-150">
              <Calendar className="h-4 w-4 text-zinc-400" />
              <span className="max-w-[220px] truncate">{formatDateRange()}</span>
              <ChevronDown className="w-3.5 h-3.5 text-zinc-400" />
            </button>
            {showDatePicker && (
              <div className="absolute top-full mt-1 left-0 bg-white border border-zinc-200 rounded-lg shadow-sm z-50 min-w-[260px]">
                <div className="p-1.5">
                  {TIME_RANGE_OPTIONS.map(opt => (
                    <button key={opt.value}
                      onClick={() => { if (opt.value !== 'custom') { setTimeRange(opt.value); setShowDatePicker(false); } else { setTimeRange('custom'); } }}
                      className={cn('w-full text-left px-3 py-1.5 text-sm rounded cursor-pointer transition-colors duration-150', timeRange === opt.value ? 'bg-zinc-100 text-zinc-900 font-medium' : 'text-zinc-600 hover:bg-zinc-50')}>
                      {opt.label}
                    </button>
                  ))}
                </div>
                {timeRange === 'custom' && (
                  <div className="border-t border-zinc-100 p-3 space-y-2">
                    <div>
                      <label className="block text-xs font-medium text-zinc-600 mb-1">From</label>
                      <input type="datetime-local" value={customFrom} onChange={e => setCustomFrom(e.target.value)} className="w-full border border-zinc-300 rounded-lg px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400" />
                    </div>
                    <div>
                      <label className="block text-xs font-medium text-zinc-600 mb-1">To</label>
                      <input type="datetime-local" value={customTo} onChange={e => setCustomTo(e.target.value)} className="w-full border border-zinc-300 rounded-lg px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400" />
                    </div>
                    <div className="text-xs text-zinc-400">Max range: 30 days</div>
                    <div className="flex gap-2">
                      <Button size="sm" onClick={handleCustomApply} className="flex-1">Apply</Button>
                      <Button size="sm" variant="secondary" onClick={() => { setTimeRange('last_7_days'); setCustomFrom(''); setCustomTo(''); setShowDatePicker(false); }}><X className="w-4 h-4" /></Button>
                    </div>
                  </div>
                )}
              </div>
            )}
          </div>
          <select value={state} onChange={e => setState(e.target.value)} className={selectCls}>
            <option value="">All statuses</option>
            {STATES.map(s => <option key={s.value} value={s.value}>{s.label}</option>)}
          </select>
          <select value={bundle} onChange={e => setBundle(e.target.value)} className={selectCls}>
            <option value="">All groups</option>
            {bundles.map(b => <option key={b} value={b}>{b}</option>)}
          </select>
        </div>

        {isLoading ? (
          <p className="p-6 text-sm text-zinc-400">Loading…</p>
        ) : runs.length === 0 ? (
          <div className="p-8 text-center text-sm text-zinc-500">No group releases yet.</div>
        ) : filtered.length === 0 ? (
          <div className="p-8 text-center text-sm text-zinc-500">No group releases match these filters.</div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-xs font-semibold uppercase tracking-wide text-zinc-500 bg-zinc-50/60">
                  <th className="px-4 py-3">Group release</th>
                  <th className="px-4 py-3">Env</th>
                  <th className="px-4 py-3">Version</th>
                  <th className="px-4 py-3">Status</th>
                  <th className="px-4 py-3">Release manager</th>
                  <th className="px-4 py-3">
                    <button
                      type="button"
                      onClick={() => setNewestFirst(v => !v)}
                      className="inline-flex items-center gap-1 uppercase font-semibold tracking-wide hover:text-zinc-800 cursor-pointer"
                      title={newestFirst ? 'Newest first — click for oldest first' : 'Oldest first — click for newest first'}
                    >
                      Created at {newestFirst ? <ArrowDown className="w-3.5 h-3.5" /> : <ArrowUp className="w-3.5 h-3.5" />}
                    </button>
                  </th>
                  <th className="px-4 py-3 text-right">Services</th>
                  <PermissionGate product="autopilot" permission="RELEASE_CREATE">
                    <th className="px-4 py-3 text-right">Actions</th>
                  </PermissionGate>
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-100">
                {rows.map(r => (
                  <tr
                    key={r.runId}
                    onClick={() => navigate(`/backend/group-releases/${r.runId}`)}
                    className="hover:bg-zinc-50 cursor-pointer"
                  >
                    <td className="px-4 py-3">
                      <Link to={`/backend/group-releases/${r.runId}`} onClick={e => e.stopPropagation()} className="font-medium text-zinc-900 hover:underline">{r.bundleName}</Link>
                      {r.description && <p className="text-xs text-zinc-500 max-w-xs truncate" title={r.description}>{r.description}</p>}
                    </td>
                    <td className="px-4 py-3 text-zinc-600">{r.env}</td>
                    <td className="px-4 py-3 font-mono text-xs text-zinc-700" title={groupVersions(r).join(', ')}>{groupVersionLabel(r)}</td>
                    <td className="px-4 py-3"><GroupStateBadge state={r.state} /></td>
                    <td className="px-4 py-3 text-zinc-600">{r.createdBy}</td>
                    <td className="px-4 py-3 text-zinc-500 whitespace-nowrap">{new Date(r.createdAt).toLocaleString()}</td>
                    <td className="px-4 py-3 text-right text-zinc-500 whitespace-nowrap">{doneCount(r)}/{r.steps.length} done</td>
                    <PermissionGate product="autopilot" permission="RELEASE_CREATE">
                      <td className="px-4 py-3 text-right">
                        <button
                          type="button"
                          onClick={e => { e.stopPropagation(); navigate(`/backend/group-releases/new?from=${r.runId}`); }}
                          className="inline-flex h-8 w-8 items-center justify-center rounded-lg text-zinc-500 hover:bg-zinc-100 hover:text-zinc-800 cursor-pointer"
                          title="Clone this group release (every service, version and setting)"
                          aria-label="Clone group release"
                        ><Copy className="w-4 h-4" /></button>
                      </td>
                    </PermissionGate>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        {!isLoading && filtered.length > 0 && (
          <div className="px-4 py-3 flex flex-wrap items-center justify-between gap-3 border-t border-zinc-100">
            <div className="flex items-center gap-3">
              <span className="text-sm text-zinc-500">
                Showing {start + 1}-{Math.min(start + pageSize, filtered.length)} of {filtered.length}
              </span>
              <select value={pageSize} onChange={e => setPageSize(Number(e.target.value))} className="border border-zinc-300 rounded-lg px-2 py-1 text-xs text-zinc-600 cursor-pointer">
                {[10, 25, 50].map(n => <option key={n} value={n}>{n} / page</option>)}
              </select>
            </div>
            <div className="flex items-center gap-1">
              <button
                onClick={() => setPage(Math.max(1, cur - 1))}
                disabled={cur === 1}
                className="h-9 w-9 flex items-center justify-center border border-zinc-300 rounded-lg hover:bg-zinc-50 disabled:opacity-40 disabled:pointer-events-none cursor-pointer"
                aria-label="Previous page"
              ><ChevronLeft className="w-4 h-4" /></button>
              <span className="text-xs text-zinc-500 px-3 font-mono">{cur} / {totalPages}</span>
              <button
                onClick={() => setPage(Math.min(totalPages, cur + 1))}
                disabled={cur === totalPages}
                className="h-9 w-9 flex items-center justify-center border border-zinc-300 rounded-lg hover:bg-zinc-50 disabled:opacity-40 disabled:pointer-events-none cursor-pointer"
                aria-label="Next page"
              ><ChevronRight className="w-4 h-4" /></button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
};

export default GroupReleases;
