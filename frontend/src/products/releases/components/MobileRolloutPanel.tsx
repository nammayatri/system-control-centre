import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import {
    Rocket,
    Loader2,
    CheckCircle2,
    XCircle,
    Clock,
    PauseCircle,
    PlayCircle,
    RefreshCw,
    Send,
    Flag,
    Info,
    ExternalLink,
} from 'lucide-react';
import { Button } from '../../../shared/ui/button';
import { Badge } from '../../../shared/ui/badge';
import { usePermissions } from '../../../core/auth/PermissionsContext';
import { mobileApi, type RolloutDetail } from '../api';
import { stageOf, lifecycleFromRollout } from './mobileStage';

function errMsg(e: any): string {
    return (
        e?.response?.data?.message ??
        e?.response?.data?.error ??
        e?.message ??
        'Request failed'
    );
}

// Where the operator goes to click "Publish" under Play Managed Publishing. We don't
// store per-app Play Console ids (only the package name), and Managed Publishing batches
// every app's pending changes at the account level, so the account console is the right
// landing spot — the operator opens the app's Publishing overview from there.
const PLAY_CONSOLE_URL = 'https://play.google.com/console';

/**
 * Promote-to-review → staged-rollout control panel for a single mobile release
 * (one app + platform). Self-contained: fetches its own state from
 * `GET /releases/:id/rollout` and drives the whole lifecycle —
 *
 *   promote → in review → approved (held) → rolling out → completed
 *
 * Hidden entirely when staged rollout is disabled (the endpoint 400s) or the
 * build isn't done. Buttons are gated on RELEASE_PROMOTE / RELEASE_ROLLOUT;
 * platform decides the controls (iOS = Apple-driven phased ramp + manual
 * Release; Android = operator-set % + opaque-review mark-approved/rejected).
 */
/**
 * Context for pre-filling the promote dialog's release notes with the AI
 * "what's new" short summary instead of the raw internal changelog. Best-effort:
 * reuses the create-time changelog summary cached by commit range; falls back to
 * the stored changelog (the promote form's default) when it isn't available.
 */
export interface PromoteAiNotes {
    app: string;
    surface: string;
    platform: string;
    branch: string;
    versionName: string;
    versionCode: string;
}

export function MobileRolloutPanel({
    releaseId,
    aiNotes,
}: {
    releaseId: string;
    aiNotes?: PromoteAiNotes;
}) {
    const qc = useQueryClient();
    const { hasPermission } = usePermissions();

    const q = useQuery({
        queryKey: ['mobile-rollout', releaseId],
        queryFn: () => mobileApi.getRolloutDetail(releaseId),
        // Poll only while a review/rollout is actively in flight.
        refetchInterval: (query) => {
            const st = query.state.data?.rdMbStatus;
            const active = ['MBSubmittingForReview', 'MBInReview', 'MBReviewApproved', 'MBRollingOut'];
            return st && active.includes(st) ? 15000 : false;
        },
        retry: false, // a 400 (flag off / not promotable) must not retry-spam
        staleTime: 5000,
    });

    const [busy, setBusy] = useState<string | null>(null);
    const [syncing, setSyncing] = useState(false);
    const [showPromote, setShowPromote] = useState(false);
    const [notes, setNotes] = useState('');
    const [phased, setPhased] = useState(true);
    const [pct, setPct] = useState('');
    const [showReject, setShowReject] = useState(false);
    const [rejectReason, setRejectReason] = useState('');

    const d = q.data;
    if (q.isError || !d) return null; // staged rollout off / not promotable / loading-error

    const stage = stageOf(lifecycleFromRollout(d));
    if (stage === 'none') return null;
    // A promote-stage build the backend says is NOT promotable (already at/below the
    // production code) has nothing to do here — hide the whole Store-release panel rather
    // than show a "Ready to promote" header next to a "nothing to promote" note. Its track
    // (e.g. Internal) is surfaced at the top of the release summary instead.
    if (stage === 'promote' && !d.rdPromotable) return null;

    const isIos = d.rdPlatform === 'ios';
    const canPromote = hasPermission('autopilot', 'RELEASE_PROMOTE');
    const canRollout = hasPermission('autopilot', 'RELEASE_ROLLOUT');

    const refresh = () => {
        void q.refetch();
        qc.invalidateQueries({ queryKey: ['release', releaseId] });
        qc.invalidateQueries({ queryKey: ['releases'] });
        // The App Monitor reads the store_status cache (not release_tracker); every
        // action here mirrors its new state into that cache on the backend, so refetch
        // the monitor to surface the promote / rollout / halt / resume / release there too.
        qc.invalidateQueries({ queryKey: ['store-monitor'] });
    };

    // A "hard" refresh that first forces a live store sync (refreshStoreApp) so the
    // store_status cache reflects an out-of-band Console publish, THEN re-reads the
    // rollout detail. This is what makes `rdLiveOnProduction` flip after the operator
    // publishes — the cached cell alone would lag until the next sync. Best-effort: a
    // sync failure (cooldown / quota) still falls through to the plain refetch.
    const syncAndRefetch = async () => {
        setSyncing(true);
        try {
            if (d.rdAppCatalogId) {
                await mobileApi.refreshStoreApp(d.rdAppCatalogId).catch(() => {});
            }
            await q.refetch();
            qc.invalidateQueries({ queryKey: ['release', releaseId] });
            qc.invalidateQueries({ queryKey: ['releases'] });
            qc.invalidateQueries({ queryKey: ['store-monitor'] });
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
            toast.error(errMsg(e));
        } finally {
            setBusy(null);
        }
    };

    const openPromote = async () => {
        setShowPromote(true);
        let formNotes = '';
        let isStoreSync = false;
        try {
            const form = await mobileApi.getPromoteForm(releaseId);
            formNotes = form.pfReleaseNotes || '';
            isStoreSync = form.pfIsStoreSync;
            setNotes(formNotes); // show the default immediately (prod notes or changelog)
        } catch {
            return; // leave notes empty — operator can type their own
        }
        // Then best-effort upgrade to the AI "what's new" short summary (store-
        // facing, polished) — diffing against production, since store notes
        // describe what's new vs the live version. Only swap if the operator
        // hasn't started editing (notes still equal the changelog default); on a
        // cache miss / AI off the changelog default simply stays.
        // Store-sync releases are skipped: the backend already fills the notes
        // with the current production "What's New" pulled from the store.
        if (!aiNotes || isStoreSync) return;
        try {
            const ai = await mobileApi.changelogAiSummary(
                aiNotes.app,
                aiNotes.surface,
                aiNotes.platform,
                aiNotes.branch,
                'production',
                aiNotes.versionName,
                aiNotes.versionCode,
            );
            if (ai.status === 'ready' && ai.summaryShort?.trim()) {
                const aiShort = ai.summaryShort.trim();
                setNotes((prev) => (prev === formNotes ? aiShort : prev));
            }
        } catch {
            /* keep the changelog default */
        }
    };

    // Not via `run`: the review submission can succeed while the best-effort
    // phased-release enable fails. The backend reports that as a non-fatal
    // `prWarning`, which we surface as a warning toast (instead of a green
    // success) so a silent phased miss can't happen again.
    const submitPromote = async () => {
        const label = 'Promoted to review';
        setBusy(label);
        try {
            const resp = await mobileApi.promote(releaseId, {
                prReleaseNotes: notes,
                prEnablePhasedRelease: isIos ? phased : undefined,
            });
            setShowPromote(false);
            if (resp?.prWarning) {
                toast.warning(resp.prWarning, { duration: 12000 });
            } else {
                toast.success(label);
            }
            refresh();
        } catch (e) {
            toast.error(errMsg(e));
        } finally {
            setBusy(null);
        }
    };

    const submitRollout = () => {
        const p = Number(pct);
        if (!Number.isFinite(p) || p <= 0 || p > 100) {
            toast.error('Enter a rollout percentage between 0 and 100.');
            return;
        }
        void run(p >= 100 ? 'Released to 100%' : `Rollout set to ${p}%`, () =>
            mobileApi.rolloutSet(releaseId, p),
        );
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

    const pctLabel =
        d.rdRolloutPercent != null ? `${+d.rdRolloutPercent.toFixed(2)}%` : isIos ? 'phased' : '—';

    return (
        <div className="rounded-lg border border-indigo-100 bg-indigo-50/40 p-4">
            <div className="mb-3 flex items-center justify-between gap-2">
                <div className="flex items-center gap-2 text-sm font-semibold text-indigo-800">
                    <Rocket size={15} className="shrink-0" />
                    Store release
                    <StageBadge label={d.rdStatusLabel} variant={d.rdStatusVariant} />
                </div>
                <Button
                    size="sm"
                    variant="ghost"
                    loading={q.isFetching || syncing}
                    onClick={syncAndRefetch}
                >
                    <RefreshCw size={13} /> Refresh
                </Button>
            </div>

            {/* ── Promote (a not-promotable promote-stage build already returned null above,
                 so reaching here means rdPromotable is true) ── */}
            {stage === 'promote' && (
                <div className="space-y-3">
                    <p className="text-xs text-zinc-600">
                        Build is ready. Promote it to {isIos ? 'App Store' : 'Google Play'} review with the
                        release notes below — nothing goes live until you roll it out.
                    </p>
                    {!showPromote ? (
                        <Button
                            size="sm"
                            disabled={!canPromote}
                            onClick={openPromote}
                            className="bg-indigo-600 text-white hover:bg-indigo-700"
                        >
                            <Send size={13} /> Promote to Review
                        </Button>
                    ) : (
                        <div className="space-y-2 rounded-md border border-indigo-200 bg-white/70 p-3">
                            <label className="block text-[11px] font-medium uppercase tracking-wider text-zinc-600">
                                Release notes (What&apos;s New)
                            </label>
                            <textarea
                                value={notes}
                                onChange={(e) => setNotes(e.target.value)}
                                rows={5}
                                placeholder="What changed in this release…"
                                className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 focus:border-transparent focus:outline-none focus:ring-2 focus:ring-indigo-400"
                            />
                            {isIos && (
                                <label className="flex cursor-pointer items-center gap-2 text-xs text-zinc-600">
                                    <input
                                        type="checkbox"
                                        checked={phased}
                                        onChange={(e) => setPhased(e.target.checked)}
                                        className="rounded border-zinc-300 accent-indigo-600"
                                    />
                                    Enable Apple’s 7-day phased release
                                </label>
                            )}
                            <div className="flex items-center gap-2 pt-1">
                                <Button
                                    size="sm"
                                    loading={busy === 'Promoted to review'}
                                    disabled={!canPromote || !notes.trim()}
                                    onClick={submitPromote}
                                    className="bg-indigo-600 text-white hover:bg-indigo-700"
                                >
                                    Submit for review
                                </Button>
                                <Button size="sm" variant="ghost" onClick={() => setShowPromote(false)}>
                                    Cancel
                                </Button>
                            </div>
                            {!canPromote && (
                                <p className="text-[11px] text-amber-600">
                                    You need the RELEASE_PROMOTE permission to submit.
                                </p>
                            )}
                        </div>
                    )}
                </div>
            )}

            {/* ── In review ── */}
            {stage === 'review' && (
                <div className="space-y-3">
                    {isIos ? (
                        <div className="space-y-2">
                            <p className="flex items-center gap-1.5 text-xs text-zinc-600">
                                <Loader2 size={12} className="animate-spin text-indigo-500" />
                                Waiting on App Store review — the outcome is detected automatically.
                            </p>
                            <Button
                                size="sm"
                                variant="outline"
                                className="border-red-300 text-red-700 hover:bg-red-50"
                                disabled={!canPromote}
                                loading={busy === 'Withdrawn from review'}
                                onClick={() => run('Withdrawn from review', () => mobileApi.withdraw(releaseId))}
                            >
                                <XCircle size={13} /> Withdraw from review
                            </Button>
                            <p className="text-[11px] text-zinc-500">
                                Cancels the App Store submission and aborts this release — use it to pull a bad
                                build before it&apos;s approved.
                            </p>
                        </div>
                    ) : (
                        <>
                            <p className="text-xs text-zinc-600">
                                Submitted to Google Play. Play review is <strong>opaque</strong> (no API
                                signal), so confirm the outcome from the Console and record it here.
                            </p>
                            <div className="flex flex-wrap items-center gap-2">
                                <Button
                                    size="sm"
                                    variant="success"
                                    disabled={!canPromote}
                                    loading={busy === 'Marked as approved'}
                                    onClick={() => run('Marked as approved', () => mobileApi.markApproved(releaseId))}
                                >
                                    <CheckCircle2 size={13} /> Mark Approved
                                </Button>
                                <Button
                                    size="sm"
                                    variant="outline"
                                    className="border-red-300 text-red-700 hover:bg-red-50"
                                    disabled={!canPromote}
                                    onClick={() => setShowReject((v) => !v)}
                                >
                                    <XCircle size={13} /> Mark Rejected
                                </Button>
                                <a href={PLAY_CONSOLE_URL} target="_blank" rel="noreferrer">
                                    <Button size="sm" variant="ghost">
                                        <ExternalLink size={13} /> Open Play Console
                                    </Button>
                                </a>
                            </div>
                            <p className="flex items-start gap-1.5 text-[11px] leading-relaxed text-zinc-500">
                                <Info size={12} className="mt-0.5 shrink-0 text-zinc-400" />
                                <span>
                                    A submitted Play review <strong>can&apos;t be withdrawn</strong> — Google Play
                                    has no cancel-review API. Wait for the verdict (record it above), or once it&apos;s
                                    live, halt the rollout. To replace it, ship a new build.
                                </span>
                            </p>
                            {showReject && (
                                <div className="space-y-2 rounded-md border border-red-200 bg-white/70 p-3">
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

            {/* ── Approved (held) ── */}
            {stage === 'approved' && (
                <div className="space-y-3">
                    <p className="flex items-center gap-1.5 text-xs text-zinc-700">
                        <CheckCircle2 size={13} className="text-emerald-600" />
                        Approved and held — nothing is live yet.
                    </p>
                    {isIos ? (
                        <div className="space-y-2">
                            <p className="flex items-center gap-1.5 text-xs text-zinc-600">
                                {d.rdPhasedId ? (
                                    <>
                                        <Clock size={12} className="shrink-0 text-indigo-500" />
                                        <span>
                                            <strong>Phased release</strong> — Apple ramps this to all users over
                                            7 days (1/2/5/10/20/50/100%). You can pause or release-to-all anytime.
                                        </span>
                                    </>
                                ) : (
                                    <>
                                        <Rocket size={12} className="shrink-0 text-indigo-500" />
                                        <span>
                                            Releases to <strong>all users immediately</strong> — no phased rollout.
                                        </span>
                                    </>
                                )}
                            </p>
                            <Button
                                size="sm"
                                disabled={!canRollout}
                                loading={busy === 'Released'}
                                onClick={() => run('Released', () => mobileApi.releaseApproved(releaseId))}
                                className="bg-indigo-600 text-white hover:bg-indigo-700"
                                title={d.rdPhasedId ? 'Start the 7-day phased release' : 'Release to all users now'}
                            >
                                <Rocket size={13} /> {d.rdPhasedId ? 'Release (phased · 7 days)' : 'Release to all users'}
                            </Button>
                        </div>
                    ) : !d.rdLiveOnProduction ? (
                        // Android approved but not serving on production yet: the build counts as
                        // live only once it's rolling out above 1% (or fully released). Below that
                        // it's staged (e.g. held under Managed Publishing) and a rollout % wouldn't
                        // apply — so point the operator at the Play Console to Publish, then a hard
                        // Refresh (forces a store sync) flips rdLiveOnProduction and reveals the
                        // rollout controls.
                        <PublishGate
                            consoleUrl={PLAY_CONSOLE_URL}
                            syncing={syncing}
                            onRefresh={syncAndRefetch}
                            syncedSecondsAgo={d.rdSyncedSecondsAgo}
                            cooldownSeconds={d.rdRefreshCooldownSeconds}
                        />
                    ) : (
                        <RolloutControls
                            pct={pct}
                            setPct={setPct}
                            onSet={submitRollout}
                            onReleaseAll={() => run('Released to 100%', () => mobileApi.rolloutReleaseAll(releaseId))}
                            canRollout={canRollout}
                            busy={busy}
                            showHaltResume={false}
                            halted={false}
                            onHalt={() => {}}
                            onResume={() => {}}
                        />
                    )}
                </div>
            )}

            {/* ── Rolling out ── */}
            {stage === 'rollout' && (
                <div className="space-y-3">
                    <p className="text-xs text-zinc-700">
                        {d.rdRolloutStatus === 'halted' ? 'Rollout paused' : 'Rolling out'} at{' '}
                        <strong>{pctLabel}</strong>
                        {isIos && ' (Apple controls the phased ramp)'}.
                    </p>
                    {isIos ? (
                        <div className="flex flex-wrap items-center gap-2">
                            <Button
                                size="sm"
                                variant="outline"
                                disabled={!canRollout}
                                loading={busy === 'Rollout paused'}
                                onClick={() => run('Rollout paused', () => mobileApi.rolloutHalt(releaseId))}
                            >
                                <PauseCircle size={13} /> Pause
                            </Button>
                            <Button
                                size="sm"
                                variant="outline"
                                disabled={!canRollout}
                                loading={busy === 'Rollout resumed'}
                                onClick={() => run('Rollout resumed', () => mobileApi.rolloutResume(releaseId))}
                            >
                                <PlayCircle size={13} /> Resume
                            </Button>
                            <Button
                                size="sm"
                                disabled={!canRollout}
                                loading={busy === 'Released to 100%'}
                                onClick={() => run('Released to 100%', () => mobileApi.rolloutReleaseAll(releaseId))}
                                className="bg-indigo-600 text-white hover:bg-indigo-700"
                            >
                                <Flag size={13} /> Release to all
                            </Button>
                        </div>
                    ) : (
                        <RolloutControls
                            pct={pct}
                            setPct={setPct}
                            onSet={submitRollout}
                            onReleaseAll={() => run('Released to 100%', () => mobileApi.rolloutReleaseAll(releaseId))}
                            canRollout={canRollout}
                            busy={busy}
                            showHaltResume
                            halted={d.rdRolloutStatus === 'halted'}
                            onHalt={() => run('Rollout paused', () => mobileApi.rolloutHalt(releaseId))}
                            onResume={() => run('Rollout resumed', () => mobileApi.rolloutResume(releaseId))}
                        />
                    )}
                </div>
            )}

            {/* ── Rejected (terminal) ── */}
            {stage === 'rejected' && (
                <div className="space-y-1">
                    <p className="flex items-center gap-1.5 text-xs font-medium text-red-700">
                        <XCircle size={13} /> Review rejected
                    </p>
                    {d.rdReviewRejectReason && (
                        <p className="rounded-md border border-red-200 bg-white/70 p-2 text-xs text-zinc-700">
                            {d.rdReviewRejectReason}
                        </p>
                    )}
                    <p className="text-[11px] text-zinc-500">
                        Fix the issue and create a new release to resubmit.
                    </p>
                </div>
            )}

            {/* ── Completed ── */}
            {stage === 'completed' && (
                <p className="flex items-center gap-1.5 text-xs font-medium text-emerald-700">
                    <CheckCircle2 size={13} /> Released to 100% of users.
                </p>
            )}
        </div>
    );
}

// Renders the one canonical backend displayStatus — no FE re-derivation.
function StageBadge({
    label,
    variant,
}: {
    label: string;
    variant: 'default' | 'success' | 'warning' | 'danger' | 'info' | 'purple' | 'blue';
}) {
    return (
        <Badge variant={variant} dot>
            {label}
        </Badge>
    );
}

/**
 * Android-only "held under Managed Publishing" gate. The build is approved and staged on
 * the production track, but nothing is live until the operator clicks Publish in the Play
 * Console — and a rollout % set here wouldn't apply until then. So instead of the rollout
 * controls we show a Publish link + a Refresh that forces a store sync (which is what flips
 * `rdLiveOnProduction` once the change is published).
 */
// "Xs" under a minute, else "Xm" — coarse freshness label.
function fmtAge(secs: number): string {
    return secs < 60 ? `${Math.round(secs)}s` : `${Math.round(secs / 60)}m`;
}

function PublishGate({
    consoleUrl,
    syncing,
    onRefresh,
    syncedSecondsAgo,
    cooldownSeconds,
}: {
    consoleUrl: string;
    syncing: boolean;
    onRefresh: () => void;
    syncedSecondsAgo: number | null;
    cooldownSeconds: number;
}) {
    // A Refresh only re-polls the LIVE store once the last sync is older than the
    // cooldown; within the window it serves cache (protects Play's edit quota). Surface
    // that so the operator knows whether clicking now will actually pick up their publish.
    const liveReady = syncedSecondsAgo == null || syncedSecondsAgo >= cooldownSeconds;
    const waitSecs = liveReady ? 0 : Math.ceil(cooldownSeconds - syncedSecondsAgo!);
    return (
        <div className="space-y-2.5 rounded-md border border-amber-200 bg-amber-50 p-3">
            <p className="flex items-start gap-1.5 text-xs leading-relaxed text-amber-800">
                <Info size={13} className="mt-0.5 shrink-0 text-amber-600" />
                <span>
                    <strong>Staged, not live yet.</strong> Counts as live only above <strong>1%</strong>{' '}
                    rollout (or fully released). Publish in the Play Console if held, then Refresh.
                </span>
            </p>
            <div className="flex flex-wrap items-center gap-2">
                <a href={consoleUrl} target="_blank" rel="noreferrer">
                    <Button size="sm" className="bg-indigo-600 text-white hover:bg-indigo-700">
                        <ExternalLink size={13} /> Open Play Console
                    </Button>
                </a>
                <Button size="sm" variant="outline" loading={syncing} onClick={onRefresh}>
                    <RefreshCw size={13} /> I&apos;ve published — Refresh
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

function RolloutControls({
    pct,
    setPct,
    onSet,
    onReleaseAll,
    canRollout,
    busy,
    showHaltResume,
    halted,
    onHalt,
    onResume,
}: {
    pct: string;
    setPct: (v: string) => void;
    onSet: () => void;
    onReleaseAll: () => void;
    canRollout: boolean;
    busy: string | null;
    showHaltResume: boolean;
    halted: boolean;
    onHalt: () => void;
    onResume: () => void;
}) {
    return (
        <div className="space-y-2">
            <div className="flex flex-wrap items-end gap-2">
                <div className="w-28">
                    <label className="block text-[11px] font-medium uppercase tracking-wider text-zinc-600">
                        Rollout %
                    </label>
                    <input
                        type="number"
                        min={0}
                        max={100}
                        step="any"
                        value={pct}
                        onChange={(e) => setPct(e.target.value)}
                        placeholder="e.g. 10"
                        className="mt-1 h-9 w-full rounded-md border border-zinc-300 bg-white px-2 text-sm focus:border-transparent focus:outline-none focus:ring-2 focus:ring-indigo-400"
                    />
                </div>
                <Button
                    size="sm"
                    disabled={!canRollout}
                    loading={busy?.startsWith('Rollout set')}
                    onClick={onSet}
                    className="bg-indigo-600 text-white hover:bg-indigo-700"
                >
                    Set %
                </Button>
                {showHaltResume &&
                    (halted ? (
                        <Button
                            size="sm"
                            variant="outline"
                            disabled={!canRollout}
                            loading={busy === 'Rollout resumed'}
                            onClick={onResume}
                        >
                            <PlayCircle size={13} /> Resume
                        </Button>
                    ) : (
                        <Button
                            size="sm"
                            variant="outline"
                            disabled={!canRollout}
                            loading={busy === 'Rollout paused'}
                            onClick={onHalt}
                        >
                            <PauseCircle size={13} /> Halt
                        </Button>
                    ))}
                <Button
                    size="sm"
                    variant="outline"
                    disabled={!canRollout}
                    loading={busy === 'Released to 100%'}
                    onClick={onReleaseAll}
                >
                    <Flag size={13} /> Release to 100%
                </Button>
            </div>
            <p className="flex items-start gap-1.5 rounded-md border border-amber-200 bg-amber-50 px-2.5 py-1.5 text-[11px] leading-relaxed text-amber-800">
                <Info size={12} className="mt-0.5 shrink-0 text-amber-600" />
                <span>
                    Play applies this through Console publishing. If <strong>Managed Publishing</strong> is on for
                    this app, the change is <strong>staged</strong> under Play Console → Publishing overview — click{' '}
                    <strong>Publish</strong> there to apply it. The % here reflects the <strong>live</strong> track,
                    so it only moves once the change is published.
                </span>
            </p>
        </div>
    );
}
