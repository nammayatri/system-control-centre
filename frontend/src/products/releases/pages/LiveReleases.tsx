import { useState, useEffect } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { Server, Smartphone, Activity, ExternalLink, RefreshCw, Apple, Cpu } from 'lucide-react';
import { useLiveReleases } from '../hooks';
import { Button } from '../../../shared/ui/button';
import { TableSkeleton } from '../../../shared/ui/skeleton';
import { cn } from '../../../lib/utils';
import { formatBuildCode } from '../utils';

// MVP assumption: all mobile builds today come from this monorepo, so we can
// hardcode the GH owner/repo for the tag link. Once multiple repos are wired
// up, plumb this through the live-releases response or app catalog instead.
const MOBILE_GH_REPO = 'nammayatri/ny-react-native';

type Category = 'all' | 'backend' | 'mobile';

const formatTime = (iso?: string | null) => {
  if (!iso) return '—';
  const d = new Date(iso);
  if (isNaN(d.getTime())) return '—';
  return d.toLocaleString('en-IN', {
    timeZone: 'Asia/Kolkata',
    month: 'short', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hour12: true,
  }) + ' IST';
};

// tagPushed shape from the workflow: "<app>/<env>/<platform>/<tag>" eg
// "nammayatri/prod/android/v2.5.0+12345". We just need to surface a clickable
// link to the GH tag page; if the data is malformed, render plain text.
function tagLink(tagPushed: string | null) {
  if (!tagPushed) return null;
  const parts = tagPushed.split('/');
  const tag = parts[parts.length - 1];
  if (!tag || !tag.startsWith('v')) return null;
  return `https://github.com/${MOBILE_GH_REPO}/releases/tag/${encodeURIComponent(tag)}`;
}

const CHIPS: { key: Category; label: string; icon: React.ReactNode }[] = [
  { key: 'all', label: 'All', icon: <Activity className="w-3.5 h-3.5" /> },
  { key: 'backend', label: 'Backend', icon: <Server className="w-3.5 h-3.5" /> },
  { key: 'mobile', label: 'Mobile', icon: <Smartphone className="w-3.5 h-3.5" /> },
];

const PlatformIcon = ({ platform }: { platform: string }) =>
  platform === 'ios'
    ? <Apple className="w-3.5 h-3.5 text-zinc-500" />
    : <Cpu className="w-3.5 h-3.5 text-emerald-600" />;

export default function LiveReleases() {
  const location = useLocation();
  const navigate = useNavigate();
  const defaultCategory: Category = location.pathname.startsWith('/mobile') ? 'mobile' : 'backend';
  const [category, setCategory] = useState<Category>(defaultCategory);
  useEffect(() => { setCategory(defaultCategory); }, [defaultCategory]);
  const { data, isLoading, isFetching, refetch } = useLiveReleases(category);

  const handleCategoryClick = (key: Category) => {
    if (key === 'all') {
      setCategory('all');
    } else if (key === defaultCategory) {
      setCategory(key);
    } else if (key === 'backend') {
      navigate('/backend/releases/live', { replace: true });
    } else {
      navigate('/mobile/releases/live', { replace: true });
    }
  };

  const backendRows = data?.backend ?? [];
  const mobileRows = data?.mobile ?? [];

  const showBackend = category === 'all' || category === 'backend';
  const showMobile = category === 'all' || category === 'mobile';

  return (
    <div className="flex flex-col flex-1 w-full pb-12 space-y-4 sm:space-y-6">
      <div className="flex items-center justify-between gap-3 flex-wrap">
        <div className="flex items-center gap-1.5 flex-wrap" role="tablist">
          {CHIPS.map((chip) => (
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
                  : 'bg-white text-zinc-600 border-zinc-300 hover:bg-zinc-50',
              )}
            >
              {chip.icon} {chip.label}
            </button>
          ))}
        </div>
        <Button
          variant="secondary"
          size="sm"
          onClick={() => { void refetch(); }}
          loading={isFetching && !isLoading}
        >
          <RefreshCw className="w-4 h-4" /> Refresh
        </Button>
      </div>

      {showBackend && (
        <section className="bg-white rounded-xl border border-zinc-200">
          <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100 flex items-center gap-2">
            <Server className="w-4 h-4 text-sky-600" />
            <h2 className="text-base sm:text-lg font-semibold text-zinc-900">
              Backend
            </h2>
            <span className="text-xs text-zinc-500">{backendRows.length} services</span>
          </header>
          {isLoading ? (
            <TableSkeleton rows={4} cols={6} />
          ) : backendRows.length === 0 ? (
            <div className="py-12 text-center text-zinc-400 text-sm">
              No backend deployments tracked.
            </div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-left whitespace-nowrap">
                <thead>
                  <tr className="bg-zinc-50 border-b border-zinc-200 text-[11px] text-zinc-500 font-medium uppercase tracking-wider">
                    <th className="py-3 px-4">App group</th>
                    <th className="py-3 px-4">Service</th>
                    <th className="py-3 px-4">Env</th>
                    <th className="py-3 px-4">Live ver.</th>
                    <th className="py-3 px-4">Rollout state</th>
                    <th className="py-3 px-4">Updated</th>
                  </tr>
                </thead>
                <tbody className="text-sm">
                  {backendRows.map((row, i) => (
                    <tr
                      key={`${row.appGroup}-${row.service}-${row.env}-${i}`}
                      className={cn(
                        'border-b border-zinc-100',
                        i % 2 === 1 ? 'bg-zinc-50' : 'bg-white',
                      )}
                    >
                      <td className="py-3 px-4 text-zinc-700">{row.appGroup}</td>
                      <td className="py-3 px-4 font-medium text-zinc-800">{row.service}</td>
                      <td className="py-3 px-4">
                        <span className="rounded px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-sky-700 text-white">
                          {row.env}
                        </span>
                      </td>
                      <td className="py-3 px-4 font-mono text-xs text-zinc-600">{row.liveVersion}</td>
                      <td className="py-3 px-4 text-xs text-zinc-600">{row.rolloutState ?? '—'}</td>
                      <td className="py-3 px-4 font-mono text-xs text-zinc-500">{formatTime(row.updatedAt)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>
      )}

      {showMobile && (
        <section className="bg-white rounded-xl border border-zinc-200">
          <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100 flex items-center gap-2">
            <Smartphone className="w-4 h-4 text-violet-600" />
            <h2 className="text-base sm:text-lg font-semibold text-zinc-900">
              Mobile
            </h2>
            <span className="text-xs text-zinc-500">{mobileRows.length} builds</span>
          </header>
          {isLoading ? (
            <TableSkeleton rows={4} cols={6} />
          ) : mobileRows.length === 0 ? (
            <div className="py-12 text-center text-zinc-400 text-sm">
              No mobile builds tracked yet.
            </div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-left whitespace-nowrap">
                <thead>
                  <tr className="bg-zinc-50 border-b border-zinc-200 text-[11px] text-zinc-500 font-medium uppercase tracking-wider">
                    <th className="py-3 px-4">App</th>
                    <th className="py-3 px-4">Surface</th>
                    <th className="py-3 px-4">Platform</th>
                    <th className="py-3 px-4">Live ver.</th>
                    <th className="py-3 px-4">Tag</th>
                    <th className="py-3 px-4">Released</th>
                  </tr>
                </thead>
                <tbody className="text-sm">
                  {mobileRows.map((row, i) => {
                    const link = tagLink(row.tagPushed);
                    return (
                      <tr
                        key={`${row.app}-${row.surface}-${row.platform}-${i}`}
                        className={cn(
                          'border-b border-zinc-100',
                          i % 2 === 1 ? 'bg-zinc-50' : 'bg-white',
                        )}
                      >
                        <td className="py-3 px-4 font-medium text-zinc-800">{row.app}</td>
                        <td className="py-3 px-4 text-xs text-zinc-600">{row.surface}</td>
                        <td className="py-3 px-4">
                          <span className="inline-flex items-center gap-1.5 text-xs text-zinc-600">
                            <PlatformIcon platform={row.platform} /> {row.platform}
                          </span>
                        </td>
                        <td className="py-3 px-4 font-mono text-xs text-zinc-600">
                          {row.liveVersion}
                          {row.versionCode != null && (
                            <span className="text-zinc-400 ml-1">{formatBuildCode(row.versionCode)}</span>
                          )}
                        </td>
                        <td className="py-3 px-4 font-mono text-xs">
                          {link ? (
                            <a
                              href={link}
                              target="_blank"
                              rel="noopener noreferrer"
                              className="inline-flex items-center gap-1 text-sky-700 hover:underline"
                            >
                              {row.tagPushed} <ExternalLink className="w-3 h-3" />
                            </a>
                          ) : (
                            <span className="text-zinc-500">{row.tagPushed ?? '—'}</span>
                          )}
                        </td>
                        <td className="py-3 px-4 font-mono text-xs text-zinc-500">{formatTime(row.releasedAt)}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </section>
      )}
    </div>
  );
}
