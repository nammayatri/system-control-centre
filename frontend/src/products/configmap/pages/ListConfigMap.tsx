import React, { useState, useEffect, useRef, useMemo, useCallback } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { Search, RefreshCw, Calendar, Copy, ChevronLeft, ChevronRight, ChevronDown, X, Plus } from 'lucide-react';
import { useQuery } from '@tanstack/react-query';
import { fetchAPConfigMaps } from '../api';
import { StatusBadge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { SimpleTooltip } from '../../../shared/ui/tooltip';
import { TableSkeleton } from '../../../shared/ui/skeleton';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { cn } from '../../../lib/utils';

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

function formatIST(iso: string) {
  if (!iso) return '-';
  try { return new Date(iso).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' }) + ' IST'; }
  catch { return iso; }
}

const getDateRange = (range: TimeRange, customFrom: string, customTo: string) => {
  const now = new Date(); let to = new Date(); let from = new Date();
  switch (range) {
    case 'last_30_mins': from = new Date(now.getTime() - 30 * 60 * 1000); break;
    case 'last_1_hour': from = new Date(now.getTime() - 60 * 60 * 1000); break;
    case 'last_6_hours': from = new Date(now.getTime() - 6 * 60 * 60 * 1000); break;
    case 'today': from.setHours(0, 0, 0, 0); break;
    case 'yesterday': from = new Date(now); from.setDate(from.getDate() - 1); from.setHours(0, 0, 0, 0); to.setHours(0, 0, 0, 0); break;
    case 'last_2_days': from.setDate(from.getDate() - 2); break;
    case 'last_7_days': from.setDate(from.getDate() - 7); break;
    case 'last_30_days': from.setDate(from.getDate() - 30); break;
    case 'this_month': from = new Date(now.getFullYear(), now.getMonth(), 1); break;
    case 'last_month': from = new Date(now.getFullYear(), now.getMonth() - 1, 1); to = new Date(now.getFullYear(), now.getMonth(), 0, 23, 59, 59); break;
    case 'custom': if (customFrom && customTo) { from = new Date(customFrom); to = new Date(customTo); } break;
  }
  return { from, to };
};

function useDebounce<T>(value: T, delay: number): T {
  const [debouncedValue, setDebouncedValue] = useState(value);
  useEffect(() => {
    const timer = setTimeout(() => setDebouncedValue(value), delay);
    return () => clearTimeout(timer);
  }, [value, delay]);
  return debouncedValue;
}

const ListConfigMap: React.FC = () => {
  const [search, setSearch] = useState('');
  const debouncedSearch = useDebounce(search, 300);
  const [timeRange, setTimeRange] = useState<TimeRange>('today');
  const [showDatePicker, setShowDatePicker] = useState(false);
  const [customFrom, setCustomFrom] = useState('');
  const [customTo, setCustomTo] = useState('');
  const [currentPage, setCurrentPage] = useState(1);
  const [itemsPerPage, setItemsPerPage] = useState(10);
  const datePickerRef = useRef<HTMLDivElement>(null);
  const navigate = useNavigate();

  const dateRange = useMemo(() => getDateRange(timeRange, customFrom, customTo), [timeRange, customFrom, customTo]);

  const { data: configMaps = [], isLoading, refetch } = useQuery({
    queryKey: ['configmaps', dateRange.from.toISOString(), dateRange.to.toISOString()],
    queryFn: () => fetchAPConfigMaps(dateRange.from.toISOString(), dateRange.to.toISOString()),
    refetchInterval: 60000,
  });

  useEffect(() => {
    const handler = (e: MouseEvent) => { if (datePickerRef.current && !datePickerRef.current.contains(e.target as Node)) setShowDatePicker(false); };
    document.addEventListener('mousedown', handler); return () => document.removeEventListener('mousedown', handler);
  }, []);

  useEffect(() => { setCurrentPage(1); }, [debouncedSearch]);

  const filtered = useMemo(() => {
    const q = debouncedSearch.toLowerCase();
    if (!q) return configMaps;
    return configMaps.filter(c =>
      c.appGroup?.toLowerCase().includes(q) ||
      c.id?.toLowerCase().includes(q) ||
      c.name?.toLowerCase().includes(q) ||
      c.status?.toLowerCase().includes(q)
    );
  }, [configMaps, debouncedSearch]);

  const totalPages = Math.ceil(filtered.length / itemsPerPage);
  const startIndex = (currentPage - 1) * itemsPerPage;
  const paginatedItems = filtered.slice(startIndex, startIndex + itemsPerPage);

  const handleCustomRangeApply = useCallback(() => {
    if (customFrom && customTo) {
      const from = new Date(customFrom); const to = new Date(customTo);
      if (Math.ceil((to.getTime() - from.getTime()) / (1000 * 60 * 60 * 24)) > 30) { alert('Max 30 days'); return; }
      if (from > to) { alert('Invalid range'); return; }
      setTimeRange('custom'); setShowDatePicker(false);
    }
  }, [customFrom, customTo]);

  return (
    <div className="flex flex-col flex-1 w-full">
      <div className="bg-white border border-zinc-200 rounded-xl">
        {/* Toolbar */}
        <div className="p-4 flex items-center gap-3 border-b border-zinc-100">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-zinc-400" />
            <input type="text" placeholder="Search config maps..." value={search} onChange={e => setSearch(e.target.value)}
              className="pl-9 pr-4 h-9 w-64 border border-zinc-300 rounded-lg text-sm outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150" />
          </div>

          <div className="relative" ref={datePickerRef}>
            <button onClick={() => setShowDatePicker(!showDatePicker)} className="flex items-center gap-2 border border-zinc-300 rounded-lg px-3 h-9 bg-white hover:bg-zinc-50 text-sm text-zinc-600 cursor-pointer transition-colors duration-150">
              <Calendar className="h-4 w-4 text-zinc-400" />
              <span className="max-w-[200px] truncate">{dateRange.from.toLocaleDateString()} - {dateRange.to.toLocaleDateString()}</span>
              <ChevronDown className="w-3.5 h-3.5 text-zinc-400" />
            </button>
            {showDatePicker && (
              <div className="absolute top-full mt-1 left-0 bg-white border border-zinc-200 rounded-lg shadow-lg z-50 min-w-[260px]">
                <div className="p-1.5">
                  {TIME_RANGE_OPTIONS.map(opt => (
                    <button key={opt.value} onClick={() => { if (opt.value !== 'custom') { setTimeRange(opt.value); setShowDatePicker(false); } else setTimeRange('custom'); }}
                      className={cn('w-full text-left px-3 py-1.5 text-sm rounded cursor-pointer transition-colors duration-150', timeRange === opt.value ? 'bg-zinc-100 text-zinc-900 font-medium' : 'text-zinc-600 hover:bg-zinc-50')}>
                      {opt.label}
                    </button>
                  ))}
                </div>
                {timeRange === 'custom' && (
                  <div className="border-t border-zinc-100 p-3 space-y-2">
                    <div><label className="block text-xs font-medium text-zinc-600 mb-1">From</label><input type="datetime-local" value={customFrom} onChange={e => setCustomFrom(e.target.value)} className="w-full border border-zinc-300 rounded-lg px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent" /></div>
                    <div><label className="block text-xs font-medium text-zinc-600 mb-1">To</label><input type="datetime-local" value={customTo} onChange={e => setCustomTo(e.target.value)} className="w-full border border-zinc-300 rounded-lg px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent" /></div>
                    <div className="text-xs text-zinc-400">Max range: 30 days</div>
                    <div className="flex gap-2">
                      <button onClick={handleCustomRangeApply} className="flex-1 bg-zinc-900 text-white px-3 py-1.5 rounded-lg text-sm font-medium hover:bg-zinc-800 cursor-pointer transition-colors duration-150">Apply</button>
                      <button onClick={() => { setTimeRange('last_30_days'); setCustomFrom(''); setCustomTo(''); setShowDatePicker(false); }} className="px-2 py-1.5 border border-zinc-300 rounded-lg hover:bg-zinc-50 cursor-pointer transition-colors duration-150"><X className="w-4 h-4" /></button>
                    </div>
                  </div>
                )}
              </div>
            )}
          </div>

          <div className="flex-1" />
          <button onClick={() => refetch()} className="h-9 w-9 flex items-center justify-center border border-zinc-300 rounded-lg hover:bg-zinc-50 text-zinc-500 cursor-pointer transition-colors duration-150"><RefreshCw className="h-4 w-4" /></button>
          <PermissionGate product="autopilot" permission="CONFIG_CREATE">
            <Link to="/configmap/new"><Button size="sm"><Plus className="w-4 h-4" /> Create ConfigMap</Button></Link>
          </PermissionGate>
        </div>

        {/* Table */}
        <div className="overflow-x-auto">
          {isLoading ? (
            <TableSkeleton rows={6} cols={8} />
          ) : (
            <table className="w-full text-left whitespace-nowrap">
              <thead>
                <tr className="bg-zinc-50 border-b border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                  <th className="py-3 px-4 w-12">#</th>
                  <th className="py-3 px-4">Product</th>
                  <th className="py-3 px-4">ID</th>
                  <th className="py-3 px-4">Name</th>
                  <th className="py-3 px-4">Status</th>
                  <th className="py-3 px-4">Created At</th>
                  <th className="py-3 px-4">Start Time</th>
                  <th className="py-3 px-4 w-16 text-center">Action</th>
                </tr>
              </thead>
              <tbody className="text-sm">
                {filtered.length === 0 ? (
                  <tr><td colSpan={8} className="py-16 text-center text-zinc-400">No config maps found.</td></tr>
                ) : (
                  paginatedItems.map((cm, i) => (
                    <tr key={cm.id} className={cn('border-b border-zinc-100 hover:bg-zinc-100 cursor-pointer transition-colors duration-150', i % 2 === 1 ? 'bg-zinc-50' : 'bg-white')}
                      onClick={() => navigate(`/configmap/${cm.cluster}&&${cm.id}`)}>
                      <td className="py-3 px-4 text-zinc-400 font-mono text-xs">{startIndex + i + 1}</td>
                      <td className="py-3 px-4 font-medium text-zinc-800">{cm.appGroup}</td>
                      <td className="py-3 px-4 font-mono text-xs text-zinc-500 max-w-xs truncate" title={cm.id}>{cm.id}</td>
                      <td className="py-3 px-4 text-zinc-700">{cm.name}</td>
                      <td className="py-3 px-4"><StatusBadge status={cm.status} /></td>
                      <td className="py-3 px-4 font-mono text-xs text-zinc-500">{formatIST(cm.date_created)}</td>
                      <td className="py-3 px-4 font-mono text-xs text-zinc-500">{formatIST(cm.start_time)}</td>
                      <td className="py-3 px-4 text-center">
                        <SimpleTooltip content="Clone">
                          <button onClick={e => { e.stopPropagation(); navigate(`/configmap/new?clone_id=${cm.id}`); }} className="p-1.5 rounded-lg text-zinc-400 hover:text-zinc-600 hover:bg-zinc-100 transition-colors duration-150 cursor-pointer">
                            <Copy className="w-3.5 h-3.5" />
                          </button>
                        </SimpleTooltip>
                      </td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
          )}
        </div>

        {/* Pagination */}
        {!isLoading && filtered.length > 0 && (
          <div className="px-4 py-3 flex items-center justify-between border-t border-zinc-100">
            <div className="flex items-center gap-3">
              <span className="text-sm text-zinc-500">Showing {startIndex + 1}-{Math.min(startIndex + itemsPerPage, filtered.length)} of {filtered.length}</span>
              <select value={itemsPerPage} onChange={e => { setItemsPerPage(Number(e.target.value)); setCurrentPage(1); }} className="border border-zinc-300 rounded-lg px-2 py-1 text-xs text-zinc-600 cursor-pointer focus:outline-none focus:ring-2 focus:ring-zinc-400">
                {[10, 25, 50].map(n => <option key={n} value={n}>{n} / page</option>)}
              </select>
            </div>
            <div className="flex items-center gap-1">
              <button onClick={() => setCurrentPage(p => Math.max(1, p - 1))} disabled={currentPage === 1} className="p-1.5 border border-zinc-300 rounded-lg hover:bg-zinc-50 disabled:opacity-40 disabled:pointer-events-none cursor-pointer transition-colors duration-150"><ChevronLeft className="w-4 h-4" /></button>
              <span className="text-xs text-zinc-500 px-3 font-mono">{currentPage} / {totalPages}</span>
              <button onClick={() => setCurrentPage(p => Math.min(totalPages, p + 1))} disabled={currentPage === totalPages} className="p-1.5 border border-zinc-300 rounded-lg hover:bg-zinc-50 disabled:opacity-40 disabled:pointer-events-none cursor-pointer transition-colors duration-150"><ChevronRight className="w-4 h-4" /></button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
};

export default ListConfigMap;
