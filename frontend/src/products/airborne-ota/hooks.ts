import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import {
  concludeOtaRelease,
  createOtaApp,
  createOtaCheckpoint,
  createOtaDimension,
  createOtaFile,
  createOtaGroup,
  createOtaPackage,
  createOtaRelease,
  createOtaView,
  deleteOtaView,
  discardOtaRelease,
  fetchOtaAccess,
  fetchOtaActiveDevices,
  fetchOtaAdoption,
  fetchOtaCohort,
  fetchOtaCohortPriority,
  fetchOtaDimensions,
  fetchOtaEvents,
  fetchOtaFailures,
  fetchOtaFileGroups,
  fetchOtaFileTags,
  fetchOtaFiles,
  fetchOtaHealth,
  fetchOtaPackageDetail,
  fetchOtaPackages,
  fetchOtaPerformance,
  fetchOtaPropertiesList,
  fetchOtaPropertiesSchema,
  fetchOtaRelease,
  fetchOtaReleases,
  fetchOtaServeConfig,
  fetchOtaVersions,
  fetchOtaViews,
  putOtaPropertiesSchema,
  rampOtaRelease,
  updateOtaCohortPriority,
  updateOtaDimension,
  updateOtaFileTag,
  updateOtaRelease,
  updateOtaView,
} from './api';
import type {
  OtaAdoptionParams,
  OtaCheckpointReq,
  OtaConcludeReq,
  OtaCreateAppReq,
  OtaCreateDimensionReq,
  OtaCreateFileReq,
  OtaCreatePackageReq,
  OtaCreateReleaseReq,
  OtaGroupReq,
  OtaRampReq,
  OtaSaveViewReq,
  OtaUpdateDimensionReq,
} from './types';

const errMsg = (err: any, fallback: string) =>
  err?.response?.data?.message || err.message || fallback;

// ── Queries ────────────────────────────────────────────────────────

export function useOtaHealth() {
  return useQuery({
    queryKey: ['ota-health'],
    queryFn: () => fetchOtaHealth(),
    staleTime: 30_000,
    retry: false,
  });
}

export function useOtaAccess() {
  return useQuery({
    queryKey: ['ota-access'],
    queryFn: () => fetchOtaAccess(),
    staleTime: 60_000,
  });
}

export function useOtaReleases(
  app: string | undefined,
  params: { page: number; count: number; status?: string },
) {
  return useQuery({
    queryKey: ['ota-releases', app, params.page, params.count, params.status ?? 'all'],
    queryFn: () => fetchOtaReleases(app!, params),
    enabled: !!app,
    refetchInterval: 60_000,
    placeholderData: keepPreviousData,
  });
}

export function useOtaRelease(app: string | undefined, releaseId: string | undefined) {
  return useQuery({
    queryKey: ['ota-release', app, releaseId],
    queryFn: () => fetchOtaRelease(app!, releaseId!),
    refetchInterval: (query) => {
      if (query.state.status === 'error') return false;
      const s = (query.state.data?.experiment?.status ?? '').toUpperCase();
      return s === 'CONCLUDED' || s === 'DISCARDED' ? false : 10_000;
    },
    enabled: !!app && !!releaseId,
  });
}

export function useOtaPackages(
  app: string | undefined,
  params: { page: number; count: number; search?: string },
) {
  return useQuery({
    queryKey: ['ota-packages', app, params.page, params.count, params.search ?? ''],
    queryFn: () => fetchOtaPackages(app!, params),
    enabled: !!app,
    refetchInterval: 60_000,
    placeholderData: keepPreviousData,
  });
}

export function useOtaFiles(
  app: string | undefined,
  params: { page: number; count: number; search?: string; tag?: string },
) {
  return useQuery({
    queryKey: ['ota-files', app, params.page, params.count, params.search ?? '', params.tag ?? ''],
    queryFn: () => fetchOtaFiles(app!, params),
    enabled: !!app,
    refetchInterval: 60_000,
    placeholderData: keepPreviousData,
  });
}

// One large page for the wizard pickers — airborne clamps files per_page to
// 200, so request exactly that; pickers show a notice when total exceeds it.
const PICKER_COUNT = 200;

export function useOtaAllPackages(app: string | undefined) {
  return useQuery({
    queryKey: ['ota-packages-all', app],
    queryFn: () => fetchOtaPackages(app!, { page: 1, count: PICKER_COUNT }),
    enabled: !!app,
    staleTime: 30_000,
  });
}

export function useOtaAllFiles(app: string | undefined) {
  return useQuery({
    queryKey: ['ota-files-all', app],
    queryFn: () => fetchOtaFiles(app!, { page: 1, count: PICKER_COUNT }),
    enabled: !!app,
    staleTime: 30_000,
  });
}

// Package rows carry no created_at upstream, but a package's `index` IS a file
// key and files do. One files query per unique index path (all versions of an
// index share it) yields an id → created_at map; versions beyond the 200-file
// clamp resolve to nothing and render "—".
export function useOtaIndexCreatedAt(app: string | undefined, indexKeys: string[]) {
  const paths = [...new Set(indexKeys.map((k) => k.split('@version:')[0]).filter(Boolean))].sort();
  return useQuery({
    queryKey: ['ota-index-created', app, paths.join('|')],
    queryFn: async () => {
      const map: Record<string, string> = {};
      const results = await Promise.all(
        paths.map((p) => fetchOtaFiles(app!, { page: 1, count: PICKER_COUNT, search: p })),
      );
      for (const r of results)
        for (const f of r.files ?? []) if (f.id && f.created_at) map[f.id] = f.created_at;
      return map;
    },
    enabled: !!app && paths.length > 0,
    staleTime: 60_000,
  });
}

export function useOtaPackageDetail(app: string | undefined, packageKey: string | undefined) {
  return useQuery({
    queryKey: ['ota-package-detail', app, packageKey],
    queryFn: () => fetchOtaPackageDetail(app!, packageKey!),
    enabled: !!app && !!packageKey,
  });
}

export function useOtaServeConfig(app: string | undefined, dimension: string, enabled: boolean) {
  return useQuery({
    queryKey: ['ota-serve-config', app, dimension],
    queryFn: () => fetchOtaServeConfig(app!, dimension || undefined),
    enabled: !!app && enabled,
    retry: false,
  });
}

// ── Mutations ──────────────────────────────────────────────────────

function useInvalidateRelease() {
  const qc = useQueryClient();
  return (app: string, releaseId: string) => {
    qc.invalidateQueries({ queryKey: ['ota-release', app, releaseId] });
    qc.invalidateQueries({ queryKey: ['ota-releases', app] });
    // Cohorts/Views "matching releases" preview panels.
    qc.invalidateQueries({ queryKey: ['ota-releases-dim', app] });
  };
}

export function useRampOtaRelease() {
  const invalidate = useInvalidateRelease();
  return useMutation({
    mutationFn: ({ app, releaseId, body }: { app: string; releaseId: string; body: OtaRampReq }) =>
      rampOtaRelease(app, releaseId, body),
    onSuccess: (_, vars) => {
      toast.success(`Traffic set to ${vars.body.trafficPercentage}%`);
      invalidate(vars.app, vars.releaseId);
    },
    onError: (err: any, vars) => {
      // 409 = someone else changed the traffic between the dialog opening and
      // submit. Refresh so the operator sees the real value before retrying —
      // never auto-retry, that would reintroduce the clobber the guard blocks.
      if (err?.response?.status === 409) {
        toast.error(errMsg(err, 'Traffic changed upstream — reload and try again'));
        invalidate(vars.app, vars.releaseId);
        return;
      }
      toast.error(errMsg(err, 'Failed to ramp release'));
    },
  });
}

export function useConcludeOtaRelease() {
  const invalidate = useInvalidateRelease();
  return useMutation({
    mutationFn: ({ app, releaseId, body }: { app: string; releaseId: string; body: OtaConcludeReq }) =>
      concludeOtaRelease(app, releaseId, body),
    onSuccess: (_, vars) => {
      toast.success(`Release concluded with variant "${vars.body.chosenVariant}"`);
      invalidate(vars.app, vars.releaseId);
    },
    onError: (err: any) => {
      toast.error(errMsg(err, 'Failed to conclude release'));
    },
  });
}

export function useDiscardOtaRelease() {
  const invalidate = useInvalidateRelease();
  return useMutation({
    mutationFn: ({ app, releaseId }: { app: string; releaseId: string }) =>
      discardOtaRelease(app, releaseId),
    onSuccess: (_, vars) => {
      toast.success('Release discarded');
      invalidate(vars.app, vars.releaseId);
    },
    onError: (err: any) => {
      toast.error(errMsg(err, 'Failed to discard release'));
    },
  });
}

export function useCreateOtaRelease(app: string | undefined) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: OtaCreateReleaseReq) => createOtaRelease(app!, body),
    onSuccess: () => {
      toast.success('Release created');
      qc.invalidateQueries({ queryKey: ['ota-releases', app] });
      qc.invalidateQueries({ queryKey: ['ota-releases-dim', app] });
    },
    onError: (err: any) => {
      toast.error(errMsg(err, 'Failed to create release'));
    },
  });
}

export function useUpdateOtaRelease(app: string | undefined) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ releaseId, body }: { releaseId: string; body: OtaCreateReleaseReq }) =>
      updateOtaRelease(app!, releaseId, body),
    onSuccess: (_, vars) => {
      toast.success('Release updated');
      qc.invalidateQueries({ queryKey: ['ota-release', app, vars.releaseId] });
      qc.invalidateQueries({ queryKey: ['ota-releases', app] });
      qc.invalidateQueries({ queryKey: ['ota-releases-dim', app] });
    },
    onError: (err: any) => {
      toast.error(errMsg(err, 'Failed to update release'));
    },
  });
}

export function useCreateOtaPackage(app: string | undefined) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: OtaCreatePackageReq) => createOtaPackage(app!, body),
    onSuccess: () => {
      toast.success('Package created');
      qc.invalidateQueries({ queryKey: ['ota-packages', app] });
      qc.invalidateQueries({ queryKey: ['ota-packages-all', app] });
    },
    onError: (err: any) => {
      toast.error(errMsg(err, 'Failed to create package'));
    },
  });
}

export function useCreateOtaFile(app: string | undefined) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: OtaCreateFileReq) => createOtaFile(app!, body),
    onSuccess: (_, vars) => {
      toast.success(`File registered: ${vars.file_path}`);
      qc.invalidateQueries({ queryKey: ['ota-files', app] });
      qc.invalidateQueries({ queryKey: ['ota-files-all', app] });
      qc.invalidateQueries({ queryKey: ['ota-file-groups', app] });
      qc.invalidateQueries({ queryKey: ['ota-file-tags', app] });
    },
    onError: (err: any) => {
      toast.error(errMsg(err, 'Failed to register file'));
    },
  });
}

export function useUpdateOtaFileTag(app: string | undefined) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ fileKey, tag }: { fileKey: string; tag: string }) =>
      updateOtaFileTag(app!, fileKey, tag),
    onSuccess: (_, vars) => {
      toast.success(`Tag set to "${vars.tag}"`);
      qc.invalidateQueries({ queryKey: ['ota-files', app] });
      qc.invalidateQueries({ queryKey: ['ota-files-all', app] });
      qc.invalidateQueries({ queryKey: ['ota-file-groups', app] });
      qc.invalidateQueries({ queryKey: ['ota-file-tags', app] });
    },
    onError: (err: any) => {
      toast.error(errMsg(err, 'Failed to update tag'));
    },
  });
}

// ── Targeting & config (Phase 3) ───────────────────────────────────

// Explicit count — airborne forwards page/count to Superposition untouched,
// which defaults to ~10/page; the bare call would silently truncate the
// targeting vocabulary used across Dimensions/Cohorts/Views/the wizard.
const DIMENSIONS_COUNT = 100;

export function useOtaDimensions(app: string | undefined) {
  return useQuery({
    queryKey: ['ota-dimensions', app],
    queryFn: () => fetchOtaDimensions(app!, { count: DIMENSIONS_COUNT }),
    enabled: !!app,
    staleTime: 30_000,
  });
}

export function useOtaCohort(app: string | undefined, dimension: string | undefined) {
  return useQuery({
    queryKey: ['ota-cohort', app, dimension],
    queryFn: () => fetchOtaCohort(app!, dimension!),
    enabled: !!app && !!dimension,
  });
}

export function useOtaCohortPriority(app: string | undefined, dimension: string | undefined) {
  return useQuery({
    queryKey: ['ota-cohort-priority', app, dimension],
    queryFn: () => fetchOtaCohortPriority(app!, dimension!),
    enabled: !!app && !!dimension,
  });
}

export function useOtaPropertiesSchema(app: string | undefined, dimension?: string) {
  return useQuery({
    queryKey: ['ota-properties-schema', app, dimension ?? ''],
    queryFn: () => fetchOtaPropertiesSchema(app!, dimension || undefined),
    enabled: !!app,
  });
}

export function useOtaPropertiesList(app: string | undefined, dimension?: string) {
  return useQuery({
    queryKey: ['ota-properties-list', app, dimension ?? ''],
    queryFn: () => fetchOtaPropertiesList(app!, dimension || undefined),
    enabled: !!app,
  });
}

export function useOtaViews(app: string | undefined, params: { page: number; count: number }) {
  return useQuery({
    queryKey: ['ota-views', app, params.page, params.count],
    queryFn: () => fetchOtaViews(app!, params),
    enabled: !!app,
    placeholderData: keepPreviousData,
  });
}

// Releases matching a dimension context ("k=v;k2=v2") — used by the Views and
// Cohorts pages to preview which releases target a segment.
export function useOtaReleasesForDimension(app: string | undefined, dimension: string | undefined) {
  return useQuery({
    queryKey: ['ota-releases-dim', app, dimension],
    queryFn: () => fetchOtaReleases(app!, { page: 1, count: 10, dimension }),
    enabled: !!app && !!dimension,
    staleTime: 30_000,
  });
}

// ── Analytics (Phase 4) ────────────────────────────────────────────

export function useOtaAdoption(
  app: string | undefined,
  params: OtaAdoptionParams,
  enabled: boolean,
) {
  return useQuery({
    queryKey: [
      'ota-adoption',
      app,
      params.interval,
      params.start_date,
      params.end_date,
      params.release_id ?? '',
    ],
    queryFn: () => fetchOtaAdoption(app!, params),
    enabled: !!app && enabled,
    staleTime: 60_000,
    retry: false,
  });
}

export function useOtaActiveDevices(app: string | undefined, days: number, enabled: boolean) {
  return useQuery({
    queryKey: ['ota-active-devices', app, days],
    queryFn: () => fetchOtaActiveDevices(app!, days),
    enabled: !!app && enabled,
    staleTime: 60_000,
    retry: false,
  });
}

export function useOtaVersions(app: string | undefined, days: number, enabled: boolean) {
  return useQuery({
    queryKey: ['ota-versions', app, days],
    queryFn: () => fetchOtaVersions(app!, days),
    enabled: !!app && enabled,
    staleTime: 60_000,
    retry: false,
  });
}

export function useOtaFailures(
  app: string | undefined,
  days: number,
  releaseId: string | undefined,
  enabled: boolean,
) {
  return useQuery({
    queryKey: ['ota-failures', app, days, releaseId ?? ''],
    queryFn: () => fetchOtaFailures(app!, { days, release_id: releaseId }),
    enabled: !!app && enabled,
    staleTime: 60_000,
    retry: false,
  });
}

export function useOtaPerformance(
  app: string | undefined,
  days: number,
  releaseId: string | undefined,
  enabled: boolean,
) {
  return useQuery({
    queryKey: ['ota-performance', app, days, releaseId ?? ''],
    queryFn: () => fetchOtaPerformance(app!, { days, release_id: releaseId }),
    enabled: !!app && enabled,
    staleTime: 60_000,
    retry: false,
  });
}

export function useCreateOtaDimension(app: string | undefined) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: OtaCreateDimensionReq) => createOtaDimension(app!, body),
    onSuccess: (_, vars) => {
      toast.success(`Dimension "${vars.dimension}" created`);
      qc.invalidateQueries({ queryKey: ['ota-dimensions', app] });
    },
    onError: (err: any) => {
      toast.error(errMsg(err, 'Failed to create dimension'));
    },
  });
}

export function useUpdateOtaDimension(app: string | undefined) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ dimension, body }: { dimension: string; body: OtaUpdateDimensionReq }) =>
      updateOtaDimension(app!, dimension, body),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['ota-dimensions', app] });
    },
    onError: (err: any) => {
      toast.error(errMsg(err, 'Failed to update dimension'));
    },
  });
}

export function useCreateOtaCheckpoint(app: string | undefined) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ dimension, body }: { dimension: string; body: OtaCheckpointReq }) =>
      createOtaCheckpoint(app!, dimension, body),
    onSuccess: (_, vars) => {
      toast.success(`Checkpoint "${vars.body.name}" added`);
      qc.invalidateQueries({ queryKey: ['ota-cohort', app, vars.dimension] });
      qc.invalidateQueries({ queryKey: ['ota-cohort-priority', app, vars.dimension] });
    },
    onError: (err: any) => {
      toast.error(errMsg(err, 'Failed to add checkpoint'));
    },
  });
}

export function useCreateOtaGroup(app: string | undefined) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ dimension, body }: { dimension: string; body: OtaGroupReq }) =>
      createOtaGroup(app!, dimension, body),
    onSuccess: (_, vars) => {
      toast.success(`Group "${vars.body.name}" added`);
      qc.invalidateQueries({ queryKey: ['ota-cohort', app, vars.dimension] });
      qc.invalidateQueries({ queryKey: ['ota-cohort-priority', app, vars.dimension] });
    },
    onError: (err: any) => {
      toast.error(errMsg(err, 'Failed to add group'));
    },
  });
}

export function useUpdateOtaCohortPriority(app: string | undefined) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({
      dimension,
      priorityMap,
    }: {
      dimension: string;
      priorityMap: Record<string, number>;
    }) => updateOtaCohortPriority(app!, dimension, priorityMap),
    onSuccess: (_, vars) => {
      qc.invalidateQueries({ queryKey: ['ota-cohort', app, vars.dimension] });
      qc.invalidateQueries({ queryKey: ['ota-cohort-priority', app, vars.dimension] });
    },
    onError: (err: any) => {
      toast.error(errMsg(err, 'Failed to reorder group'));
    },
  });
}

export function usePutOtaPropertiesSchema(app: string | undefined) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (properties: Record<string, unknown>) => putOtaPropertiesSchema(app!, properties),
    onSuccess: () => {
      toast.success('Properties schema saved');
      qc.invalidateQueries({ queryKey: ['ota-properties-schema', app] });
      qc.invalidateQueries({ queryKey: ['ota-properties-list', app] });
    },
    onError: (err: any) => {
      toast.error(errMsg(err, 'Failed to save properties schema'));
    },
  });
}

export function useCreateOtaView(app: string | undefined) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: OtaSaveViewReq) => createOtaView(app!, body),
    onSuccess: (_, vars) => {
      toast.success(`View "${vars.name}" created`);
      qc.invalidateQueries({ queryKey: ['ota-views', app] });
    },
    onError: (err: any) => {
      toast.error(errMsg(err, 'Failed to create view'));
    },
  });
}

export function useUpdateOtaView(app: string | undefined) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ viewId, body }: { viewId: string; body: OtaSaveViewReq }) =>
      updateOtaView(app!, viewId, body),
    onSuccess: (_, vars) => {
      toast.success(`View "${vars.body.name}" updated`);
      qc.invalidateQueries({ queryKey: ['ota-views', app] });
    },
    onError: (err: any) => {
      toast.error(errMsg(err, 'Failed to update view'));
    },
  });
}

export function useDeleteOtaView(app: string | undefined) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (viewId: string) => deleteOtaView(app!, viewId),
    onSuccess: () => {
      toast.success('View deleted');
      qc.invalidateQueries({ queryKey: ['ota-views', app] });
    },
    onError: (err: any) => {
      toast.error(errMsg(err, 'Failed to delete view'));
    },
  });
}

// ── App create (Phase 9) ───────────────────────────────────────────

export function useCreateOtaApp() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: OtaCreateAppReq) => createOtaApp(body),
    onSuccess: (_, vars) => {
      toast.success(`Application "${vars.app}" created in ${vars.org}`);
      // The app list is derived live upstream — refresh both views.
      qc.invalidateQueries({ queryKey: ['ota-access'] });
      qc.invalidateQueries({ queryKey: ['ota-apps'] });
    },
    onError: (err: any) => {
      toast.error(errMsg(err, 'Failed to create application'));
    },
  });
}

// ── Audit trail (Phase 8) ──────────────────────────────────────────

export function useOtaEvents(
  app: string | undefined,
  params: { page: number; count: number; action?: string },
) {
  return useQuery({
    queryKey: ['ota-events', app, params.page, params.count, params.action ?? ''],
    queryFn: () => fetchOtaEvents(app!, params),
    enabled: !!app,
    placeholderData: keepPreviousData,
    staleTime: 15_000,
  });
}

// ── Files grouped by path (airborne-dashboard shape) ───────────────

export function useOtaFileGroups(
  app: string | undefined,
  params: { page: number; count: number; search?: string; tags?: string },
) {
  return useQuery({
    queryKey: ['ota-file-groups', app, params.page, params.count, params.search ?? '', params.tags ?? ''],
    queryFn: () => fetchOtaFileGroups(app!, params),
    enabled: !!app,
    placeholderData: keepPreviousData,
    staleTime: 15_000,
  });
}

export function useOtaFileTags(app: string | undefined) {
  return useQuery({
    queryKey: ['ota-file-tags', app],
    queryFn: () => fetchOtaFileTags(app!),
    enabled: !!app,
    staleTime: 60_000,
  });
}
