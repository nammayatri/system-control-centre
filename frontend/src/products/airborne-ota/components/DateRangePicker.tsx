import { useEffect, useState } from 'react';
import * as Popover from '@radix-ui/react-popover';
import { Calendar, ChevronLeft, ChevronRight } from 'lucide-react';
import { useOtaTheme } from '../theme';
import { cn } from '../../../lib/utils';

// Day-precision range picker (values are 'YYYY-MM-DD'). ISO date strings sort
// lexicographically, so plain string comparison is a valid day ordering.

const pad = (v: number) => String(v).padStart(2, '0');
const ymd = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const parseYmd = (s: string) => {
  const [y, m, d] = s.split('-').map(Number);
  return new Date(y, (m ?? 1) - 1, d ?? 1);
};
const fmtShort = (s: string) => {
  const d = parseYmd(s);
  return isNaN(d.getTime()) ? s : d.toLocaleDateString([], { day: 'numeric', month: 'short', year: 'numeric' });
};
const WEEKDAYS = ['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa'];

interface DateRangePickerProps {
  start: string;
  end: string;
  onChange: (start: string, end: string) => void;
  min?: string;
  max?: string;
}

export function DateRangePicker({ start, end, onChange, min, max }: DateRangePickerProps) {
  const { isDark } = useOtaTheme();
  const [open, setOpen] = useState(false);
  // First day of the visible month.
  const [view, setView] = useState(() => {
    const d = parseYmd(start || ymd(new Date()));
    return new Date(d.getFullYear(), d.getMonth(), 1);
  });
  // Anchor of an in-progress selection (first click) + hovered day for preview.
  const [anchor, setAnchor] = useState<string | null>(null);
  const [hover, setHover] = useState<string | null>(null);

  // Re-centre on the current start each time the popover opens.
  useEffect(() => {
    if (open) {
      const d = parseYmd(start || ymd(new Date()));
      setView(new Date(d.getFullYear(), d.getMonth(), 1));
      setAnchor(null);
      setHover(null);
    }
  }, [open, start]);

  // Effective highlighted range: the committed [start,end], or the live
  // [anchor,hover] while the user is mid-selection.
  let loEff = start;
  let hiEff = end;
  if (anchor) {
    const other = hover ?? anchor;
    loEff = anchor <= other ? anchor : other;
    hiEff = anchor <= other ? other : anchor;
  }

  const disabled = (s: string) => (min != null && s < min) || (max != null && s > max);

  const pickDay = (s: string) => {
    if (disabled(s)) return;
    if (!anchor) {
      setAnchor(s);
      setHover(s);
      return;
    }
    const lo = anchor <= s ? anchor : s;
    const hi = anchor <= s ? s : anchor;
    onChange(lo, hi);
    setAnchor(null);
    setHover(null);
    setOpen(false);
  };

  const monthLabel = view.toLocaleDateString([], { month: 'long', year: 'numeric' });
  const y = view.getFullYear();
  const m = view.getMonth();
  const leading = new Date(y, m, 1).getDay();
  const daysInMonth = new Date(y, m + 1, 0).getDate();
  const cells: (string | null)[] = [];
  for (let i = 0; i < leading; i++) cells.push(null);
  for (let d = 1; d <= daysInMonth; d++) cells.push(ymd(new Date(y, m, d)));
  while (cells.length % 7 !== 0) cells.push(null);

  const label =
    start && end ? (start === end ? fmtShort(start) : `${fmtShort(start)} – ${fmtShort(end)}`) : 'Pick a range';

  return (
    <Popover.Root open={open} onOpenChange={setOpen}>
      <Popover.Trigger asChild>
        <button
          type="button"
          className={cn(
            'inline-flex items-center gap-2 rounded-lg border px-3 h-9 text-sm font-medium cursor-pointer transition-colors',
            'border-zinc-300 bg-white text-zinc-700 hover:bg-zinc-50',
            'dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-200 dark:hover:bg-zinc-800',
            'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-airborne',
          )}
          aria-label="Select date range"
        >
          <Calendar className="w-4 h-4 text-zinc-400 dark:text-zinc-500 shrink-0" />
          <span className="tabular-nums">{label}</span>
        </button>
      </Popover.Trigger>
      <Popover.Portal>
        <Popover.Content
          align="start"
          sideOffset={6}
          className={cn(
            'z-50 w-[17rem] rounded-xl border p-3 shadow-lg',
            'border-zinc-200 bg-white',
            isDark && 'dark border-zinc-800 bg-zinc-900',
          )}
        >
          {/* Month nav */}
          <div className="flex items-center justify-between mb-2">
            <button
              type="button"
              onClick={() => setView(new Date(y, m - 1, 1))}
              className="w-7 h-7 inline-flex items-center justify-center rounded-md text-zinc-500 hover:bg-zinc-100 hover:text-zinc-800 dark:text-zinc-400 dark:hover:bg-zinc-800 dark:hover:text-zinc-100 cursor-pointer"
              aria-label="Previous month"
            >
              <ChevronLeft className="w-4 h-4" />
            </button>
            <span className="text-sm font-semibold text-zinc-800 dark:text-zinc-100">{monthLabel}</span>
            <button
              type="button"
              onClick={() => setView(new Date(y, m + 1, 1))}
              className="w-7 h-7 inline-flex items-center justify-center rounded-md text-zinc-500 hover:bg-zinc-100 hover:text-zinc-800 dark:text-zinc-400 dark:hover:bg-zinc-800 dark:hover:text-zinc-100 cursor-pointer"
              aria-label="Next month"
            >
              <ChevronRight className="w-4 h-4" />
            </button>
          </div>

          {/* Weekday header */}
          <div className="grid grid-cols-7 mb-1">
            {WEEKDAYS.map((w) => (
              <div key={w} className="text-center text-[11px] font-medium text-zinc-400 dark:text-zinc-500 py-1">
                {w}
              </div>
            ))}
          </div>

          {/* Day grid */}
          <div className="grid grid-cols-7 gap-y-0.5" onMouseLeave={() => anchor && setHover(anchor)}>
            {cells.map((s, i) => {
              if (!s) return <div key={`b${i}`} />;
              const off = disabled(s);
              const isLo = s === loEff;
              const isHi = s === hiEff;
              const inRange = s >= loEff && s <= hiEff && loEff !== hiEff;
              const isEdge = isLo || isHi;
              const day = Number(s.slice(8));
              return (
                <div
                  key={s}
                  className={cn(
                    'relative flex items-center justify-center',
                    // Continuous range band behind the cells.
                    inRange && !isEdge && 'bg-airborne/10 dark:bg-airborne/20',
                    isLo && !isHi && 'bg-airborne/10 dark:bg-airborne/20 rounded-l-md',
                    isHi && !isLo && 'bg-airborne/10 dark:bg-airborne/20 rounded-r-md',
                  )}
                >
                  <button
                    type="button"
                    disabled={off}
                    onMouseEnter={() => anchor && setHover(s)}
                    onClick={() => pickDay(s)}
                    className={cn(
                      'w-8 h-8 text-sm rounded-md flex items-center justify-center tabular-nums transition-colors',
                      off
                        ? 'text-zinc-300 dark:text-zinc-700 cursor-not-allowed'
                        : 'cursor-pointer text-zinc-700 dark:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-zinc-800',
                      isEdge && 'bg-airborne text-white hover:bg-airborne-hover dark:hover:bg-airborne-hover',
                    )}
                  >
                    {day}
                  </button>
                </div>
              );
            })}
          </div>

          <div className="mt-2 text-[11px] text-zinc-400 dark:text-zinc-500 text-center">
            {anchor ? 'Pick the end date' : 'Pick the start date'}
          </div>
        </Popover.Content>
      </Popover.Portal>
    </Popover.Root>
  );
}
