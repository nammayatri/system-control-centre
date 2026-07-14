import { useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { AlertTriangle, Smartphone, Apple, Check, Cpu, GitBranch, ChevronDown, Search, GitCommit, ExternalLink, X } from 'lucide-react';
import {
  useMobileApps,
  useMobileBranches,
  useMobileGroup,
  usePreviewVersions,
  useCreateMobileReleases,
  useChangelogPreviews,
} from '../../hooks';
import { StoreSyncBanner } from '../../components/StoreSync';
import { formatBuildCode } from '../../utils';
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
import { BrandLogo } from '../../components/BrandLogo';
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
        <span className="text-[9px] opacity-70">{formatBuildCode(build.versionCode)}</span>
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
  const { buildType: deployBuildType, slackEnabled } = useAuth();
  const { data: apps, isLoading: appsLoading, error: appsError } = useMobileApps();
  // "Copy as new release": ?copyFrom=<groupId> prefills the form from an
  // existing group — same apps/changelog/destination, FRESH auto versions,
  // and submit mints a NEW group (a copy is a new train, never a reused one).
  const [searchParams] = useSearchParams();
  const copyFrom = searchParams.get('copyFrom') ?? undefined;
  // &only=<rowId,rowId> narrows the copy to the rows selected on the group
  // page; absent means copy every member.
  const copyOnly = searchParams.get('only')?.split(',').filter(Boolean);
  const { data: copyGroup } = useMobileGroup(copyFrom);

  // Filter to enabled apps only — disabled apps live in the catalog but
  // shouldn't be selectable for new releases.
  const enabledApps: AppCatalogEntry[] = useMemo(
    () => (apps || []).filter((a) => a.enabled),
    [apps],
  );
  // Consumer/Provider collapsible groups for the picker below.
  const appGroups = useMemo(() => groupAppsBySurface(enabledApps), [enabledApps]);
  // Groups start COLLAPSED — the selected-apps chips (below) are the at-a-glance
  // view; expand a surface only to add/remove. Search still force-opens them.
  const { isOpen, toggle } = useGroupCollapse(false);

  // Free-text filter over the app picker — matches name / label / surface /
  // platform. Filters the visible tiles only; it never touches selection, so an
  // already-selected app that's filtered out stays selected (count badge holds).
  const [appSearch, setAppSearch] = useState('');
  const visibleGroups = useMemo(() => {
    const term = appSearch.trim().toLowerCase();
    if (!term) return appGroups;
    return appGroups
      .map((g) => ({
        ...g,
        apps: g.apps.filter((a) =>
          (a.displayLabel || a.name).toLowerCase().includes(term) ||
          a.name.toLowerCase().includes(term) ||
          a.surface.toLowerCase().includes(term) ||
          a.platform.toLowerCase().includes(term),
        ),
      }))
      .filter((g) => g.apps.length > 0);
  }, [appGroups, appSearch]);

  const [sourceRef, setSourceRef] = useState<string>('main');
  const [branchSearch, setBranchSearch] = useState('main');
  // A cleared input means main — every consumer (row, bar, changelog, submit)
  // must read this, never raw sourceRef, or '' and 'main' disagree.
  const effSourceRef = sourceRef.trim() || 'main';
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
          setBranchSearch(sourceRef.trim() || 'main');
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
  // Prefilled opt-out so nobody is forced to write one — replace it with real
  // notes when you have them. Goes to the build workflow (and Slack fallback).
  const [changeLog, setChangeLog] = useState("I don't want to put changelog");
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

  // Apply the copyFrom prefill ONCE, when both the catalog and the source
  // group have loaded. Apps that left the catalog are reported, not guessed.
  const copyApplied = useRef(false);
  useEffect(() => {
    if (copyApplied.current || !copyFrom || !copyGroup || enabledApps.length === 0) return;
    copyApplied.current = true;
    const allMembers = copyGroup.members ?? [];
    const members = copyOnly?.length
      ? allMembers.filter((m) => copyOnly.includes(m.id))
      : allMembers;
    const ids: number[] = [];
    const dropped: string[] = [];
    for (const m of members) {
      const app = enabledApps.find(
        (a) => a.name === m.appGroup && a.surface === m.service && a.platform === m.env,
      );
      // A group can hold several rows per app (e.g. a build + its revert) —
      // copying selects each app once.
      if (app) {
        if (!ids.includes(app.id)) ids.push(app.id);
      } else if (!dropped.includes(`${m.appGroup} ${m.env}`)) {
        dropped.push(`${m.appGroup} ${m.env}`);
      }
    }
    if (ids.length > 0) setSelectedIds(ids);
    const copiedLog = members
      .map((m) => m.release_context?.change_log?.trim() || m.change_log?.trim())
      .find((c) => c);
    if (copiedLog) setChangeLog(copiedLog);
    if (members.some((m) => m.release_context?.destination === 'Firebase')) {
      setDestination('Firebase');
    }
    if (ids.length > 0) {
      toast.success(`Copied ${ids.length} app${ids.length === 1 ? '' : 's'} from the source group`);
    }
    if (dropped.length > 0) {
      toast.error(`Not in the app catalog anymore: ${dropped.join(', ')}`);
    }
  }, [copyFrom, copyGroup, enabledApps]);

  const previewQuery = usePreviewVersions(buildType === 'debug' ? [] : debouncedIds);
  const previews: VersionPreviewItem[] = previewQuery.data?.previews ?? [];

  // Lookup helper used by every per-row branch below: given an app catalog id,
  // tell us if it's an iOS row. iOS rows render a single "Version Number"
  // input and skip the numeric code; Android rows render both inputs.
  const isIosId = (id: number): boolean =>
    enabledApps.find((a) => a.id === id)?.platform === 'ios';

  // A provider (driver) Android release going to Firebase: its version is
  // auto-generated per build (year.MMDD.HHMM) and never reaches Play, so the
  // operator doesn't enter a version/code for it. Drives the read-only Versions
  // row + skips that row's version validation.
  const isFirebaseId = (id: number): boolean => {
    const a = enabledApps.find((x) => x.id === id);
    return (
      buildType === 'release' &&
      destination === 'Firebase' &&
      a?.surface === 'driver' &&
      a?.platform === 'android'
    );
  };

  // Live preview of the auto version a Firebase build would get right now, matching the
  // backend's UTC `year.MMDD.HHMM` format (execResolveVersion). Approximate — the final
  // value is stamped server-side when the build's ResolveVersion stage runs, so it may
  // differ by a minute; the resolved version then shows on the release row/detail.
  const firebaseVersionPreview = (): string => {
    const d = new Date();
    const mm = d.getUTCMonth() + 1;
    const dd = String(d.getUTCDate()).padStart(2, '0');
    const HH = String(d.getUTCHours()).padStart(2, '0');
    const MM = String(d.getUTCMinutes()).padStart(2, '0');
    return `${d.getUTCFullYear()}.${mm}${dd}.${HH}${MM}`;
  };

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

  // The store(s) builds will land on, derived from the SELECTED platforms (not a
  // single "primary" one) — so a mixed Android+iOS release reads "Google Play and
  // App Store", an iOS-only one "App Store", etc. Shown in the sticky summary bar.
  const uploadTargets = useMemo(() => {
    const hasAndroid = selectedPlatforms.has('android');
    const hasIos = selectedPlatforms.has('ios');
    const targets: string[] = [];
    if (buildType === 'debug') {
      if (hasAndroid) targets.push('Firebase App Distribution');
      if (hasIos) targets.push('TestFlight');
    } else {
      // Only provider Android rows follow the Firebase destination; consumer
      // Android always lands on Play — a mixed selection reports both.
      const androidIds = selectedIds.filter((id) => !isIosId(id));
      if (androidIds.some((id) => !isFirebaseId(id))) targets.push('Google Play');
      if (androidIds.some((id) => isFirebaseId(id))) targets.push('Firebase App Distribution');
      if (hasIos) targets.push('App Store');
    }
    return targets;
  }, [selectedPlatforms, selectedIds, enabledApps, buildType, destination]);

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
    effSourceRef,
    changelogBase,
  );
  const [changelogTab, setChangelogTab] = useState(0);
  // "Send changelog summary to Slack after build" — one toggle for the whole
  // release; the per-app summary text is captured into summaryByApp as each
  // app's changelog panel reports it (onSummary). Apps whose tab was never
  // opened won't have a captured summary — the backend falls back to changeLog.
  const [sendChangelogSlack, setSendChangelogSlack] = useState(false);
  const [summaryByApp, setSummaryByApp] = useState<Record<number, string>>({});
  // AI SHORT synopsis per app — stored on the release row so the promote form
  // can prefill store notes without re-querying the AI later.
  const [shortByApp, setShortByApp] = useState<Record<number, string>>({});
  // Multi-app selections get ONE combined changelog (common + per-app extras);
  // it is what every item submits as changelogSummary. Reset whenever the
  // selection/branch/base changes so a stale text can never be submitted.
  const [combinedSummary, setCombinedSummary] = useState('');
  // A duplicate-version conflict from the last submit — shown as a persistent
  // banner (not just a toast) until the version changes or it's dismissed.
  const [conflict, setConflict] = useState<{ message: string } | null>(null);
  // Any change to the apps or versions may resolve the conflict — clear it so a
  // stale banner never lingers.
  useEffect(() => {
    setConflict(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedIds.join(','), JSON.stringify(versionEdits)]);
  const [combinedShort, setCombinedShort] = useState('');
  useEffect(() => { setChangelogTab(0); }, [selectedIds.join(',')]);
  useEffect(() => {
    setCombinedSummary('');
    setCombinedShort('');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedIds.join(','), effSourceRef, changelogBase]);
  // Free-text filter over the active tab's commit list. Reset whenever the
  // visible tab changes so a stale query doesn't carry across apps.
  const [commitSearch, setCommitSearch] = useState('');
  useEffect(() => { setCommitSearch(''); }, [changelogTab]);
  // Raw commit list is collapsed by default — the AI summary is the headline;
  // the list is there for whoever wants to dig.
  const [commitsOpen, setCommitsOpen] = useState(false);

  // The Slack opt-in needs a real summary to send — a build with no comparable
  // base produces none, and we never post an empty/typed-only changelog. Gate
  // the checkbox on one being present (multi-app: combined; single: this app's).
  const hasChangelogSummary =
    changelogApps.length > 1
      ? !!combinedSummary.trim()
      : changelogApps.length === 1
        ? !!summaryByApp[changelogApps[0].id]?.trim()
        : false;
  // If the summary disappears (apps/branch/base changed), never leave it opted in.
  useEffect(() => {
    if (!hasChangelogSummary && sendChangelogSlack) setSendChangelogSlack(false);
  }, [hasChangelogSummary, sendChangelogSlack]);

  const createMutation = useCreateMobileReleases();

  // Submission validity: at least one app, every selected app has a non-empty
  // version name (Android: + numeric code; iOS: no code — workflow computes
  // the build number), and a non-empty changelog.
  const isDebug = buildType === 'debug';

  const validation = useMemo(() => {
    if (selectedIds.length === 0) return { ok: false, reason: 'Select at least one app' };
    if (!changeLog.trim()) return { ok: false, reason: 'Workflow changelog is required' };
    if (/^[0-9a-fA-F]{6,40}$/.test(changeLog.trim())) return { ok: false, reason: 'Workflow changelog cannot be a git commit ID. Please provide a descriptive changelog.' };
    if (!isDebug) {
      for (const id of selectedIds) {
        // Firebase builds auto-generate their version — nothing to validate here.
        if (isFirebaseId(id)) continue;
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
  }, [selectedIds, versionEdits, changeLog, enabledApps, isDebug, destination, buildType]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!validation.ok) {
      toast.error(validation.reason);
      return;
    }
    const items: CreateMobileReleasesItem[] = selectedIds.map((id) => {
      // Debug + Firebase builds carry no operator version — the workflow generates it
      // (debug = CalVer, Firebase = unique timestamp). Send nulls so the backend owns it.
      if (isDebug || isFirebaseId(id)) {
        return { appCatalogId: id, versionName: null, versionCode: null };
      }
      const v = versionEdits[id];
      const ios = isIosId(id);
      return {
        appCatalogId: id,
        versionName: v.versionName.trim(),
        versionCode: ios ? null : parseInt(v.versionCode, 10),
        // Never opt into the Slack post for debug builds or when Slack is off —
        // the tickbox is hidden in those cases, so force it false regardless.
        sendChangelogSlack: sendChangelogSlack && !isDebug && slackEnabled,
        // Multi-app: the SAME combined changelog goes to every app. Single-app:
        // the per-app capture. Omitted entirely when nothing was generated, so
        // the backend falls back to the request-level changeLog.
        ...(selectedIds.length > 1
          ? combinedSummary
            ? { changelogSummary: combinedSummary }
            : {}
          : summaryByApp[id]
            ? { changelogSummary: summaryByApp[id] }
            : {}),
        // The AI short synopsis — persisted for the promote form's notes prefill.
        ...(selectedIds.length > 1
          ? combinedShort
            ? { changelogSummaryShort: combinedShort }
            : {}
          : shortByApp[id]
            ? { changelogSummaryShort: shortByApp[id] }
            : {}),
      };
    });
    const req: CreateMobileReleasesReq = {
      changeLog: changeLog.trim(),
      sourceRef: effSourceRef !== 'main' ? effSourceRef : null,
      items,
      destination: showDestination ? destination : null,
    };
    try {
      const resp = await createMutation.mutateAsync(req);
      toast.success(
        `Created ${resp.releases.length} release${resp.releases.length === 1 ? '' : 's'}`,
      );
      // Never build a group URL from a missing id: an empty id resolves to
      // /mobile/groups/ which redirects to the releases list, making create
      // look like a no-op. Fall back to the new release's own page.
      if (resp.releaseGroupId) {
        navigate(`/mobile/groups/${resp.releaseGroupId}`);
      } else if (resp.releases[0]?.id) {
        navigate(`/mobile/releases/${resp.releases[0].id}`);
      } else {
        navigate('/mobile/releases');
      }
    } catch (err: unknown) {
      const msg =
        (err as { response?: { data?: { message?: string } }; message?: string })?.response?.data
          ?.message ||
        (err as { message?: string })?.message ||
        'Failed to create mobile releases';
      // A duplicate-version error names one app; find which selected item
      // collided, look up where that build lives, and offer a jump to it.
      if (/already exists/i.test(msg)) {
        const lower = msg.toLowerCase();
        const collided = selectedIds
          .map((id) => {
            const app = enabledApps.find((a) => a.id === id);
            const v = versionEdits[id];
            if (!app || !v?.versionName.trim() || isFirebaseId(id)) return null;
            const code = app.platform === 'ios' ? '' : v.versionCode.trim();
            // Robust match: the error carries the app name AND the exact
            // version(+code), regardless of the exact phrasing/spacing.
            const ident = `${v.versionName.trim()}${code ? `+${code}` : ''}`.toLowerCase();
            const named = lower.includes(app.name.toLowerCase());
            return named && lower.includes(ident) ? { app, code } : null;
          })
          .find(Boolean);
        if (collided) {
          // Persistent in-page banner (no toast) — the message already tells the
          // operator to use a new build number or discard/promote the existing build.
          setConflict({ message: msg });
          return;
        }
      }
      toast.error(msg);
    }
  };

  return (
    // No trailing page padding: the sticky bar is the last element and its own
    // wrapper cancels <main>'s bottom padding so it never "detaches" at scroll end.
    <div className="flex flex-col flex-1 w-full">
      <form onSubmit={handleSubmit} className="space-y-4 sm:space-y-6 max-w-4xl">

        {/* Store versions shown below come from the on-demand cache; auto-refreshes
            on open when cold/stale so the base build per track is current. */}
        <StoreSyncBanner />

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
                {/* Selected apps as removable chips — the at-a-glance view while
                    the surface groups stay collapsed. × deselects that app. */}
                {selectedIds.length > 0 && (
                  <div className="flex flex-wrap items-center gap-1.5">
                    {selectedIds.map((id) => {
                      const a = enabledApps.find((x) => x.id === id);
                      if (!a) return null;
                      const name = (a.displayLabel || a.name).replace(/ (Android|iOS)\)$/i, ')');
                      return (
                        <span
                          key={id}
                          className="inline-flex items-center gap-1 h-7 pl-2.5 pr-1 rounded-full border border-violet-300 bg-violet-50 text-xs font-medium text-violet-900"
                        >
                          {a.platform === 'ios' ? (
                            <Apple className="w-3 h-3 text-violet-500" />
                          ) : (
                            <Cpu className="w-3 h-3 text-emerald-600" />
                          )}
                          <span className="truncate max-w-[180px]">{name}</span>
                          <button
                            type="button"
                            aria-label={`Remove ${name} (${a.platform})`}
                            title="Deselect"
                            onClick={() => toggleApp(id)}
                            className="inline-flex items-center justify-center w-5 h-5 rounded-full text-violet-500 hover:bg-violet-200 hover:text-violet-800 transition-colors"
                          >
                            <X className="w-3.5 h-3.5" />
                          </button>
                        </span>
                      );
                    })}
                    <button
                      type="button"
                      onClick={() => setSelectedIds([])}
                      className="text-[11px] font-medium text-zinc-400 hover:text-zinc-700 px-1"
                    >
                      Clear all
                    </button>
                  </div>
                )}
                {/* App search — filters the tiles below by name / surface / platform. */}
                <div className="relative">
                  <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-zinc-400 pointer-events-none" />
                  <input
                    type="text"
                    value={appSearch}
                    onChange={(e) => setAppSearch(e.target.value)}
                    onKeyDown={(e) => { if (e.key === 'Escape') setAppSearch(''); }}
                    placeholder="Search apps — name, surface, platform…"
                    className="w-full h-10 sm:h-9 border border-zinc-300 rounded-lg pl-9 pr-3 text-sm bg-white focus:outline-none focus:ring-2 focus:ring-zinc-400"
                  />
                </div>
                {visibleGroups.length === 0 ? (
                  <p className="px-1 py-6 text-center text-sm text-zinc-400">
                    No apps match “{appSearch.trim()}”.
                  </p>
                ) : visibleGroups.map((g) => {
                  const groupSel = g.apps.filter((a) => selectedIds.includes(a.id)).length;
                  return (
                    <CollapsibleGroup
                      key={g.key}
                      label={g.label}
                      count={g.apps.length}
                      open={appSearch.trim() ? true : isOpen(g.key)}
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
                                      'rounded-lg border px-3 py-2.5 transition-all',
                                      anySel
                                        ? 'border-violet-300 bg-violet-50/40 shadow-sm'
                                        : 'border-zinc-200 hover:border-zinc-300',
                                    )}
                                  >
                                    <div className="flex items-center justify-between gap-3">
                                      <div className="flex min-w-0 items-center gap-2">
                                        <BrandLogo
                                          brand={label}
                                          surface={g.key === 'driver' ? 'driver' : undefined}
                                          size="sm"
                                        />
                                        <div className="text-sm font-medium text-zinc-900 truncate">{label}</div>
                                      </div>
                                      {/* Platform toggles styled EXACTLY like the shared
                                          Button (sm): secondary when off, primary + ✓ when on. */}
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
                                                // (position:absolute) and must stay contained here, not
                                                // escape <main>'s overflow-y-auto via <html>.
                                                'relative inline-flex items-center justify-center rounded-lg font-medium cursor-pointer whitespace-nowrap select-none',
                                                'transition-colors duration-150 h-9 sm:h-8 px-3 text-[13px] gap-1.5',
                                                sel
                                                  ? 'bg-violet-50 text-violet-900 border border-violet-300 hover:bg-violet-100'
                                                  : 'bg-white text-zinc-700 border border-zinc-300 hover:bg-zinc-50 active:bg-zinc-100',
                                              )}
                                            >
                                              <input
                                                type="checkbox"
                                                checked={sel}
                                                onChange={() => toggleApp(app.id)}
                                                className="sr-only peer"
                                              />
                                              <span className="absolute inset-0 rounded-lg pointer-events-none peer-focus-visible:ring-2 peer-focus-visible:ring-zinc-400 peer-focus-visible:ring-offset-1" />
                                              {/* Checkbox square: the "this is a selection" cue. */}
                                              <span
                                                className={cn(
                                                  'flex items-center justify-center w-4 h-4 rounded-[4px] border-[1.5px] shrink-0 transition-colors',
                                                  sel ? 'bg-violet-600 border-violet-600' : 'bg-white border-zinc-400',
                                                )}
                                              >
                                                {sel && <Check className="w-3 h-3 text-white" strokeWidth={3.5} />}
                                              </span>
                                              {plat === 'ios' ? (
                                                <Apple className={cn('w-3.5 h-3.5', sel ? 'text-violet-700' : 'text-zinc-500')} />
                                              ) : (
                                                <Cpu className={cn('w-3.5 h-3.5', sel ? 'text-violet-700' : 'text-emerald-600')} />
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

        {/* ─── Source branch — one row, combobox always visible ── */}
        <section className="bg-white rounded-xl border border-zinc-200 px-4 py-2.5 sm:px-6">
          <div className="flex items-center gap-3 flex-wrap">
            <div
              className="flex items-center gap-2 text-sm shrink-0"
              title="Branch or tag the workflow will check out. Defaults to main."
            >
              <GitBranch className="w-4 h-4 text-zinc-500" />
              <span className="font-medium text-zinc-900">Source</span>
            </div>
            <div className="relative flex-1 min-w-[200px] max-w-sm" ref={branchContainerRef}>
              <div className="relative">
                <Search className="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-zinc-400 pointer-events-none" />
                <input
                  ref={branchInputRef}
                  type="text"
                  value={branchSearch}
                  aria-label="Source branch or tag"
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
                  placeholder="Search branch or tag…"
                  className="w-full h-8 border border-zinc-300 rounded-md pl-8 pr-8 text-xs font-mono bg-white focus:outline-none focus:ring-2 focus:ring-zinc-400"
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
                <ul className="absolute z-40 mt-1 w-full max-h-56 overflow-auto rounded-lg border border-zinc-200 bg-white shadow-lg">
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
            {effSourceRef !== 'main' && (
              <>
                <span className="inline-flex items-center gap-1 text-xs text-amber-700 shrink-0">
                  <AlertTriangle className="w-3.5 h-3.5" /> not main
                </span>
                <button
                  type="button"
                  onClick={() => {
                    // Focus first: the input's onFocus opens the dropdown, and
                    // our close below lands after it in the same batch.
                    branchInputRef.current?.focus();
                    setSourceRef('main');
                    setBranchSearch('main');
                    setBranchDropdownOpen(false);
                  }}
                  className="text-xs font-medium text-zinc-500 hover:text-zinc-800 shrink-0"
                >
                  Reset to main
                </button>
              </>
            )}
          </div>
        </section>

        {/* ─── Changelog preview (per-app tabs, release builds only) ── */}
        {!isDebug && changelogApps.length > 0 && (() => {
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
                {/* Multi-app: every app has its OWN base, so a single base line in
                    the header would lie. State the rule, then list each app's base. */}
                {changelogApps.length > 1 ? (
                  <div className="mt-1 space-y-0.5">
                    <p className="text-xs text-zinc-500">
                      Each app diffs from its own last{' '}
                      {changelogBase === 'production' ? 'prod' : 'internal'} release
                      {' → '}
                      <span className="font-mono text-zinc-700">{effSourceRef}</span>
                    </p>
                    {changelogApps.map((a, i) => {
                      const d = changelogQueries[i]?.data;
                      return (
                        <p key={`${a.name}-${a.surface}-${a.platform}`} className="text-xs text-zinc-500">
                          <span className="text-zinc-400">•</span>{' '}
                          <span className="font-medium text-zinc-600">{a.label}</span>
                          {': '}
                          {d?.cpBaseTag || d?.cpBaseVersion ? (
                            <>
                              <span className="font-mono text-zinc-700">{d.cpBaseTag || d.cpBaseVersion}</span>
                              <span className="ml-1.5 text-zinc-400">
                                ({d.cpAheadBy} commit{d.cpAheadBy === 1 ? '' : 's'})
                              </span>
                            </>
                          ) : (
                            <span className="text-zinc-400">
                              {changelogQueries[i]?.isLoading ? 'loading…' : 'no base found'}
                            </span>
                          )}
                        </p>
                      );
                    })}
                  </div>
                ) : q.data?.cpBaseVersion ? (
                  <p className="text-xs text-zinc-500 mt-1">
                    Base
                    <span className="text-zinc-400"> ({changelogBase === 'production' ? 'prod' : 'internal'})</span>
                    : <span className="font-mono text-zinc-700">
                      {q.data.cpBaseTag || q.data.cpBaseVersion}
                    </span>
                    {' → '}
                    <span className="font-mono text-zinc-700">{effSourceRef}</span>
                    {q.data.cpAheadBy > 0 && (
                      <span className="ml-1.5 text-zinc-400">
                        ({q.data.cpAheadBy} commit{q.data.cpAheadBy === 1 ? '' : 's'})
                      </span>
                    )}
                  </p>
                ) : null}
              </header>

              <div className="p-4 sm:p-6">
                {/* Opt-in for the post-build Slack changelog. Hidden for debug
                    builds (never posted) and when Slack is disabled in config;
                    enabled ONLY when a summary exists — a build with no comparable
                    base produces none, and we never post an empty changelog. */}
                {!isDebug && slackEnabled && (
                  <label
                    className={cn(
                      'mb-3 flex items-start gap-2 text-xs select-none',
                      hasChangelogSummary ? 'text-zinc-600 cursor-pointer' : 'text-zinc-400 cursor-not-allowed',
                    )}
                  >
                    <input
                      type="checkbox"
                      checked={sendChangelogSlack && hasChangelogSummary}
                      disabled={!hasChangelogSummary}
                      onChange={(e) => setSendChangelogSlack(e.target.checked)}
                      className="mt-0.5 h-3.5 w-3.5 rounded border-zinc-300 text-violet-600 focus:ring-violet-400 disabled:opacity-50"
                    />
                    <span>
                      Send changelog summary to Slack after build
                      <span className="block text-[11px] text-zinc-400">
                        {hasChangelogSummary
                          ? 'Posts once per release — one message for the whole group, after the builds finish.'
                          : 'Generate a changelog summary first — needs at least one app with a comparable last release.'}
                      </span>
                    </span>
                  </label>
                )}
                {changelogApps.length > 1 ? (
                  // Multi-app: ONE combined summary for the whole selection —
                  // common changes + labeled per-app extras; every app submits
                  // this same text. The per-app tabs below still browse commits.
                  <MobileChangelogAiSummary
                    combinedApps={changelogApps.map((a) => {
                      const v = versionEdits[a.id];
                      const version = v?.versionName.trim()
                        ? `v${v.versionName.trim()}${v.versionCode.trim() ? `+${v.versionCode.trim()}` : ''}`
                        : undefined;
                      return {
                        app: a.name,
                        surface: a.surface,
                        platform: a.platform,
                        version,
                      };
                    })}
                    branch={effSourceRef}
                    base={changelogBase}
                    defaultCollapsed
                    onSummary={(long, short) => {
                      setCombinedSummary(long);
                      if (short) setCombinedShort(short);
                    }}
                  />
                ) : q.data && q.data.cpCommits.length > 0 ? (
                  <MobileChangelogAiSummary
                    app={app.name}
                    surface={app.surface}
                    platform={app.platform}
                    branch={effSourceRef}
                    base={changelogBase}
                    versionName={versionEdits[app.id]?.versionName || ''}
                    versionCode={versionEdits[app.id]?.versionCode || ''}
                    defaultCollapsed
                    onSummary={(text, short) => {
                      setSummaryByApp((m) => (m[app.id] === text ? m : { ...m, [app.id]: text }));
                      if (short)
                        setShortByApp((m) => (m[app.id] === short ? m : { ...m, [app.id]: short }));
                    }}
                  />
                ) : null}

                {/* Per-app commit browser: the combined summary above is the
                    headline; these tabs are for digging into ONE app's diff,
                    each against its own base (shown under the tabs). */}
                {changelogApps.length > 1 && (
                  <div className="mt-4 mb-3">
                    <div className="text-[10px] font-semibold uppercase tracking-wider text-zinc-400 mb-1">
                      Per-app commits
                    </div>
                    <div role="tablist" className="flex gap-0 border-b border-zinc-100 overflow-x-auto">
                      {changelogApps.map((a, i) => (
                        <button
                          key={`${a.name}-${a.surface}-${a.platform}`}
                          type="button"
                          role="tab"
                          aria-selected={i === safeTab}
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
                    {q.data?.cpBaseVersion && (
                      <p className="text-xs text-zinc-500 mt-2">
                        Base for <span className="font-medium text-zinc-700">{app.label}</span>
                        <span className="text-zinc-400"> ({changelogBase === 'production' ? 'prod' : 'internal'})</span>
                        : <span className="font-mono text-zinc-700">
                          {q.data.cpBaseTag || q.data.cpBaseVersion}
                        </span>
                        {' → '}
                        <span className="font-mono text-zinc-700">{effSourceRef}</span>
                        {q.data.cpAheadBy > 0 && (
                          <span className="ml-1.5 text-zinc-400">
                            ({q.data.cpAheadBy} commit{q.data.cpAheadBy === 1 ? '' : 's'})
                          </span>
                        )}
                      </p>
                    )}
                  </div>
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
                      <button
                        type="button"
                        aria-expanded={commitsOpen}
                        onClick={() => setCommitsOpen((o) => !o)}
                        className="inline-flex items-center gap-1.5 text-xs font-medium text-zinc-600 hover:text-zinc-900"
                      >
                        <ChevronDown
                          className={cn('w-3.5 h-3.5 transition-transform', !commitsOpen && '-rotate-90')}
                        />
                        {commitsOpen
                          ? 'Hide commits'
                          : `Show ${commits.length} commit${commits.length === 1 ? '' : 's'}${q.data.cpAheadBy > commits.length ? ` of ${q.data.cpAheadBy}` : ''}`}
                      </button>
                      {commitsOpen && (
                      <>
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
                      <ul className="divide-y divide-zinc-100 max-h-56 overflow-y-auto rounded-md border border-zinc-100">
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
                      </>
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

                // Firebase build: no editable version — it's auto-generated per build.
                // Show a clear read-only row instead of inputs the operator shouldn't fill.
                if (isFirebaseId(id)) {
                  return (
                    <div
                      key={id}
                      className="rounded-lg border border-amber-200 bg-amber-50/50 px-3 py-2.5"
                    >
                      <div className="flex items-center justify-between gap-2">
                        <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider">
                          {app.displayLabel || app.name}
                          <span className="text-zinc-400 ml-1.5 normal-case font-normal tracking-normal">
                            ({app.surface} {app.platform})
                          </span>
                        </label>
                        <span className="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-amber-100 text-amber-800 border border-amber-200">
                          Firebase
                        </span>
                      </div>
                      <div className="mt-1.5 flex items-center gap-2 text-[12px] text-amber-800">
                        <AlertTriangle className="w-3.5 h-3.5 shrink-0" />
                        <span>
                          Auto version:{' '}
                          <code className="font-mono">{firebaseVersionPreview()}</code> — no input
                          needed.
                        </span>
                      </div>
                    </div>
                  );
                }

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
                        inputMode="decimal"
                        value={v.versionName}
                        // Version names are digits-and-dots only ("3.4.3") —
                        // strip anything else as it's typed/pasted.
                        onChange={(e) =>
                          setVersionField(id, 'versionName', e.target.value.replace(/[^0-9.]/g, ''))
                        }
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

        {/* ─── Provider Android destination (appears only when a driver
            Android app is selected on a release build) ── */}
        {showDestination && (
          <section className="bg-white rounded-xl border border-zinc-200 px-4 py-3 sm:px-6">
            <div className="flex items-center justify-between gap-3 flex-wrap">
              <div className="min-w-0">
                <div className="text-sm font-medium text-zinc-900">Provider Android destination</div>
                <p className="text-[11px] text-zinc-500 mt-0.5">
                  Where the provider (driver) Android prod build is published. iOS
                  and consumer apps in this release ignore it.
                </p>
              </div>
              <div className="relative w-full sm:w-64 shrink-0">
                <select
                  value={destination}
                  onChange={(e) => setDestination(e.target.value as MobileDestination)}
                  aria-label="Provider Android destination"
                  className="w-full h-10 sm:h-9 appearance-none border border-zinc-300 rounded-lg pl-3 pr-9 text-sm bg-white focus:outline-none focus:ring-2 focus:ring-zinc-400"
                >
                  <option value="GooglePlay">Google Play</option>
                  <option value="Firebase">Firebase App Distribution</option>
                </select>
                <ChevronDown className="absolute right-2.5 top-1/2 -translate-y-1/2 w-4 h-4 text-zinc-400 pointer-events-none" />
              </div>
            </div>
            {destination === 'Firebase' && (
              <div className="mt-3 flex items-start gap-2 rounded-md border border-amber-200 bg-amber-50 px-3 py-2">
                <AlertTriangle className="w-3.5 h-3.5 text-amber-600 mt-0.5 shrink-0" />
                <p className="text-[11px] text-amber-800 leading-relaxed">
                  Firebase builds don’t go to the Play Store — each gets an{' '}
                  <span className="font-medium">auto-generated unique version</span> (shown in
                  the Versions section above). No version or code is needed.
                </p>
              </div>
            )}
          </section>
        )}

        {/* ─── Workflow changelog ───────────────────── */}
        <section className="bg-white rounded-xl border border-zinc-200 mb-4 sm:mb-6">
          <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100">
            <h2 className="text-base sm:text-lg font-semibold text-zinc-900">
              Workflow changelog
            </h2>
            <p className="text-xs text-zinc-500 mt-0.5">
              Passed to the build workflow. Replace the default if you want real notes.
            </p>
          </header>
          <div className="p-4 sm:p-6">
            <Textarea
              value={changeLog}
              onChange={(e) => setChangeLog(e.target.value)}
              placeholder="Describe what's in this release…"
              rows={1}
              required
            />
          </div>
        </section>

        {/* ─── Sticky summary bar: what will happen + the CTA, always visible.
            Replaces the old Build-type card (env-locked chip lives here) and
            the bottom Actions row. Validation reason shows BEFORE submit. ── */}
        <div className="sticky bottom-0 z-30 pt-1 pb-3 -mb-4 sm:-mb-5">
          {/* Duplicate-version conflict from the last submit — the message says
              to use a new build number or discard/promote the existing build. */}
          {conflict && (
            <div className="mb-2 rounded-xl border border-red-200 bg-red-50 px-4 py-3 shadow-sm flex flex-col sm:flex-row sm:items-center gap-2.5">
              <div className="flex items-start gap-2 min-w-0 flex-1">
                <AlertTriangle className="w-4 h-4 text-red-500 mt-0.5 shrink-0" />
                <p className="text-xs text-red-800 leading-relaxed">{conflict.message}</p>
              </div>
              <button
                type="button"
                onClick={() => setConflict(null)}
                className="text-xs font-medium text-red-600 hover:text-red-800 px-1 shrink-0"
              >
                Dismiss
              </button>
            </div>
          )}
          <div className="rounded-xl border border-zinc-200 bg-white/95 backdrop-blur px-4 py-3 shadow-[0_-6px_24px_-12px_rgba(0,0,0,0.25)] flex flex-col sm:flex-row sm:items-center gap-2.5 sm:gap-4">
            <div className="flex items-center gap-2.5 min-w-0 flex-1">
              <span
                className={cn(
                  'inline-flex items-center px-2 py-0.5 rounded text-[11px] font-medium border shrink-0',
                  buildType === 'debug'
                    ? 'bg-amber-50 text-amber-700 border-amber-200'
                    : 'bg-emerald-50 text-emerald-700 border-emerald-200',
                )}
              >
                {buildType === 'debug' ? 'Debug' : 'Release'}
              </span>
              <div className="min-w-0">
                <div className="text-sm font-medium text-zinc-900 truncate">
                  {selectedIds.length === 0
                    ? 'No apps selected'
                    : `${selectedIds.length} app${selectedIds.length === 1 ? '' : 's'} selected`}
                  {effSourceRef !== 'main' && (
                    <span className="font-normal text-amber-700">
                      {' '}· from <code className="font-mono">{effSourceRef}</code>
                    </span>
                  )}
                </div>
                {/* Destinations show as soon as apps are selected — not only once
                    the whole form validates. Reasons may wrap; never clipped. */}
                <div className="text-xs mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-0.5">
                  {uploadTargets.length > 0 && (
                    <span className="text-zinc-500">
                      Builds upload to {uploadTargets.join(' and ')}
                    </span>
                  )}
                  {!validation.ok &&
                    (selectedIds.length === 0 ? (
                      <span className="text-zinc-500">{validation.reason}</span>
                    ) : (
                      <span className="inline-flex items-center gap-1 text-amber-700">
                        <AlertTriangle className="w-3.5 h-3.5 shrink-0" />
                        {validation.reason}
                      </span>
                    ))}
                </div>
              </div>
            </div>
            <div className="flex items-center justify-end gap-2 shrink-0">
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
          </div>
        </div>
      </form>
    </div>
  );
}
