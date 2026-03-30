import React, { useState, useEffect, useRef, useMemo } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { Search, Plus, RefreshCw, ChevronDown, Copy, Calendar, ChevronLeft, ChevronRight, X, Activity, CheckCircle2, XCircle, Clock } from 'lucide-react';
import { useReleases } from '../../hooks/useReleases';
import { StatusBadge } from '../../components/ui/badge';
import { Button } from '../../components/ui/button';
import { SimpleTooltip } from '../../components/ui/tooltip';
import { PermissionGate } from '../../components/auth/PermissionGate';
import { cn } from '../../lib/utils';
import type { APRelease, ReleaseStatus } from '../../api';

type TimeRange = 'last_30_mins' | 'last_1_hour' | 'last_6_hours' | 'today' | 'yesterday' | 'last_2_days' | 'last_7_days' | 'last_30_days' | 'this_month' | 'last_month' | 'custom';

const TIME_RANGE_OPTIONS = [
  { value: 'last_30_mins' as TimeRange, label: 'Last 30 mins' },
  { value: 'last_1_hour' as TimeRange, label: 'Last 1 hour' },
  { value: 'last_6_hours' as TimeRange, label: 'Last 6 hours' },
  { value: 'today' as TimeRange, label: 'Today' },
  { value: 'yesterday' as TimeRange, label: 'Yesterday' },
  { value: 'last_2_days' as TimeRange, label: 'Last 2 days' },
  { value: 'last_7_days' as TimeRange, label: 'Last 7 days' },
  { value: 'last_30_days' as TimeRange, label: 'Last 30 days' },
  { value: 'this_month' as TimeRange, label: 'This month' },
  { value: 'last_month' as TimeRange, label: 'Last month' },
  { value: 'custom' as TimeRange, label: 'Custom range' },
];

const STATUS_FILTER_OPTIONS: ReleaseStatus[] = [
  'CREATED', 'INPROGRESS', 'PAUSED', 'COMPLETED', 'ABORTED', 'USER_ABORTED',
  'GCLT_ABORTED', 'REVERTED', 'REVERTING', 'DISCARDED', 'RECORDING', 'RECORDED',
];

const getDateRange = (range: TimeRange, customFrom: string, customTo: string): { from: Date; to: Date } => {
  const now = new Date();
  let to = new Date();
  let from = new Date();

  switch (range) {
    case 'last_30_mins': from = new Date(now.getTime() - 30 * 60 * 1000); break;
    case 'last_1_hour': from = new Date(now.getTime() - 60 * 60 * 1000); break;
    case 'last_6_hours': from = new Date(now.getTime() - 6 * 60 * 60 * 1000); break;
    case 'today': from.setHours(0, 0, 0, 0); break;
    case 'yesterday':
      from = new Date(now); from.setDate(from.getDate() - 1); from.setHours(0, 0, 0, 0);
      to.setHours(0, 0, 0, 0); break;
    case 'last_2_days': from.setDate(from.getDate() - 2); break;
    case 'last_7_days': from.setDate(from.getDate() - 7); break;
    case 'last_30_days': from.setDate(from.getDate() - 30); break;
    case 'this_month': from = new Date(now.getFullYear(), now.getMonth(), 1); break;
    case 'last_month':
      from = new Date(now.getFullYear(), now.getMonth() - 1, 1);
      to = new Date(now.getFullYear(), now.getMonth(), 0, 23, 59, 59); break;
    case 'custom':
      if (customFrom && customTo) { from = new Date(customFrom); to = new Date(customTo); }
      break;
  }
  return { from, to };
};

const formatISODate = (isoString?: string) => {
  if (!isoString) return '-';
  const date = new Date(isoString);
  return date.toLocaleString('en-US', { month: 'short', day: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: true });
};

const ListRelease: React.FC = () => {
  const [search, setSearch] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [currentPage, setCurrentPage] = useState(1);
  const [itemsPerPage, setItemsPerPage] = useState(10);
  const [timeRange, setTimeRange] = useState<TimeRange>('last_30_days');
  const [showDatePicker, setShowDatePicker] = useState(false);
  const [customFrom, setCustomFrom] = useState('');
  const [customTo, setCustomTo] = useState('');
  const [statusFilter, setStatusFilter] = useState<string>('');
  const [productFilter, setProductFilter] = useState<string>('');
  const [sortField, setSortField] = useState<string>('start_time');
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('desc');
  const datePickerRef = useRef<HTMLDivElement>(null);
  const navigate = useNavigate();

  // Debounce search
  useEffect(() => {
    const t = setTimeout(() => setDebouncedSearch(search), 300);
    return () => clearTimeout(t);
  }, [search]);

  const dateRange = useMemo(() => getDateRange(timeRange, customFrom, customTo), [timeRange, customFrom, customTo]);
  const { data: releases = [], isLoading, refetch, dataUpdatedAt } = useReleases(dateRange.from.toISOString(), dateRange.to.toISOString());

  // Outside click
  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (datePickerRef.current && !datePickerRef.current.contains(e.target as Node)) setShowDatePicker(false);
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, []);

  // Reset page on filter change
  useEffect(() => { setCurrentPage(1); }, [debouncedSearch, statusFilter, productFilter]);

  const handleCustomRangeApply = () => {
    if (customFrom && customTo) {
      const from = new Date(customFrom);
      const to = new Date(customTo);
      if (Math.ceil((to.getTime() - from.getTime()) / (1000 * 60 * 60 * 24)) > 30) {
        alert('Custom range cannot exceed 30 days'); return;
      }
      if (from > to) { alert('Start date cannot be after end date'); return; }
      setTimeRange('custom');
      setShowDatePicker(false);
    }
  };

  // KPI calculations
  const kpis = useMemo(() => {
    const today = new Date(); today.setHours(0, 0, 0, 0);
    return {
      total: releases.length,
      active: releases.filter(r => ['INPROGRESS', 'RECORDING', 'RESTARTING'].includes(r.status)).length,
      completedToday: releases.filter(r => r.status === 'COMPLETED' && r.end_time && new Date(r.end_time) >= today).length,
      failedToday: releases.filter(r => ['ABORTED', 'USER_ABORTED', 'GCLT_ABORTED'].includes(r.status) && r.end_time && new Date(r.end_time) >= today).length,
    };
  }, [releases]);

  // Products list for filter
  const productOptions = useMemo(() => [...new Set(releases.map(r => r.product).filter(Boolean))], [releases]);

  // Filter + sort
  const filteredReleases = useMemo(() => {
    let list = releases.filter(r => {
      const q = debouncedSearch.toLowerCase();
      const matchesSearch = !q || r.service?.toLowerCase().includes(q) || r.new_version?.toLowerCase().includes(q) || r.id?.toLowerCase().includes(q) || r.status?.toLowerCase().includes(q);
      const matchesStatus = !statusFilter || r.status === statusFilter;
      const matchesProduct = !productFilter || r.product === productFilter;
      return matchesSearch && matchesStatus && matchesProduct;
    });

    list.sort((a, b) => {
      let aVal = (a as any)[sortField] || '';
      let bVal = (b as any)[sortField] || '';
      if (sortDir === 'asc') return aVal > bVal ? 1 : -1;
      return aVal < bVal ? 1 : -1;
    });

    return list;
  }, [releases, debouncedSearch, statusFilter, productFilter, sortField, sortDir]);

  const totalPages = Math.ceil(filteredReleases.length / itemsPerPage);
  const startIndex = (currentPage - 1) * itemsPerPage;
  const paginatedReleases = filteredReleases.slice(startIndex, startIndex + itemsPerPage);

  const formatDateRange = () => {
    const { from, to } = dateRange;
    return `${from.toLocaleString('en-US', { month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' })} - ${to.toLocaleString('en-US', { month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' })}`;
  };

  const handleSort = (field: string) => {
    if (sortField === field) setSortDir(d => d === 'asc' ? 'desc' : 'asc');
    else { setSortField(field); setSortDir('desc'); }
  };

  return (
    <div className="flex flex-col flex-1 w-full">
      {/* KPI Cards */}
      <div className="grid grid-cols-4 gap-4 mb-6">
        {[
          { label: 'Total Releases', value: kpis.total, icon: <Layers className="w-4 h-4" />, color: 'text-zinc-600' },
          { label: 'Active', value: kpis.active, icon: <Activity className="w-4 h-4" />, color: 'text-amber-600' },
          { label: 'Completed Today', value: kpis.completedToday, icon: <CheckCircle2 className="w-4 h-4" />, color: 'text-emerald-600' },
          { label: 'Failed Today', value: kpis.failedToday, icon: <XCircle className="w-4 h-4" />, color: 'text-red-600' },
        ].map((kpi, i) => (
          <div key={i} className="bg-white border border-border rounded-lg px-5 py-4">
            <div className="flex items-center justify-between mb-2">
              <span className="text-xs font-medium text-zinc-500 uppercase tracking-wider">{kpi.label}</span>
              <span className={kpi.color}>{kpi.icon}</span>
            </div>
            <div className={cn('text-2xl font-bold font-mono', kpi.color)}>{kpi.value}</div>
          </div>
        ))}
      </div>

      {/* Toolbar */}
      <div className="bg-white border border-border rounded-lg shadow-sm">
        <div className="p-4 flex items-center gap-3 border-b border-border-light">
          {/* Search */}
          <div className="relative">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-zinc-400" />
            <input
              type="text"
              placeholder="Search releases..."
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              className="pl-9 pr-4 py-2 w-64 border border-zinc-200 rounded-lg focus:ring-2 focus:ring-zinc-800 focus:border-transparent text-sm outline-none"
            />
          </div>

          {/* Date Range */}
          <div className="relative" ref={datePickerRef}>
            <button onClick={() => setShowDatePicker(!showDatePicker)} className="flex items-center gap-2 border border-zinc-200 rounded-lg px-3 py-2 bg-white hover:bg-zinc-50 text-sm text-zinc-600">
              <Calendar className="h-4 w-4 text-zinc-400" />
              <span className="max-w-[220px] truncate">{formatDateRange()}</span>
              <ChevronDown className="w-3.5 h-3.5 text-zinc-400" />
            </button>
            {showDatePicker && (
              <div className="absolute top-full mt-1 left-0 bg-white border border-zinc-200 rounded-lg shadow-lg z-50 min-w-[260px]">
                <div className="p-1.5">
                  {TIME_RANGE_OPTIONS.map((opt) => (
                    <button key={opt.value} onClick={() => { if (opt.value !== 'custom') { setTimeRange(opt.value); setShowDatePicker(false); } else { setTimeRange('custom'); } }}
                      className={cn('w-full text-left px-3 py-1.5 text-sm rounded', timeRange === opt.value ? 'bg-zinc-100 text-zinc-900 font-medium' : 'text-zinc-600 hover:bg-zinc-50')}>
                      {opt.label}
                    </button>
                  ))}
                </div>
                {timeRange === 'custom' && (
                  <div className="border-t border-zinc-100 p-3 space-y-2">
                    <div>
                      <label className="block text-xs font-medium text-zinc-600 mb-1">From</label>
                      <input type="datetime-local" value={customFrom} onChange={(e) => setCustomFrom(e.target.value)} className="w-full border border-zinc-200 rounded px-2 py-1.5 text-sm" />
                    </div>
                    <div>
                      <label className="block text-xs font-medium text-zinc-600 mb-1">To</label>
                      <input type="datetime-local" value={customTo} onChange={(e) => setCustomTo(e.target.value)} className="w-full border border-zinc-200 rounded px-2 py-1.5 text-sm" />
                    </div>
                    <div className="text-xs text-zinc-400">Max range: 30 days</div>
                    <div className="flex gap-2">
                      <button onClick={handleCustomRangeApply} className="flex-1 bg-zinc-900 text-white px-3 py-1.5 rounded text-sm font-medium hover:bg-zinc-800">Apply</button>
                      <button onClick={() => { setTimeRange('last_30_days'); setCustomFrom(''); setCustomTo(''); setShowDatePicker(false); }} className="px-2 py-1.5 border border-zinc-200 rounded text-sm hover:bg-zinc-50"><X className="w-4 h-4" /></button>
                    </div>
                  </div>
                )}
              </div>
            )}
          </div>

          {/* Status Filter */}
          <select value={statusFilter} onChange={(e) => setStatusFilter(e.target.value)} className="border border-zinc-200 rounded-lg px-3 py-2 text-sm text-zinc-600 bg-white">
            <option value="">All Statuses</option>
            {STATUS_FILTER_OPTIONS.map(s => <option key={s} value={s}>{s}</option>)}
          </select>

          {/* Product Filter */}
          <select value={productFilter} onChange={(e) => setProductFilter(e.target.value)} className="border border-zinc-200 rounded-lg px-3 py-2 text-sm text-zinc-600 bg-white">
            <option value="">All Products</option>
            {productOptions.map(p => <option key={p} value={p}>{p}</option>)}
          </select>

          <div className="flex-1" />

          <button onClick={() => refetch()} className="p-2 border border-zinc-200 rounded-lg hover:bg-zinc-50 text-zinc-500">
            <RefreshCw className="h-4 w-4" />
          </button>

          <PermissionGate product="backend-releases" permission="RELEASE_CREATE">
            <Link to="/releases/new">
              <Button size="sm"><Plus className="w-4 h-4" /> Create Release</Button>
            </Link>
          </PermissionGate>
        </div>

        {/* Table */}
        <div className="overflow-x-auto">
          <table className="w-full text-left whitespace-nowrap">
            <thead>
              <tr className="bg-zinc-50/80 border-b border-border text-xs text-zinc-500 font-medium">
                <th className="py-3 px-4 w-12">#</th>
                <th className="py-3 px-4 cursor-pointer hover:text-zinc-700" onClick={() => handleSort('service')}>Service</th>
                <th className="py-3 px-4 cursor-pointer hover:text-zinc-700" onClick={() => handleSort('id')}>ID</th>
                <th className="py-3 px-4 cursor-pointer hover:text-zinc-700" onClick={() => handleSort('new_version')}>Version</th>
                <th className="py-3 px-4">Status</th>
                <th className="py-3 px-4 cursor-pointer hover:text-zinc-700" onClick={() => handleSort('start_time')}>Start Time</th>
                <th className="py-3 px-4 w-16 text-center">Action</th>
              </tr>
            </thead>
            <tbody className="text-sm">
              {isLoading ? (
                <tr><td colSpan={7} className="py-16 text-center text-zinc-400">Loading releases...</td></tr>
              ) : filteredReleases.length === 0 ? (
                <tr><td colSpan={7} className="py-16 text-center text-zinc-400">No releases found</td></tr>
              ) : (
                paginatedReleases.map((release, index) => {
                  const isRevert = release.release_context?.revert === 1;
                  return (
                    <tr
                      key={release.id}
                      className={cn('border-b border-border-light hover:bg-zinc-50/50 cursor-pointer transition-colors', index % 2 === 1 && 'bg-zinc-50/30')}
                      onClick={() => navigate(`/releases/${release.release_context?.cluster || 'default'}/${release.id}`)}
                    >
                      <td className="py-3 px-4 text-zinc-400 font-mono text-xs">{startIndex + index + 1}</td>
                      <td className="py-3 px-4 font-medium text-zinc-800">{release.service}</td>
                      <td className="py-3 px-4 font-mono text-xs text-zinc-500">{release.id}</td>
                      <td className="py-3 px-4 font-mono text-xs text-zinc-600">{release.new_version}</td>
                      <td className="py-3 px-4">
                        <div className="flex items-center gap-1.5">
                          <StatusBadge status={release.status} />
                          {release.env && (
                            <span className="px-1.5 py-0.5 rounded text-[9px] font-bold uppercase tracking-wide bg-sky-50 text-sky-700 border border-sky-200">
                              {release.env}
                            </span>
                          )}
                          {isRevert && (
                            <span className="px-1.5 py-0.5 rounded text-[9px] font-bold uppercase tracking-wide bg-violet-50 text-violet-700 border border-violet-200">
                              REVERT
                            </span>
                          )}
                        </div>
                      </td>
                      <td className="py-3 px-4 font-mono text-xs text-zinc-500">{formatISODate(release.start_time)}</td>
                      <td className="py-3 px-4 text-center">
                        <SimpleTooltip content="Clone release">
                          <button
                            onClick={(e) => { e.stopPropagation(); navigate(`/releases/${release.release_context?.cluster || 'default'}/${release.id}/clone`); }}
                            className="p-1.5 rounded-lg text-zinc-400 hover:text-zinc-600 hover:bg-zinc-100 transition-colors"
                          >
                            <Copy className="w-3.5 h-3.5" />
                          </button>
                        </SimpleTooltip>
                      </td>
                    </tr>
                  );
                })
              )}
            </tbody>
          </table>
        </div>

        {/* Pagination */}
        {!isLoading && filteredReleases.length > 0 && (
          <div className="px-4 py-3 flex items-center justify-between border-t border-border-light">
            <div className="flex items-center gap-3">
              <span className="text-sm text-zinc-500">
                {startIndex + 1}-{Math.min(startIndex + itemsPerPage, filteredReleases.length)} of {filteredReleases.length}
              </span>
              <select value={itemsPerPage} onChange={(e) => { setItemsPerPage(Number(e.target.value)); setCurrentPage(1); }} className="border border-zinc-200 rounded px-2 py-1 text-xs text-zinc-600">
                {[10, 25, 50].map(n => <option key={n} value={n}>{n} / page</option>)}
              </select>
            </div>
            <div className="flex items-center gap-1">
              <button onClick={() => setCurrentPage(p => Math.max(1, p - 1))} disabled={currentPage === 1} className="p-1.5 border border-zinc-200 rounded hover:bg-zinc-50 disabled:opacity-40">
                <ChevronLeft className="w-4 h-4" />
              </button>
              <span className="text-xs text-zinc-500 px-3 font-mono">{currentPage} / {totalPages}</span>
              <button onClick={() => setCurrentPage(p => Math.min(totalPages, p + 1))} disabled={currentPage === totalPages} className="p-1.5 border border-zinc-200 rounded hover:bg-zinc-50 disabled:opacity-40">
                <ChevronRight className="w-4 h-4" />
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
};

// Need to import Layers for the KPI card
import { Layers } from 'lucide-react';

export default ListRelease;
