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
  ChangelogBase,
  CreateMobileReleasesItem,
  CreateMobileReleasesReq,
  LatestBuild,
  MobileDestination,
  VersionPreviewItem,
} from '../../types';
import { useAuth } from '../../../../core/auth/AuthContext';
import { Button } from '../../../../shared/ui/button';
import { Textarea } from '../../../../shared/ui/input';
import { MobileChangelogAiSummary } from '../../components/MobileChangelogAiSummary';
import { Skeleton } from '../../../../shared/ui/skeleton';
import { CollapsibleGroup, groupAppsBySurface, useGroupCollapse } from '../../components/appGroups';
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

const formatShort = (d: string) => {
  const date = new Date(d);
  if (isNaN(date.getTime())) return '';
  return date.toLocaleDateString('en-IN', { month: 'short', day: '2-digit' });
};

const LatestBuildBadge = ({ build, label, platform }: { build: LatestBuild; label: string; platform?: string }) => {
  // Prefer the store track (prod / internal / testflight) over the generic
  // "RELEASE" build-type label. When a row pre-dates store_track, infer from the
  // platform: iOS store builds are TestFlight; Android store builds are production.
  const track =
    build.track ?? (label === 'release' ? (platform === 'ios' ? 'testflight' : 'production') : null);
  const trackLabel =
    track === 'production'
      ? 'prod'
      : track === 'internal'
        ? // iOS "internal" distribution is TestFlight — label it as such.
          platform === 'ios'
          ? 'testflight'
          : 'internal'
        : track === 'testflight'
          ? 'testflight'
          : null;
  const isLive = track === 'production';
  const display = label === 'debug' ? label : trackLabel ?? label;
  return (
    <span
      className={cn(
        'inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium',
        label === 'debug'
          ? 'bg-amber-50 text-amber-700 border border-amber-200'
          : trackLabel && !isLive
            ? 'bg-sky-50 text-sky-700 border border-sky-200'
            : 'bg-emerald-50 text-emerald-700 border border-emerald-200',
      )}
    >
      <span className="uppercase">{display}</span>
      <span className="font-mono">v{build.version}</span>
      {build.versionCode != null && (
        <span className="text-[9px] opacity-70">+{build.versionCode}</span>
      )}
      {build.completedAt && (
        <span className="opacity-60">{formatShort(build.completedAt)}</span>
      )}
    </span>
  );
};

// Store-track badges to show for an app: prefer the per-track (prod + internal)
// builds from store-sync; fall back to the single leading "release" build for
// rows synced before per-track snapshots existed.
const storeBuildsForApp = (a: AppCatalogEntry): LatestBuild[] => {
  const out: LatestBuild[] = [];
  if (a.latestProdBuild) out.push(a.latestProdBuild);
  if (a.latestInternalBuild) out.push(a.latestInternalBuild);
  if (out.length === 0 && a.latestReleaseBuild) out.push(a.latestReleaseBuild);
  return out;
};

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
  // Consumer/Provider collapsible groups for the picker below.
  const appGroups = useMemo(() => groupAppsBySurface(enabledApps), [enabledApps]);
  const { isOpen, toggle } = useGroupCollapse();

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

  // Provider (driver) PROD Android builds dispatch to provider-prod-apk-gen.yaml,
  // which requires a `destination` (Play Store vs Firebase App Distribution).
  // Default GooglePlay; surfaced as a picker only when such an app is selected.
  const [destination, setDestination] = useState<MobileDestination>('GooglePlay');

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

  // The destination picker is relevant only to provider-prod-apk-gen.yaml, so
  // show it iff a provider (driver) Android app is selected on a release build —
  // the one workflow that declares the `destination` input.
  const hasProviderAndroid = useMemo(
    () =>
      selectedIds.some((id) => {
        const a = enabledApps.find((x) => x.id === id);
        return a?.surface === 'driver' && a?.platform === 'android';
      }),
    [selectedIds, enabledApps],
  );
  const showDestination = buildType === 'release' && hasProviderAndroid;

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
          id: a.id,
          name: a.name,
          surface: a.surface,
          platform: a.platform,
          label: a.displayLabel || `${a.name} (${a.surface} ${a.platform})`,
        })),
    [selectedIds, enabledApps],
  );
  // Changelog base track: diff the new branch against the prod or the internal
  // store build. Defaults to prod. Applies across all apps in the changelog.
  const [changelogBase, setChangelogBase] = useState<ChangelogBase>('production');
  const changelogQueries = useChangelogPreviews(
    changelogApps,
    sourceRef?.trim() || undefined,
    changelogBase,
  );
  const [changelogTab, setChangelogTab] = useState(0);
  useEffect(() => { setChangelogTab(0); }, [selectedIds.join(',')]);
  // Free-text filter over the active tab's commit list. Reset whenever the
  // visible tab changes so a stale query doesn't carry across apps.
  const [commitSearch, setCommitSearch] = useState('');
  useEffect(() => { setCommitSearch(''); }, [changelogTab]);

  const createMutation = useCreateMobileReleases();

  // Submission validity: at least one app, every selected app has a non-empty
  // version name (Android: + numeric code; iOS: no code — workflow computes
  // the build number), and a non-empty changelog.
  const isDebug = buildType === 'debug';

  const validation = useMemo(() => {
    if (selectedIds.length === 0) return { ok: false, reason: 'Select at least one app' };
    if (!changeLog.trim()) return { ok: false, reason: 'Change log is required' };
    if (/^[0-9a-fA-F]{6,40}$/.test(changeLog.trim())) return { ok: false, reason: 'Change log cannot be a git commit ID. Please provide a descriptive changelog.' };
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
      destination: showDestination ? destination : null,
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
              <div className="space-y-2.5">
                {appGroups.map((g) => {
                  const groupSel = g.apps.filter((a) => selectedIds.includes(a.id)).length;
                  return (
                    <CollapsibleGroup
                      key={g.key}
                      label={g.label}
                      count={g.apps.length}
                      open={isOpen(g.key)}
                      onToggle={() => toggle(g.key)}
                      badge={
                        groupSel > 0 ? (
                          <span className="text-[11px] font-medium text-zinc-900">
                            {groupSel} selected
                          </span>
                        ) : null
                      }
                    >
                      {(() => {
                        // Merge the surface's per-platform rows into ONE tile per
                        // app (keyed by the catalyst `name`), showing Android +
                        // iOS side by side. Each platform is still independently
                        // selectable (its own appCatalogId). Android-only apps
                        // (no iOS row) just leave the iOS cell empty.
                        const order: string[] = [];
                        const byName = new Map<
                          string,
                          { label: string; byPlat: Record<string, (typeof g.apps)[number]> }
                        >();
                        for (const app of g.apps) {
                          if (!byName.has(app.name)) {
                            order.push(app.name);
                            byName.set(app.name, {
                              // Strip the trailing platform word so the tile title
                              // reads "Odisha Yatri (Driver)" not "(Driver Android)".
                              label: (app.displayLabel || app.name).replace(/ (Android|iOS)\)$/i, ')'),
                              byPlat: {},
                            });
                          }
                          byName.get(app.name)!.byPlat[app.platform] = app;
                        }
                        return (
                          <ul className="space-y-2">
                            {order.map((name) => {
                              const { label, byPlat } = byName.get(name)!;
                              const entries = Object.values(byPlat);
                              const anySel = entries.some((a) => selectedIds.includes(a.id));
                              return (
                                <li key={name}>
                                  <div
                                    className={cn(
                                      'rounded-lg border px-3 py-2.5 transition-colors',
                                      anySel ? 'border-zinc-900 bg-zinc-50/60' : 'border-zinc-200 hover:border-zinc-300',
                                    )}
                                  >
                                    <div className="flex items-center justify-between gap-3">
                                      <div className="text-sm font-medium text-zinc-900 truncate">
                                        {label}
                                      </div>
                                      <div className="flex items-center gap-1.5 shrink-0">
                                        {(['android', 'ios'] as const).map((plat) => {
                                          const app = byPlat[plat];
                                          if (!app) return null;
                                          const sel = selectedIds.includes(app.id);
                                          return (
                                            <label
                                              key={plat}
                                              title={`${app.displayLabel || app.name}`}
                                              className={cn(
                                                // `relative` is REQUIRED: the child <input> uses `sr-only`
                                                // (position:absolute). Without a positioned ancestor its
                                                // containing block becomes <html>, so it escapes <main>'s
                                                // overflow-y-auto and stretches the document — a stray blank
                                                // band below the page. Containing it here keeps it clipped.
                                                'relative inline-flex items-center gap-1.5 h-7 pl-2 pr-2.5 rounded-full border cursor-pointer text-xs font-medium select-none transition-colors',
                                                sel
                                                  ? 'border-zinc-900 bg-zinc-900 text-white'
                                                  : 'border-zinc-200 text-zinc-600 hover:border-zinc-300 hover:bg-white',
                                              )}
                                            >
                                              <input
                                                type="checkbox"
                                                checked={sel}
                                                onChange={() => toggleApp(app.id)}
                                                className="sr-only"
                                              />
                                              {plat === 'ios' ? (
                                                <Apple className={cn('w-3.5 h-3.5', sel ? 'text-white' : 'text-zinc-400')} />
                                              ) : (
                                                <Cpu className={cn('w-3.5 h-3.5', sel ? 'text-white' : 'text-emerald-600')} />
                                              )}
                                              {plat === 'ios' ? 'iOS' : 'Android'}
                                            </label>
                                          );
                                        })}
                                      </div>
                                    </div>
                                    {entries.some((a) => storeBuildsForApp(a).length || a.latestDebugBuild) && (
                                      <div className="flex flex-wrap items-center gap-x-2 gap-y-1 mt-2">
                                        {entries.map((a) => {
                                          const stores = storeBuildsForApp(a);
                                          return stores.length || a.latestDebugBuild ? (
                                            <div key={a.id} className="inline-flex items-center gap-1">
                                              <span className="text-[10px] uppercase tracking-wide text-zinc-400">
                                                {a.platform === 'ios' ? 'iOS' : 'And'}
                                              </span>
                                              {stores.map((b, i) => (
                                                <LatestBuildBadge key={i} build={b} label="release" platform={a.platform} />
                                              ))}
                                              {a.latestDebugBuild && (
                                                <LatestBuildBadge build={a.latestDebugBuild} label="debug" platform={a.platform} />
                                              )}
                                            </div>
                                          ) : null;
                                        })}
                                      </div>
                                    )}
                                  </div>
                                </li>
                              );
                            })}
                          </ul>
                        );
                      })()}
                    </CollapsibleGroup>
                  );
                })}
              </div>
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
                <div className="flex items-center justify-between gap-3">
                  <h2 className="text-base sm:text-lg font-semibold text-zinc-900 flex items-center gap-2">
                    <GitCommit className="w-4 h-4 text-zinc-500" />
                    Commits since last release
                  </h2>
                  <div className="flex items-center gap-2 shrink-0">
                    {q.isFetching && (
                      <span className="text-xs text-zinc-400">Loading…</span>
                    )}
                    {/* Base-track toggle: diff against the prod or the internal store build. */}
                    <div className="inline-flex rounded-md border border-zinc-200 overflow-hidden text-[11px] font-medium">
                      {(['production', 'internal'] as const).map((b) => (
                        <button
                          key={b}
                          type="button"
                          onClick={() => setChangelogBase(b)}
                          title={b === 'production' ? 'Diff against the live production build' : 'Diff against the latest internal / TestFlight build'}
                          className={cn(
                            'px-2.5 py-1 transition-colors',
                            changelogBase === b
                              ? 'bg-zinc-900 text-white'
                              : 'bg-white text-zinc-500 hover:text-zinc-700',
                          )}
                        >
                          {b === 'production' ? 'Prod' : 'Internal'}
                        </button>
                      ))}
                    </div>
                  </div>
                </div>
                {q.data?.cpBaseVersion && (
                  <p className="text-xs text-zinc-500 mt-1">
                    Base
                    <span className="text-zinc-400"> ({changelogBase === 'production' ? 'prod' : 'internal'})</span>
                    : <span className="font-mono text-zinc-700">
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
                {q.data && q.data.cpCommits.length > 0 && (
                  <MobileChangelogAiSummary
                    app={app.name}
                    surface={app.surface}
                    platform={app.platform}
                    branch={sourceRef}
                    base={changelogBase}
                    versionName={versionEdits[app.id]?.versionName || ''}
                    versionCode={versionEdits[app.id]?.versionCode || ''}
                  />
                )}
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
                ) : (() => {
                  // Backend returns cpCommits newest-first; filter client-side.
                  const commits = q.data.cpCommits;
                  const term = commitSearch.trim().toLowerCase();
                  const filtered = term
                    ? commits.filter((c) =>
                        c.ciSubject.toLowerCase().includes(term) ||
                        c.ciAuthorLogin.toLowerCase().includes(term) ||
                        c.ciShortSha.toLowerCase().includes(term) ||
                        (c.ciPrNumber != null && String(c.ciPrNumber).includes(term)))
                    : commits;
                  return (
                    <div className="space-y-2">
                      <div className="flex items-center gap-2">
                        <div className="relative flex-1">
                          <Search className="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-zinc-400 pointer-events-none" />
                          <input
                            type="text"
                            value={commitSearch}
                            onChange={(e) => setCommitSearch(e.target.value)}
                            placeholder="Search commits — message, author, sha, PR#…"
                            className="w-full h-8 pl-8 pr-3 text-xs border border-zinc-300 rounded-md bg-white focus:outline-none focus:ring-2 focus:ring-zinc-400"
                          />
                        </div>
                        <span className="text-[11px] text-zinc-400 whitespace-nowrap tabular-nums">
                          {term ? `${filtered.length} / ${commits.length}` : `${commits.length} commit${commits.length === 1 ? '' : 's'}`}
                          {q.data.cpAheadBy > commits.length ? ` of ${q.data.cpAheadBy}` : ''}
                        </span>
                      </div>
                      <ul className="divide-y divide-zinc-100 max-h-96 overflow-y-auto rounded-md border border-zinc-100">
                        {filtered.length === 0 ? (
                          <li className="px-3 py-6 text-center text-xs text-zinc-400">
                            No commits match “{commitSearch.trim()}”.
                          </li>
                        ) : (
                          filtered.map((c, i) => (
                            <li
                              key={c.ciSha}
                              className="flex items-center gap-2.5 py-2 px-2"
                              style={{ contentVisibility: 'auto', containIntrinsicSize: '0 36px' }}
                            >
                              <span className="text-[10px] text-zinc-300 w-7 text-right shrink-0 tabular-nums">{i + 1}</span>
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
                          ))
                        )}
                      </ul>
                      {q.data.cpCompareUrl && (
                        <div className="pt-1">
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
                  );
                })()}
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

            {showDestination && (
              <div className="mt-4 pt-4 border-t border-zinc-100">
                <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">
                  Provider Android destination
                </label>
                <div className="relative max-w-xs">
                  <select
                    value={destination}
                    onChange={(e) => setDestination(e.target.value as MobileDestination)}
                    className="w-full h-10 sm:h-9 appearance-none border border-zinc-300 rounded-lg pl-3 pr-9 text-sm bg-white focus:outline-none focus:ring-2 focus:ring-zinc-400"
                  >
                    <option value="GooglePlay">Google Play</option>
                    <option value="Firebase">Firebase App Distribution</option>
                  </select>
                  <ChevronDown className="absolute right-2.5 top-1/2 -translate-y-1/2 w-4 h-4 text-zinc-400 pointer-events-none" />
                </div>
                <p className="mt-1.5 text-[11px] text-zinc-500">
                  Where the provider (driver) Android prod build is published. iOS
                  and consumer apps in this release ignore it.
                </p>
              </div>
            )}
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
