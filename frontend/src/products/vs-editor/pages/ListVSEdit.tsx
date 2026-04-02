import React, { useState, useEffect, useMemo, useRef } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { fetchVSEdits } from '../../../api';
import type { VSEditTracker } from '../../../api';
import { StatusBadge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { SimpleTooltip } from '../../../shared/ui/tooltip';
import { TableSkeleton } from '../../../shared/ui/skeleton';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { Search, Plus, RefreshCw, Calendar, ChevronDown, ChevronLeft, ChevronRight, X } from 'lucide-react';
import { cn } from '../../../lib/utils';

type TimeRange = 'today' | 'last_7_days' | 'last_30_days' | 'custom';

const TIME_RANGE_OPTIONS = [
  { value: 'today' as TimeRange, label: 'Today' },
  { value: 'last_7_days' as TimeRange, label: 'Last 7 days' },
  { value: 'last_30_days' as TimeRange, label: 'Last 30 days' },
  { value: 'custom' as TimeRange, label: 'Custom range' },
];

const getDateRange = (range: TimeRange, customFrom: string, customTo: string): { from: Date; to: Date } => {
  const now = new Date();
  let from = new Date();
  const to = new Date();

  switch (range) {
    case 'today': from.setHours(0, 0, 0, 0); break;
    case 'last_7_days': from.setDate(from.getDate() - 7); break;
    case 'last_30_days': from.setDate(from.getDate() - 30); break;
    case 'custom':
      if (customFrom && customTo) { return { from: new Date(customFrom), to: new Date(customTo) }; }
      break;
  }
  return { from, to };
};

const formatDate = (isoString?: string) => {
  if (!isoString) return '-';
  const date = new Date(isoString);
  return date.toLocaleString('en-US', { month: 'short', day: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: true });
};

const ListVSEdit: React.FC = () => {
  const [search, setSearch] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [currentPage, setCurrentPage] = useState(1);
  const [itemsPerPage, setItemsPerPage] = useState(10);
  const [timeRange, setTimeRange] = useState<TimeRange>('last_7_days');
  const [showDatePicker, setShowDatePicker] = useState(false);
  const [customFrom, setCustomFrom] = useState('');
  const [customTo, setCustomTo] = useState('');
  const datePickerRef = useRef<HTMLDivElement>(null);
  const navigate = useNavigate();

  useEffect(() => {
    const t = setTimeout(() => setDebouncedSearch(search), 300);
    return () => clearTimeout(t);
  }, [search]);

  const dateRange = useMemo(() => getDateRange(timeRange, customFrom, customTo), [timeRange, customFrom, customTo]);

  const { data: edits = [], isLoading, refetch } = useQuery({
    queryKey: ['vs-edits', dateRange.from.toISOString(), dateRange.to.toISOString()],
    queryFn: () => fetchVSEdits({ from: dateRange.from.toISOString(), to: dateRange.to.toISOString() }),
    refetchInterval: 30000,
  });

  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (datePickerRef.current && !datePickerRef.current.contains(e.target as Node)) setShowDatePicker(false);
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, []);

  useEffect(() => { setCurrentPage(1); }, [debouncedSearch]);

  const filteredEdits = useMemo(() => {
    if (!debouncedSearch) return edits;
    const q = debouncedSearch.toLowerCase();
    return edits.filter((e: VSEditTracker) =>
      e.appGroup?.toLowerCase().includes(q) ||
      e.service?.toLowerCase().includes(q) ||
      e.vs_name?.toLowerCase().includes(q) ||
      e.status?.toLowerCase().includes(q) ||
      e.created_by?.toLowerCase().includes(q)
    );
  }, [edits, debouncedSearch]);

  const totalPages = Math.ceil(filteredEdits.length / itemsPerPage);
  const startIndex = (currentPage - 1) * itemsPerPage;
  const paginatedEdits = filteredEdits.slice(startIndex, startIndex + itemsPerPage);

  const formatDateRange = () => {
    const { from, to } = dateRange;
    return `${from.toLocaleString('en-US', { month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' })} - ${to.toLocaleString('en-US', { month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' })}`;
  };

  return (
    <div className="flex flex-col flex-1 w-full">
      {/* Toolbar + Table Card */}
      <div className="bg-white border border-zinc-200 rounded-xl">
        <div className="p-4 flex items-center gap-3 border-b border-zinc-100">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-zinc-400" />
            <input type="text" placeholder="Search VS edits..." value={search} onChange={(e) => setSearch(e.target.value)}
              className="pl-9 pr-4 h-9 w-64 border border-zinc-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150" />
          </div>

          {/* Date Range */}
          <div className="relative" ref={datePickerRef}>
            <button onClick={() => setShowDatePicker(!showDatePicker)} className="flex items-center gap-2 border border-zinc-300 rounded-lg px-3 h-9 bg-white hover:bg-zinc-50 text-sm text-zinc-600 cursor-pointer transition-colors duration-150">
              <Calendar className="h-4 w-4 text-zinc-400" />
              <span className="max-w-[220px] truncate">{formatDateRange()}</span>
              <ChevronDown className="w-3.5 h-3.5 text-zinc-400" />
            </button>
            {showDatePicker && (
              <div className="absolute top-full mt-1 left-0 bg-white border border-zinc-200 rounded-lg shadow-lg z-50 min-w-[240px]">
                <div className="p-1.5">
                  {TIME_RANGE_OPTIONS.map((opt) => (
                    <button key={opt.value} onClick={() => { if (opt.value !== 'custom') { setTimeRange(opt.value); setShowDatePicker(false); } else { setTimeRange('custom'); } }}
                      className={cn('w-full text-left px-3 py-1.5 text-sm rounded cursor-pointer transition-colors duration-150', timeRange === opt.value ? 'bg-zinc-100 text-zinc-900 font-medium' : 'text-zinc-600 hover:bg-zinc-50')}>
                      {opt.label}
                    </button>
                  ))}
                </div>
                {timeRange === 'custom' && (
                  <div className="border-t border-zinc-100 p-3 space-y-2">
                    <div>
                      <label className="block text-xs font-medium text-zinc-600 mb-1">From</label>
                      <input type="datetime-local" value={customFrom} onChange={(e) => setCustomFrom(e.target.value)} className="w-full border border-zinc-300 rounded-lg px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent" />
                    </div>
                    <div>
                      <label className="block text-xs font-medium text-zinc-600 mb-1">To</label>
                      <input type="datetime-local" value={customTo} onChange={(e) => setCustomTo(e.target.value)} className="w-full border border-zinc-300 rounded-lg px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent" />
                    </div>
                    <div className="flex gap-2">
                      <Button size="sm" onClick={() => { if (customFrom && customTo) setShowDatePicker(false); }} className="flex-1">Apply</Button>
                      <Button size="sm" variant="secondary" onClick={() => { setTimeRange('last_7_days'); setCustomFrom(''); setCustomTo(''); setShowDatePicker(false); }}><X className="w-4 h-4" /></Button>
                    </div>
                  </div>
                )}
              </div>
            )}
          </div>

          <div className="flex-1" />

          <button onClick={() => refetch()} className="h-9 w-9 flex items-center justify-center border border-zinc-300 rounded-lg hover:bg-zinc-50 text-zinc-500 cursor-pointer transition-colors duration-150">
            <RefreshCw className="h-4 w-4" />
          </button>

          <PermissionGate product="autopilot" permission="RELEASE_CREATE">
            <Link to="/vs-editor/new">
              <Button size="sm"><Plus className="w-4 h-4" /> New VS Edit</Button>
            </Link>
          </PermissionGate>
        </div>

        {/* Table */}
        <div className="overflow-x-auto">
          {isLoading ? (
            <TableSkeleton rows={8} cols={6} />
          ) : (
            <table className="w-full text-left whitespace-nowrap">
              <thead>
                <tr className="bg-zinc-50 border-b border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                  <th className="py-3 px-4 w-12">#</th>
                  <th className="py-3 px-4">Product</th>
                  <th className="py-3 px-4">Service</th>
                  <th className="py-3 px-4">VS Name</th>
                  <th className="py-3 px-4">Status</th>
                  <th className="py-3 px-4">Created By</th>
                  <th className="py-3 px-4">Created At</th>
                </tr>
              </thead>
              <tbody className="text-sm">
                {filteredEdits.length === 0 ? (
                  <tr><td colSpan={7} className="py-16 text-center text-zinc-400">No VS edits found</td></tr>
                ) : (
                  paginatedEdits.map((edit: VSEditTracker, index: number) => (
                    <tr
                      key={edit.id}
                      className={cn('border-b border-zinc-100 hover:bg-zinc-100 cursor-pointer transition-colors duration-150', index % 2 === 1 ? 'bg-zinc-50' : 'bg-white')}
                      onClick={() => navigate(`/vs-editor/${edit.id}`)}
                    >
                      <td className="py-3 px-4 text-zinc-400 font-mono text-xs">{startIndex + index + 1}</td>
                      <td className="py-3 px-4 font-medium text-zinc-800">{edit.appGroup}</td>
                      <td className="py-3 px-4 text-zinc-700">{edit.service}</td>
                      <td className="py-3 px-4 font-mono text-xs text-zinc-600">{edit.vs_name}</td>
                      <td className="py-3 px-4"><StatusBadge status={edit.status} /></td>
                      <td className="py-3 px-4 text-zinc-600">{edit.created_by}</td>
                      <td className="py-3 px-4 font-mono text-xs text-zinc-500">{formatDate(edit.created_at)}</td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
          )}
        </div>

        {/* Pagination */}
        {!isLoading && filteredEdits.length > 0 && (
          <div className="px-4 py-3 flex items-center justify-between border-t border-zinc-100">
            <div className="flex items-center gap-3">
              <span className="text-sm text-zinc-500">
                Showing {startIndex + 1}-{Math.min(startIndex + itemsPerPage, filteredEdits.length)} of {filteredEdits.length}
              </span>
              <select value={itemsPerPage} onChange={(e) => { setItemsPerPage(Number(e.target.value)); setCurrentPage(1); }} className="border border-zinc-300 rounded-lg px-2 py-1 text-xs text-zinc-600 cursor-pointer focus:outline-none focus:ring-2 focus:ring-zinc-400">
                {[10, 25, 50].map(n => <option key={n} value={n}>{n} / page</option>)}
              </select>
            </div>
            <div className="flex items-center gap-1">
              <button onClick={() => setCurrentPage(p => Math.max(1, p - 1))} disabled={currentPage === 1} className="p-1.5 border border-zinc-300 rounded-lg hover:bg-zinc-50 disabled:opacity-40 disabled:pointer-events-none cursor-pointer transition-colors duration-150">
                <ChevronLeft className="w-4 h-4" />
              </button>
              <span className="text-xs text-zinc-500 px-3 font-mono">{currentPage} / {totalPages}</span>
              <button onClick={() => setCurrentPage(p => Math.min(totalPages, p + 1))} disabled={currentPage === totalPages} className="p-1.5 border border-zinc-300 rounded-lg hover:bg-zinc-50 disabled:opacity-40 disabled:pointer-events-none cursor-pointer transition-colors duration-150">
                <ChevronRight className="w-4 h-4" />
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
};

export default ListVSEdit;
