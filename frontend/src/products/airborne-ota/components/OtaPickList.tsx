import { useMemo, useState } from 'react';
import { Search } from 'lucide-react';
import { cn } from '../../../lib/utils';

export interface OtaPickOption {
  value: string;
  label: string;
  /** Small mono secondary line (e.g. the file/package key). */
  hint?: string;
}

interface OtaPickListProps {
  options: OtaPickOption[];
  /** Controlled selected value ('' = none). */
  value: string;
  onChange: (value: string) => void;
  label?: string;
  placeholder?: string;
  loading?: boolean;
  error?: string | null;
  emptyText?: string;
  /** Max height of the scrollable option list, px. Default 240. */
  maxListHeight?: number;
}

// Searchable single-pick list (radio semantics), styled to match MultiSelect.
export function OtaPickList({
  options,
  value,
  onChange,
  label,
  placeholder = 'Search…',
  loading = false,
  error = null,
  emptyText = 'No options',
  maxListHeight = 240,
}: OtaPickListProps) {
  const [query, setQuery] = useState('');

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return options;
    return options.filter(
      (o) =>
        o.label.toLowerCase().includes(q) ||
        o.value.toLowerCase().includes(q) ||
        (o.hint?.toLowerCase().includes(q) ?? false),
    );
  }, [options, query]);

  return (
    <div className="w-full">
      {label && (
        <label className="block text-xs font-medium text-zinc-600 dark:text-zinc-400 mb-1.5">
          {label}
        </label>
      )}
      <div
        className={cn(
          'rounded-lg border bg-white dark:bg-zinc-900',
          error ? 'border-red-300 dark:border-red-800' : 'border-zinc-300 dark:border-zinc-700',
        )}
      >
        <div className="flex items-center gap-2 px-2.5 py-2 border-b border-zinc-100 dark:border-zinc-800">
          <Search className="w-4 h-4 text-zinc-400 shrink-0" />
          <input
            type="text"
            className="flex-1 min-w-0 bg-transparent text-sm text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400 focus:outline-none"
            placeholder={placeholder}
            value={query}
            disabled={loading}
            onChange={(e) => setQuery(e.target.value)}
          />
        </div>
        <div role="radiogroup" className="overflow-y-auto py-1" style={{ maxHeight: maxListHeight }}>
          {loading ? (
            <div className="px-3 py-6 text-center text-sm text-zinc-400">Loading…</div>
          ) : error ? (
            <div className="px-3 py-6 text-center text-sm text-red-500">{error}</div>
          ) : filtered.length === 0 ? (
            <div className="px-3 py-6 text-center text-sm text-zinc-400">
              {query ? `No matches for “${query}”` : emptyText}
            </div>
          ) : (
            filtered.map((opt) => {
              const isSel = opt.value === value;
              return (
                <div
                  key={opt.value}
                  role="radio"
                  aria-checked={isSel}
                  tabIndex={0}
                  onClick={() => onChange(opt.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter' || e.key === ' ') {
                      e.preventDefault();
                      onChange(opt.value);
                    }
                  }}
                  className={cn(
                    'flex items-center gap-2.5 mx-1 px-2 py-1.5 rounded-md min-w-0 cursor-pointer',
                    isSel
                      ? 'bg-airborne/10 dark:bg-airborne/15'
                      : 'hover:bg-zinc-100 dark:hover:bg-airborne-nav',
                  )}
                >
                  <span
                    className={cn(
                      'w-4 h-4 rounded-full border flex items-center justify-center shrink-0 transition-colors',
                      isSel ? 'border-airborne' : 'border-zinc-300 dark:border-zinc-600',
                    )}
                    aria-hidden="true"
                  >
                    {isSel && <span className="w-2 h-2 rounded-full bg-airborne" />}
                  </span>
                  <div className="min-w-0 flex-1">
                    <div className="text-sm text-zinc-800 dark:text-zinc-200 truncate">{opt.label}</div>
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
    </div>
  );
}
