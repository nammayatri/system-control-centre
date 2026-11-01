import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import type { ReactNode } from 'react';
import { cn } from '../../lib/utils';
import './mr2.css';

// Mobile Releases v2 theme. Scoped to the v2 content column (like the Airborne
// OTA wrapper), light by default, with an explicit light / dark / auto choice.

export type Mr2Theme = 'light' | 'dark' | 'auto';

const STORAGE_KEY = 'mr2_theme';

interface Mr2ThemeCtx {
  theme: Mr2Theme;
  setTheme: (t: Mr2Theme) => void;
  isDark: boolean;
}

const ThemeContext = createContext<Mr2ThemeCtx>({ theme: 'light', setTheme: () => {}, isDark: false });

export function useMr2Theme() {
  return useContext(ThemeContext);
}

function readStored(): Mr2Theme {
  try {
    const v = localStorage.getItem(STORAGE_KEY);
    if (v === 'light' || v === 'dark' || v === 'auto') return v;
  } catch {
    /* localStorage unavailable */
  }
  return 'light';
}

export function Mr2ThemeWrapper({ children }: { children: ReactNode }) {
  const [theme, setThemeState] = useState<Mr2Theme>(readStored);
  const [systemDark, setSystemDark] = useState(() => window.matchMedia('(prefers-color-scheme: dark)').matches);

  useEffect(() => {
    const mq = window.matchMedia('(prefers-color-scheme: dark)');
    const onChange = (e: MediaQueryListEvent) => setSystemDark(e.matches);
    mq.addEventListener('change', onChange);
    return () => mq.removeEventListener('change', onChange);
  }, []);

  const setTheme = useCallback((t: Mr2Theme) => {
    setThemeState(t);
    try {
      localStorage.setItem(STORAGE_KEY, t);
    } catch {
      /* ignore */
    }
  }, []);

  const isDark = theme === 'dark' || (theme === 'auto' && systemDark);
  const value = useMemo(() => ({ theme, setTheme, isDark }), [theme, setTheme, isDark]);

  return (
    <ThemeContext.Provider value={value}>
      {/* `dark` also flips the shared TopBar's dark: variants (same mechanism as Airborne). */}
      <div className={cn('mr2 min-h-full flex flex-col flex-1', isDark && 'mr2-dark dark')}>{children}</div>
    </ThemeContext.Provider>
  );
}

/** TopBar control: Light / Dark / Auto. */
export function Mr2ThemeToggle() {
  const { theme, setTheme } = useMr2Theme();
  return (
    <div className="m2-seg" role="group" aria-label="Theme">
      {(['light', 'dark', 'auto'] as const).map((t) => (
        <button key={t} type="button" aria-pressed={theme === t} onClick={() => setTheme(t)}>
          {t === 'light' ? 'Light' : t === 'dark' ? 'Dark' : 'Auto'}
        </button>
      ))}
    </div>
  );
}
