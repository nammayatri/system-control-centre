import React, { useEffect, useId, useMemo, useRef, useState } from 'react';
import { Check, Minus, Search, X } from 'lucide-react';
import { cn } from '../../lib/utils';

export interface MultiSelectOption {
  value: string;
  label: string;
  /** Optional grouping key — options with the same group render under one header. */
  group?: string;
  /** Small secondary line under the label (e.g. an upstream id). */
  hint?: string;
  /** Non-selectable (e.g. already granted); still counted in "already selected". */
  disabled?: boolean;
}

export interface MultiSelectProps {
  options: MultiSelectOption[];
  /** Controlled selected values. */
  value: string[];
  onChange: (values: string[]) => void;
  label?: string;
  /** Search box placeholder. */
  placeholder?: string;
  loading?: boolean;
  error?: string | null;
  emptyText?: string;
  disabled?: boolean;
  /** Explicit group ordering; groups not listed follow alphabetically. */
  groupOrder?: string[];
  /** Max height of the scrollable option list, px. Default 264. */
  maxListHeight?: number;
  /** Show removable chips for the current selection. Default true. */
  showChips?: boolean;
  id?: string;
  className?: string;
}

interface FlatRow {
  type: 'header' | 'option';
  group: string;
  option?: MultiSelectOption;
}

/**
 * Accessible searchable multi-select (combobox + multiselectable listbox).
 * Groups options under headers with tri-state select-all, filters by search,
 * and supports full keyboard nav (↑/↓ move, Enter/Space toggle, Home/End,
 * Esc clears search). Loading / empty / error / overflow all handled.
 */
export function MultiSelect({
  options,
  value,
  onChange,
  label,
  placeholder = 'Search…',
  loading = false,
  error = null,
  emptyText = 'No options',
  disabled = false,
  groupOrder,
  maxListHeight = 264,
  showChips = true,
  id,
  className,
}: MultiSelectProps) {
  const reactId = useId();
  const baseId = id ?? reactId;
  const listId = `${baseId}-listbox`;
  const labelId = `${baseId}-label`;

  const [query, setQuery] = useState('');
  const [activeIndex, setActiveIndex] = useState(-1);
  const listRef = useRef<HTMLDivElement>(null);

  const selected = useMemo(() => new Set(value), [value]);

  // Filter, then order into [header, ...options] rows per group.
  const { rows, optionRows, groups } = useMemo(() => {
    const q = query.trim().toLowerCase();
    const match = (o: MultiSelectOption) =>
      !q ||
      o.label.toLowerCase().includes(q) ||
      o.value.toLowerCase().includes(q) ||
      (o.hint?.toLowerCase().includes(q) ?? false);

    const byGroup = new Map<string, MultiSelectOption[]>();
    for (const o of options) {
      if (!match(o)) continue;
      const g = o.group ?? '';
      (byGroup.get(g) ?? byGroup.set(g, []).get(g)!).push(o);
    }

    const order = (a: string, b: string) => {
      const ia = groupOrder?.indexOf(a) ?? -1;
      const ib = groupOrder?.indexOf(b) ?? -1;
      if (ia !== -1 || ib !== -1) return (ia === -1 ? Infinity : ia) - (ib === -1 ? Infinity : ib);
      return a.localeCompare(b);
    };

    const rows: FlatRow[] = [];
    const optionRows: FlatRow[] = [];
    const groups = [...byGroup.keys()].sort(order);
    for (const g of groups) {
      if (g !== '') rows.push({ type: 'header', group: g });
      for (const o of byGroup.get(g)!) {
        const row: FlatRow = { type: 'option', group: g, option: o };
        rows.push(row);
        optionRows.push(row);
      }
    }
    return { rows, optionRows, groups };
  }, [options, query, groupOrder]);

  // Keep the active option in view and valid as the filter changes.
  useEffect(() => {
    if (activeIndex >= optionRows.length) setActiveIndex(optionRows.length - 1);
  }, [optionRows.length, activeIndex]);

  useEffect(() => {
    const el = listRef.current?.querySelector<HTMLElement>(`#${baseId}-opt-${activeIndex}`);
    el?.scrollIntoView({ block: 'nearest' });
  }, [activeIndex, baseId]);

  const toggle = (val: string) => {
    if (selected.has(val)) onChange(value.filter((v) => v !== val));
    else onChange([...value, val]);
  };

  const groupState = (g: string): 'all' | 'some' | 'none' => {
    const opts = optionRows.filter((r) => r.group === g && !r.option!.disabled).map((r) => r.option!);
    if (opts.length === 0) return 'none';
    const sel = opts.filter((o) => selected.has(o.value)).length;
    return sel === 0 ? 'none' : sel === opts.length ? 'all' : 'some';
  };

  const toggleGroup = (g: string) => {
    const opts = optionRows
      .filter((r) => r.group === g && !r.option!.disabled)
      .map((r) => r.option!.value);
    const allSelected = opts.every((v) => selected.has(v));
    const next = new Set(value);
    opts.forEach((v) => (allSelected ? next.delete(v) : next.add(v)));
    onChange([...next]);
  };

  const selectableValues = useMemo(
    () => optionRows.filter((r) => !r.option!.disabled).map((r) => r.option!.value),
    [optionRows],
  );
  const allFilteredSelected =
    selectableValues.length > 0 && selectableValues.every((v) => selected.has(v));

  const selectAllFiltered = () => {
    const next = new Set(value);
    if (allFilteredSelected) selectableValues.forEach((v) => next.delete(v));
    else selectableValues.forEach((v) => next.add(v));
    onChange([...next]);
  };

  const onKeyDown = (e: React.KeyboardEvent) => {
    if (!optionRows.length) return;
    switch (e.key) {
      case 'ArrowDown':
        e.preventDefault();
        setActiveIndex((i) => (i + 1) % optionRows.length);
        break;
      case 'ArrowUp':
        e.preventDefault();
        setActiveIndex((i) => (i <= 0 ? optionRows.length - 1 : i - 1));
        break;
      case 'Home':
        e.preventDefault();
        setActiveIndex(0);
        break;
      case 'End':
        e.preventDefault();
        setActiveIndex(optionRows.length - 1);
        break;
      case 'Enter':
      case ' ': {
        if (activeIndex < 0) break;
        e.preventDefault();
        const opt = optionRows[activeIndex].option!;
        if (!opt.disabled) toggle(opt.value);
        break;
      }
      case 'Escape':
        if (query) {
          e.preventDefault();
          setQuery('');
        }
        break;
    }
  };

  const selectedOptions = useMemo(
    () => options.filter((o) => selected.has(o.value)),
    [options, selected],
  );

  let optIndex = -1; // running index of option rows, for activedescendant

  return (
    <div className={cn('w-full', className)}>
      {label && (
        <div className="flex items-center justify-between mb-1.5">
          <label id={labelId} className="block text-xs font-medium text-zinc-600 dark:text-zinc-400">
            {label}
          </label>
          {value.length > 0 && (
            <span className="text-[11px] text-airborne font-medium">{value.length} selected</span>
          )}
        </div>
      )}

      <div
        className={cn(
          'rounded-lg border bg-white dark:bg-zinc-900',
          error ? 'border-red-300 dark:border-red-800' : 'border-zinc-300 dark:border-zinc-700',
          disabled && 'opacity-60 pointer-events-none',
        )}
      >
        {/* Search + bulk toolbar */}
        <div className="flex items-center gap-2 px-2.5 py-2 border-b border-zinc-100 dark:border-zinc-800">
          <Search className="w-4 h-4 text-zinc-400 shrink-0" />
          <input
            type="text"
            role="combobox"
            aria-expanded="true"
            aria-controls={listId}
            aria-label={label ? undefined : 'Search options'}
            aria-labelledby={label ? labelId : undefined}
            aria-activedescendant={activeIndex >= 0 ? `${baseId}-opt-${activeIndex}` : undefined}
            className="flex-1 min-w-0 bg-transparent text-sm text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400 focus:outline-none"
            placeholder={placeholder}
            value={query}
            disabled={disabled || loading}
            onChange={(e) => {
              setQuery(e.target.value);
              setActiveIndex(0);
            }}
            onKeyDown={onKeyDown}
          />
          {selectableValues.length > 0 && (
            <button
              type="button"
              onClick={selectAllFiltered}
              className="text-[11px] font-medium text-zinc-500 hover:text-airborne dark:text-zinc-400 shrink-0 cursor-pointer transition-colors"
            >
              {allFilteredSelected ? 'Clear' : 'Select all'}
            </button>
          )}
        </div>

        {/* Option list */}
        <div
          ref={listRef}
          id={listId}
          role="listbox"
          aria-multiselectable="true"
          aria-labelledby={label ? labelId : undefined}
          className="overflow-y-auto py-1"
          style={{ maxHeight: maxListHeight }}
        >
          {loading ? (
            <div className="px-3 py-6 text-center text-sm text-zinc-400">Loading…</div>
          ) : error ? (
            <div className="px-3 py-6 text-center text-sm text-red-500">{error}</div>
          ) : optionRows.length === 0 ? (
            <div className="px-3 py-6 text-center text-sm text-zinc-400">
              {query ? `No matches for “${query}”` : emptyText}
            </div>
          ) : (
            rows.map((row, i) => {
              if (row.type === 'header') {
                const state = groupState(row.group);
                return (
                  <button
                    key={`h-${row.group}-${i}`}
                    type="button"
                    onClick={() => toggleGroup(row.group)}
                    className="w-full flex items-center gap-2 px-2.5 py-1.5 text-left cursor-pointer group"
                  >
                    <TriState state={state} />
                    <span className="text-[11px] font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 truncate">
                      {row.group}
                    </span>
                  </button>
                );
              }
              const opt = row.option!;
              optIndex += 1;
              const idx = optIndex;
              const isSel = selected.has(opt.value);
              const isActive = idx === activeIndex;
              return (
                <div
                  key={opt.value}
                  id={`${baseId}-opt-${idx}`}
                  role="option"
                  aria-selected={isSel}
                  aria-disabled={opt.disabled || undefined}
                  onMouseEnter={() => setActiveIndex(idx)}
                  onClick={() => !opt.disabled && toggle(opt.value)}
                  className={cn(
                    'flex items-center gap-2.5 mx-1 px-2 py-1.5 rounded-md min-w-0',
                    opt.disabled ? 'opacity-50 cursor-not-allowed' : 'cursor-pointer',
                    isActive && !opt.disabled && 'bg-zinc-100 dark:bg-airborne-nav',
                  )}
                >
                  <Box checked={isSel} />
                  <div className="min-w-0 flex-1">
                    <div className="text-sm text-zinc-800 dark:text-zinc-200 truncate">
                      {opt.label}
                      {opt.disabled && <span className="ml-1.5 text-[11px] text-zinc-400">already granted</span>}
                    </div>
                    {opt.hint && (
                      <div className="text-[11px] text-zinc-400 dark:text-zinc-500 font-mono truncate">
                        {opt.hint}
                      </div>
                    )}
                  </div>
                </div>
              );
            })
          )}
        </div>
      </div>

      {error && <p className="mt-1 text-xs text-red-600 dark:text-red-400">{error}</p>}

      {/* Selected chips */}
      {showChips && selectedOptions.length > 0 && (
        <div className="mt-2 flex flex-wrap gap-1.5 max-h-24 overflow-y-auto">
          {selectedOptions.map((o) => (
            <span
              key={o.value}
              className="inline-flex items-center gap-1 pl-2 pr-1 py-0.5 rounded-md text-xs bg-airborne/10 text-airborne dark:bg-airborne/15 border border-airborne/30"
            >
              <span className="truncate max-w-[160px]">{o.label}</span>
              <button
                type="button"
                onClick={() => toggle(o.value)}
                className="p-0.5 rounded hover:bg-airborne/20 cursor-pointer"
                aria-label={`Remove ${o.label}`}
              >
                <X className="w-3 h-3" />
              </button>
            </span>
          ))}
        </div>
      )}
    </div>
  );
}

function TriState({ state }: { state: 'all' | 'some' | 'none' }) {
  return (
    <span
      className={cn(
        'w-4 h-4 rounded border flex items-center justify-center shrink-0 transition-colors',
        state === 'none'
          ? 'border-zinc-300 dark:border-zinc-600'
          : 'bg-airborne border-airborne text-white',
      )}
      aria-hidden="true"
    >
      {state === 'all' && <Check className="w-3 h-3" />}
      {state === 'some' && <Minus className="w-3 h-3" />}
    </span>
  );
}

function Box({ checked }: { checked: boolean }) {
  return (
    <span
      className={cn(
        'w-4 h-4 rounded border flex items-center justify-center shrink-0 transition-colors',
        checked ? 'bg-airborne border-airborne text-white' : 'border-zinc-300 dark:border-zinc-600',
      )}
      aria-hidden="true"
    >
      {checked && <Check className="w-3 h-3" />}
    </span>
  );
}
