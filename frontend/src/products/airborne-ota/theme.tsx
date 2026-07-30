import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react';
import type { ReactNode } from 'react';
import { Check, Monitor, Moon, Sun } from 'lucide-react';
import { cn } from '../../lib/utils';

export type OtaTheme = 'light' | 'dark' | 'system';

const STORAGE_KEY = 'ota_theme';

interface OtaThemeCtx {
  theme: OtaTheme;
  setTheme: (t: OtaTheme) => void;
  isDark: boolean;
}

const ThemeContext = createContext<OtaThemeCtx>({
  theme: 'system',
  setTheme: () => {},
  isDark: false,
});

export function useOtaTheme() {
  return useContext(ThemeContext);
}

function readStored(): OtaTheme {
  try {
    const v = localStorage.getItem(STORAGE_KEY);
    if (v === 'light' || v === 'dark' || v === 'system') return v;
  } catch {
    /* localStorage unavailable */
  }
  return 'system';
}

// Provider + scoped .dark wrapper for the Airborne OTA content area. The
// `dark` class only lands on this subtree, so the rest of SCC stays light.
export function OtaThemeWrapper({ children }: { children: ReactNode }) {
  const [theme, setThemeState] = useState<OtaTheme>(readStored);
  const [systemDark, setSystemDark] = useState(
    () => window.matchMedia('(prefers-color-scheme: dark)').matches,
  );

  useEffect(() => {
    const mq = window.matchMedia('(prefers-color-scheme: dark)');
    const onChange = (e: MediaQueryListEvent) => setSystemDark(e.matches);
    mq.addEventListener('change', onChange);
    return () => mq.removeEventListener('change', onChange);
  }, []);

  const setTheme = useCallback((t: OtaTheme) => {
    setThemeState(t);
    try {
      localStorage.setItem(STORAGE_KEY, t);
    } catch {
      /* ignore */
    }
  }, []);

  const isDark = theme === 'dark' || (theme === 'system' && systemDark);
  const value = useMemo(() => ({ theme, setTheme, isDark }), [theme, setTheme, isDark]);

  return (
    <ThemeContext.Provider value={value}>
      <div
        className={cn(
          'min-h-full flex flex-col flex-1',
          isDark && 'dark',
          'dark:bg-[#0b0b0c] dark:text-zinc-100',
        )}
      >
        {children}
      </div>
    </ThemeContext.Provider>
  );
}

const OPTIONS: { value: OtaTheme; label: string; icon: ReactNode }[] = [
  { value: 'light', label: 'Light', icon: <Sun className="w-3.5 h-3.5" /> },
  { value: 'dark', label: 'Dark', icon: <Moon className="w-3.5 h-3.5" /> },
  { value: 'system', label: 'System', icon: <Monitor className="w-3.5 h-3.5" /> },
];

// Sun/Moon button opening a Light / Dark / System dropdown.
export function OtaThemeToggle() {
  const { theme, setTheme, isDark } = useOtaTheme();
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, []);

  return (
    <div className="relative shrink-0" ref={ref}>
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        className={cn(
          'h-9 w-9 rounded-lg border flex items-center justify-center cursor-pointer',
          'transition-colors duration-150',
          'border-zinc-200 bg-white text-zinc-600 hover:bg-zinc-50 hover:text-zinc-900',
          'dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-300 dark:hover:bg-zinc-800 dark:hover:text-zinc-100',
        )}
        aria-label="Change theme"
        aria-expanded={open}
      >
        {isDark ? <Moon className="w-4 h-4" /> : <Sun className="w-4 h-4" />}
      </button>
      {open && (
        <div
          className={cn(
            'absolute right-0 top-full mt-2 w-36 rounded-lg border shadow-sm z-50 py-1',
            'bg-white border-zinc-200 dark:bg-zinc-900 dark:border-zinc-800',
          )}
        >
          {OPTIONS.map((opt) => (
            <button
              key={opt.value}
              type="button"
              onClick={() => {
                setTheme(opt.value);
                setOpen(false);
              }}
              className={cn(
                'w-full flex items-center gap-2 px-3 py-2 text-sm cursor-pointer',
                'transition-colors duration-150',
                'text-zinc-700 hover:bg-zinc-50 dark:text-zinc-300 dark:hover:bg-zinc-800',
              )}
            >
              {opt.icon}
              <span className="flex-1 text-left">{opt.label}</span>
              {theme === opt.value && <Check className="w-3.5 h-3.5 text-airborne" />}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
