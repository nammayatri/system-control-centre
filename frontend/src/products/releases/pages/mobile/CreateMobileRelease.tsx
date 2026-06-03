import { useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { AlertTriangle, Smartphone, Apple, Cpu, GitBranch, ChevronDown, Search, GitCommit, ExternalLink } from 'lucide-react';
import {
  useMobileApps,
  useMobileBranches,
  usePreviewVersions,
  useCreateMobileReleases,
  useChangelogPreviews,
} from '../../hooks';
import type { ChangelogApp } from '../../hooks';
import type {
  AppCatalogEntry,
  BranchInfo,
  BuildType,
  CreateMobileReleasesItem,
  CreateMobileReleasesReq,
  LatestBuild,
  VersionPreviewItem,
} from '../../types';
import { useAuth } from '../../../../core/auth/AuthContext';
import { Button } from '../../../../shared/ui/button';
import { Textarea } from '../../../../shared/ui/input';
import { Skeleton } from '../../../../shared/ui/skeleton';
import { cn } from '../../../../lib/utils';
import { toast } from 'sonner';

// Per-app form state — version overrides keyed by appCatalogId.
type VersionEdit = { versionName: string; versionCode: string };

const DEBOUNCE_MS = 500;

const prUrlFromCommitUrl = (commitUrl: string, prNumber: number): string => {
  const idx = commitUrl.indexOf('/commit/');
  if (idx === -1) return commitUrl;
  return commitUrl.slice(0, idx) + '/pull/' + prNumber;
};

const PlatformIcon = ({ platform }: { platform: string }) =>
  platform === 'ios'
    ? <Apple className="w-4 h-4 text-zinc-500" />
    : <Cpu className="w-4 h-4 text-emerald-600" />;

const formatShort = (d: string) => {
  const date = new Date(d);
  if (isNaN(date.getTime())) return '';
  return date.toLocaleDateString('en-IN', { month: 'short', day: '2-digit' });
};

const LatestBuildBadge = ({ build, label }: { build: LatestBuild; label: string }) => (
  <span
    className={cn(
      'inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium',
      label === 'debug'
        ? 'bg-amber-50 text-amber-700 border border-amber-200'
        : 'bg-emerald-50 text-emerald-700 border border-emerald-200',
    )}
  >
    <span className="uppercase">{label}</span>
    <span className="font-mono">v{build.version}</span>
    {build.versionCode != null && (
      <span className="text-[9px] opacity-70">+{build.versionCode}</span>
    )}
    {build.completedAt && (
      <span className="opacity-60">{formatShort(build.completedAt)}</span>
    )}
  </span>
);

export default function CreateMobileRelease() {
  const navigate = useNavigate();
  const { buildType: deployBuildType } = useAuth();
  const { data: apps, isLoading: appsLoading, error: appsError } = useMobileApps();

  // Filter to enabled apps only — disabled apps live in the catalog but
  // shouldn't be selectable for new releases.
  const enabledApps: AppCatalogEntry[] = useMemo(
    () => (apps || []).filter((a) => a.enabled),
    [apps],
  );

  const [sourceRef, setSourceRef] = useState<string>('main');
  const [branchSearch, setBranchSearch] = useState('main');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [branchDropdownOpen, setBranchDropdownOpen] = useState(false);
  const branchInputRef = useRef<HTMLInputElement>(null);
  const branchContainerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const timer = setTimeout(() => {
      const q = branchSearch.trim();
      setDebouncedSearch(q.length >= 2 ? q : '');
    }, 300);
    return () => clearTimeout(timer);
  }, [branchSearch]);

  const { data: branchesData, isLoading: branchesLoading } = useMobileBranches(
    debouncedSearch || undefined,
  );
  const filteredBranches: BranchInfo[] = branchesData ?? [];

  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (branchContainerRef.current && !branchContainerRef.current.contains(e.target as Node)) {
        setBranchDropdownOpen(false);
        if (!branchSearch.trim()) {
          setBranchSearch(sourceRef);
        }
      }
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, [branchSearch, sourceRef]);

  const [selectedIds, setSelectedIds] = useState<number[]>([]);
  // Debounced selection feeds the preview query so toggling several apps in
  // quick succession only fires one preview call.
  const [debouncedIds, setDebouncedIds] = useState<number[]>([]);

  useEffect(() => {
    const t = setTimeout(() => setDebouncedIds(selectedIds), DEBOUNCE_MS);
    return () => clearTimeout(t);
  }, [selectedIds]);

  const [versionEdits, setVersionEdits] = useState<Record<number, VersionEdit>>({});
  const [changeLog, setChangeLog] = useState('');
  // Build type is fixed by the deployment (mobile_build_type config), surfaced
  // via auth as config.buildType — not chosen on the form.
  const [buildType, setBuildType] = useState<BuildType>(deployBuildType);

  useEffect(() => {
    setBuildType(deployBuildType);
  }, [deployBuildType]);

  const previewQuery = usePreviewVersions(buildType === 'debug' ? [] : debouncedIds);
  const previews: VersionPreviewItem[] = previewQuery.data?.previews ?? [];

  // Lookup helper used by every per-row branch below: given an app catalog id,
  // tell us if it's an iOS row. iOS rows render a single "Version Number"
  // input and skip the numeric code; Android rows render both inputs.
  const isIosId = (id: number): boolean =>
    enabledApps.find((a) => a.id === id)?.platform === 'ios';

  // Platforms in the current selection — drives the destination dropdown
  // and gives us a quick check for mixed-platform validation messaging.
  const selectedPlatforms = useMemo(() => {
    const s = new Set<'android' | 'ios'>();
    for (const id of selectedIds) {
      const p = enabledApps.find((a) => a.id === id)?.platform;
      if (p) s.add(p);
    }
    return s;
  }, [selectedIds, enabledApps]);

  // Primary platform drives the "uploaded to …" hint in the Build type
  // card. Build type/destination are decided by the backend (env-locked),
  // so nothing is sent from here.
  const primaryPlatform: 'android' | 'ios' =
    selectedPlatforms.has('ios') && !selectedPlatforms.has('android')
      ? 'ios'
      : 'android';

  // When a fresh preview lands, prefill any unedited rows with the suggested
  // version. Don't clobber values the user has already typed. Per-platform:
  //   - Android rows fill `versionName` + `versionCode` from the two-field response.
  //   - iOS rows fill `versionName` from `nextVersionNumber` (single field).
  useEffect(() => {
    if (!previews.length) return;
    setVersionEdits((prev) => {
      const next = { ...prev };
      for (const p of previews) {
        if (!next[p.appCatalogId]) {
          next[p.appCatalogId] = {
            versionName:
              p.nextVersionName ?? p.nextVersionNumber ?? '',
            versionCode:
              p.nextVersionCode != null ? String(p.nextVersionCode) : '',
          };
        }
      }
      return next;
    });
  }, [previews]);

  const previewById = useMemo(() => {
    const m = new Map<number, VersionPreviewItem>();
    for (const p of previews) m.set(p.appCatalogId, p);
    return m;
  }, [previews]);

  const toggleApp = (id: number) => {
    setSelectedIds((prev) =>
      prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id],
    );
  };

  const setVersionField = (id: number, field: keyof VersionEdit, value: string) => {
    setVersionEdits((prev) => ({
      ...prev,
      [id]: { ...(prev[id] || { versionName: '', versionCode: '' }), [field]: value },
    }));
  };

  const changelogApps: ChangelogApp[] = useMemo(
    () =>
      selectedIds
        .map((id) => enabledApps.find((a) => a.id === id))
        .filter((a): a is AppCatalogEntry => !!a)
        .map((a) => ({
          name: a.name,
          surface: a.surface,
          platform: a.platform,
          label: a.displayLabel || `${a.name} (${a.surface} ${a.platform})`,
        })),
    [selectedIds, enabledApps],
  );
  const changelogQueries = useChangelogPreviews(
    changelogApps,
    sourceRef?.trim() || undefined,
  );
  const [changelogTab, setChangelogTab] = useState(0);
  useEffect(() => { setChangelogTab(0); }, [selectedIds.join(',')]);

  const createMutation = useCreateMobileReleases();

  // Submission validity: at least one app, every selected app has a non-empty
  // version name (Android: + numeric code; iOS: no code — workflow computes
  // the build number), and a non-empty changelog.
  const isDebug = buildType === 'debug';

  const validation = useMemo(() => {
    if (selectedIds.length === 0) return { ok: false, reason: 'Select at least one app' };
    if (!changeLog.trim()) return { ok: false, reason: 'Change log is required' };
    if (!isDebug) {
      for (const id of selectedIds) {
        const v = versionEdits[id];
        const ios = isIosId(id);
        const fieldLabel = ios ? 'version number' : 'version name';
        if (!v?.versionName.trim()) {
          return { ok: false, reason: `All selected apps need a ${fieldLabel}` };
        }
        if (!ios) {
          if (v.versionCode.trim() === '' || !/^\d+$/.test(v.versionCode.trim())) {
            return { ok: false, reason: 'Android rows need a numeric version code' };
          }
        }
      }
    }
    return { ok: true as const };
  }, [selectedIds, versionEdits, changeLog, enabledApps, isDebug]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!validation.ok) {
      toast.error(validation.reason);
      return;
    }
    const items: CreateMobileReleasesItem[] = selectedIds.map((id) => {
      if (isDebug) {
        return { appCatalogId: id, versionName: null, versionCode: null };
      }
      const v = versionEdits[id];
      const ios = isIosId(id);
      return {
        appCatalogId: id,
        versionName: v.versionName.trim(),
        versionCode: ios ? null : parseInt(v.versionCode, 10),
      };
    });
    const req: CreateMobileReleasesReq = {
      changeLog: changeLog.trim(),
      sourceRef: sourceRef && sourceRef !== 'main' ? sourceRef : null,
      items,
    };
    try {
      const resp = await createMutation.mutateAsync(req);
      toast.success(
        `Created ${resp.releases.length} release${resp.releases.length === 1 ? '' : 's'}`,
      );
      navigate(`/mobile/groups/${resp.releaseGroupId}`);
    } catch {
      // toast surfaced inside the hook — nothing else to do here.
    }
  };

  return (
    <div className="flex flex-col flex-1 w-full pb-12">
      <form onSubmit={handleSubmit} className="space-y-4 sm:space-y-6 max-w-4xl">

        {/* ─── Apps card ─────────────────────────────── */}
        <section className="bg-white rounded-xl border border-zinc-200">
          <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100">
            <h2 className="text-base sm:text-lg font-semibold text-zinc-900">
              Apps
              <span className="ml-2 text-xs font-normal text-zinc-500">
                {selectedIds.length} selected
              </span>
            </h2>
            <p className="text-xs text-zinc-500 mt-0.5">
              Pick the apps to release. Versions auto-fill from the latest live
              version.
            </p>
          </header>
          <div className="p-4 sm:p-6">
            {appsLoading ? (
              <div className="space-y-2">
                <Skeleton className="h-12 w-full" />
                <Skeleton className="h-12 w-full" />
                <Skeleton className="h-12 w-full" />
              </div>
            ) : appsError ? (
              <div className="text-sm text-red-600">
                Failed to load apps. Refresh to retry.
              </div>
            ) : enabledApps.length === 0 ? (
              <div className="text-sm text-zinc-500">
                No enabled apps in the catalog.{' '}
                <a href="/mobile/apps" className="underline text-zinc-700">
                  Manage apps
                </a>
                .
              </div>
            ) : (
              <ul className="space-y-2">
                {enabledApps.map((app) => {
                  const checked = selectedIds.includes(app.id);
                  return (
                    <li key={app.id}>
                      <label
                        className={cn(
                          'flex items-center gap-3 px-3 py-2.5 rounded-lg border cursor-pointer transition-colors',
                          checked
                            ? 'border-zinc-900 bg-zinc-50'
                            : 'border-zinc-200 hover:bg-zinc-50',
                        )}
                      >
                        <input
                          type="checkbox"
                          checked={checked}
                          onChange={() => toggleApp(app.id)}
                          className="rounded border-zinc-300 accent-zinc-900"
                        />
                        <PlatformIcon platform={app.platform} />
                        <div className="min-w-0 flex-1">
                          <div className="text-sm font-medium text-zinc-900 truncate">
                            {app.displayLabel || app.name}
                          </div>
                          <div className="text-xs text-zinc-500 truncate">
                            {app.surface} · {app.platform}
                          </div>
                          {(app.latestReleaseBuild || app.latestDebugBuild) && (
                            <div className="flex flex-wrap gap-1 mt-1">
                              {app.latestReleaseBuild && (
                                <LatestBuildBadge build={app.latestReleaseBuild} label="release" />
                              )}
                              {app.latestDebugBuild && (
                                <LatestBuildBadge build={app.latestDebugBuild} label="debug" />
                              )}
                            </div>
                          )}
                        </div>
                      </label>
                    </li>
                  );
                })}
              </ul>
            )}
          </div>
        </section>

        {/* ─── Source branch ────────────────────────── */}
        <section className="bg-white rounded-xl border border-zinc-200">
          <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100">
            <h2 className="text-base sm:text-lg font-semibold text-zinc-900 flex items-center gap-2">
              <GitBranch className="w-4 h-4 text-zinc-500" />
              Source
            </h2>
            <p className="text-xs text-zinc-500 mt-0.5">
              Branch or tag the workflow will check out. Defaults to <code className="text-zinc-700">main</code>.
            </p>
          </header>
          <div className="p-4 sm:p-6 space-y-3">
            <div className="relative" ref={branchContainerRef}>
              <div className="relative">
                <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-zinc-400 pointer-events-none" />
                <input
                  ref={branchInputRef}
                  type="text"
                  value={branchSearch}
                  onChange={(e) => {
                    setBranchSearch(e.target.value);
                    setSourceRef(e.target.value.trim());
                    setBranchDropdownOpen(true);
                  }}
                  onFocus={() => {
                    setBranchDropdownOpen(true);
                    branchInputRef.current?.select();
                  }}
                  onKeyDown={(e) => {
                    if (e.key === 'Escape') {
                      setBranchDropdownOpen(false);
                      branchInputRef.current?.blur();
                    }
                    if (e.key === 'Enter' && branchDropdownOpen) {
                      e.preventDefault();
                      if (filteredBranches.length > 0) {
                        const pick = filteredBranches[0];
                        setSourceRef(pick.name);
                        setBranchSearch(pick.name);
                      }
                      setBranchDropdownOpen(false);
                    }
                  }}
                  placeholder="Search branch or enter name…"
                  className="w-full h-10 sm:h-9 border border-zinc-300 rounded-lg pl-9 pr-8 text-sm font-mono bg-white focus:outline-none focus:ring-2 focus:ring-zinc-400"
                />
                <ChevronDown
                  className={cn(
                    'absolute right-2.5 top-1/2 -translate-y-1/2 w-4 h-4 text-zinc-400 cursor-pointer transition-transform',
                    branchDropdownOpen && 'rotate-180',
                  )}
                  onClick={() => {
                    setBranchDropdownOpen((o) => !o);
                    if (!branchDropdownOpen) branchInputRef.current?.focus();
                  }}
                />
              </div>

              {branchDropdownOpen && (
                <ul className="absolute z-20 mt-1 w-full max-h-56 overflow-auto rounded-lg border border-zinc-200 bg-white shadow-lg">
                  {branchesLoading ? (
                    <li className="px-3 py-2 text-sm text-zinc-400">Loading branches…</li>
                  ) : filteredBranches.length === 0 ? (
                    <li className="px-3 py-2 text-sm text-zinc-500">
                      {branchSearch.trim()
                        ? <>No matches — <span className="font-mono text-zinc-700">{branchSearch.trim()}</span> will be used as-is</>
                        : 'No branches found'}
                    </li>
                  ) : (
                    filteredBranches.map((b) => (
                      <li
                        key={b.name}
                        onMouseDown={(e) => {
                          e.preventDefault();
                          setSourceRef(b.name);
                          setBranchSearch(b.name);
                          setBranchDropdownOpen(false);
                        }}
                        className={cn(
                          'px-3 py-2 text-sm font-mono cursor-pointer hover:bg-zinc-50 flex items-center justify-between',
                          sourceRef === b.name && 'bg-zinc-50 font-medium',
                        )}
                      >
                        <span className="truncate">{b.name}</span>
                        <span className="text-[10px] text-zinc-400 font-mono ml-2 shrink-0">
                          {b.sha.slice(0, 7)}
                        </span>
                      </li>
                    ))
                  )}
                </ul>
              )}
            </div>

            {sourceRef !== 'main' && sourceRef.trim() !== '' && (
              <p className="text-xs text-amber-700 flex items-center gap-1">
                <AlertTriangle className="w-3.5 h-3.5" />
                Building from <code className="font-mono">{sourceRef}</code> instead of main
              </p>
            )}
          </div>
        </section>

        {/* ─── Changelog preview (per-app tabs, release builds only) ── */}
        {!isDebug && changelogApps.length > 0 && sourceRef.trim() && (() => {
          const safeTab = Math.min(changelogTab, changelogApps.length - 1);
          const q = changelogQueries[safeTab];
          const app = changelogApps[safeTab];
          if (!q || !app) return null;
          return (
            <section className="bg-white rounded-xl border border-zinc-200">
              <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100">
                <div className="flex items-center justify-between">
                  <h2 className="text-base sm:text-lg font-semibold text-zinc-900 flex items-center gap-2">
                    <GitCommit className="w-4 h-4 text-zinc-500" />
                    Commits since last release
                  </h2>
                  {q.isFetching && (
                    <span className="text-xs text-zinc-400">Loading…</span>
                  )}
                </div>
                {q.data?.cpBaseVersion && (
                  <p className="text-xs text-zinc-500 mt-0.5">
                    Base: <span className="font-mono text-zinc-700">
                      {q.data.cpBaseTag || q.data.cpBaseVersion}
                    </span>
                    {' → '}
                    <span className="font-mono text-zinc-700">{sourceRef}</span>
                    {q.data.cpAheadBy > 0 && (
                      <span className="ml-1.5 text-zinc-400">
                        ({q.data.cpAheadBy} commit{q.data.cpAheadBy === 1 ? '' : 's'})
                      </span>
                    )}
                  </p>
                )}
              </header>

              {changelogApps.length > 1 && (
                <div className="flex gap-0 border-b border-zinc-100 overflow-x-auto px-4 sm:px-6">
                  {changelogApps.map((a, i) => (
                    <button
                      key={`${a.name}-${a.surface}-${a.platform}`}
                      type="button"
                      onClick={() => setChangelogTab(i)}
                      className={cn(
                        'px-3 py-2 text-xs font-medium whitespace-nowrap border-b-2 transition-colors',
                        i === safeTab
                          ? 'border-zinc-900 text-zinc-900'
                          : 'border-transparent text-zinc-400 hover:text-zinc-600',
                      )}
                    >
                      {a.label}
                      {changelogQueries[i]?.data && (
                        <span className="ml-1.5 text-[10px] text-zinc-400">
                          {changelogQueries[i].data!.cpAheadBy}
                        </span>
                      )}
                    </button>
                  ))}
                </div>
              )}

              <div className="p-4 sm:p-6">
                {q.isLoading ? (
                  <div className="space-y-2">
                    <Skeleton className="h-6 w-full" />
                    <Skeleton className="h-6 w-3/4" />
                    <Skeleton className="h-6 w-5/6" />
                  </div>
                ) : q.isError ? (
                  <p className="text-sm text-red-600">Failed to load changelog preview.</p>
                ) : !q.data || q.data.cpCommits.length === 0 ? (
                  <p className="text-sm text-zinc-500">
                    {q.data?.cpStatus === 'identical'
                      ? 'Branch is identical to the last release — no new commits.'
                      : 'No commits found (no previous release to compare against).'}
                  </p>
                ) : (
                  <div className="space-y-3">
                    <div className="flex items-center justify-between text-[11px] text-zinc-400 px-0.5">
                      <span>Newest first</span>
                      {q.data.cpAheadBy > 50 && (
                        <span>Showing 50 of {q.data.cpAheadBy}</span>
                      )}
                    </div>
                    <ul className="divide-y divide-zinc-100 max-h-80 overflow-y-auto">
                      {[...q.data.cpCommits].reverse().map((c, i) => (
                        <li key={c.ciSha} className="flex items-center gap-2.5 py-2">
                          <span className="text-[10px] text-zinc-300 w-4 text-right shrink-0 tabular-nums">{i + 1}</span>
                          <img
                            src={`https://github.com/${c.ciAuthorLogin}.png?size=40`}
                            alt={c.ciAuthorLogin}
                            className="w-5 h-5 rounded-full shrink-0 bg-zinc-100"
                            loading="lazy"
                            onError={(e) => { (e.target as HTMLImageElement).style.display = 'none'; }}
                          />
                          <a
                            href={c.ciHtmlUrl}
                            target="_blank"
                            rel="noopener noreferrer"
                            className="font-mono text-[11px] text-blue-600 hover:text-blue-800 hover:underline shrink-0"
                          >
                            {c.ciShortSha}
                          </a>
                          <span className="text-sm text-zinc-800 min-w-0 truncate flex-1">
                            {c.ciSubject}
                          </span>
                          {c.ciPrNumber != null && (
                            <a
                              href={prUrlFromCommitUrl(c.ciHtmlUrl, c.ciPrNumber)}
                              target="_blank"
                              rel="noopener noreferrer"
                              className="text-[11px] text-blue-600 hover:text-blue-800 hover:underline shrink-0"
                            >
                              #{c.ciPrNumber}
                            </a>
                          )}
                          <span className="text-[11px] text-zinc-400 shrink-0 max-w-[100px] truncate text-right">{c.ciAuthorLogin}</span>
                        </li>
                      ))}
                    </ul>
                    {q.data.cpCompareUrl && (
                      <div className="pt-1 border-t border-zinc-100">
                        <a
                          href={q.data.cpCompareUrl}
                          target="_blank"
                          rel="noopener noreferrer"
                          className="inline-flex items-center gap-1 text-xs text-blue-600 hover:text-blue-800 hover:underline"
                        >
                          View full diff on GitHub <ExternalLink className="w-3 h-3" />
                        </a>
                      </div>
                    )}
                  </div>
                )}
              </div>
            </section>
          );
        })()}

        {/* ─── Versions card (hidden for debug builds) ── */}
        {selectedIds.length > 0 && !isDebug && (
          <section className="bg-white rounded-xl border border-zinc-200">
            <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100 flex items-center justify-between gap-3">
              <h2 className="text-base sm:text-lg font-semibold text-zinc-900">
                Versions
              </h2>
              {previewQuery.isFetching && (
                <span className="text-xs text-zinc-400">Loading suggestions…</span>
              )}
            </header>
            <div className="p-4 sm:p-6 space-y-3">
              {selectedIds.map((id) => {
                const app = enabledApps.find((a) => a.id === id);
                if (!app) return null;
                const preview = previewById.get(id);
                const v = versionEdits[id] || { versionName: '', versionCode: '' };
                const ios = app.platform === 'ios';
                // Android rows render a 3-column grid (name + code + status);
                // iOS rows collapse to a 2-column grid (just the version_number
                // input + status) since the build number is workflow-computed.
                return (
                  <div
                    key={id}
                    className={cn(
                      'grid grid-cols-1 gap-3 items-end',
                      ios
                        ? 'sm:grid-cols-[1fr_auto]'
                        : 'sm:grid-cols-[1fr_auto_auto]',
                    )}
                  >
                    <div>
                      <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">
                        {app.displayLabel || app.name}
                        <span className="text-zinc-400 ml-1.5 normal-case font-normal tracking-normal">
                          ({app.surface} {app.platform})
                        </span>
                      </label>
                      <input
                        type="text"
                        value={v.versionName}
                        onChange={(e) => setVersionField(id, 'versionName', e.target.value)}
                        placeholder={
                          preview?.nextVersionName ??
                          preview?.nextVersionNumber ??
                          '2.5.1'
                        }
                        className="w-full h-10 sm:h-9 border border-zinc-300 rounded-lg px-3 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400"
                      />
                      {ios && (
                        <p className="mt-1 text-[11px] text-zinc-500">
                          Build number is computed by the build workflow.
                        </p>
                      )}
                    </div>
                    {!ios && (
                      <div className="sm:w-32">
                        <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">
                          Code
                        </label>
                        <input
                          type="number"
                          value={v.versionCode}
                          onChange={(e) => setVersionField(id, 'versionCode', e.target.value)}
                          placeholder={preview?.nextVersionCode != null ? String(preview.nextVersionCode) : '12345'}
                          className="w-full h-10 sm:h-9 border border-zinc-300 rounded-lg px-3 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400"
                        />
                      </div>
                    )}
                    <div className="text-xs text-zinc-400 pb-2">
                      {preview?.source && !preview.err && (
                        <span>auto · {preview.source}</span>
                      )}
                      {preview?.err && (
                        <span className="inline-flex items-center gap-1 text-amber-700">
                          <AlertTriangle className="w-3.5 h-3.5" />
                          {preview.err}
                        </span>
                      )}
                    </div>
                  </div>
                );
              })}
            </div>
          </section>
        )}

        {/* ─── Change log ───────────────────────────── */}
        <section className="bg-white rounded-xl border border-zinc-200">
          <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100">
            <h2 className="text-base sm:text-lg font-semibold text-zinc-900">
              Change log
            </h2>
          </header>
          <div className="p-4 sm:p-6">
            <Textarea
              value={changeLog}
              onChange={(e) => setChangeLog(e.target.value)}
              placeholder="Describe what's in this release…"
              rows={5}
              required
            />
          </div>
        </section>

        {/* ─── Build Type (env-locked) ────────────── */}
        <section className="bg-white rounded-xl border border-zinc-200">
          <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100">
            <h2 className="text-base sm:text-lg font-semibold text-zinc-900">
              Build type
            </h2>
          </header>
          <div className="p-4 sm:p-6">
            <span className={cn(
              'inline-flex items-center px-3 py-1.5 rounded-md text-sm font-medium',
              buildType === 'debug'
                ? 'bg-amber-50 text-amber-700 border border-amber-200'
                : 'bg-emerald-50 text-emerald-700 border border-emerald-200',
            )}>
              {buildType === 'debug' ? 'Debug' : 'Release'}
            </span>
            <p className="mt-2.5 text-xs text-zinc-500">
              {buildType === 'debug'
                ? `Builds will be uploaded to ${primaryPlatform === 'ios' ? 'TestFlight' : 'Firebase App Distribution'}.`
                : `Builds will be uploaded to ${primaryPlatform === 'ios' ? 'App Store' : 'Google Play'}.`}
            </p>
          </div>
        </section>

        {/* ─── Actions ──────────────────────────────── */}
        <div className="flex flex-col-reverse sm:flex-row sm:justify-end gap-2 sm:gap-3 pt-2">
          <Button
            type="button"
            variant="secondary"
            onClick={() => navigate('/mobile/releases')}
          >
            Cancel
          </Button>
          {/* Note: "Save & approve" intentionally omitted in MVP — the bulk
              approve action lives on the release group page. */}
          <Button
            type="submit"
            loading={createMutation.isPending}
            disabled={!validation.ok}
          >
            <Smartphone className="w-4 h-4" />
            {createMutation.isPending ? 'Creating…' : 'Save as draft'}
          </Button>
        </div>
      </form>
    </div>
  );
}
