import React, { useEffect, useRef, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import {
  Undo2,
  AlertTriangle,
  ChevronRight as ChevronRightIcon,
  ArrowLeft,
  ExternalLink,
  Smartphone,
  Tag,
  GitCommit,
  GitBranch,
  Hash,
  Calendar,
  Store,
  Info,
  CheckCircle2,
  Loader2,
  Search,
  ChevronDown,
} from 'lucide-react';
import { cn } from '../../../../lib/utils';
import { Button } from '../../../../shared/ui/button';
import { Input } from '../../../../shared/ui/input';
import { CardSkeleton } from '../../../../shared/ui/skeleton';
import {
  createMobileRevert,
  getMobileRevertDraft,
  verifyRevertCommit,
  type RevertDraft,
  type VerifyCommitResp,
} from '../../api';
import { useMobileBranches } from '../../hooks';
import type { BranchInfo } from '../../types';

/**
 * Mobile-release Revert page.
 *
 * Full-page version of what used to be `RevertModal`. Reachable from:
 *   - The "Revert" button on the release detail page.
 *   - The "Revert" action icon in the releases list.
 *
 * Routing: `/mobile/releases/:id/revert` (mobile releases only — backend
 * releases use a different revert mechanism).
 *
 * The page loads a draft from the BE, seeds editable fields with
 * server-suggested defaults, validates client-side (server re-validates
 * regardless), and on submit creates a new release row + navigates to
 * its detail page.
 */
const MobileRevert: React.FC = () => {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const qc = useQueryClient();

  const {
    data: draft,
    isLoading,
    error,
    isFetching,
    refetch,
  } = useQuery<RevertDraft, Error>({
    queryKey: ['mobile-revert-draft', id],
    queryFn: () => getMobileRevertDraft(id!),
    enabled: !!id,
    retry: false,
    staleTime: 0,
  });

  // Editable form fields, seeded from the draft.
  const [versionName, setVersionName] = useState('');
  const [versionCode, setVersionCode] = useState('');
  const [changelog, setChangelog] = useState('');
  const [sourceMode, setSourceMode] = useState<'prevGood' | 'customCommit'>('prevGood');
  const [customInputMode, setCustomInputMode] = useState<'sha' | 'branch'>('sha');
  const [customCommit, setCustomCommit] = useState('');
  const [verifiedCommit, setVerifiedCommit] = useState<VerifyCommitResp | null>(null);

  // Branch search state
  const [branchSearch, setBranchSearch] = useState('');
  const [debouncedBranchSearch, setDebouncedBranchSearch] = useState('');
  const [branchDropdownOpen, setBranchDropdownOpen] = useState(false);
  const branchInputRef = useRef<HTMLInputElement>(null);
  const branchContainerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const t = setTimeout(() => setDebouncedBranchSearch(branchSearch.trim()), 300);
    return () => clearTimeout(t);
  }, [branchSearch]);

  const { data: branchesData, isLoading: branchesLoading } = useMobileBranches(
    sourceMode === 'customCommit' && customInputMode === 'branch'
      ? debouncedBranchSearch || undefined
      : undefined,
  );
  const filteredBranches: BranchInfo[] = branchesData ?? [];

  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (branchContainerRef.current && !branchContainerRef.current.contains(e.target as Node)) {
        setBranchDropdownOpen(false);
      }
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, []);

  const pendingVerifyRef = useRef<string | null>(null);

  const verifyMut = useMutation({
    mutationFn: () => {
      const ref = pendingVerifyRef.current ?? customCommit.trim();
      pendingVerifyRef.current = null;
      return verifyRevertCommit(id!, ref);
    },
    onSuccess: (resp) => {
      setVerifiedCommit(resp);
      setCustomCommit(resp.vcFullSha);
      toast.success(`Commit verified: ${resp.vcShortSha}`);
    },
    onError: (err: any) => {
      setVerifiedCommit(null);
      const msg = err?.response?.data?.message || err?.message || 'Commit not found';
      toast.error(msg);
    },
  });

  useEffect(() => {
    if (!draft) return;
    setVersionName(draft.rdSuggestedVersion);
    setVersionCode(draft.rdSuggestedCode != null ? String(draft.rdSuggestedCode) : '');
    setChangelog(draft.rdChangelog);
  }, [draft]);

  const isAndroid = draft?.rdPlatform === 'android';
  const badCode = draft?.rdBadVersionCode ?? null;
  const storeCode = draft?.rdStoreVersionCode ?? null;
  const floorCode = badCode != null && storeCode != null
    ? Math.max(badCode, storeCode)
    : badCode ?? storeCode;
  const codeAsInt = versionCode === '' ? null : Number(versionCode);

  const validationError: string | null = (() => {
    if (!draft) return null;
    if (!versionName.trim()) return 'Version name is required';
    if (versionName === draft.rdBadVersion) return 'Version name must differ from the bad release';
    if (isAndroid) {
      if (codeAsInt == null || !Number.isFinite(codeAsInt))
        return 'Version code is required for Android';
      if (floorCode != null && codeAsInt <= floorCode)
        return `Version code must be strictly greater than ${floorCode}`;
    }
    if (!changelog.trim()) return 'Changelog cannot be empty';
    if (sourceMode === 'customCommit') {
      const trimmed = customCommit.trim();
      if (!trimmed) return customInputMode === 'sha'
        ? 'Commit SHA is required when using custom commit'
        : 'Select a branch to build from';
      if (customInputMode === 'sha' && !/^[0-9a-f]{7,40}$/i.test(trimmed))
        return 'Commit SHA must be 7–40 hex characters';
      if (!verifiedCommit || verifiedCommit.vcFullSha !== trimmed)
        return customInputMode === 'sha'
          ? 'Please verify the commit SHA before creating the revert'
          : 'Please verify the branch before creating the revert';
    }
    return null;
  })();

  const createMut = useMutation({
    mutationFn: () =>
      createMobileRevert(id!, {
        rrNewVersionName: versionName.trim(),
        rrNewVersionCode: isAndroid ? codeAsInt : null,
        rrChangelog: changelog,
        rrSourceCommit: sourceMode === 'customCommit' ? customCommit.trim() : null,
      }),
    onSuccess: (resp) => {
      toast.success('Revert release created. Approve it to dispatch the rebuild.');
      qc.invalidateQueries({ queryKey: ['release', id] });
      qc.invalidateQueries({ queryKey: ['releases'] });
      navigate(`/mobile/releases/${resp.rrRevertReleaseId}`);
    },
    onError: (err: any) => {
      const msg =
        err?.response?.data?.message || err?.message || 'Failed to create revert release';
      toast.error(msg);
    },
  });

  // ── Header crumbs ──────────────────────────────────────────────
  const crumbs = (
    <div className="flex items-center text-sm text-zinc-500 font-medium mb-3 sm:mb-4 flex-wrap gap-y-1">
      <Link to="/mobile/releases" className="hover:text-zinc-700 transition-colors">
        Releases
      </Link>
      <ChevronRightIcon className="w-4 h-4 mx-1 text-zinc-300 shrink-0" />
      <Link
        to={`/mobile/releases/${id}`}
        className="font-mono text-xs hover:text-zinc-700 transition-colors truncate max-w-[200px]"
      >
        {id}
      </Link>
      <ChevronRightIcon className="w-4 h-4 mx-1 text-zinc-300 shrink-0" />
      <span className="text-zinc-700">Revert</span>
    </div>
  );

  // ── Loading state ──────────────────────────────────────────────
  if (isLoading) {
    return (
      <div className="flex flex-col flex-1 w-full pb-12">
        {crumbs}
        <div className="max-w-4xl space-y-4">
          <CardSkeleton />
          <CardSkeleton />
        </div>
      </div>
    );
  }

  // ── Error state ────────────────────────────────────────────────
  if (error || !draft) {
    const msg =
      (error as any)?.response?.data?.message ||
      error?.message ||
      'Could not load revert preview.';
    return (
      <div className="flex flex-col flex-1 w-full pb-12">
        {crumbs}
        <div className="max-w-2xl">
          <div className="rounded-xl border border-red-200 bg-red-50 p-6">
            <div className="flex items-start gap-3">
              <AlertTriangle className="w-5 h-5 mt-0.5 shrink-0 text-red-600" />
              <div className="flex-1">
                <h2 className="text-base font-semibold text-red-900">Cannot prepare revert</h2>
                <p className="mt-1 text-sm text-red-800 leading-relaxed">{msg}</p>
                <p className="mt-3 text-xs text-red-700">
                  Common causes: no previous SCC-dispatched release exists for this app, or the
                  previous release's tag has been deleted from the repo. You can ship a fresh
                  release from the New Release flow instead.
                </p>
              </div>
            </div>
            <div className="mt-5 flex gap-2">
              <Button variant="outline" onClick={() => refetch()}>
                Retry
              </Button>
              <Button
                variant="primary"
                className="bg-violet-600 hover:bg-violet-700 text-white"
                onClick={() => navigate('/mobile/releases/new')}
              >
                Create new release instead
              </Button>
              <Button
                variant="secondary"
                onClick={() => navigate(`/mobile/releases/${id}`)}
              >
                <ArrowLeft className="w-4 h-4" /> Back to release
              </Button>
            </div>
          </div>
        </div>
      </div>
    );
  }

  // ── Success: render the form ───────────────────────────────────
  return (
    <div className="flex flex-col flex-1 w-full pb-12">
      {crumbs}

      <div className="flex items-center gap-2 sm:gap-3 mb-2">
        <Undo2 className="w-6 h-6 text-violet-600" />
        <h1 className="text-lg sm:text-xl font-semibold text-zinc-900">Revert release</h1>
      </div>
      <p className="text-sm text-zinc-600 max-w-3xl mb-4">
        Rebuild the previous good code under a new, higher version. Play Store and App Store
        require monotonically-increasing version codes, so a revert isn't "ship the old version
        again" — it's the previous good binary wrapped as a fresh release.
      </p>

      {draft.rdIsStoreSyncRevert && (
        <div className="rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm mb-4 max-w-6xl">
          <div className="flex items-start gap-3">
            <Store className="w-5 h-5 shrink-0 mt-0.5 text-amber-600" />
            <div className="flex-1">
              <div className="font-semibold text-amber-900">Reverting a store-synced release</div>
              <p className="mt-1 text-amber-800 text-xs leading-relaxed">
                This release was imported from the store API (not dispatched through SCC). The
                revert will build from the most recent SCC-dispatched release's tag.
                {draft.rdCommits.length === 0
                  ? ' No commit diff is available since the store release has no associated Git tag.'
                  : ` ${draft.rdCommitCount} commits detected between the two releases.`}
              </p>
            </div>
          </div>
        </div>
      )}

      {(draft.rdStoreVersion || draft.rdStoreVersionCode != null) && (
        <div className="rounded-lg border border-blue-100 bg-blue-50 px-4 py-3 text-xs text-blue-900 mb-4 max-w-6xl flex items-center gap-2">
          <Info className="w-4 h-4 shrink-0 text-blue-600" />
          <span>
            Current live store version: <strong className="font-mono">v{draft.rdStoreVersion}</strong>
            {draft.rdStoreVersionCode != null && (
              <span> (code <strong className="font-mono">{draft.rdStoreVersionCode}</strong>)</span>
            )}
            {isAndroid && draft.rdStoreVersionCode != null && (
              <span className="text-blue-700"> — suggested version code accounts for this.</span>
            )}
          </span>
        </div>
      )}

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4 sm:gap-6 max-w-6xl">
        {/* ─── Summary card (left, spans 2 cols on lg) ──────────── */}
        <section className="lg:col-span-2 bg-white rounded-xl border border-zinc-200">
          <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100">
            <h2 className="text-base sm:text-lg font-semibold text-zinc-900">Revert details</h2>
            <p className="text-xs text-zinc-500 mt-0.5">
              Server-suggested defaults — override version or notes as needed.
            </p>
          </header>

          <div className="p-4 sm:p-6 space-y-5">
            {/* Source/target summary */}
            <div className="rounded-lg border border-violet-100 bg-violet-50 p-4 text-sm">
              <div className="flex items-start gap-3">
                <Smartphone className="w-5 h-5 shrink-0 mt-0.5 text-violet-600" />
                <div className="flex-1 space-y-2">
                  <div className="text-violet-900 font-medium">
                    Reverting v{draft.rdBadVersion}
                    {draft.rdBadVersionCode != null && (
                      <span className="text-violet-700 font-normal"> (code {draft.rdBadVersionCode})</span>
                    )}
                    {' → '}
                    rebuilding from v{draft.rdPrevGoodVersion}
                  </div>
                  <div className="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-1.5 text-xs text-violet-900/80">
                    <div className="flex items-center gap-1.5">
                      <Tag className="w-3.5 h-3.5" />
                      <span className="font-mono text-[11px]">{draft.rdPrevGoodTag}</span>
                    </div>
                    <div className="flex items-center gap-1.5">
                      <GitCommit className="w-3.5 h-3.5" />
                      <span className="font-mono text-[11px]">{draft.rdPrevGoodShortSha}</span>
                    </div>
                    <div className="flex items-center gap-1.5">
                      <Hash className="w-3.5 h-3.5" />
                      <span className="capitalize">{draft.rdPlatform}</span>
                    </div>
                    <div className="flex items-center gap-1.5">
                      <Calendar className="w-3.5 h-3.5" />
                      <span>
                        {draft.rdIsStoreSyncRevert && draft.rdCommitCount === 0
                          ? 'Store-synced release (no commit diff)'
                          : `${draft.rdCommitCount} commits being rolled back`}
                      </span>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            {/* Build source selector */}
            <div>
              <label className="block text-xs font-semibold text-zinc-700 uppercase tracking-wider mb-2">
                Build source
              </label>
              <div className="space-y-2">
                <label className={`flex items-start gap-3 rounded-lg border p-3 cursor-pointer transition-colors ${sourceMode === 'prevGood' ? 'border-violet-300 bg-violet-50' : 'border-zinc-200 hover:bg-zinc-50'}`}>
                  <input
                    type="radio"
                    name="sourceMode"
                    checked={sourceMode === 'prevGood'}
                    onChange={() => setSourceMode('prevGood')}
                    className="mt-0.5 accent-violet-600"
                  />
                  <div className="flex-1 min-w-0">
                    <div className="text-sm font-medium text-zinc-900">Previous good release</div>
                    <div className="text-xs text-zinc-500 mt-0.5">
                      Build from <code className="font-mono text-[11px] bg-zinc-100 px-1 rounded">{draft.rdPrevGoodTag}</code>
                      {' '}(v{draft.rdPrevGoodVersion}, commit {draft.rdPrevGoodShortSha})
                    </div>
                  </div>
                </label>
                <label className={`flex items-start gap-3 rounded-lg border p-3 cursor-pointer transition-colors ${sourceMode === 'customCommit' ? 'border-violet-300 bg-violet-50' : 'border-zinc-200 hover:bg-zinc-50'}`}>
                  <input
                    type="radio"
                    name="sourceMode"
                    checked={sourceMode === 'customCommit'}
                    onChange={() => setSourceMode('customCommit')}
                    className="mt-0.5 accent-violet-600"
                  />
                  <div className="flex-1 min-w-0">
                    <div className="text-sm font-medium text-zinc-900">Custom source</div>
                    <div className="text-xs text-zinc-500 mt-0.5">
                      Build from a specific commit SHA or a branch
                    </div>
                    {sourceMode === 'customCommit' && (
                      <div className="mt-2 space-y-2">
                        {/* SHA / Branch toggle */}
                        <div className="flex gap-1 rounded-lg bg-zinc-100 p-0.5 w-fit">
                          <button
                            type="button"
                            onClick={() => {
                              setCustomInputMode('sha');
                              setVerifiedCommit(null);
                              setCustomCommit('');
                            }}
                            className={cn(
                              'flex items-center gap-1.5 rounded-md px-3 py-1 text-xs font-medium transition-colors',
                              customInputMode === 'sha'
                                ? 'bg-white text-zinc-900 shadow-sm'
                                : 'text-zinc-500 hover:text-zinc-700',
                            )}
                          >
                            <Hash className="w-3 h-3" /> Commit SHA
                          </button>
                          <button
                            type="button"
                            onClick={() => {
                              setCustomInputMode('branch');
                              setVerifiedCommit(null);
                              setCustomCommit('');
                              setBranchSearch('');
                            }}
                            className={cn(
                              'flex items-center gap-1.5 rounded-md px-3 py-1 text-xs font-medium transition-colors',
                              customInputMode === 'branch'
                                ? 'bg-white text-zinc-900 shadow-sm'
                                : 'text-zinc-500 hover:text-zinc-700',
                            )}
                          >
                            <GitBranch className="w-3 h-3" /> Branch
                          </button>
                        </div>

                        {customInputMode === 'sha' ? (
                          <>
                            <div className="flex items-center gap-2">
                              <Input
                                value={customCommit}
                                onChange={(e) => {
                                  setCustomCommit(e.target.value);
                                  if (verifiedCommit && verifiedCommit.vcFullSha !== e.target.value.trim())
                                    setVerifiedCommit(null);
                                }}
                                placeholder="e.g. a1b2c3d4e5f6..."
                                className="max-w-md font-mono text-sm"
                              />
                              <Button
                                variant="outline"
                                size="sm"
                                disabled={!customCommit.trim() || !/^[0-9a-f]{7,40}$/i.test(customCommit.trim()) || verifyMut.isPending}
                                onClick={() => verifyMut.mutate()}
                              >
                                {verifyMut.isPending ? (
                                  <><Loader2 className="w-3.5 h-3.5 animate-spin" /> Verifying</>
                                ) : (
                                  'Verify'
                                )}
                              </Button>
                            </div>
                            <p className="text-[11px] text-zinc-400">
                              {verifiedCommit
                                ? 'Commit verified. A temporary tag will be created at this commit for the build.'
                                : 'Enter a SHA and click Verify to confirm it exists in the repo.'}
                            </p>
                          </>
                        ) : (
                          <>
                            <div className="relative" ref={branchContainerRef}>
                              <div className="relative">
                                <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-zinc-400 pointer-events-none" />
                                <input
                                  ref={branchInputRef}
                                  type="text"
                                  value={branchSearch}
                                  onChange={(e) => {
                                    setBranchSearch(e.target.value);
                                    setBranchDropdownOpen(true);
                                    setVerifiedCommit(null);
                                    setCustomCommit('');
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
                                        setBranchSearch(pick.name);
                                        setCustomCommit(pick.name);
                                        setBranchDropdownOpen(false);
                                        pendingVerifyRef.current = pick.name;
                                        verifyMut.mutate();
                                      }
                                    }
                                  }}
                                  placeholder="Search branch…"
                                  className="w-full h-9 border border-zinc-300 rounded-lg pl-9 pr-8 text-sm font-mono bg-white focus:outline-none focus:ring-2 focus:ring-zinc-400 max-w-md"
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
                                <ul className="absolute z-20 mt-1 w-full max-w-md max-h-56 overflow-auto rounded-lg border border-zinc-200 bg-white shadow-lg">
                                  {branchesLoading ? (
                                    <li className="px-3 py-2 text-sm text-zinc-400">Loading branches…</li>
                                  ) : filteredBranches.length === 0 ? (
                                    <li className="px-3 py-2 text-sm text-zinc-500">
                                      {branchSearch.trim()
                                        ? 'No matching branches'
                                        : 'Type to search branches'}
                                    </li>
                                  ) : (
                                    filteredBranches.map((b) => (
                                      <li
                                        key={b.name}
                                        onMouseDown={(e) => {
                                          e.preventDefault();
                                          setBranchSearch(b.name);
                                          setCustomCommit(b.name);
                                          setBranchDropdownOpen(false);
                                          setVerifiedCommit(null);
                                          pendingVerifyRef.current = b.name;
                                          verifyMut.mutate();
                                        }}
                                        className="px-3 py-2 text-sm font-mono cursor-pointer hover:bg-zinc-50"
                                      >
                                        {b.name}
                                      </li>
                                    ))
                                  )}
                                </ul>
                              )}
                            </div>
                            <p className="text-[11px] text-zinc-400">
                              {verifiedCommit
                                ? 'Branch resolved. The build will use the latest commit on this branch.'
                                : 'Select a branch to resolve its HEAD commit.'}
                            </p>
                          </>
                        )}

                        {verifiedCommit && (
                          <div className="flex items-start gap-2 rounded-md border border-green-200 bg-green-50 px-3 py-2 text-xs text-green-900">
                            <CheckCircle2 className="w-4 h-4 shrink-0 mt-0.5 text-green-600" />
                            <div className="flex-1 min-w-0">
                              <div className="font-medium truncate">{verifiedCommit.vcMessage}</div>
                              <div className="flex items-center gap-2 mt-0.5 text-green-700">
                                <span className="font-mono">{verifiedCommit.vcShortSha}</span>
                                <span>by @{verifiedCommit.vcAuthor}</span>
                                <a
                                  href={verifiedCommit.vcHtmlUrl}
                                  target="_blank"
                                  rel="noopener"
                                  className="inline-flex items-center gap-0.5 hover:underline"
                                >
                                  View <ExternalLink className="w-3 h-3" />
                                </a>
                              </div>
                            </div>
                          </div>
                        )}
                      </div>
                    )}
                  </div>
                </label>
              </div>
            </div>

            {/* Editable: version name */}
            <div>
              <label className="block text-xs font-semibold text-zinc-700 uppercase tracking-wider mb-1.5">
                New version name
              </label>
              <Input
                value={versionName}
                onChange={(e) => setVersionName(e.target.value)}
                placeholder={draft.rdSuggestedVersion}
                className="max-w-xs font-mono"
              />
              <p className="mt-1.5 text-xs text-zinc-500">
                Must differ from the bad release (v{draft.rdBadVersion}). Default bumps the patch
                component.
              </p>
            </div>

            {/* Editable: version code (Android only) */}
            {isAndroid && (
              <div>
                <label className="block text-xs font-semibold text-zinc-700 uppercase tracking-wider mb-1.5">
                  New version code
                </label>
                <Input
                  type="number"
                  inputMode="numeric"
                  value={versionCode}
                  onChange={(e) => setVersionCode(e.target.value)}
                  placeholder={
                    draft.rdSuggestedCode != null ? String(draft.rdSuggestedCode) : ''
                  }
                  min={floorCode != null ? floorCode + 1 : undefined}
                  className="max-w-xs font-mono"
                />
                <p className="mt-1.5 text-xs text-zinc-500">
                  Play Store requires strictly increasing codes.{' '}
                  {floorCode != null && `Must be > ${floorCode}.`}
                  {storeCode != null && badCode != null && storeCode > badCode && (
                    <span className="text-amber-600"> Store version code ({storeCode}) is higher than the bad release.</span>
                  )}
                </p>
              </div>
            )}

            {!isAndroid && (
              <div className="rounded-lg border border-blue-100 bg-blue-50 px-4 py-3 text-xs text-blue-900">
                <strong className="font-semibold">iOS:</strong> the build number is auto-computed
                by fastlane (<code className="font-mono text-[11px]">fetch_build_number</code>) at
                build time — no input needed here.
              </div>
            )}

            {/* Commits being rolled back */}
            <div>
              <div className="flex items-center justify-between mb-2">
                <label className="block text-xs font-semibold text-zinc-700 uppercase tracking-wider">
                  {draft.rdIsStoreSyncRevert && draft.rdCommits.length === 0 ? 'Build source' : 'Commits being rolled back'}
                </label>
                {draft.rdCommits.length > 0 && (
                  <span className="text-[11px] text-zinc-500">
                    {draft.rdCommitCount} from v{draft.rdBadVersion}
                  </span>
                )}
              </div>

              {draft.rdIsStoreSyncRevert && draft.rdCommits.length === 0 ? (
                <div className="rounded-md border border-amber-100 bg-amber-50 px-4 py-4 text-xs text-amber-900">
                  <p className="font-medium">This release was synced from the store API.</p>
                  <p className="mt-1 text-amber-800">
                    No Git commit diff is available. The revert will rebuild from the last
                    SCC-dispatched release: <strong className="font-mono">v{draft.rdPrevGoodVersion}</strong>{' '}
                    (tag: <code className="font-mono text-[11px]">{draft.rdPrevGoodTag}</code>).
                  </p>
                </div>
              ) : draft.rdCommits.length === 0 ? (
                <div className="rounded-md border border-zinc-200 bg-zinc-50 px-4 py-6 text-center text-xs text-zinc-500 italic">
                  No commit differences detected between v{draft.rdPrevGoodVersion} and v
                  {draft.rdBadVersion}.
                </div>
              ) : (
                <div className="border border-zinc-200 rounded-md bg-white">
                  <div className="flex items-center justify-between text-[11px] text-zinc-400 px-3 py-1.5 border-b border-zinc-100">
                    <span>Newest first</span>
                    {draft.rdCommitCount > draft.rdCommits.length && (
                      <span>Showing {draft.rdCommits.length} of {draft.rdCommitCount}</span>
                    )}
                  </div>
                  <ul className="divide-y divide-zinc-100 max-h-80 overflow-y-auto">
                    {[...draft.rdCommits].reverse().map((c, i) => (
                      <li key={c.rcShortSha} className="flex items-center gap-2.5 px-3 py-2">
                        <span className="text-[10px] text-zinc-300 w-4 text-right shrink-0 tabular-nums">{i + 1}</span>
                        <img
                          src={`https://github.com/${c.rcAuthorLogin}.png?size=40`}
                          alt={c.rcAuthorLogin}
                          className="w-5 h-5 rounded-full shrink-0 bg-zinc-100"
                          loading="lazy"
                          onError={(e) => { (e.target as HTMLImageElement).style.display = 'none'; }}
                        />
                        <a
                          href={c.rcHtmlUrl}
                          target="_blank"
                          rel="noopener noreferrer"
                          className="font-mono text-[11px] text-blue-600 hover:text-blue-800 hover:underline shrink-0"
                        >
                          {c.rcShortSha}
                        </a>
                        <span className="text-sm text-zinc-800 min-w-0 truncate flex-1">
                          {c.rcSubject}
                        </span>
                        {c.rcPrNumber != null && (
                          <a
                            href={c.rcHtmlUrl.replace(/\/commit\/.*$/, `/pull/${c.rcPrNumber}`)}
                            target="_blank"
                            rel="noopener noreferrer"
                            className="text-[11px] text-blue-600 hover:text-blue-800 hover:underline shrink-0"
                          >
                            #{c.rcPrNumber}
                          </a>
                        )}
                        <span className="text-[11px] text-zinc-400 shrink-0 max-w-[100px] truncate text-right">{c.rcAuthorLogin}</span>
                      </li>
                    ))}
                  </ul>
                  {(() => {
                    const first = draft.rdCommits[0];
                    if (!first) return null;
                    const repoUrl = first.rcHtmlUrl.replace(/\/commit\/.*$/, '');
                    const head = draft.rdCommits[draft.rdCommits.length - 1].rcShortSha;
                    const compareUrl = `${repoUrl}/compare/${encodeURIComponent(draft.rdPrevGoodTag)}...${head}`;
                    return (
                      <div className="px-3 py-2 border-t border-zinc-100">
                        <a
                          href={compareUrl}
                          target="_blank"
                          rel="noopener noreferrer"
                          className="inline-flex items-center gap-1 text-xs text-blue-600 hover:text-blue-800 hover:underline"
                        >
                          View full diff on GitHub <ExternalLink className="w-3 h-3" />
                        </a>
                      </div>
                    );
                  })()}
                </div>
              )}
            </div>

            {/* Release notes — single-line message of the form
                "Revert v{badVer}: sha1, sha2, ...". Pre-filled by the
                BE; operator can append or override. Sent to the GH
                Actions workflow as `change_log`. */}
            <div>
              <label className="block text-xs font-semibold text-zinc-700 uppercase tracking-wider mb-1.5">
                Release notes
              </label>
              <Input
                value={changelog}
                onChange={(e) => setChangelog(e.target.value)}
                placeholder="Revert v… : commit ids"
                className="font-mono text-sm"
              />
              <p className="mt-1.5 text-xs text-zinc-500">
                Single-line summary sent to the GH Actions workflow as{' '}
                <code className="font-mono">change_log</code>.
              </p>
            </div>
          </div>
        </section>

        {/* ─── Action card (right, sticky-ish on lg) ────────────── */}
        <aside className="lg:col-span-1">
          <div className="bg-white rounded-xl border border-zinc-200 lg:sticky lg:top-4">
            <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100">
              <h2 className="text-sm font-semibold text-zinc-900">Confirm revert</h2>
            </header>
            <div className="p-4 sm:p-6 space-y-3">
              <dl className="text-xs space-y-2">
                <div className="flex justify-between gap-2">
                  <dt className="text-zinc-500">Will ship as</dt>
                  <dd className="font-mono font-medium text-zinc-900">
                    v{versionName || '?'}
                    {isAndroid && versionCode && ` (code ${versionCode})`}
                  </dd>
                </div>
                <div className="flex justify-between gap-2">
                  <dt className="text-zinc-500">Built from</dt>
                  <dd className="font-mono text-zinc-700">
                    {sourceMode === 'customCommit' && customCommit.trim()
                      ? customCommit.trim().slice(0, 7)
                      : draft.rdPrevGoodShortSha}
                  </dd>
                </div>
                {sourceMode === 'customCommit' && customCommit.trim() && (
                  <div className="flex justify-between gap-2">
                    <dt className="text-zinc-500">Source</dt>
                    <dd className="text-amber-700 text-[11px] font-medium">
                      {customInputMode === 'branch' && branchSearch.trim()
                        ? <>Branch: <span className="font-mono">{branchSearch.trim()}</span></>
                        : 'Custom commit'}
                    </dd>
                  </div>
                )}
                <div className="flex justify-between gap-2">
                  <dt className="text-zinc-500">Reverting</dt>
                  <dd className="text-zinc-700">v{draft.rdBadVersion}</dd>
                </div>
              </dl>

              {validationError && (
                <div className="rounded-md bg-red-50 border border-red-200 px-3 py-2 text-xs text-red-800">
                  {validationError}
                </div>
              )}

              <div className="pt-2 space-y-2">
                <Button
                  variant="primary"
                  fullWidth
                  className="bg-violet-600 hover:bg-violet-700 text-white"
                  disabled={!!validationError || isFetching}
                  loading={createMut.isPending}
                  onClick={() => createMut.mutate()}
                >
                  <Undo2 className="w-4 h-4" /> Create revert release
                </Button>
                <Button
                  variant="outline"
                  fullWidth
                  onClick={() => navigate(`/mobile/releases/${id}`)}
                  disabled={createMut.isPending}
                >
                  Cancel
                </Button>
              </div>

              <p className="text-[11px] text-zinc-500 leading-relaxed pt-2 border-t border-zinc-100">
                A new release row is created in CREATED status. Approve and dispatch it like any
                release to actually run the rebuild.
              </p>
            </div>
          </div>
        </aside>
      </div>
    </div>
  );
};

export default MobileRevert;
