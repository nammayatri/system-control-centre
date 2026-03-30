import { apiClient, authClient } from './utils';

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

// ── All statuses matching ny-autopilot ─────────────────────────────

export type ReleaseStatus =
    | 'CREATED'
    | 'INPROGRESS'
    | 'ABORTED'
    | 'USER_ABORTED'
    | 'COMPLETED'
    | 'DISCARDED'
    | 'PAUSED'
    | 'ABORTING'
    | 'RECORDING'
    | 'REVERTING'
    | 'REVERTED'
    | 'RECORDED'
    | 'RESTARTING'
    | 'GCLT_ABORTED'
    | 'DISCARDING'
    | 'VS_APPLIED';

export const TERMINAL_STATUSES: ReleaseStatus[] = [
    'ABORTED', 'USER_ABORTED', 'COMPLETED', 'DISCARDED', 'GCLT_ABORTED', 'RECORDED', 'REVERTED'
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
    product: string;
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
    is_art_recorder: number;
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
    product: string;
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
    product: string;
    cluster: string;
    namespace: string;
    vs_name: string;
    repo_name?: string;
    product_acronym?: string;
    release_branch?: string;
    product_type: string;
    sync_cluster?: string | null;
    need_infra_approval?: number;
}

// ── Namma AP backend → frontend normalizer ─────────────────────────

type NammaRelease = {
    releaseId: string;
    service: string;
    product: string;
    status: string;
    env: string;
    trackerType?: string;
    mode?: string;
    createdBy?: string;
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

const toLegacyStatus = (status?: string): ReleaseStatus => {
    switch (status) {
        case 'Created': return 'CREATED';
        case 'InProgress': return 'INPROGRESS';
        case 'Paused': return 'PAUSED';
        case 'Aborting': return 'ABORTING';
        case 'Reverting': return 'REVERTING';
        case 'Reverted': return 'REVERTED';
        case 'Aborted': return 'ABORTED';
        case 'Completed': return 'COMPLETED';
        case 'UserAborted': return 'USER_ABORTED';
        case 'GcltAborted': return 'GCLT_ABORTED';
        case 'Discarded': return 'DISCARDED';
        case 'Recording': return 'RECORDING';
        case 'Recorded': return 'RECORDED';
        case 'Restarting': return 'RESTARTING';
        case 'Discarding': return 'DISCARDING';
        case 'VsApplied': return 'VS_APPLIED';
        default: return ((status || '').toUpperCase() || 'CREATED') as ReleaseStatus;
    }
};

const normalizeRelease = (r: NammaRelease): APRelease => ({
    id: r.releaseId,
    service: r.service,
    product: r.product,
    status: toLegacyStatus(r.status),
    env: r.env,
    tracker_type: r.trackerType || 'Service',
    mode: (r.mode || 'AUTO').toUpperCase(),
    release_manager: r.createdBy || '',
    is_approved: r.isApproved ? 1 : 0,
    is_infra_approved: r.isInfraApproved ? 1 : 0,
    release_tag: r.releaseTag || '',
    schedule_time: r.scheduleTime || '',
    date_created: '',
    start_time: r.startTime || '',
    end_time: r.endTime || '',
    last_updated: '',
    description: r.description || '',
    change_log: r.changeLog || '',
    info: r.info || '',
    priority: r.priority ?? 0,
    global_id: r.globalId || '',
    new_service: r.newService ? 'Yes' : 'No',
    is_art_recorder: r.isArtRecorder ?? 0,
    cronjob_suspend: r.cronjobSuspend ?? false,
    ab_hs_status: r.abHsStatus || 'Uninitiated',
    udf1: r.udf1 || '',
    udf2: r.udf2 || '',
    udf3: r.udf3 || '',

    new_version: r.releaseContext?.newVersion || '',
    old_version: r.releaseContext?.oldVersion || '',
    docker_image: r.releaseContext?.dockerImage || '',
    discription: '',

    release_context: {
        cluster: r.releaseContext?.cluster || '',
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
    switch (status) {
        case 'COMPLETED':
        case 'RECORDED':
            return 'bg-green-600 text-white';
        case 'INPROGRESS':
        case 'RECORDING':
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
        case 'VS_APPLIED':
        case 'RESTARTING':
            return 'bg-blue-500 text-white';
        case 'ABORTED':
        case 'USER_ABORTED':
        case 'GCLT_ABORTED':
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
    const { data } = await apiClient.get('/products');
    if (!Array.isArray(data)) return [];
    return data.map((p: any) => ({
        product: p.product,
        cluster: p.cluster,
        namespace: p.namespace,
        vs_name: p.vsName || '',
        product_type: p.productType,
        product_acronym: p.productAcronym,
        sync_cluster: p.syncCluster || p.sync_cluster || null,
    }));
}

export async function fetchProducts(): Promise<string[]> {
    const configs = await fetchProductConfigs();
    const unique = [...new Set(configs.map(c => c.product).filter(Boolean))];
    return unique;
}

export async function fetchServices(product: string, isNewService: boolean): Promise<string[]> {
    if (!product) return [];
    const { data } = await apiClient.get(`/products/${encodeURIComponent(product)}/services`);
    const services = Array.isArray(data) ? data : [];
    const names = services.map((s: any) => s.service).filter(Boolean);
    return [...new Set(names)];
}

export async function fetchEnvs(product: string, env: string, service: string): Promise<any> {
    if (!product || !env || !service) return [];
    try {
        const { data } = await apiClient.get('/envs', { params: { product, env, service } });
        return Array.isArray(data) ? data : [];
    } catch {
        return [];
    }
}

export async function fetchSecondaryEnvs(product: string, env: string, service: string): Promise<any> {
    if (!product || !env || !service) return [];
    try {
        const { data } = await apiClient.get('/envs/secondary', { params: { product, env, service } });
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
        (payload.serviceType === 'SCHEDULER' ? 'Scheduler' : 'Service');
    const requestBody = {
        product: payload.product,
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
        deployFilePath: null,
        serviceFilePath: null,
        drFilePath: null,
        vsFilePath: null,
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
        is_art_recorder: payload.is_art_recorder ?? 0,
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
export const pauseRelease = (id: string) => updateTracker(id, { status: 'Paused' });
export const resumeRelease = (id: string) => updateTracker(id, { status: 'InProgress' });
export const abortRelease = (id: string) => updateTracker(id, { status: 'Aborting' });
export const immediateRevert = (id: string, requestedBy?: string) =>
    revertRelease(id, requestedBy, undefined, true);

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
