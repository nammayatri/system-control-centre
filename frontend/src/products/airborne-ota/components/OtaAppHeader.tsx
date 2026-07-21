import { Link } from 'react-router-dom';
import { ArrowLeft } from 'lucide-react';
import { useOtaAccess } from '../hooks';

// Per-app page header: back arrow + title. App switching lives in the
// sidebar (OtaSidebarSwitcher); the theme toggle in the TopBar.
export function OtaAppHeader({ app, title }: { app: string; title?: string }) {
  const { data: access } = useOtaAccess();
  const current = (access?.apps ?? []).find((a) => a.appRef === app);

  return (
    <div className="flex items-center gap-3 min-w-0">
      <Link
        to="/airborne"
        className="w-9 h-9 rounded-lg border border-zinc-200 bg-white text-zinc-500 hover:text-zinc-800 hover:bg-zinc-50 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100 dark:hover:bg-zinc-800 flex items-center justify-center shrink-0 transition-colors duration-150"
        aria-label="All apps"
      >
        <ArrowLeft className="w-4 h-4" />
      </Link>
      <div className="min-w-0">
        <h1 className="text-base sm:text-lg font-semibold text-zinc-900 dark:text-zinc-100 truncate">
          {title || current?.app || app}
        </h1>
        <p className="text-xs text-zinc-500 dark:text-zinc-400 font-mono truncate">
          {current ? `${current.org}/${current.app}` : app}
        </p>
      </div>
    </div>
  );
}
