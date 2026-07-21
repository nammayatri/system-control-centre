import { useEffect, useRef, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { Check, ChevronDown } from 'lucide-react';
import { useOtaAccess } from '../hooks';
import { resolveOrg, setOtaOrg, useOtaOrg } from '../orgStore';
import { cn } from '../../../lib/utils';

const ROOT_SEGMENTS = ['apps'];

function useClickOutside(onOutside: () => void) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) onOutside();
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  });
  return ref;
}

// Org + app switchers at the top of the sidebar (airborne.juspay.in layout).
// Rendered outside the ThemeWrapper: the sidebar is always dark, so this is
// styled dark unconditionally and must not use the OTA theme context.
export function OtaSidebarSwitcher() {
  const location = useLocation();
  const navigate = useNavigate();
  const { data } = useOtaAccess();
  const storedOrg = useOtaOrg();
  const [orgOpen, setOrgOpen] = useState(false);
  const [appOpen, setAppOpen] = useState(false);
  const orgRef = useClickOutside(() => setOrgOpen(false));
  const appRef = useClickOutside(() => setAppOpen(false));

  const apps = data?.apps ?? [];
  const orgs = [...new Set(apps.map((a) => a.org).filter(Boolean))].sort();

  const parts = location.pathname.split('/').filter(Boolean); // ['airborne', ':app', section?]
  const appSlug =
    parts[1] && !ROOT_SEGMENTS.includes(parts[1]) ? decodeURIComponent(parts[1]) : null;
  const currentApp = appSlug ? apps.find((a) => a.appRef === appSlug) : undefined;
  const section = parts[2] ?? '';

  // Deep-linking into an app of another org moves the org selection with it.
  useEffect(() => {
    if (currentApp && currentApp.org && currentApp.org !== storedOrg) {
      setOtaOrg(currentApp.org);
    }
  }, [currentApp, storedOrg]);

  const org = currentApp?.org || resolveOrg(storedOrg, orgs);
  const orgApps = apps.filter((a) => a.org === org);

  const pickOrg = (o: string) => {
    setOrgOpen(false);
    setOtaOrg(o);
    // Org change invalidates the current app context — go to the overview.
    if (appSlug) navigate('/airborne');
  };

  const pickApp = (ref: string) => {
    setAppOpen(false);
    navigate(`/airborne/${encodeURIComponent(ref)}${section ? `/${section}` : ''}`);
  };

  if (orgs.length === 0) return null;

  return (
    <div className="shrink-0">
      {/* Organisation switcher — always visible */}
      <div className="relative px-3 pt-3" ref={orgRef}>
        <button
          type="button"
          onClick={() => setOrgOpen((o) => !o)}
          className="w-full flex items-center gap-1.5 text-xs uppercase tracking-wider text-zinc-500 hover:text-zinc-200 cursor-pointer transition-colors duration-150 min-w-0"
          aria-label="Switch organisation"
          aria-expanded={orgOpen}
        >
          <span className="truncate font-semibold">{org || 'organisation'}</span>
          <ChevronDown
            className={cn('w-3 h-3 shrink-0 transition-transform', orgOpen && 'rotate-180')}
          />
        </button>
        {orgOpen && (
          <div className="absolute left-3 right-3 top-full mt-2 rounded-lg border border-zinc-800 bg-zinc-900 shadow-lg z-50 py-1">
            {orgs.map((o) => (
              <button
                key={o}
                type="button"
                onClick={() => pickOrg(o)}
                className="w-full flex items-center gap-2 px-3 py-2 text-sm text-zinc-300 hover:bg-airborne hover:text-white cursor-pointer transition-colors duration-150 min-w-0"
              >
                <span className="flex-1 text-left truncate">{o}</span>
                {o === org && <Check className="w-3.5 h-3.5 shrink-0" />}
              </button>
            ))}
          </div>
        )}
      </div>

      {/* App switcher — only inside an app */}
      {appSlug && (
        <div className="relative px-3 pt-2.5" ref={appRef}>
          <button
            type="button"
            onClick={() => setAppOpen((o) => !o)}
            className="w-full flex items-center gap-1.5 text-sm text-zinc-300 hover:text-white cursor-pointer transition-colors duration-150 min-w-0"
            aria-label="Switch app"
            aria-expanded={appOpen}
          >
            <span className="truncate font-medium">{currentApp?.app || appSlug}</span>
            <ChevronDown
              className={cn('w-3.5 h-3.5 shrink-0 transition-transform', appOpen && 'rotate-180')}
            />
          </button>
          {appOpen && (
            <div className="absolute left-3 right-3 top-full mt-2 rounded-lg border border-zinc-800 bg-zinc-900 shadow-lg z-50 py-1 max-h-72 overflow-y-auto">
              {orgApps.map((a) => (
                <button
                  key={a.appRef}
                  type="button"
                  onClick={() => pickApp(a.appRef)}
                  className="w-full flex items-center gap-2 px-3 py-2 text-sm text-zinc-300 hover:bg-airborne hover:text-white cursor-pointer transition-colors duration-150 min-w-0"
                >
                  <span className="flex-1 text-left truncate">{a.app}</span>
                  {a.appRef === appSlug && <Check className="w-3.5 h-3.5 shrink-0" />}
                </button>
              ))}
              {orgApps.length === 0 && (
                <div className="px-3 py-2 text-xs text-zinc-500">No apps in this organisation</div>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
