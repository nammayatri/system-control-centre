import { apiClient } from '../../lib/api-client';

// ── Rollout types ──────────────────────────────────────────────────

export interface RolloutStrategyEvent {
    rollout: number;
    cooloff: number;
    pods: number;
}

export interface RolloutHistoryEvent {
    rollout: number;
    cooloff: number;
    pods: number;
    last_decision: string;
    decision_result: string;
    started_at: string;
    completed_at: string;
    manual_override: boolean;
    last_decision_hs: string;
    decision_hs_result: string;
}

export interface RolloutEvent {
    category: string;
    label: string;
    data: string;
    timestamp: string;
}

// ── Release context ────────────────────────────────────────────────

export interface Matches {
    match: string;
    running_version: string;
    weight: number;
}

export interface ReleaseContext {
    // ── K8s / backend fields ────────────────────────────────────────
    cluster: string;
    namespace: string;
    deployment_name: string;
    vs_name: string;
    docker_image: string;
    matches: Matches[];
    pods_scale_down_timestamp: string;
    pods_scale_down_status: string;
    old_version_pod_count: number;
    revert: number;
    deploy_file_path: string;
    service_file_path: string;
    dr_file_path: string;
    vs_file_path: string;
    sync_cluster_env_override_data: string;
    sync_cluster_rollout_strategy: string;
    sync_x_forwarded_email: string;
    sync_x_pomerium_jwt: string;
    // ── Mobile-build fields (populated only for MobileBuild releases) ─
    kind?: string;
    release_group_id?: string;
    version_code?: number;
    tag_pushed?: string | null;
    matrix_job_name?: string;
    build_type?: string;
    ota_namespace?: string | null;
    change_log?: string;
    // Mobile build workflow status (e.g. MBTagPushed / MBInReview / MBRollingOut).
    // Injected by the backend serializer from the MobileBuildState so the list +
    // detail can derive the promote→rollout stage without a /rollout call.
    mb_wf_status?: string;
}

// ── All statuses (UPPERCASE — canonical) ─────

export type ReleaseStatus =
    | 'CREATED'
    | 'INPROGRESS'
    | 'COMPLETED'
    | 'ABORTED'
    | 'USER_ABORTED'
    | 'GCLT_ABORTED'
    | 'DISCARDED'
    | 'DISCARDING'
    | 'PAUSED'
    | 'ABORTING'
    | 'REVERTING'
    | 'REVERTED'
    | 'RESTARTING';

export const TERMINAL_STATUSES: ReleaseStatus[] = [
    'ABORTED', 'USER_ABORTED', 'GCLT_ABORTED', 'COMPLETED', 'DISCARDED', 'REVERTED'
];

export const ABORTED_STATUSES: ReleaseStatus[] = [
    'ABORTED', 'USER_ABORTED', 'GCLT_ABORTED', 'ABORTING'
];

// ── Main release type ──────────────────────────────────────────────

export interface APRelease {
    service: string;
    id: string;
    new_version: string;
    status: ReleaseStatus;
    description: string;
    date_created: string;
    start_time: string;
    release_tag: string;
    discription: string;
    docker_image?: string;
    old_version: string;
    appGroup: string;
    is_approved: number;
    is_infra_approved: number;
    mode: string;
    last_updated: string;
    end_time: string;
    release_manager: string;
    approved_by?: string | null;
    env: string;
    priority: number;
    schedule_time: string;
    change_log: string;
    info: string;
    sync_enabled: string;
    env_override_data: string;
    slack_thread_ts: string;
    global_id: string;
    new_service: string;
    cronjob_suspend: boolean;
    ab_hs_status: string;
    tracker_type: string;
    rollout_strategy: RolloutStrategyEvent[];
    rollout_history: RolloutHistoryEvent[];
    events: RolloutEvent[];
    release_context: ReleaseContext;
    // ── Revert chain (mobile + future backend revert plumbing) ──────
    // Server-side optional; null on rows that pre-date 0012-mobile-revert.
    sourceRef?: string | null;
    commitSha?: string | null;
    revertsReleaseId?: string | null;
    // `metadata.reverted_by` is set on a bad release once its revert
    // row has been created. Drives the "Reverted by" banner.
    metadata?: { reverted_by?: string;[k: string]: any } | null;
    // AB validation fields — null on pre-migration rows.
    abValidationStatus?: ABValidationStatus | null;
    abValidation?: ABValidation | null;
}

// ── AB Validation types ────────────────────────────────────────────

export type ABValidationStatus =
    | 'UNASSIGNED'
    | 'VERIFIED'
    | 'MISSED_ABORT'
    | 'FALSE_ABORT'
    | 'TRUE_ABORT'
    | 'INVALID';

export interface ABValidationEntry {
    abveStatus: ABValidationStatus;
    abveChangedBy: string;
    abveIsApproved: boolean;
    abveRcaDesc?: string | null;
    abveUpdatedAt: string;
}

export interface ABValidation {
    abvStatus: ABValidationStatus;
    abvIsApproved: boolean;
    abvRcaDesc?: string | null;
    abvHistory: ABValidationEntry[];
}

export const AB_STATUS_LABELS: Record<ABValidationStatus, string> = {
    UNASSIGNED: 'Unassigned',
    VERIFIED: 'Verified',
    MISSED_ABORT: 'Missed Abort',
    FALSE_ABORT: 'False Abort',
    TRUE_ABORT: 'True Abort',
    INVALID: 'Invalid',
};

export const AB_STATUS_COLORS: Record<ABValidationStatus, string> = {
    UNASSIGNED: 'bg-gray-400 text-white',
    VERIFIED: 'bg-green-600 text-white',
    MISSED_ABORT: 'bg-orange-500 text-white',
    FALSE_ABORT: 'bg-yellow-500 text-white',
    TRUE_ABORT: 'bg-red-600 text-white',
    INVALID: 'bg-gray-600 text-white',
};

export interface ABMetricItem {
    status: ABValidationStatus;
    count: number;
    percentage: number;
    ab_success_rate?: number;
}

export interface ABMetrics {
    total_releases: number;
    list: ABMetricItem[];
}

// ── ConfigMap type ─────────────────────────────────────────────────

export interface APConfigMap {
    appGroup: string;
    id: string;
    name: string;
    status: string;
    date_created: string;
    start_time: string;
    env: string;
    description: string;
    is_approved: number;
    last_updated: string;
    end_time: string;
    release_manager: string;
    priority: number;
    events: RolloutEvent[];
    change_log: string;
    file: string;
    schedule_time: string;
    slack_thread_id: string;
    cluster: string;
}

// ── Product config ─────────────────────────────────────────────────

export interface ProductConfig {
    id?: number;
    appGroup: string;
    cluster: string;
    namespace: string;
    vs_name: string;
    repo_name?: string;
    product_acronym?: string;
    release_branch?: string;
    product_type: string;
    sync_cluster?: string | null;
    need_infra_approval?: number;
    vs_locked_by?: string | null;
    slack_channel?: string | null;
}

// ── Namma AP backend → frontend normalizer ─────────────────────────

type NammaRelease = {
    releaseId: string;
    service: string;
    appGroup?: string;
    product?: string;  // backward compat
    status: string;
    env: string;
    trackerType?: string;
    mode?: string;
    createdBy?: string;
    createdAt?: string | null;
    dateCreated?: string | null;
    lastUpdated?: string | null;
    approvedBy?: string | null;
    isApproved?: boolean;
    isInfraApproved?: boolean;
    releaseTag?: string;
    scheduleTime?: string | null;
    startTime?: string | null;
    endTime?: string | null;
    description?: string | null;
    changeLog?: string | null;
    info?: string | null;
    priority?: number;
    globalId?: string | null;
    newService?: boolean;
    isArtRecorder?: number;
    cronjobSuspend?: boolean;
    abHsStatus?: string;
    syncEnabled?: string | null;
    envOverrideData?: string | null;
    slackThreadTs?: string | null;
    metadata?: any;
    rolloutStrategy?: Array<{ rolloutPercent: number; cooloffMinutes: number; podCount: number }>;
    rolloutHistory?: Array<{
        historyRolloutPercent: number;
        historyCooloffMinutes: number;
        historyPodsCount: number;
        historyDecision?: string | null;
        historyDecisionReason?: string | null;
        historyStartedAt: string;
        historyCompletedAt?: string | null;
        historyManualOverride?: boolean;
        historyDecisionHs?: string | null;
        historyDecisionHsReason?: string | null;
    }>;
    releaseContext?: {
        cluster?: string;
        namespace?: string;
        deploymentName?: string;
        serviceName?: string;
        destinationRuleName?: string;
        virtualServiceName?: string;
        internalVirtualServiceName?: string | null;
        containerName?: string;
        oldVersion?: string;
        newVersion?: string;
        dockerImage?: string | null;
        matches?: Array<{ matchHost: string; matchRunningVersion: string; matchWeight: number }>;
        podsScaleDownTimestamp?: string | null;
        podsScaleDownStatus?: string | null;
        oldVersionPodCount?: number | null;
        revert?: number | null;
        abRunId?: string | null;
        abStatus?: string | null;
        cleanupAt?: string | null;
        cleanupTargetDeployment?: string | null;
        cleanupStatus?: string | null;
        deployFilePath?: string | null;
        serviceFilePath?: string | null;
        drFilePath?: string | null;
        vsFilePath?: string | null;
        syncClusterEnvOverrideData?: string | null;
        syncClusterRolloutStrategy?: string | null;
        syncXForwardedEmail?: string | null;
        syncXPomeriumJwt?: string | null;
    };
};

/** Backend returns UPPERCASE statuses; normalize any unexpected casing just in case. */
const normalizeStatus = (status?: string): ReleaseStatus => {
    const upper = (status || 'CREATED').toUpperCase().replace(/\s+/g, '_');
    switch (upper) {
        case 'CREATED': return 'CREATED';
        case 'INPROGRESS': return 'INPROGRESS';
        case 'COMPLETED': return 'COMPLETED';
        case 'ABORTED': return 'ABORTED';
        case 'USER_ABORTED': case 'USERABORTED': return 'USER_ABORTED';
        case 'GCLT_ABORTED': case 'GCLTABORTED': return 'GCLT_ABORTED';
        case 'DISCARDED': return 'DISCARDED';
        case 'DISCARDING': return 'DISCARDING';
        case 'PAUSED': return 'PAUSED';
        case 'ABORTING': return 'ABORTING';
        case 'REVERTING': return 'REVERTING';
        case 'REVERTED': return 'REVERTED';
        case 'RESTARTING': return 'RESTARTING';
        default: return (upper || 'CREATED') as ReleaseStatus;
    }
};

const normalizeRelease = (r: NammaRelease): APRelease => ({
    id: r.releaseId,
    service: r.service,
    appGroup: r.appGroup || r.product || '',
    status: normalizeStatus(r.status),
    env: r.env,
    tracker_type: (r as any).category || r.trackerType || 'BackendService',
    mode: (r.mode || 'AUTO').toUpperCase(),
    release_manager: r.createdBy || '',
    approved_by: r.approvedBy || null,
    is_approved: r.isApproved ? 1 : 0,
    is_infra_approved: r.isInfraApproved ? 1 : 0,
    release_tag: r.releaseTag || '',
    schedule_time: r.scheduleTime || '',
    date_created: r.dateCreated || r.createdAt || '',
    start_time: r.startTime || '',
    end_time: r.endTime || '',
    last_updated: r.lastUpdated || '',
    description: r.description || '',
    change_log: r.changeLog || '',
    info: r.info || '',
    priority: r.priority ?? 0,
    global_id: r.globalId || '',
    new_service: r.newService ? 'Yes' : 'No',
    cronjob_suspend: r.cronjobSuspend ?? false,
    ab_hs_status: r.abHsStatus || 'Uninitiated',
    sync_enabled: r.syncEnabled || (r as any).sync_enabled || (r as any).udf1 || '',
    env_override_data: r.envOverrideData || (r as any).env_override_data || (r as any).udf2 || '',
    slack_thread_ts: r.slackThreadTs || (r as any).slack_thread_ts || (r as any).udf3 || '',

    new_version: (r as any).newVersion || r.releaseContext?.newVersion || '',
    old_version: (r as any).oldVersion || r.releaseContext?.oldVersion || '',
    docker_image: (r as any).metadata?.['docker-image'] || r.releaseContext?.dockerImage || '',
    discription: '',

    release_context: {
        cluster: r.releaseContext?.cluster || (r as any).metadata?.cluster || '',
        namespace: r.releaseContext?.namespace || '',
        deployment_name: r.releaseContext?.deploymentName || '',
        vs_name: r.releaseContext?.virtualServiceName || '',
        docker_image: r.releaseContext?.dockerImage || '',
        matches: (r.releaseContext?.matches || []).map(m => ({
            match: m.matchHost || '',
            running_version: m.matchRunningVersion || '',
            weight: m.matchWeight || 0,
        })),
        pods_scale_down_timestamp: r.releaseContext?.podsScaleDownTimestamp || '',
        pods_scale_down_status: r.releaseContext?.podsScaleDownStatus || '',
        old_version_pod_count: r.releaseContext?.oldVersionPodCount ?? 0,
        revert: r.releaseContext?.revert ?? 0,
        deploy_file_path: r.releaseContext?.deployFilePath || '',
        service_file_path: r.releaseContext?.serviceFilePath || '',
        dr_file_path: r.releaseContext?.drFilePath || '',
        vs_file_path: r.releaseContext?.vsFilePath || '',
        sync_cluster_env_override_data: r.releaseContext?.syncClusterEnvOverrideData || '',
        sync_cluster_rollout_strategy: r.releaseContext?.syncClusterRolloutStrategy || '',
        sync_x_forwarded_email: r.releaseContext?.syncXForwardedEmail || '',
        sync_x_pomerium_jwt: r.releaseContext?.syncXPomeriumJwt || '',
        // Mobile fields pass through unchanged from the raw API (snake_case JSON keys).
        kind:             (r.releaseContext as any)?.kind,
        release_group_id: (r.releaseContext as any)?.release_group_id,
        version_code:     (r.releaseContext as any)?.version_code,
        tag_pushed:       (r.releaseContext as any)?.tag_pushed,
        matrix_job_name:  (r.releaseContext as any)?.matrix_job_name,
        build_type:       (r.releaseContext as any)?.build_type,
        ota_namespace:    (r.releaseContext as any)?.ota_namespace,
        change_log:       (r.releaseContext as any)?.change_log,
        mb_wf_status:     (r.releaseContext as any)?.mb_wf_status,
    },

    rollout_strategy: (r.rolloutStrategy || []).map(s => ({
        rollout: s.rolloutPercent,
        cooloff: s.cooloffMinutes,
        pods: s.podCount,
    })),

    rollout_history: (r.rolloutHistory || []).map(h => ({
        rollout: h.historyRolloutPercent,
        cooloff: h.historyCooloffMinutes,
        pods: h.historyPodsCount,
        last_decision: h.historyDecision || '',
        decision_result: h.historyDecisionReason || '',
        started_at: h.historyStartedAt || '',
        completed_at: h.historyCompletedAt || '',
        manual_override: h.historyManualOverride ?? false,
        last_decision_hs: h.historyDecisionHs || '',
        decision_hs_result: h.historyDecisionHsReason || '',
    })),

    events: [],

    // Revert-chain fields — added by migration 0012-mobile-revert.
    // Pre-0012 rows have nulls; consumers must handle undefined too.
    sourceRef: (r as any).sourceRef ?? null,
    commitSha: (r as any).commitSha ?? null,
    revertsReleaseId: (r as any).revertsReleaseId ?? null,
    metadata: (r as any).metadata ?? null,
    abValidationStatus: (r as any).abValidationStatus ?? null,
    abValidation: (r as any).abValidation ?? null,
});

export function statusColor(status: ReleaseStatus | string): string {
    const upper = (status || '').toUpperCase().replace(/\s+/g, '_');
    switch (upper) {
        case 'COMPLETED':
            return 'bg-green-600 text-white';
        case 'INPROGRESS':
        case 'RESTARTING':
            return 'bg-orange-500 text-white';
        case 'PAUSED':
            return 'bg-yellow-500 text-white';
        case 'CREATED':
            return 'bg-blue-600 text-white';
        case 'DISCARDED':
        case 'DISCARDING':
            return 'bg-gray-500 text-white';
        case 'REVERTING':
        case 'REVERTED':
            return 'bg-blue-500 text-white';
        case 'ABORTED':
        case 'USER_ABORTED':
        case 'ABORTING':
            return 'bg-red-500 text-white';
        case 'GCLT_ABORTED':
            return 'bg-red-700 text-white';
        default:
            return 'bg-red-500 text-white';
    }
}

// ── API Calls ──────────────────────────────────────────────────────

/**
 * Category filter accepted by the list endpoint. The backend understands
 * the high-level grouping ("backend"/"mobile") and uses it to expand into
 * the matching ReleaseCategory variants. Pass `undefined`/omit for no
 * filter.
 */
export type ReleaseCategoryFilter = 'backend' | 'mobile' | undefined;

export async function fetchAPReleases(
    from: string,
    to: string,
    category?: ReleaseCategoryFilter,
): Promise<APRelease[]> {
    const params: Record<string, string> = { from, to };
    if (category) params.category = category;
    const { data } = await apiClient.get('/releases', { params });
    const rows = Array.isArray(data) ? data : [];
    return rows.map(normalizeRelease);
}

export async function fetchReleaseDetails(id: string): Promise<APRelease> {
    const { data } = await apiClient.get(`/releases/${id}`);
    if (!data) throw new Error(`Release ${id} not found`);
    return normalizeRelease(data);
}

export async function fetchReleaseEvents(id: string): Promise<RolloutEvent[]> {
    const { data } = await apiClient.get(`/releases/${id}/events`);
    if (!Array.isArray(data)) return [];
    return data.map((e: any) => ({
        category: e.category || '',
        label: e.label || '',
        data: typeof e.data === 'string' ? e.data : JSON.stringify(e.data || ''),
        timestamp: e.timestamp || '',
    }));
}

export async function fetchProductConfigs(): Promise<ProductConfig[]> {
    const { data } = await apiClient.get('/products/config');
    if (!Array.isArray(data)) return [];
    return data.map((p: any) => ({
        id: p.id,
        appGroup: p.appGroup || p.product || '',
        cluster: p.cluster,
        namespace: p.namespace,
        vs_name: p.vsName || '',
        product_type: p.productType || '',
        product_acronym: p.productAcronym || '',
        release_branch: p.releaseBranch || '',
        repo_name: p.repoName || '',
        sync_cluster: p.syncCluster || p.sync_cluster || null,
        need_infra_approval: p.needInfraApproval ? 1 : 0,
        slack_channel: p.slackChannel ?? p.slack_channel ?? null,
        vs_locked_by: p.vsLockedBy || null,
    }));
}

export async function fetchProducts(): Promise<string[]> {
    const configs = await fetchProductConfigs();
    const unique = [...new Set(configs.map(c => c.appGroup).filter(Boolean))];
    return unique;
}

export async function fetchServices(appGroup: string, isNewService: boolean): Promise<string[]> {
    if (!appGroup) return [];
    const { data } = await apiClient.get(`/products/${encodeURIComponent(appGroup)}/services`);
    const services = Array.isArray(data) ? data : [];
    const names = services.map((s: any) => s.service).filter(Boolean);
    return [...new Set(names)];
}

export async function fetchEnvs(appGroup: string, env: string, service: string): Promise<any> {
    if (!appGroup || !env || !service) return [];
    try {
        const { data } = await apiClient.get('/envs', { params: { product: appGroup, env, service } });
        return Array.isArray(data) ? data : [];
    } catch {
        return [];
    }
}

export async function fetchSecondaryEnvs(appGroup: string, env: string, service: string): Promise<any> {
    if (!appGroup || !env || !service) return [];
    try {
        const { data } = await apiClient.get('/envs/secondary', { params: { product: appGroup, env, service } });
        return Array.isArray(data) ? data : [];
    } catch {
        return [];
    }
}

export async function fetchAPConfigMaps(from: string, to: string): Promise<APConfigMap[]> {
    const { data } = await apiClient.get('/tracker/configmap/list', { params: { from, to } });
    // Backend returns either {list: [...]} or a plain array depending on the handler.
    if (Array.isArray(data)) return data;
    if (data && Array.isArray(data.list)) return data.list;
    return [];
}

export async function fetchConfigMapDetail(id: string): Promise<APConfigMap | null> {
    const { data } = await apiClient.get(`/tracker/configmap/${encodeURIComponent(id)}`);
    return data;
}

export async function updateConfigMap(id: string, updates: Record<string, any>): Promise<any> {
    const { data } = await apiClient.put(`/tracker/configmap/${encodeURIComponent(id)}`, updates);
    return data;
}

// ── Release CRUD ───────────────────────────────────────────────────

export async function createRelease(isNewService: boolean, payload: any): Promise<any> {
    const trackerType =
        payload.trackerType ||
        (payload.serviceType === 'SCHEDULER' ? 'BackendScheduler' : 'BackendService');
    const requestBody = {
        appGroup: payload.appGroup || payload.product,
        service: Array.isArray(payload.service) ? payload.service[0] : payload.service,
        env: payload.env || 'UAT',
        requestedCluster: payload.cluster || null,
        trackerType,
        createdBy: payload.release_manager || 'local_admin',
        approvedBy: null,
        releaseTag: payload.release_tag || null,
        scheduleTime: payload.schedule_time || null,
        oldVersion: payload.old_version || 'unknown',
        newVersion: payload.new_version || '',
        deployFilePath: payload.deploy_file_path || null,
        serviceFilePath: payload.service_file_path || null,
        drFilePath: payload.dr_file_path || null,
        vsFilePath: payload.vs_file_path || null,
        rolloutStrategy: (payload.rollout_strategy || []).map((s: any) => ({
            rolloutPercent: Number(s.rollout || 0),
            cooloffMinutes: Number(s.cooloff || 0),
            podCount: Number(s.pods || 0),
        })),
        info: payload.info || null,
        description: payload.description || null,
        metadata: {
            ...(payload.metadata || {}),
            ...(payload.docker_image ? { 'docker-image': payload.docker_image } : {}),
        },
        mode: payload.mode || 'AUTO',
        is_approved: payload.is_approved ? true : false,
        is_infra_approved: payload.is_infra_approved ? true : false,
        priority: payload.priority ?? 0,
        global_id: payload.global_id || null,
        new_service: payload.new_service || false,
        cronjob_suspend: payload.cronjob_suspend || false,
        change_log: payload.change_log || null,
        syncEnabled: payload.sync_enabled || null,
        envOverrideData: payload.env_override_data || null,
        slackThreadTs: payload.slack_thread_ts || null,
        isReleaseSync: payload.isReleaseSync || false,
        syncClusterEnvOverrideData: payload.syncClusterEnvOverrideData || null,
        syncClusterRolloutStrategy: payload.syncClusterRolloutStrategy || null,
    };
    const { data } = await apiClient.post('/releases/create', requestBody);
    return data;
}

export async function approveRelease(releaseId: string, approvedBy: string, isInfraApproved?: boolean): Promise<any> {
    const { data } = await apiClient.post(`/releases/${encodeURIComponent(releaseId)}/approve`, { approvedBy, isInfraApproved: isInfraApproved ?? null });
    return data;
}

export async function rollbackRelease(releaseId: string, reason?: string): Promise<any> {
    const { data } = await apiClient.post(`/releases/${encodeURIComponent(releaseId)}/rollback`, { reason: reason || null });
    return data;
}

export async function revertRelease(releaseId: string, requestedBy?: string, info?: string, immediate?: boolean, isRevertSync?: boolean): Promise<any> {
    const { data } = await apiClient.post(`/releases/${encodeURIComponent(releaseId)}/revert`, {
        requestedBy: requestedBy || null,
        info: info || null,
        immediate: immediate || false,
        isRevertSync: isRevertSync || false,
    });
    return data;
}

export async function discardRelease(releaseId: string, reason?: string): Promise<any> {
    const { data } = await apiClient.post(`/releases/${encodeURIComponent(releaseId)}/discard`, { reason: reason || null });
    return data;
}

export async function updateTracker(releaseId: string, updates: Record<string, any>): Promise<any> {
    const { data } = await apiClient.post(`/releases/${encodeURIComponent(releaseId)}/update`, updates);
    return data;
}

export const pauseRelease = (id: string) => updateTracker(id, { status: 'PAUSED' });
export const resumeRelease = (id: string) => updateTracker(id, { status: 'INPROGRESS' });
export const abortRelease = (id: string) => updateTracker(id, { status: 'ABORTING' });
export const immediateRevert = (id: string, requestedBy?: string) =>
    revertRelease(id, requestedBy, undefined, true);

export async function deleteRelease(releaseId: string): Promise<any> {
    const { data } = await apiClient.post(`/releases/${encodeURIComponent(releaseId)}/delete`);
    return data;
}

export async function restartRelease(releaseId: string): Promise<any> {
    const { data } = await apiClient.post(`/releases/${encodeURIComponent(releaseId)}/restart`, {});
    return data;
}

export async function fastForwardRelease(releaseId: string): Promise<any> {
    const { data } = await apiClient.post(`/releases/${encodeURIComponent(releaseId)}/fast-forward`, {});
    return data;
}

export async function immediateRevertRelease(releaseId: string, isRevertSync: boolean): Promise<any> {
    const { data } = await apiClient.post(`/releases/${encodeURIComponent(releaseId)}/revert/immediate`, { isRevertSync });
    return data;
}

// ── Mobile revert ─────────────────────────────────────────────────
// GET /releases/:id/mobile-revert/draft  — read-only preview
// POST /releases/:id/mobile-revert       — confirm + create
//
// Both gated by RELEASE_REVERT permission. The draft returns the
// previous good release's tag + auto-generated changelog; the create
// endpoint enforces version-name and version-code strictly-greater
// than the bad release's.

export interface RevertCommit {
    rcShortSha: string;
    rcSubject: string;
    rcAuthorLogin: string;
    rcHtmlUrl: string;
    rcPrNumber: number | null;
}

export interface RevertDraft {
    rdBadReleaseId: string;
    rdBadVersion: string;
    rdBadVersionCode: number | null;
    rdPrevGoodReleaseId: string;
    rdPrevGoodVersion: string;
    rdPrevGoodShortSha: string;
    rdPrevGoodTag: string;
    rdSuggestedVersion: string;
    rdSuggestedCode: number | null;
    rdChangelog: string;
    rdCommits: RevertCommit[];
    rdCommitCount: number;
    rdPlatform: string; // "android" | "ios"
    rdIsStoreSyncRevert: boolean;
    rdStoreVersion: string | null;
    rdStoreVersionCode: number | null;
}

export interface RevertCreateReq {
    rrNewVersionName: string;
    rrNewVersionCode: number | null;
    rrChangelog: string;
    rrSourceCommit?: string | null;
}

export interface RevertCreateResp {
    rrRevertReleaseId: string;
}

export async function getMobileRevertDraft(releaseId: string): Promise<RevertDraft> {
    const { data } = await apiClient.get(`/releases/${encodeURIComponent(releaseId)}/mobile-revert/draft`);
    return data;
}

export async function createMobileRevert(
    releaseId: string,
    body: RevertCreateReq,
): Promise<RevertCreateResp> {
    const { data } = await apiClient.post(
        `/releases/${encodeURIComponent(releaseId)}/mobile-revert`,
        body,
    );
    return data;
}

export interface VerifyCommitResp {
    vcFullSha: string;
    vcShortSha: string;
    vcMessage: string;
    vcAuthor: string;
    vcHtmlUrl: string;
}

export async function verifyRevertCommit(
    releaseId: string,
    sha: string,
): Promise<VerifyCommitResp> {
    const { data } = await apiClient.get(
        `/releases/${encodeURIComponent(releaseId)}/mobile-revert/verify-commit`,
        { params: { sha } },
    );
    return data;
}

// Live "commits being rolled back" for whatever source the operator selects
// (previous-good tag, a custom SHA, or a branch) vs the bad release.
export interface RevertDiffResp {
    rdfCommits: RevertCommit[];
    rdfCommitCount: number;
    rdfBaseRef: string;
    rdfHeadRef: string;
    rdfStatus: string;
}

export async function getRevertDiff(
    releaseId: string,
    source: string,
): Promise<RevertDiffResp> {
    const { data } = await apiClient.get(
        `/releases/${encodeURIComponent(releaseId)}/mobile-revert/diff`,
        { params: { source } },
    );
    return data;
}

// ── Release Diff ──────────────────────────────────────────────────

export interface ReleaseDiff {
    oldfile: string;
    newfile: string;
    message: string;
}

export async function fetchReleaseDiff(releaseId: string, type?: string): Promise<ReleaseDiff> {
    const params: Record<string, string> = {};
    if (type) params.type = type;
    const { data } = await apiClient.get(`/releases/${encodeURIComponent(releaseId)}/diff`, { params });
    return data;
}

// ── Pod Health ────────────────────────────────────────────────────

export interface PodInfo {
    name: string;
    status: string;
    ready: boolean;
    restarts: number;
    age: string;
    version: string;
}

export interface PodHealthSummary {
    total: number;
    running: number;
    pending: number;
    failed: number;
    unknown: number;
}

export interface PodHealthResponse {
    pods: PodInfo[];
    summary: PodHealthSummary;
}

export async function fetchPodHealth(releaseId: string): Promise<PodHealthResponse> {
    const { data } = await apiClient.get(`/releases/${encodeURIComponent(releaseId)}/pods/health`);
    return data;
}

// ── Resources ─────────────────────────────────────────────────────

export interface ResourceInfo {
    cpu_requests: string;
    cpu_limits: string;
    memory_requests: string;
    memory_limits: string;
}

export async function fetchResources(appGroup: string, service: string): Promise<ResourceInfo> {
    const { data } = await apiClient.get('/resources', { params: { PRODUCT: appGroup, SERVICE: service } });
    return data;
}

// ── Product Config CRUD ───────────────────────────────────────────

export async function createProductConfig(payload: Partial<ProductConfig>): Promise<any> {
    const body = {
        appGroup: payload.appGroup,
        cluster: payload.cluster,
        namespace: payload.namespace,
        vsName: payload.vs_name,
        productType: payload.product_type,
        productAcronym: payload.product_acronym,
        releaseBranch: payload.release_branch,
        repoName: payload.repo_name,
        syncCluster: payload.sync_cluster,
        needInfraApproval: payload.need_infra_approval ? true : false,
        slackChannel: payload.slack_channel || null,
    };
    const { data } = await apiClient.post('/products/config', body);
    return data;
}

export async function updateProductConfig(id: number, payload: Partial<ProductConfig>): Promise<any> {
    const body = {
        id,
        appGroup: payload.appGroup,
        cluster: payload.cluster,
        namespace: payload.namespace,
        vsName: payload.vs_name,
        productType: payload.product_type,
        productAcronym: payload.product_acronym,
        releaseBranch: payload.release_branch,
        repoName: payload.repo_name,
        syncCluster: payload.sync_cluster,
        needInfraApproval: payload.need_infra_approval ? true : false,
        slackChannel: payload.slack_channel || null,
    };
    const { data } = await apiClient.put(`/products/config/${id}`, body);
    return data;
}

export async function deleteProductConfig(id: number): Promise<any> {
    const { data } = await apiClient.delete(`/products/config/${id}`);
    return data;
}

// ── Release Config (Service Config) ───────────────────────────────

export interface ReleaseConfig {
    id?: number;
    appGroup: string;
    service: string;
    host: string;
    rollout_strategy: string;
    serviceType?: string;
    serviceAcronym?: string;
    revert_strategy?: string;
    decision_config?: string;
}

export async function fetchReleaseConfigs(appGroup?: string): Promise<ReleaseConfig[]> {
    const params = appGroup ? { product: appGroup } : {};
    const { data } = await apiClient.get('/services/config', { params });
    if (!Array.isArray(data)) return [];
    return data.map((d: any) => ({
        id: d.id,
        appGroup: d.serviceProduct || d.appGroup || d.product || '',
        service: d.serviceName || d.service || '',
        host: d.serviceHost || d.host || '',
        rollout_strategy: d.rolloutStrategy || d.rollout_strategy || '',
        serviceType: d.serviceType || '',
        serviceAcronym: d.serviceAcronym || '',
        revert_strategy: d.revertStrategy || d.revert_strategy || '',
        decision_config: d.decisionConfig || d.decision_config || '',
    }));
}

export async function createReleaseConfig(payload: Partial<ReleaseConfig>): Promise<any> {
    const body = {
        id: payload.id,
        appGroup: payload.appGroup,
        service: payload.service,
        serviceType: payload.serviceType || 'SERVICE',
        serviceHost: payload.host,
        rolloutStrategyText: payload.rollout_strategy,
        revertStrategyText: payload.revert_strategy || null,
        decisionConfigText: payload.decision_config || null,
    };
    const { data } = await apiClient.post('/services/config', body);
    return data;
}

export async function updateReleaseConfig(id: number, payload: Partial<ReleaseConfig>): Promise<any> {
    const body = {
        id,
        appGroup: payload.appGroup,
        service: payload.service,
        serviceType: payload.serviceType || 'SERVICE',
        serviceHost: payload.host,
        rolloutStrategyText: payload.rollout_strategy,
        revertStrategyText: payload.revert_strategy || null,
        decisionConfigText: payload.decision_config || null,
    };
    const { data } = await apiClient.put(`/services/config/${id}`, body);
    return data;
}

export async function deleteReleaseConfig(id: number): Promise<any> {
    const { data } = await apiClient.delete(`/services/config/${id}`);
    return data;
}

// ── VS Edit Tracker ───────────────────────────────────────────────

export interface VSEditTracker {
    id: string;
    appGroup: string;
    service: string;
    vs_name: string;
    status: string;
    created_by: string;
    approved_by?: string;
    is_locked?: boolean;
    locked_by?: string;
    created_at: string;
    updated_at: string;
    old_vs_data: string;
    new_vs_data: string;
}

export async function fetchVSEdits(params: { from?: string; to?: string; search?: string }): Promise<VSEditTracker[]> {
    const { data } = await apiClient.get('/vs-edit-tracker/list', { params });
    if (!Array.isArray(data)) return [];
    return data;
}

export async function fetchVSEditDetail(id: string): Promise<VSEditTracker> {
    const { data } = await apiClient.get(`/vs-edit-tracker/${encodeURIComponent(id)}`);
    return data;
}

export async function fetchCurrentVS(appGroup: string, service: string): Promise<string> {
    const { data } = await apiClient.get('/vs-edit-tracker/current-vs', { params: { product: appGroup, service } });
    return typeof data === 'string' ? data : JSON.stringify(data, null, 2);
}

export async function lockAndEditVS(payload: { appGroup: string; service: string; env: string; vsName: string; lockedBy: string; oldVsData?: string }): Promise<any> {
    const { data } = await apiClient.post('/vs-edit-tracker/lock', { ...payload, product: payload.appGroup });
    return data;
}

export async function applyVSEdit(id: string, newVsData: string): Promise<any> {
    const { data } = await apiClient.put(`/vs-edit-tracker/${encodeURIComponent(id)}`, { status: 'APPLIED', newVsData });
    return data;
}

export async function saveVSEdit(id: string, newVsData: string): Promise<any> {
    const { data } = await apiClient.put(`/vs-edit-tracker/${encodeURIComponent(id)}`, { status: 'CREATED', newVsData });
    return data;
}

export async function revertVSEdit(id: string): Promise<any> {
    const { data } = await apiClient.put(`/vs-edit-tracker/revert/${encodeURIComponent(id)}`);
    return data;
}

export async function unlockVSEdit(id: string): Promise<any> {
    const { data } = await apiClient.post('/vs-edit-tracker/unlock', { trackerId: id });
    return data;
}

export async function deleteServerConfig(id: number): Promise<any> {
    const { data } = await apiClient.delete(`/server-config/${id}`);
    return data;
}

export async function fetchLogsLink(releaseId: string): Promise<{ grafana_dashboard: string; kibana_logs: string; pod_logs: string }> {
    const { data } = await apiClient.get(`/releases/${encodeURIComponent(releaseId)}/logslink`);
    return data;
}

// ── ConfigMap CRUD ─────────────────────────────────────────────────

export async function createConfigMap(payload: any, isUpdate: boolean = false): Promise<any> {
    const { data } = isUpdate
        ? await apiClient.put('/tracker/configmap', payload)
        : await apiClient.post('/tracker/configmap', payload);
    return data;
}

export async function fetchConfigMapNames(product: string): Promise<string[]> {
    const { data } = await apiClient.get('/configmap', { params: { PRODUCT: product } });
    return data.configMap || [];
}

export async function fetchConfigMapData(product: string, name: string): Promise<string> {
    const { data } = await apiClient.get('/configmap', { params: { PRODUCT: product, NAME: name } });
    return data.configMap || '';
}

// ── AB Validation API ─────────────────────────────────────────────

export async function fetchValidABStatuses(releaseId: string): Promise<{
    statusList: ABValidationStatus[];
    currentStatus: ABValidationStatus;
    isApproved: boolean;
}> {
    const { data } = await apiClient.get(`/releases/${releaseId}/ab`);
    return data;
}

export async function updateABValidation(
    releaseId: string,
    payload: { status: ABValidationStatus; is_approved: boolean; rca_description?: string }
): Promise<{ status: string; message: string }> {
    const { data } = await apiClient.put(`/releases/${releaseId}/ab`, payload);
    return data;
}

export async function fetchABMetrics(params?: {
    from?: string;
    to?: string;
    product?: string;
}): Promise<ABMetrics> {
    const { data } = await apiClient.get('/releases/abstatus', { params });
    return data;
}

// ── Mobile Releases API ───────────────────────────────────────────
// Parallel namespace for the mobile-release flow. Kept separate from
// the legacy free-function exports above so call sites read clearly
// (`mobileApi.listApps()` vs `fetchAPReleases(...)`). Each method
// unwraps the AxiosResponse and returns the data payload directly,
// matching how the existing helpers above are written.

import type {
    AppCatalogEntry,
    BranchInfo,
    ChangelogPreviewResp,
    CreateMobileReleasesReq,
    CreateMobileReleasesResp,
    DispatchMobileReleasesResp,
    VersionPreviewItem,
    LiveReleasesResp,
} from './types';

// ─── AI (Grid / LiteLLM) ─────────────────────────────────────────
// Shared response shape for every AI endpoint. `available:false` (with a
// `reason`) means AI is disabled / unconfigured / errored — render a notice,
// not an error toast.
export interface AiResp {
    available: boolean;
    reason?: string | null;
    summary?: string | null;
    model?: string | null;
    cached?: boolean | null;
    inputTokens?: number | null;
    outputTokens?: number | null;
}

// Mobile changelog summary: long (AI prose, chunked; deterministic fallback) +
// short (2-3 line AI synopsis). Generated async server-side; `status` drives
// polling. `summaryLong` is present even while `pending`/`failed`.
export interface ChangelogSummaryResp {
    available: boolean;
    status: 'ready' | 'pending' | 'failed' | 'unavailable';
    reason?: string | null;
    summaryLong?: string | null;
    summaryShort?: string | null;
    model?: string | null;
}

export async function releaseAiSummary(id: string, force = false): Promise<AiResp> {
    const { data } = await apiClient.post(`/releases/${id}/ai/summary`, { force });
    return data;
}

export async function releaseAiRisk(id: string, force = false): Promise<AiResp> {
    const { data } = await apiClient.post(`/releases/${id}/ai/risk`, { force });
    return data;
}

export async function releaseAiAsk(id: string, question: string): Promise<AiResp> {
    const { data } = await apiClient.post(`/releases/${id}/ai/ask`, { question });
    return data;
}

// ── Promote-to-review + staged rollout (Phase 6/8) ──────────────────
// Backend encodes Haskell record field names verbatim (pf*/rd* responses;
// pr*/rs*/mr* requests). Every endpoint is gated on
// `mobile_staged_rollout_enabled` — when the flag is off they 400, and the
// rollout panel stays hidden (no behavior change until ops opt in).

export interface PromoteForm {
    pfReleaseId: string;
    pfPlatform: string; // "android" | "ios"
    pfAppLabel: string;
    pfVersion: string;
    pfReleaseNotes: string; // editable default: prod "What's New" if store-synced, else the changelog
    pfReviewStatus: string | null;
    pfLocked: boolean; // true once submitted (iOS notes can't change mid-review)
    pfPhasedSupported: boolean; // iOS only
    pfIsStoreSync: boolean; // store-synced → notes are the live prod notes; don't swap in AI
}

export interface RolloutDetail {
    rdReleaseId: string;
    rdPlatform: string; // "android" | "ios"
    rdMbStatus: string; // MBTagPushed | MBInReview | MBReviewApproved | MBRollingOut | MBCompleted | MBReviewRejected | …
    rdReviewStatus: string | null; // in_review | submitted | approved | rejected
    rdReviewRejectReason: string | null;
    rdReviewSubmittedAt: string | null;
    rdReviewDecidedAt: string | null;
    rdRolloutStatus: string | null; // rolling_out | halted | completed
    rdRolloutPercent: number | null;
    rdPhasedId: string | null; // iOS phased-release id (present ⇒ phased ramp on)
    rdStoreTrack: string | null; // production | internal | testflight (store-sync rows)
}

export interface PromoteReq {
    prReleaseNotes: string;
    prEnablePhasedRelease?: boolean; // iOS only
    prInitialRolloutPercent?: number; // Android only; omit → config fraction
}

export interface PromoteResp {
    prResult: string;
    prWarning?: string | null; // non-fatal warning, e.g. phased release couldn't be enabled
}

export const mobileApi = {
    listApps: async (): Promise<AppCatalogEntry[]> => {
        const { data } = await apiClient.get('/mobile/apps');
        return Array.isArray(data) ? data : [];
    },

    createApp: async (body: Partial<AppCatalogEntry>): Promise<AppCatalogEntry> => {
        const { data } = await apiClient.post('/mobile/apps', body);
        return data;
    },

    patchApp: async (id: number, body: Partial<AppCatalogEntry>): Promise<AppCatalogEntry> => {
        const { data } = await apiClient.patch(`/mobile/apps/${id}`, body);
        return data;
    },

    previewVersions: async (appCatalogIds: number[]): Promise<{ previews: VersionPreviewItem[] }> => {
        const { data } = await apiClient.post('/mobile/versions/preview', { appCatalogIds });
        return data;
    },

    createReleases: async (req: CreateMobileReleasesReq): Promise<CreateMobileReleasesResp> => {
        const { data } = await apiClient.post('/releases/mobile/create', req);
        return data;
    },

    dispatchReleases: async (releaseIds: string[]): Promise<DispatchMobileReleasesResp> => {
        const { data } = await apiClient.post('/releases/mobile/dispatch', { releaseIds });
        return data;
    },

    liveReleases: async (category: 'all' | 'backend' | 'mobile' = 'all'): Promise<LiveReleasesResp> => {
        const { data } = await apiClient.get(`/releases/live?category=${category}`);
        return data;
    },

    listBranches: async (q?: string): Promise<BranchInfo[]> => {
        const params: Record<string, string> = {};
        if (q) params.q = q;
        const { data } = await apiClient.get('/mobile/branches', { params });
        return data?.branches ?? [];
    },

    changelogPreview: async (
        app: string,
        surface: string,
        platform: string,
        branch: string,
        base?: string,
    ): Promise<ChangelogPreviewResp> => {
        const params: Record<string, string> = { app, surface, platform, branch };
        if (base) params.base = base;
        const { data } = await apiClient.get('/mobile/changelog-preview', { params });
        return data;
    },

    // Create-time changelog summary of the commit range (before the release
    // exists). Generated async server-side; poll while status === 'pending'.
    changelogAiSummary: async (
        app: string,
        surface: string,
        platform: string,
        branch: string,
        base = '',
        versionName = '',
        versionCode = '',
    ): Promise<ChangelogSummaryResp> => {
        const params: Record<string, string> = { app, surface, platform, branch };
        if (base) params.base = base;
        if (versionName) params.versionName = versionName;
        if (versionCode) params.versionCode = versionCode;
        const { data } = await apiClient.get('/mobile/changelog-ai-summary', { params });
        return data;
    },

    // ── Promote-to-review + staged rollout ──
    getPromoteForm: async (id: string): Promise<PromoteForm> => {
        const { data } = await apiClient.get(`/releases/${encodeURIComponent(id)}/promote-form`);
        return data;
    },

    getRolloutDetail: async (id: string): Promise<RolloutDetail> => {
        const { data } = await apiClient.get(`/releases/${encodeURIComponent(id)}/rollout`);
        return data;
    },

    promote: async (id: string, body: PromoteReq): Promise<PromoteResp> => {
        const { data } = await apiClient.post(`/releases/${encodeURIComponent(id)}/promote`, body);
        return data;
    },

    // iOS only — release an approved (held) version.
    releaseApproved: async (id: string): Promise<void> => {
        await apiClient.post(`/releases/${encodeURIComponent(id)}/release`, {});
    },

    // Android only — set staged rollout % in (0,100]; 100 finishes the release.
    rolloutSet: async (id: string, percent: number): Promise<void> => {
        await apiClient.post(`/releases/${encodeURIComponent(id)}/rollout/set`, { rsPercent: percent });
    },

    rolloutHalt: async (id: string): Promise<void> => {
        await apiClient.post(`/releases/${encodeURIComponent(id)}/rollout/halt`, {});
    },

    rolloutResume: async (id: string): Promise<void> => {
        await apiClient.post(`/releases/${encodeURIComponent(id)}/rollout/resume`, {});
    },

    rolloutReleaseAll: async (id: string): Promise<void> => {
        await apiClient.post(`/releases/${encodeURIComponent(id)}/rollout/release-all`, {});
    },

    // Android only — record the opaque Play review outcome.
    markApproved: async (id: string): Promise<void> => {
        await apiClient.post(`/releases/${encodeURIComponent(id)}/review/mark-approved`, {});
    },

    markRejected: async (id: string, reason: string): Promise<void> => {
        await apiClient.post(`/releases/${encodeURIComponent(id)}/review/mark-rejected`, { mrReason: reason });
    },
};
