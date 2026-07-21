import { apiClient } from '../../lib/api-client';
import type { MultiSelectOption } from '../../shared/ui/multi-select';
import type {
  OtaAccessResp,
  OtaActiveDevices,
  OtaAdoptionMetrics,
  OtaAdoptionParams,
  OtaAnalyticsEnvelope,
  OtaCheckpointReq,
  OtaCohortPriorityResp,
  OtaCohortSchema,
  OtaConcludeReq,
  OtaCreateAppReq,
  OtaCreateDimensionReq,
  OtaCreateFileReq,
  OtaCreatePackageReq,
  OtaCreateReleaseReq,
  OtaDimension,
  OtaEventsResp,
  OtaFailureMetrics,
  OtaFile,
  OtaFileGroupsResp,
  OtaFilesResp,
  OtaGroupReq,
  OtaHealthResp,
  OtaListEnvelope,
  OtaPackage,
  OtaPerformanceMetrics,
  OtaPropertiesListResp,
  OtaPropertiesSchemaResp,
  OtaRampReq,
  OtaRelease,
  OtaReleaseDetail,
  OtaReleaseView,
  OtaSaveViewReq,
  OtaServeConfig,
  OtaTagsResp,
  OtaUpdateDimensionReq,
  OtaVersionDistribution,
  OtaViewsResp,
} from './types';

// ── Health / access ────────────────────────────────────────────────

export async function fetchOtaHealth(): Promise<OtaHealthResp> {
  const { data } = await apiClient.get('/airborne/health');
  return data;
}

export async function fetchOtaAccess(): Promise<OtaAccessResp> {
  const { data } = await apiClient.get('/airborne/access');
  return data;
}

// ── App list for the grant-picker (OTA_APP_MANAGE) ─────────────────

// The full live airborne app list as deployment app-groups (keyed on the
// composite ref "<org>~<app>"), for the admin scoped-access screens — grouped
// by airborne org for the multi-select. Requires OTA_APP_MANAGE.
export async function fetchOtaAppGroups(): Promise<MultiSelectOption[]> {
  const { data } = await apiClient.get<{ apps?: { appRef: string; org: string; app: string }[] }>(
    '/airborne/apps',
  );
  return (data.apps ?? []).map((a) => ({
    value: a.appRef,
    label: a.app,
    hint: a.org,
    group: a.org,
  }));
}

// ── Releases ───────────────────────────────────────────────────────

// dimension = "k1=v1;k2=v2" — filters the list to releases targeting that
// dimension context (sent as x-dimension header).
export async function fetchOtaReleases(
  app: string,
  params: { page?: number; count?: number; status?: string; dimension?: string },
): Promise<OtaListEnvelope<OtaRelease>> {
  const query: Record<string, string | number> = {};
  if (params.page != null) query.page = params.page;
  if (params.count != null) query.count = params.count;
  if (params.status) query.status = params.status;
  const { data } = await apiClient.get(`/airborne/${encodeURIComponent(app)}/releases`, {
    params: query,
    ...(params.dimension ? { headers: { 'x-dimension': params.dimension } } : {}),
  });
  return data;
}

export async function fetchOtaRelease(app: string, releaseId: string): Promise<OtaReleaseDetail> {
  const { data } = await apiClient.get(
    `/airborne/${encodeURIComponent(app)}/releases/${encodeURIComponent(releaseId)}`,
  );
  return data;
}

export async function rampOtaRelease(
  app: string,
  releaseId: string,
  body: OtaRampReq,
): Promise<unknown> {
  const { data } = await apiClient.post(
    `/airborne/${encodeURIComponent(app)}/releases/${encodeURIComponent(releaseId)}/ramp`,
    body,
  );
  return data;
}

export async function concludeOtaRelease(
  app: string,
  releaseId: string,
  body: OtaConcludeReq,
): Promise<unknown> {
  const { data } = await apiClient.post(
    `/airborne/${encodeURIComponent(app)}/releases/${encodeURIComponent(releaseId)}/conclude`,
    body,
  );
  return data;
}

export async function discardOtaRelease(app: string, releaseId: string): Promise<unknown> {
  const { data } = await apiClient.post(
    `/airborne/${encodeURIComponent(app)}/releases/${encodeURIComponent(releaseId)}/discard`,
  );
  return data;
}

export async function createOtaRelease(app: string, body: OtaCreateReleaseReq): Promise<OtaRelease> {
  const { data } = await apiClient.post(`/airborne/${encodeURIComponent(app)}/releases/create`, body);
  return data;
}

export async function updateOtaRelease(
  app: string,
  releaseId: string,
  body: OtaCreateReleaseReq,
): Promise<OtaRelease> {
  const { data } = await apiClient.put(
    `/airborne/${encodeURIComponent(app)}/releases/${encodeURIComponent(releaseId)}/update`,
    body,
  );
  return data;
}

// dimension = "k1=v1;k2=v2" — sent as x-dimension header only when provided.
export async function fetchOtaServeConfig(app: string, dimension?: string): Promise<OtaServeConfig> {
  const { data } = await apiClient.get(
    `/airborne/${encodeURIComponent(app)}/serve-config`,
    dimension ? { headers: { 'x-dimension': dimension } } : undefined,
  );
  return data;
}

// ── Packages / files ───────────────────────────────────────────────

export async function fetchOtaPackages(
  app: string,
  params: { page?: number; count?: number; search?: string },
): Promise<OtaListEnvelope<OtaPackage>> {
  const query: Record<string, string | number> = {};
  if (params.page != null) query.page = params.page;
  if (params.count != null) query.count = params.count;
  if (params.search) query.search = params.search;
  const { data } = await apiClient.get(`/airborne/${encodeURIComponent(app)}/packages`, { params: query });
  return data;
}

export async function fetchOtaFiles(
  app: string,
  params: { page?: number; count?: number; search?: string; tag?: string },
): Promise<OtaFilesResp> {
  const query: Record<string, string | number> = {};
  if (params.page != null) query.page = params.page;
  if (params.count != null) query.count = params.count;
  if (params.search) query.search = params.search;
  if (params.tag) query.tag = params.tag;
  const { data } = await apiClient.get(`/airborne/${encodeURIComponent(app)}/files`, { params: query });
  return data;
}

export async function createOtaPackage(app: string, body: OtaCreatePackageReq): Promise<OtaPackage> {
  const { data } = await apiClient.post(`/airborne/${encodeURIComponent(app)}/packages/create`, body);
  return data;
}

// packageKey = "version:<n>" or "tag:<t>".
export async function fetchOtaPackageDetail(app: string, packageKey: string): Promise<OtaPackage> {
  const { data } = await apiClient.get(`/airborne/${encodeURIComponent(app)}/packages/detail`, {
    params: { package_key: packageKey },
  });
  return data;
}

export async function fetchOtaFileGroups(
  app: string,
  params: { page?: number; count?: number; search?: string; tags?: string },
): Promise<OtaFileGroupsResp> {
  const query: Record<string, string | number> = {};
  if (params.page != null) query.page = params.page;
  if (params.count != null) query.count = params.count;
  if (params.search) query.search = params.search;
  if (params.tags) query.tags = params.tags;
  const { data } = await apiClient.get(`/airborne/${encodeURIComponent(app)}/files/groups`, {
    params: query,
  });
  return data;
}

export async function fetchOtaFileTags(app: string, count = 100): Promise<OtaTagsResp> {
  const { data } = await apiClient.get(`/airborne/${encodeURIComponent(app)}/files/tags`, {
    params: { page: 1, count },
  });
  return data;
}

export async function createOtaFile(app: string, body: OtaCreateFileReq): Promise<OtaFile> {
  const { data } = await apiClient.post(`/airborne/${encodeURIComponent(app)}/files/create`, body);
  return data;
}

// fileKey = "<file_path>@version:<n>" — contains @ and :, so encode the segment.
export async function updateOtaFileTag(app: string, fileKey: string, tag: string): Promise<OtaFile> {
  const { data } = await apiClient.post(
    `/airborne/${encodeURIComponent(app)}/files/tag/${encodeURIComponent(fileKey)}`,
    { tag },
  );
  return data;
}

// ── Dimensions / cohorts (Phase 3) ─────────────────────────────────

export async function fetchOtaDimensions(
  app: string,
  params?: { page?: number; count?: number },
): Promise<OtaListEnvelope<OtaDimension>> {
  const query: Record<string, string | number> = {};
  if (params?.page != null) query.page = params.page;
  if (params?.count != null) query.count = params.count;
  const { data } = await apiClient.get(`/airborne/${encodeURIComponent(app)}/dimensions`, {
    params: query,
  });
  return data;
}

export async function createOtaDimension(
  app: string,
  body: OtaCreateDimensionReq,
): Promise<OtaDimension> {
  const { data } = await apiClient.post(
    `/airborne/${encodeURIComponent(app)}/dimensions/create`,
    body,
  );
  return data;
}

export async function updateOtaDimension(
  app: string,
  dimension: string,
  body: OtaUpdateDimensionReq,
): Promise<OtaDimension> {
  const { data } = await apiClient.put(
    `/airborne/${encodeURIComponent(app)}/dimensions/${encodeURIComponent(dimension)}`,
    body,
  );
  return data;
}

export async function fetchOtaCohort(app: string, dimension: string): Promise<OtaCohortSchema> {
  const { data } = await apiClient.get(
    `/airborne/${encodeURIComponent(app)}/dimensions/${encodeURIComponent(dimension)}/cohort`,
  );
  return data;
}

export async function createOtaCheckpoint(
  app: string,
  dimension: string,
  body: OtaCheckpointReq,
): Promise<OtaCheckpointReq> {
  const { data } = await apiClient.post(
    `/airborne/${encodeURIComponent(app)}/dimensions/${encodeURIComponent(dimension)}/cohort/checkpoint`,
    body,
  );
  return data;
}

export async function createOtaGroup(
  app: string,
  dimension: string,
  body: OtaGroupReq,
): Promise<OtaGroupReq> {
  const { data } = await apiClient.post(
    `/airborne/${encodeURIComponent(app)}/dimensions/${encodeURIComponent(dimension)}/cohort/group`,
    body,
  );
  return data;
}

export async function fetchOtaCohortPriority(
  app: string,
  dimension: string,
): Promise<OtaCohortPriorityResp> {
  const { data } = await apiClient.get(
    `/airborne/${encodeURIComponent(app)}/dimensions/${encodeURIComponent(dimension)}/cohort/priority`,
  );
  return data;
}

// Send ONE {name: newIndex} entry per call — upstream applies multi-entry maps
// in nondeterministic order.
export async function updateOtaCohortPriority(
  app: string,
  dimension: string,
  priorityMap: Record<string, number>,
): Promise<OtaCohortPriorityResp> {
  const { data } = await apiClient.put(
    `/airborne/${encodeURIComponent(app)}/dimensions/${encodeURIComponent(dimension)}/cohort/priority`,
    { priority_map: priorityMap },
  );
  return data;
}

// ── Properties / remote config (Phase 3) ───────────────────────────

// dimension context ("k=v;k2=v2") resolves scoped values into default_value.
export async function fetchOtaPropertiesSchema(
  app: string,
  dimension?: string,
): Promise<OtaPropertiesSchemaResp> {
  const { data } = await apiClient.get(`/airborne/${encodeURIComponent(app)}/properties/schema`, {
    ...(dimension ? { headers: { 'x-dimension': dimension } } : {}),
  });
  return data;
}

// FULL-REPLACE upstream: properties omitted from the map are DELETED. Callers
// must always send the complete desired set.
export async function putOtaPropertiesSchema(
  app: string,
  properties: Record<string, unknown>,
): Promise<OtaPropertiesSchemaResp> {
  const { data } = await apiClient.put(`/airborne/${encodeURIComponent(app)}/properties/schema`, {
    properties,
  });
  return data;
}

export async function fetchOtaPropertiesList(
  app: string,
  dimension?: string,
): Promise<OtaPropertiesListResp> {
  const { data } = await apiClient.get(`/airborne/${encodeURIComponent(app)}/properties/list`, {
    ...(dimension ? { headers: { 'x-dimension': dimension } } : {}),
  });
  return data;
}

// ── Release views (Phase 3) ────────────────────────────────────────

export async function fetchOtaViews(
  app: string,
  params?: { page?: number; count?: number },
): Promise<OtaViewsResp> {
  const query: Record<string, string | number> = {};
  if (params?.page != null) query.page = params.page;
  if (params?.count != null) query.count = params.count;
  const { data } = await apiClient.get(`/airborne/${encodeURIComponent(app)}/views`, {
    params: query,
  });
  return data;
}

export async function createOtaView(app: string, body: OtaSaveViewReq): Promise<OtaReleaseView> {
  const { data } = await apiClient.post(`/airborne/${encodeURIComponent(app)}/views/create`, body);
  return data;
}

export async function updateOtaView(
  app: string,
  viewId: string,
  body: OtaSaveViewReq,
): Promise<OtaReleaseView> {
  const { data } = await apiClient.put(
    `/airborne/${encodeURIComponent(app)}/views/${encodeURIComponent(viewId)}`,
    body,
  );
  return data;
}

export async function deleteOtaView(app: string, viewId: string): Promise<unknown> {
  const { data } = await apiClient.delete(
    `/airborne/${encodeURIComponent(app)}/views/${encodeURIComponent(viewId)}`,
  );
  return data;
}

// ── Analytics (Phase 4) ────────────────────────────────────────────

// Adoption is release-scoped: interval (DAY|HOUR), epoch-millis dates, and a
// release_id. Backend derives org_id/app_id by splitting the "<org>~<app>" ref.
export async function fetchOtaAdoption(
  app: string,
  params: OtaAdoptionParams,
): Promise<OtaAnalyticsEnvelope<OtaAdoptionMetrics>> {
  const query: Record<string, string> = {
    interval: params.interval,
    start_date: params.start_date,
    end_date: params.end_date,
    date: params.date,
  };
  if (params.release_id) query.release_id = params.release_id;
  const { data } = await apiClient.get(`/airborne/${encodeURIComponent(app)}/analytics/adoption`, {
    params: query,
  });
  return data;
}

export async function fetchOtaVersions(
  app: string,
  days?: number,
): Promise<OtaAnalyticsEnvelope<OtaVersionDistribution[]>> {
  const query: Record<string, number> = {};
  if (days != null) query.days = days;
  const { data } = await apiClient.get(`/airborne/${encodeURIComponent(app)}/analytics/versions`, {
    params: query,
  });
  return data;
}

export async function fetchOtaActiveDevices(
  app: string,
  days?: number,
): Promise<OtaAnalyticsEnvelope<OtaActiveDevices>> {
  const query: Record<string, number> = {};
  if (days != null) query.days = days;
  const { data } = await apiClient.get(
    `/airborne/${encodeURIComponent(app)}/analytics/active-devices`,
    { params: query },
  );
  return data;
}

export async function fetchOtaFailures(
  app: string,
  params?: { days?: number; release_id?: string },
): Promise<OtaAnalyticsEnvelope<OtaFailureMetrics>> {
  const query: Record<string, string | number> = {};
  if (params?.days != null) query.days = params.days;
  if (params?.release_id) query.release_id = params.release_id;
  const { data } = await apiClient.get(`/airborne/${encodeURIComponent(app)}/analytics/failures`, {
    params: query,
  });
  return data;
}

export async function fetchOtaPerformance(
  app: string,
  params?: { days?: number; release_id?: string },
): Promise<OtaAnalyticsEnvelope<OtaPerformanceMetrics>> {
  const query: Record<string, string | number> = {};
  if (params?.days != null) query.days = params.days;
  if (params?.release_id) query.release_id = params.release_id;
  const { data } = await apiClient.get(
    `/airborne/${encodeURIComponent(app)}/analytics/performance`,
    { params: query },
  );
  return data;
}

// ── App create (org-scoped; backend enforces product-level OTA_APP_MANAGE) ──

export async function createOtaApp(body: OtaCreateAppReq): Promise<unknown> {
  const { data } = await apiClient.post('/airborne/apps/create', body);
  return data;
}

// ── Audit trail ────────────────────────────────────────────────────

export async function fetchOtaEvents(
  app: string,
  params: { page: number; count: number; action?: string },
): Promise<OtaEventsResp> {
  const query: Record<string, string | number> = { page: params.page, count: params.count };
  if (params.action) query.action = params.action;
  const { data } = await apiClient.get(`/airborne/${encodeURIComponent(app)}/events`, {
    params: query,
  });
  return data;
}
