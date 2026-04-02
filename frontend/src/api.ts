import { apiClient, authClient } from './lib/api-client';

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
    cluster: string;
    namespace: string;
    deployment_name: string;
    vs_name: string;
    docker_image: string;
    matches: Matches[];
    pods_scale_down_delay: number;
    pods_scale_down_timestamp: string;
    pods_scale_down_status: string;
    old_version_pod_count: number;
    revert: number;
    deploy_file_path: string;
    service_file_path: string;
    dr_file_path: string;
    vs_file_path: string;
    sync_cluster_udf2: string;
    sync_cluster_rollout_strategy: string;
    sync_x_forwarded_email: string;
    sync_x_pomerium_jwt: string;
}

// ── All statuses (UPPERCASE — canonical) ─────

export type ReleaseStatus =
    | 'CREATED'
    | 'INPROGRESS'
    | 'COMPLETED'
    | 'ABORTED'
    | 'USER_ABORTED'
    | 'DISCARDED'
    | 'DISCARDING'
    | 'PAUSED'
    | 'ABORTING'
    | 'REVERTING'
    | 'REVERTED'
    | 'RESTARTING';

export const TERMINAL_STATUSES: ReleaseStatus[] = [
    'ABORTED', 'USER_ABORTED', 'COMPLETED', 'DISCARDED', 'REVERTED'
];

export const ABORTED_STATUSES: ReleaseStatus[] = [
    'ABORTED', 'USER_ABORTED', 'ABORTING'
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
    env: string;
    priority: number;
    schedule_time: string;
    change_log: string;
    info: string;
    udf1: string;
    udf2: string;
    udf3: string;
    global_id: string;
    new_service: string;
    // is_art_recorder removed (column dropped)
    cronjob_suspend: boolean;
    ab_hs_status: string;
    tracker_type: string;
    rollout_strategy: RolloutStrategyEvent[];
    rollout_history: RolloutHistoryEvent[];
    events: RolloutEvent[];
    release_context: ReleaseContext;
    custom_pod_scaledown_days: number;
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
    udf1?: string | null;
    udf2?: string | null;
    udf3?: string | null;
    metadata?: any;
    rolloutStrategy?: Array<{ rolloutPercent: number; cooloffSeconds: number; podPercent: number }>;
    rolloutHistory?: Array<{
        historyRolloutPercent: number;
        historyCooloffSeconds: number;
        historyPodsPercent: number;
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
        podsScaleDownDelay?: number | null;
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
        syncClusterUdf2?: string | null;
        syncClusterRolloutStrategy?: string | null;
        syncXForwardedEmail?: string | null;
        syncXPomeriumJwt?: string | null;
    };
};

/** Backend returns UPPERCASE statuses. Pass through directly.
 *  Safety: normalize any unexpected casing to UPPERCASE. */
const normalizeStatus = (status?: string): ReleaseStatus => {
    const upper = (status || 'CREATED').toUpperCase().replace(/\s+/g, '_');
    switch (upper) {
        case 'CREATED': return 'CREATED';
        case 'INPROGRESS': return 'INPROGRESS';
        case 'COMPLETED': return 'COMPLETED';
        case 'ABORTED': return 'ABORTED';
        case 'USER_ABORTED': case 'USERABORTED': return 'USER_ABORTED';
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
    // is_art_recorder removed
    cronjob_suspend: r.cronjobSuspend ?? false,
    ab_hs_status: r.abHsStatus || 'Uninitiated',
    udf1: r.udf1 || '',
    udf2: r.udf2 || '',
    udf3: r.udf3 || '',

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
        pods_scale_down_delay: r.releaseContext?.podsScaleDownDelay ?? 0,
        pods_scale_down_timestamp: r.releaseContext?.podsScaleDownTimestamp || '',
        pods_scale_down_status: r.releaseContext?.podsScaleDownStatus || '',
        old_version_pod_count: r.releaseContext?.oldVersionPodCount ?? 0,
        revert: r.releaseContext?.revert ?? 0,
        deploy_file_path: r.releaseContext?.deployFilePath || '',
        service_file_path: r.releaseContext?.serviceFilePath || '',
        dr_file_path: r.releaseContext?.drFilePath || '',
        vs_file_path: r.releaseContext?.vsFilePath || '',
        sync_cluster_udf2: r.releaseContext?.syncClusterUdf2 || '',
        sync_cluster_rollout_strategy: r.releaseContext?.syncClusterRolloutStrategy || '',
        sync_x_forwarded_email: r.releaseContext?.syncXForwardedEmail || '',
        sync_x_pomerium_jwt: r.releaseContext?.syncXPomeriumJwt || '',
    },

    rollout_strategy: (r.rolloutStrategy || []).map(s => ({
        rollout: s.rolloutPercent,
        cooloff: s.cooloffSeconds,
        pods: s.podPercent,
    })),

    rollout_history: (r.rolloutHistory || []).map(h => ({
        rollout: h.historyRolloutPercent,
        cooloff: h.historyCooloffSeconds,
        pods: h.historyPodsPercent,
        last_decision: h.historyDecision || '',
        decision_result: h.historyDecisionReason || '',
        started_at: h.historyStartedAt || '',
        completed_at: h.historyCompletedAt || '',
        manual_override: h.historyManualOverride ?? false,
        last_decision_hs: h.historyDecisionHs || '',
        decision_hs_result: h.historyDecisionHsReason || '',
    })),

    events: [],
    custom_pod_scaledown_days: 0,
});

// ── Status color helpers (matching rescript dashboard) ──────────────

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
        default:
            return 'bg-red-500 text-white';
    }
}

// ── API Calls ──────────────────────────────────────────────────────

export async function fetchAPReleases(from: string, to: string): Promise<APRelease[]> {
    const { data } = await apiClient.get('/releases', { params: { from, to } });
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
    return data.list ?? [];
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
            cooloffSeconds: Number(s.cooloff || 0),
            podPercent: Number(s.pods || 0),
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
        // is_art_recorder removed
        cronjob_suspend: payload.cronjob_suspend || false,
        change_log: payload.change_log || null,
        udf1: payload.udf1 || null,
        udf2: payload.udf2 || null,
        udf3: payload.udf3 || null,
        isReleaseSync: payload.isReleaseSync || false,
        syncClusterUdf2: payload.syncClusterUdf2 || null,
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

export async function revertRelease(releaseId: string, requestedBy?: string, info?: string, immediate?: boolean): Promise<any> {
    const { data } = await apiClient.post(`/releases/${encodeURIComponent(releaseId)}/revert`, { requestedBy: requestedBy || null, info: info || null, immediate: immediate || false });
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

// Convenience wrappers matching rescript dashboard actions
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

export async function fetchResources(product: string, service: string): Promise<ResourceInfo> {
    const { data } = await apiClient.get('/resources', { params: { PRODUCT: product, SERVICE: service } });
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
    slack_channel: string;
    serviceType?: string;
    serviceAcronym?: string;
    emails?: string;
    revert_strategy?: string;
    decision_config?: string;
}

export async function fetchReleaseConfigs(appGroup?: string): Promise<ReleaseConfig[]> {
    const params = appGroup ? { product: appGroup } : {};
    const { data } = await apiClient.get('/services/config', { params });
    if (!Array.isArray(data)) return [];
    // Map backend field names to frontend interface
    return data.map((d: any) => ({
        id: d.id,
        appGroup: d.serviceProduct || d.appGroup || d.product || '',
        service: d.serviceName || d.service || '',
        host: d.serviceHost || d.host || '',
        rollout_strategy: d.rolloutStrategy || d.rollout_strategy || '',
        slack_channel: d.slackWebhookUrls || d.slack_channel || '',
        serviceType: d.serviceType || '',
        serviceAcronym: d.serviceAcronym || '',
        emails: d.emails || '',
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
        slackWebhookUrls: payload.slack_channel,
        emails: payload.emails,
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
        slackWebhookUrls: payload.slack_channel,
        emails: payload.emails,
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

export async function fetchCurrentVS(product: string, service: string): Promise<string> {
    const { data } = await apiClient.get('/vs-edit-tracker/current-vs', { params: { product, service } });
    return typeof data === 'string' ? data : JSON.stringify(data, null, 2);
}

export async function lockAndEditVS(payload: { product: string; service: string; env: string; vsName: string; lockedBy: string; oldVsData?: string }): Promise<any> {
    const { data } = await apiClient.post('/vs-edit-tracker/lock', payload);
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

// ── Auth ───────────────────────────────────────────────────────────

export async function loginUser(username: string, password: string): Promise<any> {
    const { data } = await authClient.post('/api/ec/v1/login', { username, password });
    if (data.status === 'FAILURE' || data.error) {
        throw new Error(data.userMessage || data.responseMessage || 'Login failed');
    }
    return data;
}

export async function registerUser(email: string, password: string, phone: string): Promise<any> {
    await authClient.get('/api/ec/v1/signUp/validate/email', { params: { email } });
    return new Promise((resolve) => setTimeout(() => resolve({ status: 'SUCCESS' }), 1000));
}
