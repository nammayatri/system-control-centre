import { useEffect, useRef, useState } from 'react';
import { GitBranch } from 'lucide-react';
import { cn } from '../../../lib/utils';
import { useBranches } from '../hooks';
import type { BranchRepo } from '../types';

function useDebounced<T>(value: T, ms = 300): T {
  const [v, setV] = useState(value);
  useEffect(() => {
    const t = setTimeout(() => setV(value), ms);
    return () => clearTimeout(t);
  }, [value, ms]);
  return v;
}

/**
 * Type-to-search branch picker. Suggestions come from GitHub (2+ characters,
 * up to 20), each with the commit the release would pin. Any typed name is
 * still accepted, so the form works when the search cannot reach GitHub.
 */
export function BranchField({
  id,
  label,
  repo,
  value,
  onChange,
  placeholder,
  required,
  emptyHint,
}: {
  id: string;
  label: string;
  repo: BranchRepo;
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  required?: boolean;
  emptyHint?: string;
}) {
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);
  const boxRef = useRef<HTMLDivElement>(null);
  const q = useDebounced(value.trim());
  const { data: options = [], isFetching, isError } = useBranches(repo, q);
  const exact = options.find((o) => o.name === value.trim());

  useEffect(() => {
    const close = (e: MouseEvent) => {
      if (boxRef.current && !boxRef.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener('mousedown', close);
    return () => document.removeEventListener('mousedown', close);
  }, []);
  useEffect(() => setActive(0), [q]);

  const pick = (name: string) => {
    onChange(name);
    setOpen(false);
  };

  const hint = isError
    ? "Can't search GitHub right now; type the full branch name."
    : exact
      ? `Pins to ${exact.sha.slice(0, 7)} (latest commit)`
      : value.trim().length >= 2 && !isFetching && options.length === 0
        ? 'No branch starts with this.'
        : value.trim()
          ? 'Type 2+ letters to search, then pick a branch.'
          : emptyHint;

  return (
    <div ref={boxRef} className="relative space-y-1.5">
      {/* Same look as shared/ui/input.tsx labelBase, so the form reads as one. */}
      <label htmlFor={id} className="block text-[11px] font-medium uppercase tracking-wider text-zinc-600 dark:text-zinc-400">
        {label}
        {required && <span className="ml-0.5 text-red-500">*</span>}
      </label>
      <div className="relative">
        <GitBranch className="pointer-events-none absolute left-2.5 top-2.5 h-4 w-4 text-zinc-400" />
        <input
          id={id}
          value={value}
          autoComplete="off"
          placeholder={placeholder}
          required={required}
          role="combobox"
          aria-expanded={open && options.length > 0}
          aria-controls={`${id}-list`}
          onChange={(e) => {
            onChange(e.target.value);
            setOpen(true);
          }}
          onFocus={() => setOpen(true)}
          onKeyDown={(e) => {
            if (!open || options.length === 0) return;
            if (e.key === 'ArrowDown') {
              e.preventDefault();
              setActive((a) => Math.min(a + 1, options.length - 1));
            } else if (e.key === 'ArrowUp') {
              e.preventDefault();
              setActive((a) => Math.max(a - 1, 0));
            } else if (e.key === 'Enter') {
              e.preventDefault();
              pick(options[active].name);
            } else if (e.key === 'Escape') {
              setOpen(false);
            }
          }}
          className="w-full rounded-lg border border-zinc-200 bg-white py-2 pl-8 pr-3 font-mono text-sm dark:border-zinc-700 dark:bg-zinc-900"
        />
      </div>
      {open && options.length > 0 && !exact && (
        <ul
          id={`${id}-list`}
          role="listbox"
          className="absolute z-20 mt-1 max-h-64 w-full overflow-auto rounded-lg border border-zinc-200 bg-white py-1 shadow-lg dark:border-zinc-700 dark:bg-zinc-900"
        >
          {options.map((o, i) => (
            <li
              key={o.name}
              role="option"
              aria-selected={i === active}
              onMouseDown={(e) => {
                e.preventDefault();
                pick(o.name);
              }}
              onMouseEnter={() => setActive(i)}
              className={cn(
                'flex cursor-pointer items-center justify-between gap-3 px-3 py-1.5 text-sm',
                i === active && 'bg-zinc-100 dark:bg-zinc-800',
              )}
            >
              <span className="truncate font-mono text-xs">{o.name}</span>
              <span className="shrink-0 font-mono text-[11px] text-zinc-500">{o.sha.slice(0, 7)}</span>
            </li>
          ))}
        </ul>
      )}
      {hint && <p className={cn('text-xs', isError ? 'text-amber-600' : 'text-zinc-500')}>{isFetching && value.trim().length >= 2 ? 'Searching…' : hint}</p>}
    </div>
  );
}
