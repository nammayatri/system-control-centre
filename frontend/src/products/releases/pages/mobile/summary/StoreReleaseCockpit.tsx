import { useEffect, useState, type ReactNode } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import {
  AppStoreLogoIcon,
  ArrowSquareOutIcon,
  ChartLineUpIcon,
  CheckCircleIcon,
  CheckIcon,
  GooglePlayLogoIcon,
  InfoIcon,
  MagnifyingGlassIcon,
  PackageIcon,
  PauseIcon,
  PlayIcon,
  ShieldWarningIcon,
  TagIcon,
  WarningCircleIcon,
  XCircleIcon,
} from '@phosphor-icons/react';
import { Button } from '../../../../../shared/ui/button';
import { usePermissions } from '../../../../../core/auth/PermissionsContext';
import { mobileApi, type APRelease, type RolloutDetail } from '../../../api';
import { cn } from '../../../../../lib/utils';
import { fullStamp, shortDate } from './dates';
import { stageOf, lifecycleFromRollout } from '../../../components/mobileStage';
import type { TagConflict } from './heal';
import { breadcrumbsOf } from './BuildDetailsCard';
import { SCENARIO_ACCENT, type Scenario } from './scenario';

function errMsg(e: any): string {
  return e?.response?.data?.message ?? e?.response?.data?.error ?? e?.message ?? 'Request failed';
}

// Backend guidance may end with " Open: <App Store Connect url>" — lift that
// into a clickable toast action instead of showing a raw URL in the text.
function errorToast(e: any) {
  const msg = errMsg(e);
  const m = msg.match(/\s*Open:\s*(https:\/\/appstoreconnect\.apple\.com\/\S+)\s*$/);
  if (m && m.index !== undefined) {
    toast.error(msg.slice(0, m.index).trim(), {
      duration: 12000,
      action: { label: 'Open App Store Connect', onClick: () => window.open(m[1], '_blank') },
    });
  } else {
    toast.error(msg);
  }
}

// Where the operator goes to click "Publish" under Play Managed Publishing. We don't
// store per-app Play Console ids (only the package name), and Managed Publishing batches
// every app's pending changes at the account level, so the account console is the right
// landing spot — the operator opens the app's Publishing overview from there.
const PLAY_CONSOLE_URL = 'https://play.google.com/console';

// Apple's fixed 7-day phased-release ladder — read-only, Apple drives the ramp.
const APPLE_LADDER = [1, 2, 5, 10, 20, 50, 100];

// Play staged-rollout suggestion ladder: next conventional step above current.
const PLAY_LADDER = [1, 2, 5, 10, 20, 50, 100];

// "Xs" under a minute, else "Xm" — coarse freshness label.
const fmtAge = (secs: number) => (secs < 60 ? `${Math.round(secs)}s` : `${Math.round(secs / 60)}m`);

export interface StoreReleaseCockpitProps {
  release: APRelease;
  /** Shared ['mobile-rollout', id] cache — undefined while loading or when staged rollout is off. */
  rollout?: RolloutDetail;
  scenario: Scenario;
  statusLabel: string;
  /** "<appName>/<platform>" — per-app grant key (unified permission model). */
  appKey: string;
  /** Unresolved TAG_CONFLICT from the event stream (failed rows only): the
   * expected tag exists but points at a commit this build didn't ship. */
  tagConflict?: TagConflict | null;
  /** Failure cause for the post-mortem block — the GH-side ##[error] excerpt
   * (BUILD_FAILURE_DETAIL event) when captured, else the SCC failure reason. */
  failureDetail?: string | null;
}

/**
 * The Store Release cockpit (v4 design) — one card, one stage body at a time,
 * driving the whole promote → review → approved → rollout lifecycle with real
 * mutations (ported from MobileRolloutPanel). Stage truth is stageOf() over the
 * rollout detail; visuals key off the page scenario.
 */
export function StoreReleaseCockpit({ release, rollout: d, scenario, statusLabel, appKey, tagConflict, failureDetail }: StoreReleaseCockpitProps) {
  const qc = useQueryClient();
  const { hasPermission } = usePermissions();
  const releaseId = release.id;
  const isIos = release.env === 'ios';

  const [busy, setBusy] = useState<string | null>(null);
  const [syncing, setSyncing] = useState(false);
  const [pct, setPct] = useState('');
  const [showReject, setShowReject] = useState(false);
  const [rejectReason, setRejectReason] = useState('');
  // iOS approved-held: releasing can 409 when another build is Pending Developer
  // Release — surfaced as the rose "one in flight" banner, not just a toast.
  const [conflictMsg, setConflictMsg] = useState<string | null>(null);

  // Promote form: notes prefill (AI short summary vs the store's current
  // production "What's New"), switchable via the toggle.
  const [notes, setNotes] = useState('');
  const [noteSource, setNoteSource] = useState<'ai' | 'prod'>('ai');
  const [aiText, setAiText] = useState<string | null>(null);
  const [prodText, setProdText] = useState<string | null>(null);
  const [notesLoading, setNotesLoading] = useState(false);
  const [phased, setPhased] = useState(true);

  const stage = d ? stageOf(lifecycleFromRollout(d)) : 'none';
  const promoteReady = stage === 'promote' && !!d?.rdPromotable;

  const canPromote = hasPermission('mobile', 'MB_RELEASE_PROMOTE', appKey);
  const canRollout = hasPermission('mobile', 'MB_RELEASE_ROLLOUT', appKey);

  const refresh = () => {
    qc.invalidateQueries({ queryKey: ['mobile-rollout', releaseId] });
    qc.invalidateQueries({ queryKey: ['release', releaseId] });
    qc.invalidateQueries({ queryKey: ['releases'] });
    // The App Monitor reads the store_status cache; every action here mirrors its
    // new state into that cache on the backend, so refetch the monitor too.
    qc.invalidateQueries({ queryKey: ['store-monitor'] });
  };

  // A "hard" refresh that first forces a live store sync so the store_status
  // cache reflects an out-of-band Console publish, THEN re-reads the rollout
  // detail. This is what flips `rdLiveOnProduction` after the operator publishes.
  // Best-effort: a sync failure (cooldown / quota) still falls through.
  const syncAndRefetch = async () => {
    setSyncing(true);
    try {
      if (d?.rdAppCatalogId) {
        await mobileApi.refreshStoreApp(d.rdAppCatalogId).catch(() => {});
      }
      refresh();
      await qc.refetchQueries({ queryKey: ['mobile-rollout', releaseId] });
    } finally {
      setSyncing(false);
    }
  };

  const run = async (label: string, fn: () => Promise<unknown>) => {
    setBusy(label);
    try {
      await fn();
      toast.success(label);
      refresh();
    } catch (e) {
      errorToast(e);
    } finally {
      setBusy(null);
    }
  };

  // Heal check for a failed BUILD: CI said failure, but the artifact may have
  // reached the store (e.g. upload ok, tag push died). Backend verifies against
  // store truth and resumes the lifecycle on a hit; a miss changes nothing.
  const verifyStore = async () => {
    setBusy('verify-store');
    try {
      const resp = await mobileApi.verifyStore(releaseId);
      if (resp.vsResult === 'healed') toast.success(resp.vsDetail, { duration: 10000 });
      else toast.warning(resp.vsDetail, { duration: 12000 });
      refresh();
    } catch (e) {
      errorToast(e);
    } finally {
      setBusy(null);
    }
  };

  // Prefill the promote notes as soon as the promote stage is reached (the v4
  // cockpit shows the editable notes inline, no dialog). One promote-form call
  // carries BOTH sources; live AI is only a fallback for rows created before the
  // short summary was stored at create time (a live re-query of the branch head
  // would describe the wrong commits, so the stored value always wins).
  useEffect(() => {
    if (!promoteReady) return;
    let cancelled = false;
    setNotes('');
    setNoteSource('ai');
    setAiText(null);
    setProdText(null);
    setNotesLoading(true);
    (async () => {
      const form = await mobileApi.getPromoteForm(releaseId).catch(() => null);
      const p = (form?.pfReleaseNotes || '').trim() || null;
      const stored = (form?.pfAiShort || '').trim() || null;
      const a =
        stored ??
        (await (async (): Promise<string | null> => {
          try {
            for (let attempt = 0; attempt < 15; attempt++) {
              if (cancelled) return null;
              const ai = await mobileApi.changelogAiSummary(
                release.appGroup,
                release.service,
                release.env,
                release.sourceRef || '',
                'production',
                release.new_version,
                String(release.release_context?.version_code ?? ''),
              );
              if (ai.status === 'ready') return ai.summaryShort?.trim() || null;
              if (ai.status !== 'pending') return null;
              await new Promise((r) => setTimeout(r, 4000));
            }
          } catch {
            /* fall through */
          }
          return null;
        })());
      if (cancelled) return;
      setProdText(p);
      setAiText(a);
      setNotesLoading(false);
      setNoteSource(a ? 'ai' : 'prod');
      // Fill only if the operator hasn't typed meanwhile.
      setNotes((prev) => (prev === '' ? (a ?? p ?? '') : prev));
    })();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [promoteReady, releaseId]);

  // Not via `run`: the review submission can succeed while the best-effort
  // phased-release enable fails — the backend reports that as a non-fatal
  // `prWarning`, surfaced as a warning toast instead of a green success.
  const submitPromote = async () => {
    const label = 'Promoted to review';
    setBusy(label);
    try {
      const resp = await mobileApi.promote(releaseId, {
        prReleaseNotes: notes,
        prEnablePhasedRelease: isIos ? phased : undefined,
      });
      if (resp?.prWarning) {
        toast.warning(resp.prWarning, { duration: 12000 });
      } else {
        toast.success(label);
      }
      refresh();
    } catch (e) {
      errorToast(e);
    } finally {
      setBusy(null);
    }
  };

  const currentPct = d?.rdRolloutPercent ?? null;
  const halted = d?.rdRolloutStatus === 'halted';
  const suggestion = PLAY_LADDER.find((s) => s > (currentPct ?? 0));

  // Play staged rollouts only ramp up — the Console rejects a decrease, so
  // validate here instead of round-tripping a doomed request.
  const submitRollout = () => {
    const p = Number(pct);
    if (!Number.isFinite(p) || p <= 0 || p > 100) {
      toast.error('Enter a rollout percentage between 0 and 100.');
      return;
    }
    if (stage === 'rollout' && currentPct != null && p <= currentPct) {
      toast.error(`Play rollouts can only ramp up — enter a value above ${+currentPct.toFixed(2)}%.`);
      return;
    }
    void run(p >= 100 ? 'Released to 100%' : `Rollout set to ${p}%`, () => mobileApi.rolloutSet(releaseId, p));
  };

  const submitReject = () => {
    if (!rejectReason.trim()) {
      toast.error('A rejection reason is required.');
      return;
    }
    void run('Marked as rejected', async () => {
      await mobileApi.markRejected(releaseId, rejectReason.trim());
      setShowReject(false);
    });
  };

  const startRelease = async () => {
    const label = 'Released';
    setBusy(label);
    setConflictMsg(null);
    try {
      await mobileApi.releaseApproved(releaseId);
      toast.success(label);
      refresh();
    } catch (e: any) {
      const msg = errMsg(e);
      // The one-in-flight conflict gets the persistent rose banner (mockup);
      // everything else stays a toast.
      if (/pending developer release|in flight|already.*(awaiting|pending)/i.test(msg)) {
        setConflictMsg(msg);
      } else {
        errorToast(e);
      }
    } finally {
      setBusy(null);
    }
  };

  const { ghRunUrl } = breadcrumbsOf(release);

  // Subtitle under "Store Release" — platform + stage flavored (mockup copy).
  const subtitle = (() => {
    if (scenario === 'failed')
      return <p className="text-sm text-red-500 mt-0.5 font-medium">{statusLabel}</p>;
    if (promoteReady)
      return (
        <p className="text-sm text-zinc-500 mt-0.5 flex items-center gap-1">
          <GooglePlayLogoIcon size={16} weight="fill" className="text-blue-600" aria-hidden="true" />
          Held on the {d?.rdStoreTrack === 'testflight' ? 'TestFlight' : 'internal testing'} track
        </p>
      );
    if (isIos)
      return (
        <p className="text-sm text-zinc-500 mt-0.5 flex items-center gap-1">
          <AppStoreLogoIcon size={16} weight="fill" className="text-sky-600" aria-hidden="true" />
          App Store Connect / TestFlight managed
        </p>
      );
    return (
      <p className="text-sm text-zinc-500 mt-0.5 flex items-center gap-1">
        <GooglePlayLogoIcon size={16} weight="fill" className="text-emerald-600" aria-hidden="true" />
        Code published to Google Play Developer API
      </p>
    );
  })();

  return (
    <div className="card-surface p-6 overflow-hidden relative">
      <div className={cn('absolute top-0 left-0 right-0 h-1', SCENARIO_ACCENT[scenario])} />

      <div className="mx-1 mb-6">
        <h2 className="text-lg font-bold text-zinc-900 tracking-tight">Store Release</h2>
        {subtitle}
      </div>

      {/* Managed Publishing warning — Android rollout controls only apply once the
          staged change is published in the Console. */}
      {!isIos && stage === 'rollout' && (
        <div className="bg-amber-50 border border-amber-200 text-amber-900 px-4 py-3 rounded-lg mb-6 flex items-start gap-3">
          <WarningCircleIcon size={18} weight="fill" className="text-amber-500 mt-0.5 shrink-0" aria-hidden="true" />
          <div className="flex-1">
            <p className="text-sm font-semibold">Managed Publishing may hold this change</p>
            <p className="text-xs text-amber-700 mt-0.5">
              Play applies rollout changes through Console publishing. If Managed Publishing is on, the change is
              staged under Publishing overview — click Publish there to apply it. The % here reflects the live track.
            </p>
          </div>
          <a
            href={PLAY_CONSOLE_URL}
            target="_blank"
            rel="noreferrer"
            className="text-xs font-bold text-amber-700 underline shrink-0 mt-1"
          >
            Open Console
          </a>
        </div>
      )}

      {/* One-in-flight conflict (iOS approved-held) */}
      {conflictMsg && (
        <div className="bg-rose-50 border border-rose-200 text-rose-900 px-4 py-3 rounded-lg mb-6 flex items-start gap-3">
          <ShieldWarningIcon size={18} weight="fill" className="text-rose-500 mt-0.5 shrink-0" aria-hidden="true" />
          <div className="flex-1">
            <p className="text-sm font-semibold">Conflict: one in flight</p>
            <p className="text-xs text-rose-700 mt-0.5">{conflictMsg}</p>
          </div>
          <a
            href="https://appstoreconnect.apple.com"
            target="_blank"
            rel="noreferrer"
            className="bg-white border border-rose-200 text-xs text-rose-700 font-bold px-3 py-1.5 rounded hover:bg-rose-50 shadow-sm shrink-0 cursor-pointer"
          >
            Open Connect
          </a>
        </div>
      )}

      {/* ── STAGE BODIES (one at a time) ── */}

      {/* Build not on a store track yet / staged rollout off */}
      {stage === 'none' && scenario !== 'failed' && (
        <div className="border border-dashed border-zinc-200 rounded-lg px-4 py-6 text-center text-xs text-zinc-500">
          {scenario === 'draft'
            ? 'Store controls unlock after the build is dispatched and lands on a store track.'
            : scenario === 'building'
              ? 'Building — store controls unlock once the binary reaches a store track.'
              : scenario === 'live'
                ? 'This build is live on the store.'
                : 'No store actions available for this build.'}
        </div>
      )}

      {/* Promote stage, but blocked — cause-specific copy from rdPromoteBlock */}
      {stage === 'promote' &&
        d &&
        !d.rdPromotable &&
        (d.rdPromoteBlock === 'one_in_flight' ? (
          <div className="bg-rose-50 border border-rose-200 text-rose-900 px-4 py-3 rounded-lg flex items-start gap-3">
            <ShieldWarningIcon size={18} weight="fill" className="text-rose-500 mt-0.5 shrink-0" aria-hidden="true" />
            <div className="text-xs">
              <p className="text-sm font-semibold">Conflict: one in flight</p>
              <p className="mt-0.5">
                {d.rdPromoteBlockVersion ? `v${d.rdPromoteBlockVersion}` : 'Another version'} is awaiting developer
                release — Apple allows one at a time. Release (or withdraw) it before promoting this build.
              </p>
            </div>
          </div>
        ) : d.rdPromoteBlock === 'behind_held' || d.rdPromoteBlock === 'blocked_by_incoming' ? (
          <div className="border border-dashed border-zinc-200 rounded-lg px-4 py-6 text-center text-xs text-zinc-500">
            Nothing to promote — a newer build{d.rdPromoteBlockVersion ? ` (v${d.rdPromoteBlockVersion})` : ''} is
            ahead of this one in release order.
          </div>
        ) : (
          <div className="border border-dashed border-zinc-200 rounded-lg px-4 py-6 text-center text-xs text-zinc-500">
            Built and on the {d.rdStoreTrack ?? 'internal'} track — nothing to promote: this version code is at or
            below what&apos;s already on production.
          </div>
        ))}

      {/* === READY TO PROMOTE (held on internal / TestFlight) === */}
      {promoteReady && (
        <div className="flex flex-col gap-4 bg-blue-50/50 border border-blue-100 rounded-lg p-6">
          <div className="flex flex-wrap items-start justify-between gap-4 w-full">
            <div>
              <h3 className="text-sm font-bold text-blue-900 flex items-center gap-2">
                <PackageIcon size={16} weight="fill" className="text-blue-500" aria-hidden="true" />
                Built · held on {d?.rdStoreTrack === 'testflight' ? 'TestFlight' : 'Internal track'}
              </h3>
              <p className="text-xs text-zinc-500 mt-1">
                The binary is uploaded to the {d?.rdStoreTrack === 'testflight' ? 'TestFlight' : 'internal testing'}{' '}
                track. Promote submits it to store review — nothing goes live until you roll it out.
              </p>
            </div>
            <Button
              className="px-6 py-3 bg-blue-600 text-white rounded-lg shadow border border-blue-700 font-bold enabled:hover:bg-blue-700 shrink-0"
              disabled={!canPromote || !notes.trim()}
              loading={busy === 'Promoted to review'}
              onClick={submitPromote}
            >
              Promote to review
            </Button>
          </div>
          <div className="w-full mt-1">
            <div className="flex items-center mb-2">
              {/* Source toggle: clicking REPLACES the textarea with that source. */}
              <button
                type="button"
                disabled={!aiText}
                title={
                  aiText
                    ? 'AI summary of what changed in this build'
                    : notesLoading
                      ? 'AI summary is generating…'
                      : 'No AI summary available'
                }
                onClick={() => {
                  if (!aiText) return;
                  setNoteSource('ai');
                  setNotes(aiText);
                }}
                className={cn(
                  'text-[10px] font-bold px-2.5 py-1 rounded-l border transition-colors cursor-pointer disabled:opacity-40 disabled:cursor-default',
                  noteSource === 'ai'
                    ? 'bg-blue-600 text-white border-blue-600'
                    : 'bg-white border-zinc-200 text-zinc-500 hover:bg-zinc-50',
                )}
              >
                ✦ AI summary{notesLoading && !aiText ? '…' : ''}
              </button>
              <button
                type="button"
                disabled={!prodText}
                title={prodText ? 'Current production "What\'s New" from the store' : 'No production notes found'}
                onClick={() => {
                  if (!prodText) return;
                  setNoteSource('prod');
                  setNotes(prodText);
                }}
                className={cn(
                  'text-[10px] font-bold px-2.5 py-1 rounded-r border border-l-0 transition-colors cursor-pointer disabled:opacity-40 disabled:cursor-default',
                  noteSource === 'prod'
                    ? 'bg-blue-600 text-white border-blue-600'
                    : 'bg-white border-zinc-200 text-zinc-500 hover:bg-zinc-50',
                )}
              >
                Store notes
              </button>
            </div>
            <textarea
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              rows={4}
              placeholder={notesLoading ? 'Loading AI summary and production notes…' : 'What changed in this release…'}
              aria-label="Release notes (What's New)"
              className="w-full bg-white border border-zinc-200 rounded-lg p-3 text-xs text-zinc-700 leading-relaxed focus:outline-none focus:ring-2 focus:ring-blue-200 focus:border-blue-400"
            />
            {isIos ? (
              <label className="flex cursor-pointer items-center gap-2 text-[10px] text-zinc-500 mt-2">
                <input
                  type="checkbox"
                  checked={phased}
                  onChange={(e) => setPhased(e.target.checked)}
                  className="rounded border-zinc-300 accent-blue-600"
                />
                Enable Apple&apos;s 7-day phased release
              </label>
            ) : (
              <p className="text-[10px] text-zinc-400 mt-2">
                Phased release: n/a on Android — the staged % rollout begins after approval.
              </p>
            )}
            {!canPromote && (
              <p className="text-[10px] text-amber-600 mt-1">You need the RELEASE_PROMOTE permission to submit.</p>
            )}
          </div>
        </div>
      )}

      {/* === IN REVIEW (opaque on Android, auto-detected on iOS) === */}
      {stage === 'review' && (
        <div className="bg-violet-50/40 border border-violet-100 rounded-lg p-6 flex flex-col items-center text-center">
          <div className="w-16 h-16 bg-white border border-violet-200 rounded-full flex items-center justify-center shadow-lg relative mb-4">
            <MagnifyingGlassIcon size={24} weight="light" className="text-violet-500" aria-hidden="true" />
            <div className="absolute inset-0 rounded-full border border-violet-400 animate-ping opacity-30 motion-reduce:animate-none" />
          </div>
          {isIos ? (
            <>
              <h3 className="text-sm font-bold text-zinc-900">App Store review in progress</h3>
              <p className="text-xs text-zinc-500 mt-2 max-w-sm">
                Waiting on App Store review — the outcome is detected automatically.
              </p>
              <div className="flex gap-4 mt-6">
                <Button
                  variant="outline"
                  className="border-red-300 text-red-700 enabled:hover:bg-red-50 px-6 font-bold"
                  disabled={!canPromote}
                  loading={busy === 'Withdrawn from review'}
                  onClick={() => run('Withdrawn from review', () => mobileApi.withdraw(releaseId))}
                >
                  <XCircleIcon size={14} weight="bold" aria-hidden="true" /> Withdraw from review
                </Button>
              </div>
              <p className="text-[11px] text-zinc-500 mt-3 max-w-sm">
                Cancels the App Store submission and aborts this release — use it to pull a bad build before
                it&apos;s approved.
              </p>
            </>
          ) : (
            <>
              <h3 className="text-sm font-bold text-zinc-900">Developer Review in Progress</h3>
              <p className="text-xs text-zinc-500 mt-2 max-w-sm">
                The Store API does not broadcast real-time review progress. You must record the verdict here
                manually once the console notifies you.
              </p>
              <div className="flex flex-wrap justify-center gap-4 mt-6">
                <Button
                  className="bg-emerald-50 text-emerald-700 border border-emerald-200 enabled:hover:bg-emerald-100 px-6 font-bold shadow-sm"
                  disabled={!canPromote}
                  loading={busy === 'Marked as approved'}
                  onClick={() => run('Marked as approved', () => mobileApi.markApproved(releaseId))}
                >
                  Mark Approved
                </Button>
                <Button
                  className="bg-red-50 text-red-700 border border-red-200 enabled:hover:bg-red-100 px-6 font-bold shadow-sm"
                  disabled={!canPromote}
                  onClick={() => setShowReject((v) => !v)}
                >
                  Mark Rejected
                </Button>
              </div>
              <p className="flex items-start gap-1.5 text-[11px] leading-relaxed text-zinc-500 mt-4 max-w-md text-left">
                <InfoIcon size={12} className="mt-0.5 shrink-0 text-zinc-400" aria-hidden="true" />
                <span>
                  A submitted Play review <strong>can&apos;t be withdrawn</strong> — Google Play has no
                  cancel-review API. Wait for the verdict, or once it&apos;s live, halt the rollout.{' '}
                  <a
                    href={PLAY_CONSOLE_URL}
                    target="_blank"
                    rel="noreferrer"
                    className="font-bold text-violet-600 hover:underline cursor-pointer"
                  >
                    Open Play Console ↗
                  </a>
                </span>
              </p>
              {showReject && (
                <div className="w-full max-w-md space-y-2 rounded-md border border-red-200 bg-white/70 p-3 mt-4 text-left">
                  <textarea
                    value={rejectReason}
                    onChange={(e) => setRejectReason(e.target.value)}
                    rows={2}
                    placeholder="Rejection reason (from the Play Console / email)…"
                    className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-transparent focus:outline-none focus:ring-2 focus:ring-red-400"
                  />
                  <div className="flex items-center gap-2">
                    <Button
                      size="sm"
                      variant="danger"
                      loading={busy === 'Marked as rejected'}
                      disabled={!canPromote || !rejectReason.trim()}
                      onClick={submitReject}
                    >
                      Confirm rejection
                    </Button>
                    <Button size="sm" variant="ghost" onClick={() => setShowReject(false)}>
                      Cancel
                    </Button>
                  </div>
                </div>
              )}
            </>
          )}
        </div>
      )}

      {/* === APPROVED & HELD === */}
      {stage === 'approved' && d && (
        <>
          {isIos ? (
            <div className="bg-emerald-50/50 border border-emerald-100 rounded-lg p-6 flex flex-col sm:flex-row items-center justify-between gap-6">
              <div>
                <h3 className="text-sm font-bold text-emerald-800 flex items-center gap-2">
                  <CheckCircleIcon size={16} weight="fill" className="text-emerald-500" aria-hidden="true" />
                  Approved and Ready
                </h3>
                <p className="text-xs text-emerald-600 mt-1 pl-6">
                  {d.rdReviewDecidedAt ? (
                    <>
                      Store review passed{' '}
                      <span title={fullStamp(d.rdReviewDecidedAt)}>{shortDate(d.rdReviewDecidedAt)}</span>.{' '}
                    </>
                  ) : (
                    'Store review passed. '
                  )}
                  Nothing is live yet.
                </p>
                <div className="mt-4 pl-6 flex items-center gap-2 text-xs">
                  <label className="font-medium text-zinc-700">Phased Release:</label>
                  <span className="bg-white border border-zinc-200 px-2 py-0.5 rounded text-zinc-500 shadow-sm font-mono">
                    {d.rdPhasedId ? 'ON · 7-day ramp' : 'OFF · all users at once'}
                  </span>
                </div>
              </div>
              <Button
                className="px-6 py-3 bg-emerald-600 text-white rounded-lg shadow border border-emerald-700 font-bold enabled:hover:bg-emerald-700 shrink-0 w-full sm:w-auto"
                disabled={!canRollout}
                loading={busy === 'Released'}
                onClick={startRelease}
                title={d.rdPhasedId ? 'Start the 7-day phased release' : 'Release to all users now'}
              >
                Start Release
              </Button>
            </div>
          ) : !d.rdLiveOnProduction ? (
            // Android approved but not serving on production yet: counts as live
            // only above 1% rollout (or fully released) — publish in the Console,
            // then a hard Refresh (live store sync) flips rdLiveOnProduction and
            // reveals the rollout controls.
            <PublishGate
              syncing={syncing}
              onRefresh={() => void syncAndRefetch()}
              syncedSecondsAgo={d.rdSyncedSecondsAgo}
              cooldownSeconds={d.rdRefreshCooldownSeconds}
            />
          ) : (
            <div className="flex flex-col gap-4">
              <p className="flex items-center gap-1.5 text-xs text-zinc-700">
                <CheckCircleIcon size={14} weight="fill" className="text-emerald-600" aria-hidden="true" />
                Approved and held — start the staged rollout below. Nothing is live yet.
              </p>
              <RolloutBody
                pct={pct}
                setPct={setPct}
                currentPct={null}
                suggestion={1}
                halted={false}
                showHalt={false}
                canRollout={canRollout}
                busy={busy}
                onSet={submitRollout}
                onHalt={() => {}}
                onResume={() => {}}
                onReleaseAll={() => run('Released to 100%', () => mobileApi.rolloutReleaseAll(releaseId))}
              />
            </div>
          )}
        </>
      )}

      {/* === ROLLING OUT === */}
      {stage === 'rollout' &&
        d &&
        (isIos ? (
          <div className="bg-sky-50/50 border border-sky-100 rounded-lg p-5">
            <div className="flex items-center justify-between mb-4 border-b border-sky-200/50 pb-4">
              <div>
                <p className="text-sm font-bold text-zinc-900 flex items-center gap-2">
                  <ChartLineUpIcon size={16} weight="bold" className="text-sky-600" aria-hidden="true" />
                  {d.rdPhasedId
                    ? halted
                      ? 'Apple Phased Release Paused'
                      : 'Apple Phased Release Active'
                    : 'Releasing to all users'}
                </p>
                <p className="text-xs text-zinc-500 mt-1">
                  {d.rdPhasedId
                    ? 'Apple is rolling this out over a 7-day automated schedule. Percentages cannot be manually input.'
                    : 'This version was released without a phased ramp.'}
                </p>
              </div>
            </div>

            {d.rdPhasedId && <AppleLadder currentPct={currentPct} halted={halted} />}

            <div className="flex flex-wrap justify-end gap-3 mt-4">
              {halted ? (
                <Button
                  variant="outline"
                  className="border-sky-200 bg-white text-sky-700 font-bold enabled:hover:bg-sky-50"
                  disabled={!canRollout}
                  loading={busy === 'Rollout resumed'}
                  onClick={() => run('Rollout resumed', () => mobileApi.rolloutResume(releaseId))}
                >
                  <PlayIcon size={14} weight="bold" aria-hidden="true" /> Resume Curve
                </Button>
              ) : (
                <Button
                  variant="outline"
                  className="border-sky-200 bg-white text-sky-700 font-bold enabled:hover:bg-sky-50"
                  disabled={!canRollout}
                  loading={busy === 'Rollout paused'}
                  onClick={() => run('Rollout paused', () => mobileApi.rolloutHalt(releaseId))}
                >
                  <PauseIcon size={14} weight="bold" aria-hidden="true" /> Pause Curve
                </Button>
              )}
              <Button
                className="bg-zinc-900 text-white font-bold enabled:hover:bg-zinc-800"
                disabled={!canRollout}
                loading={busy === 'Released to 100%'}
                onClick={() => run('Released to 100%', () => mobileApi.rolloutReleaseAll(releaseId))}
              >
                Force Release 100%
              </Button>
            </div>
          </div>
        ) : (
          <RolloutBody
            pct={pct}
            setPct={setPct}
            currentPct={currentPct}
            suggestion={suggestion}
            halted={halted}
            showHalt
            canRollout={canRollout}
            busy={busy}
            onSet={submitRollout}
            onHalt={() => run('Rollout paused', () => mobileApi.rolloutHalt(releaseId))}
            onResume={() => run('Rollout resumed', () => mobileApi.rolloutResume(releaseId))}
            onReleaseAll={() => run('Released to 100%', () => mobileApi.rolloutReleaseAll(releaseId))}
          />
        ))}

      {/* === REJECTED (terminal) === */}
      {stage === 'rejected' && (
        <PostMortem
          title="Store review rejected"
          detail={d?.rdReviewRejectReason ?? null}
          note="Fix the issue and create a new release to resubmit."
          ghRunUrl={null}
        />
      )}

      {/* === FAILED / ABORTED / REVERTED (no rollout stage carries it) === */}
      {scenario === 'failed' && stage !== 'rejected' && tagConflict && (
        <TagConflictPanel conflict={tagConflict} />
      )}
      {scenario === 'failed' && stage !== 'rejected' && (
        <PostMortem
          title={statusLabel}
          detail={failureDetail ?? null}
          note="This release is terminal. Create a new release (or a revert) to ship a fix."
          ghRunUrl={ghRunUrl ?? null}
          action={
            // Build failures only (not aborts/reverts): CI failure may be a
            // post-upload step — offer the store-truth heal check.
            (d?.rdPhase ?? release.release_context?.display_phase) === 'build_failed' &&
            hasPermission('mobile', 'MB_MOBILE_DISPATCH', appKey) ? (
              <button
                onClick={verifyStore}
                disabled={busy !== null}
                className="text-xs bg-white text-red-700 border border-red-300 px-3 py-1.5 rounded font-bold hover:bg-red-100 cursor-pointer disabled:opacity-50"
              >
                {busy === 'verify-store' ? 'Checking store…' : 'Verify on store'}
              </button>
            ) : null
          }
        />
      )}

      {/* === COMPLETED / SUPERSEDED === */}
      {stage === 'completed' && scenario !== 'failed' && (
        <p className="flex items-center gap-1.5 text-xs font-medium text-emerald-700 bg-emerald-50/50 border border-emerald-100 rounded-lg px-4 py-3">
          <CheckIcon size={14} weight="bold" aria-hidden="true" /> Released to 100% of users.
        </p>
      )}
      {stage === 'superseded' && (
        <p className="text-xs font-medium text-zinc-500 bg-zinc-50 border border-zinc-100 rounded-lg px-4 py-3">
          Superseded — a newer version took over the rollout. This row is frozen at{' '}
          {currentPct != null ? `${+currentPct.toFixed(2)}%` : 'its last percentage'} as history.
        </p>
      )}
    </div>
  );
}

/** Apple's read-only 7-day phased ladder with the current day pinned. */
function AppleLadder({ currentPct, halted }: { currentPct: number | null; halted: boolean }) {
  const idx = Math.max(
    0,
    APPLE_LADDER.findIndex((p) => p >= (currentPct ?? 1)),
  );
  const current = idx === -1 ? APPLE_LADDER.length - 1 : idx;
  return (
    <div className="flex items-center justify-between mb-2 px-2 overflow-x-auto">
      {APPLE_LADDER.map((p, i) => (
        <div key={p} className="contents">
          {i > 0 && (
            <div
              className={cn(
                'flex-1 h-px mx-2 min-w-4',
                i <= current - 1 ? 'bg-emerald-500' : i === current ? 'bg-sky-300' : 'bg-zinc-200 border-dashed border-t',
              )}
            />
          )}
          <div className="flex flex-col items-center shrink-0">
            {i < current ? (
              <div className="w-6 h-6 rounded-full bg-emerald-500 text-white flex items-center justify-center text-xs">
                <CheckIcon size={12} weight="bold" aria-hidden="true" />
              </div>
            ) : i === current ? (
              <div className="w-6 h-6 rounded-full bg-white border-[3px] border-sky-500 relative flex items-center justify-center">
                {halted ? (
                  <PauseIcon size={10} weight="bold" className="text-sky-500" aria-hidden="true" />
                ) : (
                  <div className="w-2 h-2 rounded-full bg-sky-500" />
                )}
              </div>
            ) : (
              <div className="w-6 h-6 rounded-full bg-zinc-100 border border-zinc-200" />
            )}
            <span
              className={cn(
                'text-[10px] mt-1 text-center',
                i === current ? 'font-bold text-sky-700' : i < current ? 'text-zinc-500' : 'text-zinc-400',
              )}
            >
              Day {i + 1}
              <br />
              {p}%
            </span>
          </div>
        </div>
      ))}
    </div>
  );
}

/** Android staged-rollout control row (mockup's "Current Target" body). */
function RolloutBody({
  pct,
  setPct,
  currentPct,
  suggestion,
  halted,
  showHalt,
  canRollout,
  busy,
  onSet,
  onHalt,
  onResume,
  onReleaseAll,
}: {
  pct: string;
  setPct: (v: string) => void;
  currentPct: number | null;
  suggestion: number | undefined;
  halted: boolean;
  showHalt: boolean;
  canRollout: boolean;
  busy: string | null;
  onSet: () => void;
  onHalt: () => void;
  onResume: () => void;
  onReleaseAll: () => void;
}) {
  return (
    <div className="flex flex-col sm:flex-row items-end gap-6 bg-zinc-50 p-5 rounded-lg border border-zinc-100">
      <div className="w-full sm:w-1/3">
        <label className="block eyebrow mb-2" htmlFor="rollout-target">
          Current Target
        </label>
        <div className="relative">
          <input
            id="rollout-target"
            type="number"
            min={0}
            max={100}
            step="any"
            value={pct}
            onChange={(e) => setPct(e.target.value)}
            placeholder={currentPct != null ? String(+currentPct.toFixed(2)) : 'e.g. 10'}
            className="w-full font-mono text-2xl font-bold bg-white border border-zinc-200 rounded-md py-2 px-3 outline-none focus:ring-2 focus:ring-emerald-200 focus:border-emerald-500 transition-all"
          />
          <span className="absolute right-4 top-1/2 -translate-y-1/2 text-lg font-mono text-zinc-400">%</span>
        </div>
        <p className="text-[10px] text-zinc-500 mt-2 font-medium">
          {currentPct != null && <>Live at {+currentPct.toFixed(2)}% · </>}
          {suggestion != null ? `Suggestion: Ramp to ${suggestion}%` : 'At the final step — release 100%'}
        </p>
      </div>
      <div className="flex-1 flex flex-wrap items-center justify-start sm:justify-end gap-3 w-full border-t border-zinc-200 pt-4 sm:border-0 sm:pt-0">
        <Button
          className="px-5 py-2.5 font-semibold shrink-0"
          disabled={!canRollout}
          loading={!!busy?.startsWith('Rollout set')}
          onClick={onSet}
        >
          Set %
        </Button>
        {showHalt &&
          (halted ? (
            <Button
              className="px-4 py-2.5 bg-emerald-50 text-emerald-700 border border-emerald-200 font-semibold enabled:hover:bg-emerald-100 shrink-0"
              disabled={!canRollout}
              loading={busy === 'Rollout resumed'}
              onClick={onResume}
            >
              <PlayIcon size={14} weight="bold" aria-hidden="true" /> Resume
            </Button>
          ) : (
            <Button
              className="px-4 py-2.5 bg-amber-50 text-amber-700 border border-amber-200 font-semibold enabled:hover:bg-amber-100 shrink-0"
              disabled={!canRollout}
              loading={busy === 'Rollout paused'}
              onClick={onHalt}
            >
              <PauseIcon size={14} weight="bold" aria-hidden="true" /> Halt
            </Button>
          ))}
        <Button
          variant="outline"
          className="px-4 py-2.5 font-semibold shrink-0"
          disabled={!canRollout}
          loading={busy === 'Released to 100%'}
          onClick={onReleaseAll}
        >
          Release 100%
        </Button>
      </div>
    </div>
  );
}

/**
 * Android "approved but held under Managed Publishing" gate: publish in the Play
 * Console, then a hard Refresh (forces a live store sync) flips
 * rdLiveOnProduction and reveals the rollout controls. The cooldown note tells
 * the operator whether Refresh will actually re-poll the live store.
 */
function PublishGate({
  syncing,
  onRefresh,
  syncedSecondsAgo,
  cooldownSeconds,
}: {
  syncing: boolean;
  onRefresh: () => void;
  syncedSecondsAgo: number | null;
  cooldownSeconds: number;
}) {
  const liveReady = syncedSecondsAgo == null || syncedSecondsAgo >= cooldownSeconds;
  const waitSecs = liveReady ? 0 : Math.ceil(cooldownSeconds - syncedSecondsAgo!);
  return (
    <div className="space-y-3 rounded-lg border border-amber-200 bg-amber-50 p-5">
      <p className="flex items-start gap-2 text-xs leading-relaxed text-amber-800">
        <InfoIcon size={14} weight="fill" className="mt-0.5 shrink-0 text-amber-600" aria-hidden="true" />
        <span>
          <strong>Approved — staged, not live yet.</strong> Counts as live only above <strong>1%</strong> rollout
          (or fully released). Publish in the Play Console if held under Managed Publishing, then Refresh.
        </span>
      </p>
      <div className="flex flex-wrap items-center gap-2">
        <a href={PLAY_CONSOLE_URL} target="_blank" rel="noreferrer">
          <Button size="sm" className="font-semibold">
            <ArrowSquareOutIcon size={13} weight="bold" aria-hidden="true" /> Open Play Console
          </Button>
        </a>
        <Button size="sm" variant="outline" className="font-semibold" loading={syncing} onClick={onRefresh}>
          I&apos;ve published — Refresh
        </Button>
      </div>
      <p className="text-[11px] leading-relaxed text-amber-700">
        {liveReady ? (
          'Refresh now runs a live store check.'
        ) : (
          <>
            Last checked {fmtAge(syncedSecondsAgo!)} ago — a live re-check is available in{' '}
            <strong>{fmtAge(waitSecs)}</strong>. Until then Refresh shows the cached state.
          </>
        )}
      </p>
    </div>
  );
}

/** Amber remediation panel for an unresolved TAG_CONFLICT: the store artifact
 * is fine — a stale git tag squats on this build's name at the wrong commit.
 * Never auto-fixed (published-tag rewrites are a human decision); this panel
 * hands the operator the exact command, then Verify on store resumes the row. */
function TagConflictPanel({ conflict }: { conflict: TagConflict }) {
  const short = (sha: string) => (sha ? sha.slice(0, 9) : '?');
  return (
    <div className="bg-amber-50 border border-amber-200 rounded-lg p-5 flex gap-4">
      <TagIcon size={24} weight="fill" className="text-amber-500 shrink-0" aria-hidden="true" />
      <div className="min-w-0 flex-1">
        <h3 className="text-sm font-bold text-amber-900">Tag conflict — a stale tag owns this build's name</h3>
        <p className="text-xs text-amber-800 mt-1">
          Tag <code className="font-mono bg-amber-100 px-1 rounded">{conflict.tag}</code> points at{' '}
          <code className="font-mono bg-amber-100 px-1 rounded">{short(conflict.tagCommit)}</code>, but this build was
          made from <code className="font-mono bg-amber-100 px-1 rounded">{short(conflict.buildCommit)}</code>. The
          store artifact is fine — only the git tag is wrong.
        </p>
        {conflict.remediation && (
          <div className="relative mt-3">
            <pre className="bg-zinc-900 text-zinc-100 p-3 pr-16 rounded text-[11px] font-mono overflow-x-auto whitespace-pre-wrap">
              {conflict.remediation}
            </pre>
            <button
              onClick={() => {
                navigator.clipboard
                  .writeText(conflict.remediation)
                  .then(() => toast.success('Retag command copied'))
                  .catch(() => toast.error('Could not copy'));
              }}
              className="absolute top-2 right-2 text-[10px] bg-zinc-700 text-white px-2 py-1 rounded font-bold hover:bg-zinc-600 cursor-pointer"
            >
              Copy
            </button>
          </div>
        )}
        <p className="text-[11px] text-zinc-500 mt-2">
          Run the retag, then press <b>Verify on store</b> — the release resumes and adopts the corrected tag.
        </p>
      </div>
    </div>
  );
}

/** Red terminal post-mortem body (build failed / aborted / reverted / rejected). */
function PostMortem({
  title,
  detail,
  note,
  ghRunUrl,
  action,
}: {
  title: string;
  detail: string | null;
  note: string;
  ghRunUrl: string | null;
  action?: ReactNode;
}) {
  return (
    <div className="bg-red-50 p-5 rounded-lg border border-red-100 flex gap-4">
      <XCircleIcon size={24} weight="fill" className="text-red-500 shrink-0" aria-hidden="true" />
      <div className="min-w-0 flex-1">
        <h3 className="text-sm font-bold text-red-900">{title}</h3>
        {detail && (
          <pre className="bg-red-950 text-red-200 p-3 rounded text-xs mt-3 font-mono overflow-x-auto whitespace-pre-wrap">
            {detail}
          </pre>
        )}
        <p className="text-[11px] text-zinc-500 mt-2">{note}</p>
        {(ghRunUrl || action) && (
          <div className="flex gap-3 mt-4">
            {ghRunUrl && (
              <a
                href={ghRunUrl}
                target="_blank"
                rel="noreferrer"
                className="text-xs bg-red-600 text-white px-3 py-1.5 rounded font-bold hover:bg-red-700 cursor-pointer"
              >
                View CI output ↗
              </a>
            )}
            {action}
          </div>
        )}
      </div>
    </div>
  );
}
