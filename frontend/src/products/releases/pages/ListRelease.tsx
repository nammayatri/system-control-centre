import React, { useState, useEffect, useRef, useMemo, useCallback } from 'react';
import { Link, useNavigate, useLocation } from 'react-router-dom';
import { Search, Plus, RefreshCw, ChevronDown, Copy, Clipboard, Calendar, ChevronLeft, ChevronRight, X, SlidersHorizontal, Server, Smartphone, Layers, Undo2, Apple } from 'lucide-react';
import { useReleases } from '../hooks';
import { useRefreshAnimation } from '../../../shared/hooks';
import { StatusBadge } from '../components/StatusBadge';
import { Button } from '../../../shared/ui/button';
import { SimpleTooltip } from '../../../shared/ui/tooltip';
import { TableSkeleton } from '../../../shared/ui/skeleton';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { cn } from '../../../lib/utils';
import { toast } from 'sonner';
import type { ReleaseStatus } from '../api';

const AndroidIcon = ({ className }: { className?: string }) => (
  <svg viewBox="0 0 24 24" fill="currentColor" className={className}>
    <path d="M17.6 9.48l1.84-3.18c.16-.31.04-.69-.27-.85a.637.637 0 00-.83.22l-1.88 3.24a11.463 11.463 0 00-8.92 0L5.66 5.67c-.19-.29-.58-.38-.87-.2-.28.18-.37.54-.19.83L6.4 9.48A10.78 10.78 0 003 16h18a10.78 10.78 0 00-3.4-6.52zM8.86 13a.98.98 0 110-1.96.98.98 0 010 1.96zm6.28 0a.98.98 0 110-1.96.98.98 0 010 1.96z"/>
  </svg>
);

const PlatformBadge = ({ platform, isMobile }: { platform: string; isMobile: boolean }) => {
  if (!isMobile) {
    return (
      <span className="rounded px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-sky-700 text-white">
        {platform}
      </span>
    );
  }
  if (platform === 'android') {
    return (
      <span className="inline-flex items-center gap-1 rounded px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-[#3DDC84]/15 text-[#1B8A4F] border border-[#3DDC84]/30">
        <AndroidIcon className="w-3 h-3" />
        Android
      </span>
    );
  }
  if (platform === 'ios') {
    return (
      <span className="inline-flex items-center gap-1 rounded px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-zinc-500/15 text-zinc-700 border border-zinc-400/30">
        <Apple className="w-3 h-3" />
        iOS
      </span>
    );
  }
  return (
    <span className="rounded px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-violet-600 text-white">
      {platform}
    </span>
  );
};

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
  'GCLT_ABORTED', 'REVERTED', 'REVERTING', 'DISCARDED', 'DISCARDING', 'ABORTING', 'RESTARTING',
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

// Display-only IST formatting so worldwide dashboard users see on-call India's timestamps.
const formatISODate = (isoString?: string) => {
  if (!isoString) return '-';
  const date = new Date(isoString);
  if (isNaN(date.getTime())) return '-';
  return date.toLocaleString('en-IN', {
    timeZone: 'Asia/Kolkata',
    month: 'short', day: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit', hour12: true,
  }) + ' IST';
};

type CategoryFilter = 'all' | 'backend' | 'mobile';

const ListRelease: React.FC = () => {
  const [search, setSearch] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [currentPage, setCurrentPage] = useState(1);
  const [itemsPerPage, setItemsPerPage] = useState(10);
  const [timeRange, setTimeRange] = useState<TimeRange>('today');
  const [showDatePicker, setShowDatePicker] = useState(false);
  const [customFrom, setCustomFrom] = useState('');
  const [customTo, setCustomTo] = useState('');
  const [statusFilter, setStatusFilter] = useState<string>('');
  const [productFilter, setProductFilter] = useState<string>('');
  const [platformFilter, setPlatformFilter] = useState<string>('');
  const [showMobileFilters, setShowMobileFilters] = useState(false);
  const [sortField, setSortField] = useState<string>('date_created');
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('desc');
  const [refreshTick, setRefreshTick] = useState(0);
  const datePickerRef = useRef<HTMLDivElement>(null);
  const navigate = useNavigate();
  const location = useLocation();

  const defaultCategory: CategoryFilter = location.pathname.startsWith('/mobile') ? 'mobile' : 'backend';
  const [category, setCategory] = useState<CategoryFilter>(defaultCategory);
  useEffect(() => { setCategory(defaultCategory); }, [defaultCategory]);
  const apiCategory = category === 'all' ? undefined : category;

  useEffect(() => {
    const t = setTimeout(() => setDebouncedSearch(search), 300);
    return () => clearTimeout(t);
  }, [search]);

  const dateRange = useMemo(() => getDateRange(timeRange, customFrom, customTo), [timeRange, customFrom, customTo, refreshTick]);
  const { data: releases = [], isLoading, isFetching, refetch } = useReleases(
    dateRange.from.toISOString(),
    dateRange.to.toISOString(),
    apiCategory,
  );

  const doRefresh = useCallback(() => {
    setRefreshTick((n) => n + 1);
    // queueMicrotask so refetch runs after React commits the new dateRange into the query key.
    queueMicrotask(() => { void refetch(); });
  }, [refetch]);
  const { spinning: refreshSpinning, onRefresh: handleRefresh } = useRefreshAnimation(isFetching, doRefresh);

  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (datePickerRef.current && !datePickerRef.current.contains(e.target as Node)) setShowDatePicker(false);
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, []);

  useEffect(() => { setCurrentPage(1); }, [debouncedSearch, statusFilter, productFilter, platformFilter, category]);
  useEffect(() => { if (category === 'backend') setPlatformFilter(''); }, [category]);

  const handleCustomRangeApply = () => {
    if (customFrom && customTo) {
      const from = new Date(customFrom);
      const to = new Date(customTo);
      if (Math.ceil((to.getTime() - from.getTime()) / (1000 * 60 * 60 * 24)) > 30) {
        toast.error('Custom range cannot exceed 30 days'); return;
      }
      if (from > to) { toast.error('Start date cannot be after end date'); return; }
      setTimeRange('custom');
      setShowDatePicker(false);
    }
  };

  const kpis = useMemo(() => {
    const today = new Date(); today.setHours(0, 0, 0, 0);
    return {
      total: releases.length,
      active: releases.filter(r => ['INPROGRESS', 'RESTARTING'].includes(r.status)).length,
      completedToday: releases.filter(r => r.status === 'COMPLETED' && r.end_time && new Date(r.end_time) >= today).length,
      failedToday: releases.filter(r => ['ABORTED', 'USER_ABORTED', 'GCLT_ABORTED'].includes(r.status) && r.end_time && new Date(r.end_time) >= today).length,
    };
  }, [releases]);

  const productOptions = useMemo(() => [...new Set(releases.map(r => r.appGroup).filter(Boolean))], [releases]);

  const filteredReleases = useMemo(() => {
    let list = releases.filter(r => {
      const q = debouncedSearch.toLowerCase();
      const matchesSearch = !q || r.service?.toLowerCase().includes(q) || r.new_version?.toLowerCase().includes(q) || r.id?.toLowerCase().includes(q) || r.status?.toLowerCase().includes(q);
      const matchesStatus = !statusFilter || r.status === statusFilter;
      const matchesProduct = !productFilter || r.appGroup === productFilter;
      const matchesPlatform = !platformFilter || r.env === platformFilter;
      return matchesSearch && matchesStatus && matchesProduct && matchesPlatform;
    });

    list.sort((a, b) => {
      let aVal = (a as any)[sortField] || '';
      let bVal = (b as any)[sortField] || '';
      if (sortDir === 'asc') return aVal > bVal ? 1 : -1;
      return aVal < bVal ? 1 : -1;
    });

    return list;
  }, [releases, debouncedSearch, statusFilter, productFilter, platformFilter, sortField, sortDir]);

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

  const kpiCards = [
    { label: 'Total Releases', value: kpis.total, dotColor: 'bg-zinc-400' },
    { label: 'Active', value: kpis.active, dotColor: 'bg-amber-500' },
    { label: 'Completed Today', value: kpis.completedToday, dotColor: 'bg-emerald-500' },
    { label: 'Failed Today', value: kpis.failedToday, dotColor: 'bg-red-500' },
  ];

  const activeFilterCount = (statusFilter ? 1 : 0) + (productFilter ? 1 : 0) + (platformFilter ? 1 : 0);

  const categoryChips: { key: CategoryFilter; label: string; icon?: React.ReactNode }[] = [
    { key: 'all', label: 'All' },
    { key: 'backend', label: 'Backend', icon: <Server className="w-3.5 h-3.5" /> },
    { key: 'mobile', label: 'Mobile', icon: <Smartphone className="w-3.5 h-3.5" /> },
  ];

  const handleCategoryClick = (key: CategoryFilter) => {
    if (key === 'all') {
      setCategory('all');
    } else if (key === defaultCategory) {
      setCategory(key);
    } else if (key === 'backend') {
      navigate('/backend/releases', { replace: true });
    } else {
      navigate('/mobile/releases', { replace: true });
    }
  };

  return (
    <div className="flex flex-col flex-1 w-full">
      <div className="flex items-center gap-1.5 mb-4 sm:mb-5 flex-wrap" role="tablist" aria-label="Release category">
        {categoryChips.map(chip => (
          <button
            key={chip.key}
            type="button"
            role="tab"
            aria-selected={category === chip.key}
            onClick={() => handleCategoryClick(chip.key)}
            className={cn(
              'inline-flex items-center gap-1.5 h-8 px-3 rounded-full text-xs font-medium border cursor-pointer transition-colors duration-150',
              category === chip.key
                ? 'bg-zinc-900 text-white border-zinc-900'
                : 'bg-white text-zinc-600 border-zinc-300 hover:bg-zinc-50'
            )}
          >
            {chip.icon}
            {chip.label}
          </button>
        ))}
      </div>

      <div className="grid grid-cols-2 md:grid-cols-4 gap-3 sm:gap-4 mb-4 sm:mb-6">
        {kpiCards.map((kpi, i) => (
          <div
            key={i}
            className="bg-white border border-zinc-200 rounded-xl px-4 py-3 sm:px-5 sm:py-4 flex flex-col justify-between min-h-[72px] sm:min-h-[80px]"
          >
            <span className="text-[10px] sm:text-[11px] font-medium text-zinc-500 uppercase tracking-wider">{kpi.label}</span>
            <div className="flex items-center gap-2 mt-1">
              <span className={cn('w-1.5 h-1.5 rounded-full', kpi.dotColor)} />
              <span className="text-xl sm:text-2xl font-bold text-zinc-900">{kpi.value}</span>
            </div>
          </div>
        ))}
      </div>

      <div className="bg-white border border-zinc-200 rounded-xl">
        <div className="md:hidden p-3 border-b border-zinc-100 space-y-2">
          <div className="flex gap-2">
            <div className="relative flex-1">
              <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-zinc-400" />
              <input
                type="text"
                placeholder="Search..."
                value={search}
                onChange={(e) => setSearch(e.target.value)}
                className="pl-9 pr-3 h-10 w-full border border-zinc-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent"
              />
            </div>
            <button
              onClick={() => setShowMobileFilters(!showMobileFilters)}
              className={cn(
                'h-10 px-3 flex items-center gap-1.5 border border-zinc-300 rounded-lg text-sm cursor-pointer transition-colors',
                showMobileFilters ? 'bg-zinc-100 text-zinc-900' : 'bg-white text-zinc-600 hover:bg-zinc-50'
              )}
              aria-label="Toggle filters"
            >
              <SlidersHorizontal className="w-4 h-4" />
              {activeFilterCount > 0 && (
                <span className="bg-zinc-900 text-white rounded-full text-[10px] w-4 h-4 flex items-center justify-center font-medium">
                  {activeFilterCount}
                </span>
              )}
            </button>
            <button
              onClick={handleRefresh}
              className="h-10 w-10 flex items-center justify-center border border-zinc-300 rounded-lg hover:bg-zinc-50 text-zinc-500 cursor-pointer transition-colors"
              aria-label="Refresh"
            >
              <RefreshCw className={`h-4 w-4 ${refreshSpinning ? 'animate-spin' : ''}`} />
            </button>
          </div>
          {showMobileFilters && (
            <div className="space-y-2 pt-1">
              <div className="relative" ref={datePickerRef}>
                <button
                  onClick={() => setShowDatePicker(!showDatePicker)}
                  className="w-full flex items-center justify-between gap-2 border border-zinc-300 rounded-lg px-3 h-10 bg-white text-sm text-zinc-600 cursor-pointer"
                >
                  <span className="flex items-center gap-2 truncate">
                    <Calendar className="h-4 w-4 text-zinc-400 shrink-0" />
                    <span className="truncate">{formatDateRange()}</span>
                  </span>
                  <ChevronDown className="w-3.5 h-3.5 text-zinc-400 shrink-0" />
                </button>
                {showDatePicker && (
                  <div className="absolute top-full mt-1 left-0 right-0 bg-white border border-zinc-200 rounded-lg shadow-sm z-50">
                    <div className="p-1.5 max-h-60 overflow-y-auto">
                      {TIME_RANGE_OPTIONS.map((opt) => (
                        <button
                          key={opt.value}
                          onClick={() => { if (opt.value !== 'custom') { setTimeRange(opt.value); setShowDatePicker(false); } else { setTimeRange('custom'); } }}
                          className={cn(
                            'w-full text-left px-3 py-2 text-sm rounded cursor-pointer transition-colors',
                            timeRange === opt.value ? 'bg-zinc-100 text-zinc-900 font-medium' : 'text-zinc-600 hover:bg-zinc-50'
                          )}
                        >
                          {opt.label}
                        </button>
                      ))}
                    </div>
                    {timeRange === 'custom' && (
                      <div className="border-t border-zinc-100 p-3 space-y-2">
                        <div>
                          <label className="block text-xs font-medium text-zinc-600 mb-1">From</label>
                          <input type="datetime-local" value={customFrom} onChange={(e) => setCustomFrom(e.target.value)} className="w-full border border-zinc-300 rounded-lg px-2 py-2 text-sm" />
                        </div>
                        <div>
                          <label className="block text-xs font-medium text-zinc-600 mb-1">To</label>
                          <input type="datetime-local" value={customTo} onChange={(e) => setCustomTo(e.target.value)} className="w-full border border-zinc-300 rounded-lg px-2 py-2 text-sm" />
                        </div>
                        <Button size="md" onClick={handleCustomRangeApply} fullWidth>Apply</Button>
                      </div>
                    )}
                  </div>
                )}
              </div>
              <select
                value={statusFilter}
                onChange={(e) => setStatusFilter(e.target.value)}
                className="w-full border border-zinc-300 rounded-lg px-3 h-10 text-sm text-zinc-600 bg-white"
              >
                <option value="">All Statuses</option>
                {STATUS_FILTER_OPTIONS.map(s => <option key={s} value={s}>{s.replace(/_/g, ' ')}</option>)}
              </select>
              <select
                value={productFilter}
                onChange={(e) => setProductFilter(e.target.value)}
                className="w-full border border-zinc-300 rounded-lg px-3 h-10 text-sm text-zinc-600 bg-white"
              >
                <option value="">All Groups</option>
                {productOptions.map(p => <option key={p} value={p}>{p}</option>)}
              </select>
              {category === 'mobile' && (
                <select
                  value={platformFilter}
                  onChange={(e) => setPlatformFilter(e.target.value)}
                  className="w-full border border-zinc-300 rounded-lg px-3 h-10 text-sm text-zinc-600 bg-white"
                >
                  <option value="">All Platforms</option>
                  <option value="android">Android</option>
                  <option value="ios">iOS</option>
                </select>
              )}
            </div>
          )}
          <PermissionGate product="autopilot" permission="RELEASE_CREATE">
            <Link to={category === 'mobile' ? '/mobile/releases/new' : '/backend/releases/new'} className="block">
              <Button size="md" fullWidth>
                <Plus className="w-4 h-4" /> Create Release
              </Button>
            </Link>
          </PermissionGate>
        </div>

        <div className="hidden md:flex p-4 items-center gap-3 border-b border-zinc-100 flex-wrap">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-zinc-400" />
            <input
              type="text"
              placeholder="Search releases..."
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              className="pl-9 pr-4 h-9 w-56 lg:w-64 border border-zinc-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150"
            />
          </div>

          <div className="relative" ref={datePickerRef}>
            <button onClick={() => setShowDatePicker(!showDatePicker)} className="flex items-center gap-2 border border-zinc-300 rounded-lg px-3 h-9 bg-white hover:bg-zinc-50 text-sm text-zinc-600 cursor-pointer transition-colors duration-150">
              <Calendar className="h-4 w-4 text-zinc-400" />
              <span className="max-w-[180px] lg:max-w-[220px] truncate">{formatDateRange()}</span>
              <ChevronDown className="w-3.5 h-3.5 text-zinc-400" />
            </button>
            {showDatePicker && (
              <div className="absolute top-full mt-1 left-0 bg-white border border-zinc-200 rounded-lg shadow-sm z-50 min-w-[260px]">
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
                    <div className="text-xs text-zinc-400">Max range: 30 days</div>
                    <div className="flex gap-2">
                      <Button size="sm" onClick={handleCustomRangeApply} className="flex-1">Apply</Button>
                      <Button size="sm" variant="secondary" onClick={() => { setTimeRange('last_30_days'); setCustomFrom(''); setCustomTo(''); setShowDatePicker(false); }}><X className="w-4 h-4" /></Button>
                    </div>
                  </div>
                )}
              </div>
            )}
          </div>

          <select value={statusFilter} onChange={(e) => setStatusFilter(e.target.value)} className="border border-zinc-300 rounded-lg px-3 h-9 text-sm text-zinc-600 bg-white cursor-pointer focus:outline-none focus:ring-2 focus:ring-zinc-400">
            <option value="">All Statuses</option>
            {STATUS_FILTER_OPTIONS.map(s => <option key={s} value={s}>{s.replace(/_/g, ' ')}</option>)}
          </select>

          <select value={productFilter} onChange={(e) => setProductFilter(e.target.value)} className="border border-zinc-300 rounded-lg px-3 h-9 text-sm text-zinc-600 bg-white cursor-pointer focus:outline-none focus:ring-2 focus:ring-zinc-400">
            <option value="">All Groups</option>
            {productOptions.map(p => <option key={p} value={p}>{p}</option>)}
          </select>

          {category === 'mobile' && (
            <select value={platformFilter} onChange={(e) => setPlatformFilter(e.target.value)} className="border border-zinc-300 rounded-lg px-3 h-9 text-sm text-zinc-600 bg-white cursor-pointer focus:outline-none focus:ring-2 focus:ring-zinc-400">
              <option value="">All Platforms</option>
              <option value="android">Android</option>
              <option value="ios">iOS</option>
            </select>
          )}

          <div className="flex-1" />

          <button onClick={handleRefresh} aria-label="Refresh" className="h-9 w-9 flex items-center justify-center border border-zinc-300 rounded-lg hover:bg-zinc-50 text-zinc-500 cursor-pointer transition-colors duration-150">
            <RefreshCw className={`h-4 w-4 ${refreshSpinning ? 'animate-spin' : ''}`} />
          </button>

          <PermissionGate product="autopilot" permission="RELEASE_CREATE">
            <Link to={category === 'mobile' ? '/mobile/releases/new' : '/backend/releases/new'}>
              <Button size="sm"><Plus className="w-4 h-4" /> Create Release</Button>
            </Link>
          </PermissionGate>
        </div>

        <div className="hidden md:block overflow-x-auto">
          {isLoading ? (
            <TableSkeleton rows={8} cols={7} />
          ) : (
            <table className="w-full text-left whitespace-nowrap">
              <thead>
                <tr className="bg-zinc-50 border-b border-zinc-200 text-[11px] text-zinc-500 font-medium uppercase tracking-wider">
                  <th className="py-3 px-4 w-12">#</th>
                  <th className="py-3 px-4 w-24">Category</th>
                  <th className="py-3 px-4 cursor-pointer hover:text-zinc-700 transition-colors" onClick={() => handleSort('appGroup')}>App / Group</th>
                  <th className="py-3 px-4 cursor-pointer hover:text-zinc-700 transition-colors" onClick={() => handleSort('service')}>Service / Surface</th>
                  <th className="py-3 px-4 cursor-pointer hover:text-zinc-700 transition-colors" onClick={() => handleSort('new_version')}>Version</th>
                  <th className="py-3 px-4">Status</th>
                  <th className="py-3 px-4 cursor-pointer hover:text-zinc-700 transition-colors" onClick={() => handleSort('release_manager')}>Release Manager</th>
                  <th className="py-3 px-4 cursor-pointer hover:text-zinc-700 transition-colors" onClick={() => handleSort('date_created')}>Created At</th>
                  <th className="py-3 px-4 w-24 text-center">Actions</th>
                </tr>
              </thead>
              <tbody className="text-sm">
                {filteredReleases.length === 0 ? (
                  <tr><td colSpan={9} className="py-16 text-center text-zinc-400">No releases found</td></tr>
                ) : (
                  paginatedReleases.map((release, index) => {
                    const isRevert = release.release_context?.revert === 1 || !!release.revertsReleaseId;
                    const isMobile = release.tracker_type === 'MobileBuild';
                    const isDebugBuild = isMobile && (release.release_context?.destination === 'Firebase' || release.release_context?.destination === 'TestFlight');
                    const isMobileRevertBuild = isMobile && !!release.revertsReleaseId;
                    // Mobile rows reuse the underlying tracker columns with relabeled
                    // semantics (app/surface/platform). Backend rows render the
                    // historical (app_group/service/env) layout. Same data, different
                    // user-facing labels — matches what was inserted in
                    // insertMobileTracker (rtAppGroup=acName, rtService=acSurface,
                    // rtEnv=acPlatform).
                    const releaseHref = isMobile
                      ? `/mobile/releases/${release.id}`
                      : `/backend/releases/${release.id}`;
                    return (
                      <tr
                        key={release.id}
                        className={cn(
                          'border-b border-zinc-100 hover:bg-zinc-100 cursor-pointer transition-colors duration-150',
                          index % 2 === 1 ? 'bg-zinc-50' : 'bg-white'
                        )}
                        onClick={() => navigate(releaseHref)}
                      >
                        <td className="py-3 px-4 text-zinc-400 font-mono text-xs">{startIndex + index + 1}</td>
                        <td className="py-3 px-4">
                          <span className="inline-flex items-center gap-1 text-[11px] text-zinc-600">
                            {isMobile ? <Smartphone className="w-3.5 h-3.5 text-violet-600" /> : <Server className="w-3.5 h-3.5 text-sky-600" />}
                            {isMobile ? 'Mobile' : 'Backend'}
                          </span>
                        </td>
                        <td className="py-3 px-4 text-xs text-zinc-600">{release.appGroup}</td>
                        <td className="py-3 px-4 font-medium text-zinc-800">{release.service}</td>
                        <td className="py-3 px-4 font-mono text-xs text-zinc-600">{release.new_version}</td>
                        <td className="py-3 px-4">
                          <div className="flex items-center gap-1.5 flex-wrap">
                            <StatusBadge status={release.status} />
                            {release.env && (
                              <PlatformBadge platform={release.env} isMobile={isMobile} />
                            )}
                            {release.env_override_data && (
                              <span className="rounded px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-blue-700 text-white">
                                ENV
                              </span>
                            )}
                            {isRevert && (
                              <span className="rounded px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-violet-700 text-white">
                                REVERT
                              </span>
                            )}
                            {isDebugBuild && (
                              <span className="rounded px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-amber-600 text-white">
                                DEBUG
                              </span>
                            )}
                          </div>
                        </td>
                        <td className="py-3 px-4 text-xs text-zinc-600">{release.release_manager || '-'}</td>
                        <td className="py-3 px-4 font-mono text-xs text-zinc-500">{formatISODate(release.date_created)}</td>
                        <td className="py-3 px-4 text-center">
                          <div className="inline-flex items-center gap-0.5">
                            {isMobile && release.release_context?.release_group_id && (
                              <SimpleTooltip content="Open release group">
                                <button
                                  onClick={(e) => {
                                    e.stopPropagation();
                                    navigate(`/mobile/groups/${release.release_context!.release_group_id}`);
                                  }}
                                  className="p-1.5 rounded-lg text-zinc-400 hover:text-violet-700 hover:bg-violet-50 transition-colors duration-150 cursor-pointer"
                                  aria-label="Open release group"
                                >
                                  <Layers className="w-3.5 h-3.5" />
                                </button>
                              </SimpleTooltip>
                            )}
                            {/* Revert action for completed mobile releases. Hidden
                                if the release was already reverted (drives the
                                "Reverted by X" banner on detail page) to prevent
                                double-reverts. Click navigates to the full revert
                                page; permission gating mirrors the detail page. */}
                            {isMobile
                              && !isDebugBuild
                              && !isMobileRevertBuild
                              && release.status === 'COMPLETED'
                              && !release.metadata?.reverted_by && (
                              <SimpleTooltip content="Revert this release">
                                <button
                                  onClick={(e) => {
                                    e.stopPropagation();
                                    navigate(`/mobile/releases/${release.id}/revert`);
                                  }}
                                  className="p-1.5 rounded-lg text-zinc-400 hover:text-violet-700 hover:bg-violet-50 transition-colors duration-150 cursor-pointer"
                                  aria-label="Revert release"
                                >
                                  <Undo2 className="w-3.5 h-3.5" />
                                </button>
                              </SimpleTooltip>
                            )}
                            {!isMobile && (
                              <SimpleTooltip content="Clone release">
                                <button
                                  onClick={(e) => { e.stopPropagation(); navigate(`/backend/releases/${release.id}/clone`); }}
                                  className="p-1.5 rounded-lg text-zinc-400 hover:text-zinc-600 hover:bg-zinc-100 transition-colors duration-150 cursor-pointer"
                                  aria-label="Clone release"
                                >
                                  <Copy className="w-3.5 h-3.5" />
                                </button>
                              </SimpleTooltip>
                            )}
                            <SimpleTooltip content="Copy release ID">
                              <button
                                onClick={(e) => { e.stopPropagation(); navigator.clipboard.writeText(release.id); toast.success('Release ID copied'); }}
                                className="p-1.5 rounded-lg text-zinc-400 hover:text-zinc-600 hover:bg-zinc-100 transition-colors duration-150 cursor-pointer"
                                aria-label="Copy release ID"
                              >
                                <Clipboard className="w-3.5 h-3.5" />
                              </button>
                            </SimpleTooltip>
                          </div>
                        </td>
                      </tr>
                    );
                  })
                )}
              </tbody>
            </table>
          )}
        </div>

        <div className="md:hidden">
          {isLoading ? (
            <TableSkeleton rows={4} cols={4} />
          ) : filteredReleases.length === 0 ? (
            <div className="py-16 text-center text-zinc-400 text-sm">No releases found</div>
          ) : (
            <div className="divide-y divide-zinc-100">
              {paginatedReleases.map((release) => {
                const isRevert = release.release_context?.revert === 1 || !!release.revertsReleaseId;
                const isMobile = release.tracker_type === 'MobileBuild';
                const isDebugBuild = isMobile && (release.release_context?.destination === 'Firebase' || release.release_context?.destination === 'TestFlight');
                const releaseHref = isMobile
                  ? `/mobile/releases/${release.id}`
                  : `/backend/releases/${release.id}`;
                return (
                  <div
                    key={release.id}
                    onClick={() => navigate(releaseHref)}
                    className="p-4 cursor-pointer hover:bg-zinc-50 transition-colors active:bg-zinc-100"
                  >
                    <div className="flex items-start justify-between gap-3 mb-2">
                      <div className="min-w-0 flex-1">
                        <div className="flex items-center gap-1.5 mb-0.5">
                          {isMobile
                            ? <Smartphone className="w-3.5 h-3.5 text-violet-600 shrink-0" />
                            : <Server className="w-3.5 h-3.5 text-sky-600 shrink-0" />}
                          <span className="text-[10px] font-medium uppercase tracking-wider text-zinc-500">
                            {isMobile ? 'Mobile' : 'Backend'}
                          </span>
                        </div>
                        <div className="text-sm font-medium text-zinc-900 truncate">
                          {isMobile ? release.appGroup : release.service}
                        </div>
                        <div className="text-xs text-zinc-500 mt-0.5 truncate flex items-center gap-1.5">
                          {isMobile ? (
                            <>
                              {release.service}
                              <span className="text-zinc-300">·</span>
                              <PlatformBadge platform={release.env} isMobile />
                            </>
                          ) : release.appGroup}
                        </div>
                      </div>
                      <div className="flex items-center gap-1 shrink-0">
                        {isMobile && release.release_context?.release_group_id && (
                          <button
                            onClick={(e) => {
                              e.stopPropagation();
                              navigate(`/mobile/groups/${release.release_context!.release_group_id}`);
                            }}
                            className="w-9 h-9 rounded-lg flex items-center justify-center text-zinc-400 hover:text-violet-700 hover:bg-violet-50"
                            aria-label="Open release group"
                          >
                            <Layers className="w-4 h-4" />
                          </button>
                        )}
                        {!isMobile && (
                          <button
                            onClick={(e) => { e.stopPropagation(); navigate(`/backend/releases/${release.id}/clone`); }}
                            className="w-9 h-9 rounded-lg flex items-center justify-center text-zinc-400 hover:text-zinc-700 hover:bg-zinc-100"
                            aria-label="Clone release"
                          >
                            <Copy className="w-4 h-4" />
                          </button>
                        )}
                        <button
                          onClick={(e) => { e.stopPropagation(); navigator.clipboard.writeText(release.id); toast.success('Release ID copied'); }}
                          className="w-9 h-9 rounded-lg flex items-center justify-center text-zinc-400 hover:text-zinc-700 hover:bg-zinc-100"
                          aria-label="Copy release ID"
                        >
                          <Clipboard className="w-4 h-4" />
                        </button>
                      </div>
                    </div>
                    <div className="flex items-center gap-1.5 flex-wrap mb-2">
                      <StatusBadge status={release.status} />
                      {/* For mobile rows the platform is already shown inline above; skip the badge to avoid duplicating it. */}
                      {release.env && !isMobile && (
                        <span className="rounded px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-sky-700 text-white">
                          {release.env}
                        </span>
                      )}
                      {release.env_override_data && (
                        <span className="rounded px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-blue-700 text-white">
                          ENV
                        </span>
                      )}
                      {isRevert && (
                        <span className="rounded px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-violet-700 text-white">
                          REVERT
                        </span>
                      )}
                      {isDebugBuild && (
                        <span className="rounded px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-amber-600 text-white">
                          DEBUG
                        </span>
                      )}
                    </div>
                    <div className="flex items-center gap-3 text-[11px] text-zinc-500 font-mono flex-wrap">
                      <span>{release.new_version}</span>
                      <span>·</span>
                      <span>{formatISODate(release.date_created)}</span>
                    </div>
                    {release.release_manager && (
                      <div className="text-xs text-zinc-500 mt-1">By {release.release_manager}</div>
                    )}
                  </div>
                );
              })}
            </div>
          )}
        </div>

        {!isLoading && filteredReleases.length > 0 && (
          <div className="px-3 sm:px-4 py-3 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 border-t border-zinc-100">
            <div className="flex items-center gap-3 flex-wrap">
              <span className="text-xs sm:text-sm text-zinc-500">
                Showing {startIndex + 1}-{Math.min(startIndex + itemsPerPage, filteredReleases.length)} of {filteredReleases.length}
              </span>
              <select
                value={itemsPerPage}
                onChange={(e) => { setItemsPerPage(Number(e.target.value)); setCurrentPage(1); }}
                className="border border-zinc-300 rounded-lg px-2 py-1 text-xs text-zinc-600 cursor-pointer focus:outline-none focus:ring-2 focus:ring-zinc-400"
              >
                {[10, 25, 50].map(n => <option key={n} value={n}>{n} / page</option>)}
              </select>
            </div>
            <div className="flex items-center gap-1">
              <button
                onClick={() => setCurrentPage(p => Math.max(1, p - 1))}
                disabled={currentPage === 1}
                className="h-9 w-9 flex items-center justify-center border border-zinc-300 rounded-lg hover:bg-zinc-50 disabled:opacity-40 disabled:pointer-events-none cursor-pointer transition-colors"
                aria-label="Previous page"
              >
                <ChevronLeft className="w-4 h-4" />
              </button>
              <span className="text-xs text-zinc-500 px-3 font-mono">{currentPage} / {totalPages}</span>
              <button
                onClick={() => setCurrentPage(p => Math.min(totalPages, p + 1))}
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
    </div>
  );
};

export default ListRelease;
