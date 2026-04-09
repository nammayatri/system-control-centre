/**
 * Shared hooks for product screens.
 * Products import these instead of reimplementing common patterns.
 */

import { useState, useMemo, useCallback, useEffect, useRef } from 'react';
import type { DateRange, PaginationState } from '../types';

/** Search + debounce hook for list views */
export function useSearch(delay = 300) {
  const [search, setSearch] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');

  const updateSearch = useCallback((value: string) => {
    setSearch(value);
    const timeout = setTimeout(() => setDebouncedSearch(value), delay);
    return () => clearTimeout(timeout);
  }, [delay]);

  return { search, debouncedSearch, setSearch: updateSearch };
}

/** Pagination hook for list views */
export function usePagination(total: number, defaultPageSize = 10) {
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(defaultPageSize);

  const totalPages = Math.ceil(total / pageSize);
  const hasNext = page < totalPages;
  const hasPrev = page > 1;

  const goNext = () => hasNext && setPage(p => p + 1);
  const goPrev = () => hasPrev && setPage(p => p - 1);
  const goTo = (p: number) => setPage(Math.min(Math.max(1, p), totalPages));

  // Reset to page 1 when total changes significantly
  const resetPage = () => setPage(1);

  return {
    page, pageSize, totalPages, hasNext, hasPrev,
    goNext, goPrev, goTo, setPageSize, resetPage,
    // Slice helpers for client-side pagination
    startIndex: (page - 1) * pageSize,
    endIndex: page * pageSize,
  };
}

/** Date range filter hook — common preset ranges */
export function useDateRange() {
  const [range, setRange] = useState<DateRange>(() => {
    const now = new Date();
    const from = new Date(now);
    from.setDate(from.getDate() - 2);
    return { from: from.toISOString(), to: now.toISOString() };
  });

  const presets = useMemo(() => [
    { label: 'Last 30m', getValue: () => offsetRange(30 * 60 * 1000) },
    { label: 'Last 1h', getValue: () => offsetRange(60 * 60 * 1000) },
    { label: 'Last 6h', getValue: () => offsetRange(6 * 60 * 60 * 1000) },
    { label: 'Today', getValue: () => todayRange() },
    { label: 'Yesterday', getValue: () => yesterdayRange() },
    { label: 'Last 2 days', getValue: () => offsetRange(2 * 24 * 60 * 60 * 1000) },
    { label: 'Last 7 days', getValue: () => offsetRange(7 * 24 * 60 * 60 * 1000) },
    { label: 'Last 30 days', getValue: () => offsetRange(30 * 24 * 60 * 60 * 1000) },
  ], []);

  return { range, setRange, presets };
}

function offsetRange(ms: number): DateRange {
  const now = new Date();
  return { from: new Date(now.getTime() - ms).toISOString(), to: now.toISOString() };
}

function todayRange(): DateRange {
  const now = new Date();
  const start = new Date(now);
  start.setHours(0, 0, 0, 0);
  return { from: start.toISOString(), to: now.toISOString() };
}

function yesterdayRange(): DateRange {
  const now = new Date();
  const start = new Date(now);
  start.setDate(start.getDate() - 1);
  start.setHours(0, 0, 0, 0);
  const end = new Date(start);
  end.setHours(23, 59, 59, 999);
  return { from: start.toISOString(), to: end.toISOString() };
}

/**
 * Refresh button helper with a minimum visible spin duration.
 *
 * Problem: react-query's @isFetching@ flips true→false within ~50ms for cached
 * or fast API calls. The refresh icon @animate-spin@ class then flickers on
 * and off so quickly the user doesn't perceive any feedback — making the
 * button feel broken even when it works.
 *
 * Solution: this hook returns a @spinning@ boolean that stays true for AT
 * LEAST @minMs@ after @trigger()@ is called, OR until @isFetching@ goes
 * false, whichever is LONGER. Users always see a visible spin animation.
 *
 * Usage:
 * ```
 * const { spinning, onRefresh } = useRefreshAnimation(isFetching, refetch);
 * <RefreshCw className={`w-4 h-4 ${spinning ? 'animate-spin' : ''}`} onClick={onRefresh} />
 * ```
 */
export function useRefreshAnimation(
  isFetching: boolean,
  onRefresh: () => void | Promise<unknown>,
  minMs = 400
) {
  const [manualSpin, setManualSpin] = useState(false);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Stop manual spin when both (a) minMs elapsed AND (b) isFetching done.
  // The minMs timer sets a flag; we only CLEAR manualSpin once both are true.
  const minTimeDoneRef = useRef(false);

  useEffect(() => {
    if (!manualSpin) return;
    // If fetch finishes AND minimum time has elapsed, stop spinning.
    if (!isFetching && minTimeDoneRef.current) {
      setManualSpin(false);
    }
  }, [isFetching, manualSpin]);

  const trigger = useCallback(() => {
    if (timerRef.current) clearTimeout(timerRef.current);
    minTimeDoneRef.current = false;
    setManualSpin(true);
    void onRefresh();
    timerRef.current = setTimeout(() => {
      minTimeDoneRef.current = true;
      // If fetch already finished by this point, stop spinning now.
      setManualSpin((cur) => {
        // read latest isFetching via effect; if still fetching, stay true
        // (effect will flip it off when fetch finishes)
        return cur && isFetchingRef.current;
      });
    }, minMs);
  }, [onRefresh, minMs]);

  // Mirror isFetching in a ref so trigger's setTimeout callback reads latest.
  const isFetchingRef = useRef(isFetching);
  useEffect(() => {
    isFetchingRef.current = isFetching;
  }, [isFetching]);

  // Cleanup on unmount
  useEffect(() => () => {
    if (timerRef.current) clearTimeout(timerRef.current);
  }, []);

  // Spin whenever the library is fetching OR we're in the forced-minimum window.
  const spinning = isFetching || manualSpin;

  return { spinning, onRefresh: trigger };
}

/** Filter list by search string across multiple fields */
export function useFilteredList<T>(
  items: T[],
  search: string,
  getSearchableFields: (item: T) => string[]
) {
  return useMemo(() => {
    if (!search.trim()) return items;
    const lower = search.toLowerCase();
    return items.filter(item =>
      getSearchableFields(item).some(field =>
        field?.toLowerCase().includes(lower)
      )
    );
  }, [items, search, getSearchableFields]);
}
