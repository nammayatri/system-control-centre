import { useCallback, useState, type CSSProperties } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { Check, Send, Square, Trash2, Undo2, X } from 'lucide-react';
import { RocketLaunchIcon } from '@phosphor-icons/react';
import { useAuth } from '../../../../../core/auth/AuthContext';
import { PermissionGate } from '../../../../../core/auth/PermissionGate';
import { usePermissions } from '../../../../../core/auth/PermissionsContext';
import { useRefreshAnimation } from '../../../../../shared/hooks';
import { Button } from '../../../../../shared/ui/button';
import { CardSkeleton } from '../../../../../shared/ui/skeleton';
import { SimpleTooltip } from '../../../../../shared/ui/tooltip';
import { useConfirm } from '../../../../../shared/ui/confirm-dialog';
import { cn } from '../../../../../lib/utils';
import {
  useRelease,
  useReleaseEvents,
  useApproveRelease,
  useDiscardRelease,
  useAbortRelease,
  useDeleteRelease,
  useDispatchMobileReleases,
  useMobileRollout,
  useMobileApps,
} from '../../../hooks';
import { useGroupOta } from '../../../otaApi';
import { ReleaseEventsTab } from '../../../components/ReleaseEventsTab';
import ReleaseSummary from '../../ReleaseSummary';
import { SummaryHeader } from './SummaryHeader';
import { RevertChainBanners } from './RevertChainBanners';
import { PhaseRail } from './PhaseRail';
import { ChangelogCard, ProvenanceCard } from './BuildDetailsCard';
import { StoreReleaseCockpit } from './StoreReleaseCockpit';
import { OtaFlow } from './OtaFlow';
import { deriveScenario } from './scenario';
import { mobileDisplayOf } from '../../../components/V4StatusPill';

/**
 * Mobile Release Summary — v4 design (docs/design/
 * mobile-release-summary-mockup-v4.html): data orchestration + layout here,
 * presentation in the sibling components. The mockup's state machine is real:
 * deriveScenario() drives every accent from canonical release state.
 *
 * Phase 1 of the design adoption: shell + info cards are final; the Store
 * Release cockpit (Phase 2) and OTA rail (Phase 3) render their design shells
 * with the stage controls landing in their phases.
 */
const MobileReleaseSummary = () => {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const [activeTab, setActiveTab] = useState<'summary' | 'events' | 'json'>('summary');

  // Polls every 10s until the release reaches a terminal status (hook-owned).
  const { data: release, isLoading, isFetching, error, refetch } = useRelease(id, { mobile: true });
  const { data: events = [] } = useReleaseEvents(id, { mobile: true });
  const qc = useQueryClient();
  const { user: authUser } = useAuth();
  const actor = authUser?.email || 'admin';

  const approveMut = useApproveRelease();
  const discardMut = useDiscardRelease();
  const abortMut = useAbortRelease();
  const deleteMut = useDeleteRelease();
  const dispatchMobileMut = useDispatchMobileReleases();

  // Rollout + OTA queries stay above the early returns (rules of hooks);
  // `enabled` flags are read off the possibly-undefined release. Both share
  // their cache keys with the panels below (deduped, no double fetch).
  const rolloutQ = useMobileRollout(id, release?.tracker_type === 'MobileBuild');
  const groupId =
    release?.tracker_type === 'MobileBuild'
      ? (release?.release_context?.release_group_id ?? undefined)
      : undefined;
  const otaQ = useGroupOta(groupId, release?.release_context?.build_type !== 'debug');
  const { hasPermission: hasPerm } = usePermissions();
  const { data: mobileApps = [] } = useMobileApps();
  const confirmAction = useConfirm();

  // Refresh scope: release + events, plus the two mobile panels' caches (the
  // backend serves its own store-refresh cooldown, so this is always safe).
  const doRefresh = useCallback(async () => {
    await Promise.all([
      refetch(),
      qc.invalidateQueries({ queryKey: ['release-events', id] }),
      qc.invalidateQueries({ queryKey: ['mobile-rollout', id] }),
      ...(groupId ? [qc.invalidateQueries({ queryKey: ['mobile-group-ota', groupId] })] : []),
    ]);
  }, [refetch, qc, id, groupId]);
  const { spinning: refreshSpinning, onRefresh: handleRefresh } = useRefreshAnimation(isFetching, doRefresh);

  const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

  // `label` is a short verb ("approve", "dispatch") used as title/confirm label;
  // `description` overrides the generic confirmation body for action-specific wording.
  const doAction = async (
    label: string,
    fn: () => Promise<any>,
    isDanger = false,
    description?: string,
  ) => {
    const ok = await confirmAction({
      title: `${cap(label)} Release`,
      description:
        description ??
        `Are you sure you want to ${label} this release? This action cannot be undone.`,
      confirmLabel: cap(label),
      variant: isDanger ? 'danger' : 'primary',
    });
    if (!ok) return;
    try { await fn(); } catch (err: any) {
      // Safety net — individual mutations fire their own error toasts.
      console.error('[doAction]', err);
    }
  };

  if (isLoading && !release) {
    return (
      <div className="flex flex-col flex-1 w-full pb-12 space-y-6">
        <CardSkeleton />
        <CardSkeleton />
      </div>
    );
  }
  if (error && !release) return <div className="p-8 text-center text-red-500">Release not found</div>;
  if (!release) return null;

  // A backend release deep-linked under /mobile/releases/:id belongs to the
  // shared page (which never delegates non-mobile rows back here — no loop).
  if (release.tracker_type !== 'MobileBuild') return <ReleaseSummary />;

  const s = release.status;
  const rollout = rolloutQ.data;
  const scenario = deriveScenario(release, rollout);
  const isDebug = release.release_context?.build_type === 'debug';

  // Which OTA card belongs on this page (unmapped apps → none).
  const otaCapable = otaQ.data?.available
    ? otaQ.data.capableApps.find(
        (c) => c.appName === release.appGroup && c.platform === release.env,
      )
    : undefined;

  // Operator-facing status text. Override the raw engine status only when it's
  // the misleading one — INPROGRESS (awaiting a human), a promotable store-sync
  // snapshot, or a COMPLETED live-mirror row the store says is actively
  // ramping. Terminal states keep their truthful label.
  const isPromotableSnapshot =
    (rollout?.rdStoreTrack === 'internal' || rollout?.rdStoreTrack === 'testflight') &&
    !!rollout?.rdPromotable;
  const activeStorePhase = ['rolling_out', 'halted'].includes(rollout?.rdPhase ?? '');
  const liveStatusWins =
    rollout &&
    (s === 'INPROGRESS' || isPromotableSnapshot || activeStorePhase) &&
    rollout.rdPhase !== 'building';
  // Terminal rows must never show their stale display_label (an aborted promote
  // still carries "Ready to promote") — canonical pill derivation wins there.
  const isDead = ['ABORTED', 'USER_ABORTED', 'GCLT_ABORTED', 'DISCARDED', 'REVERTED'].includes(s);
  const statusLabel = isDead
    ? mobileDisplayOf(release).label
    : ((liveStatusWins ? rollout!.rdStatusLabel : null) ??
      release.release_context?.display_label ??
      cap(s.toLowerCase().replace(/_/g, ' ')));

  // Shared-run blast radius: abort cancels the whole GitHub run, so warn which
  // sibling apps' still-running builds die with it (BE lists those only).
  const mobileAbortWarning = rollout?.rdRunSiblings?.length
    ? `This cancels the shared GitHub run. Still building in the same run and will ALSO be cancelled: ${rollout.rdRunSiblings.join(', ')}.`
    : undefined;

  const matchedMobileApp = mobileApps.find(
    (a) => a.name === release.appGroup && a.surface === release.service && a.platform === release.env,
  );

  const crashlyticsUrl = (() => {
    const fbProject = matchedMobileApp?.firebaseProjectId || '_';
    const pkg = matchedMobileApp?.packageName;
    const platform = release.env;
    const version = release.new_version;
    const versionCode = release.release_context?.version_code;
    if (pkg && platform) {
      const base = `https://console.firebase.google.com/project/${fbProject}/crashlytics/app/${platform}:${pkg}/issues`;
      const params = new URLSearchParams({ state: 'open', time: '7d', types: 'crash', tag: 'all', sort: 'eventCount' });
      if (version && versionCode) {
        params.set('versions', `${version} (${versionCode})`);
      }
      return `${base}?${params.toString()}`;
    }
    return `https://console.firebase.google.com/project/${fbProject}/crashlytics`;
  })();

  const revertsTarget = release.revertsReleaseId || null;
  const revertedByTarget = release.metadata?.reverted_by || null;

  const tabs = [
    { key: 'summary' as const, label: 'Summary' },
    { key: 'events' as const, label: 'Events', count: events.length },
    // No ENV Diff: mobile builds don't deploy YAML.
    { key: 'json' as const, label: 'JSON Data' },
  ];

  // Mutually-exclusive header actions (mockup rule): Abort only while
  // un-shipped, Revert only for shipped builds, Delete on terminal rows.
  const actions = (
    <>
      {s === 'CREATED' && release.is_approved === 0 && (
        <PermissionGate product="autopilot" permission="RELEASE_APPROVE" appGroup={release.appGroup}>
          <Button
            size="sm"
            variant="success"
            loading={approveMut.isPending}
            onClick={() => doAction('approve', () => approveMut.mutateAsync({ releaseId: id!, approvedBy: actor }))}
          >
            <Check className="w-3.5 h-3.5" /> Approve
          </Button>
        </PermissionGate>
      )}
      {s === 'CREATED' && !!release.is_approved && (
        <PermissionGate product="autopilot" permission="MOBILE_DISPATCH" appGroup={release.appGroup}>
          <Button
            size="sm"
            variant="outline"
            className="border-emerald-300 text-emerald-700 enabled:hover:bg-emerald-50"
            loading={dispatchMobileMut.isPending}
            onClick={() =>
              doAction(
                'dispatch',
                () => dispatchMobileMut.mutateAsync([id!]),
                false,
                'This will dispatch the GitHub workflow for this release. The runner will pick it up and start the build.',
              )
            }
          >
            <Send className="w-3.5 h-3.5" /> Dispatch
          </Button>
        </PermissionGate>
      )}
      {s === 'CREATED' && (
        <PermissionGate product="autopilot" permission="RELEASE_DISCARD" appGroup={release.appGroup}>
          <Button
            size="sm"
            variant="outline"
            className="border-red-300 text-red-700 enabled:hover:bg-red-50"
            loading={discardMut.isPending}
            onClick={() => doAction('discard', () => discardMut.mutateAsync({ releaseId: id! }), true)}
          >
            <X className="w-3.5 h-3.5" /> Discard
          </Button>
        </PermissionGate>
      )}
      {/* Abort visibility is BE-driven (rdAbortable): shown only while the build
          is still Building. A rejected / on-store / terminal build can't be
          un-shipped, so Abort is hidden. */}
      {s === 'INPROGRESS' && !!rollout?.rdAbortable && (
        <PermissionGate product="autopilot" permission="RELEASE_PAUSE" appGroup={release.appGroup}>
          <Button
            size="sm"
            variant="secondary"
            loading={abortMut.isPending}
            onClick={() => doAction('abort', () => abortMut.mutateAsync(id!), true, mobileAbortWarning)}
            title={mobileAbortWarning}
          >
            <Square className="w-3.5 h-3.5" /> Abort
          </Button>
        </PermissionGate>
      )}
      {/* Dedicated revert flow: the /revert page loads a BE draft (previous-good
          commit + auto-changelog) and POSTs a new release row. No revert-of-a-
          revert, no re-revert, no debug reverts. */}
      {s === 'COMPLETED' &&
        !revertedByTarget &&
        !revertsTarget &&
        !isDebug && (
          <PermissionGate product="autopilot" permission="RELEASE_REVERT" appGroup={release.appGroup}>
            <Button
              size="sm"
              variant="secondary"
              className="border-red-200 text-red-600 enabled:hover:bg-red-50"
              onClick={() => navigate(`/mobile/releases/${id}/revert`)}
            >
              <Undo2 className="w-3.5 h-3.5" /> Revert
            </Button>
          </PermissionGate>
        )}
      <PermissionGate product="autopilot" permission="RELEASE_DELETE" appGroup={release.appGroup}>
        <SimpleTooltip content="Delete">
          <Button
            size="icon"
            variant="ghost"
            className="text-red-500 enabled:hover:bg-red-50"
            loading={deleteMut.isPending}
            onClick={() =>
              doAction(
                'delete',
                async () => {
                  await deleteMut.mutateAsync(id!);
                  navigate('/mobile/releases');
                },
                true,
                'Delete this release tracker permanently. This removes the audit trail and cannot be undone.',
              )
            }
          >
            <Trash2 className="w-4 h-4" />
          </Button>
        </SimpleTooltip>
      </PermissionGate>
    </>
  );

  return (
    <div className="flex flex-col flex-1 w-full pb-12">
      <SummaryHeader
        release={release}
        scenario={scenario}
        statusLabel={statusLabel}
        rollout={rollout}
        crashlyticsUrl={crashlyticsUrl}
        matchedApp={matchedMobileApp}
        actions={actions}
        syncedSecondsAgo={rollout?.rdSyncedSecondsAgo}
        onRefresh={handleRefresh}
        refreshSpinning={refreshSpinning}
      />

      <RevertChainBanners release={release} />

      {/* THE PHASE RAIL */}
      <section className="card-surface px-6 py-8 mb-6 stagger-item" style={{ '--index': 1 } as CSSProperties}>
        <p className="eyebrow mb-6">Release Lifecycle · Native Binary</p>
        <PhaseRail release={release} rollout={rollout} />
      </section>

      {/* TABS */}
      <div className="flex items-center gap-6 border-b border-zinc-200 px-2 mb-6 stagger-item" style={{ '--index': 2 } as CSSProperties}>
        {tabs.map((tab) => (
          <button
            key={tab.key}
            onClick={() => setActiveTab(tab.key)}
            className={cn(
              'pb-3 border-b-2 text-sm transition-colors duration-150 cursor-pointer whitespace-nowrap group',
              activeTab === tab.key
                ? 'border-zinc-900 font-bold text-zinc-900'
                : 'border-transparent font-medium text-zinc-500 hover:text-zinc-800',
            )}
          >
            {tab.label}
            {tab.count != null && tab.count > 0 && (
              <span className="bg-zinc-100 text-zinc-600 text-[10px] px-1.5 py-0.5 rounded ml-1 group-hover:bg-zinc-200">
                {tab.count}
              </span>
            )}
          </button>
        ))}
      </div>

      {activeTab === 'summary' && (
        <div className="grid grid-cols-1 lg:grid-cols-12 gap-6 items-start">
          {/* LEFT COLUMN: NATIVE FLOW */}
          <div className="col-span-1 lg:col-span-7 flex flex-col gap-6">
            {/* Store Release cockpit — real stage controls (promote → review →
                approved → rollout) driven by the shared rollout detail. */}
            {!isDebug && (
              <div className="stagger-item" style={{ '--index': 3 } as CSSProperties}>
                <StoreReleaseCockpit
                  release={release}
                  rollout={rollout}
                  scenario={scenario}
                  statusLabel={statusLabel}
                  appKey={`${release.appGroup}/${release.env}`}
                />
              </div>
            )}


            <ProvenanceCard release={release} events={events} matchedApp={matchedMobileApp} index={5} />
            <ChangelogCard release={release} index={6} />
          </div>

          {/* RIGHT COLUMN: OTA FLOW — strictly separated */}
          {!isDebug && (
            <div className="col-span-1 lg:col-span-5 flex flex-col stagger-item" style={{ '--index': 4 } as CSSProperties}>
              {otaCapable ? (
                <OtaFlow
                  groupId={groupId ?? ''}
                  releaseId={release.id}
                  appName={release.appGroup}
                  platform={release.env}
                  airborneAppRef={otaCapable.airborneAppRef}
                  sourceRef={release.sourceRef ?? null}
                  nativeVersion={release.new_version ?? null}
                  buildSuperseded={otaCapable.superseded}
                  pushEligible={otaCapable.pushEligible}
                  ineligibleReason={otaCapable.ineligibleReason}
                  releaseBlocked={otaCapable.releaseBlocked ?? null}
                  pushes={otaQ.data?.rows ?? []}
                  links={otaQ.data?.links ?? []}
                  activePush={otaQ.data?.activePush ?? null}
                  canDispatch={hasPerm('mobile', 'MB_MOBILE_DISPATCH', `${release.appGroup}/${release.env}`)}
                  onChanged={() => void otaQ.refetch()}
                />
              ) : otaQ.data ? (
                <div className="card-surface p-8 flex flex-col items-center justify-center text-center h-48 border-dashed border-2 border-zinc-200 shadow-none">
                  <RocketLaunchIcon size={36} weight="duotone" className="text-zinc-300 mb-3" aria-hidden="true" />
                  <h3 className="text-sm font-bold text-zinc-700">No OTA available</h3>
                  <p className="text-xs text-zinc-500 mt-1 max-w-[220px]">
                    {release.service === 'driver'
                      ? 'Airborne is not available for provider apps.'
                      : 'This app has no Airborne mapping configured — set "OTA ref" in Mobile Apps admin.'}
                  </p>
                </div>
              ) : null}
            </div>
          )}
        </div>
      )}

      {activeTab === 'events' && (
        <div className="card-surface stagger-item" style={{ '--index': 3 } as CSSProperties}>
          <ReleaseEventsTab events={events} />
        </div>
      )}

      {activeTab === 'json' && (
        <div className="card-surface p-4 sm:p-6 stagger-item" style={{ '--index': 3 } as CSSProperties}>
          <pre className="bg-zinc-50 border border-zinc-200 rounded-lg p-3 sm:p-4 text-[11px] sm:text-xs font-mono text-zinc-700 overflow-auto max-h-[600px] whitespace-pre-wrap break-all">
            {JSON.stringify(release, null, 2)}
          </pre>
        </div>
      )}
    </div>
  );
};

export default MobileReleaseSummary;
