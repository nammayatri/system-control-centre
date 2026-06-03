import { useQuery, useQueries, useMutation, useQueryClient, keepPreviousData } from '@tanstack/react-query';
import {
  fetchAPReleases,
  fetchReleaseDetails,
  fetchReleaseEvents,
  createRelease,
  approveRelease,
  rollbackRelease,
  revertRelease,
  discardRelease,
  pauseRelease,
  resumeRelease,
  abortRelease,
  immediateRevert,
  updateTracker,
  deleteRelease,
  restartRelease,
  fastForwardRelease,
  immediateRevertRelease,
  fetchReleaseDiff,
  fetchPodHealth,
  fetchResources,
  TERMINAL_STATUSES,
  mobileApi,
} from './api';
import { toast } from 'sonner';

export function useReleases(
  from: string,
  to: string,
  category?: 'backend' | 'mobile',
) {
  return useQuery({
    queryKey: ['releases', from, to, category ?? 'all'],
    queryFn: () => fetchAPReleases(from, to, category),
    refetchInterval: 60000,
    enabled: !!from && !!to,
  });
}

export function useRelease(id: string | undefined) {
  return useQuery({
    queryKey: ['release', id],
    queryFn: () => fetchReleaseDetails(id!),
    refetchInterval: (query) => {
      const status = query.state.data?.status;
      if (!status) return 10000; // still loading, poll
      if (TERMINAL_STATUSES.includes(status)) return false; // terminal — stop polling
      return 10000; // active — poll every 10s
    },
    enabled: !!id,
  });
}

export function useReleaseEvents(id: string | undefined) {
  // Poll while the release is active; peek at the ['release', id] cache so terminal
  // releases stop refetching events.
  const qc = useQueryClient();
  return useQuery({
    queryKey: ['release-events', id],
    queryFn: () => fetchReleaseEvents(id!),
    refetchInterval: () => {
      const release = qc.getQueryData<any>(['release', id]);
      const status = release?.status;
      if (status && TERMINAL_STATUSES.includes(status)) return false;
      return 10000;
    },
    enabled: !!id,
  });
}

export function useCreateRelease() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ isNewService, payload }: { isNewService: boolean; payload: any }) =>
      createRelease(isNewService, payload),
    onSuccess: () => {
      toast.success('Release created successfully');
      qc.invalidateQueries({ queryKey: ['releases'] });
    },
    onError: (err: any) => {
      toast.error(err?.response?.data?.message || err.message || 'Failed to create release');
    },
  });
}

export function useApproveRelease() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ releaseId, approvedBy, isInfraApproved }: { releaseId: string; approvedBy: string; isInfraApproved?: boolean }) =>
      approveRelease(releaseId, approvedBy, isInfraApproved),
    onSuccess: (_, vars) => {
      toast.success('Release approved');
      qc.invalidateQueries({ queryKey: ['release', vars.releaseId] });
      qc.invalidateQueries({ queryKey: ['releases'] });
    },
    onError: (err: any) => {
      toast.error(err?.response?.data?.message || err.message || 'Failed to approve release');
    },
  });
}

export function useRollbackRelease() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ releaseId, reason }: { releaseId: string; reason?: string }) =>
      rollbackRelease(releaseId, reason),
    onSuccess: (_, vars) => {
      toast.success('Rollback initiated');
      qc.invalidateQueries({ queryKey: ['release', vars.releaseId] });
    },
    onError: (err: any) => {
      toast.error(err?.response?.data?.message || err.message || 'Rollback failed');
    },
  });
}

export function useRevertRelease() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ releaseId, requestedBy, info, immediate, isRevertSync }: { releaseId: string; requestedBy?: string; info?: string; immediate?: boolean; isRevertSync?: boolean }) =>
      revertRelease(releaseId, requestedBy, info, immediate, isRevertSync),
    onSuccess: (_, vars) => {
      toast.success(vars.immediate ? 'Immediate revert initiated' : 'Revert initiated');
      qc.invalidateQueries({ queryKey: ['release', vars.releaseId] });
    },
    onError: (err: any) => {
      toast.error(err?.response?.data?.message || err.message || 'Revert failed');
    },
  });
}

export function useDiscardRelease() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ releaseId, reason }: { releaseId: string; reason?: string }) =>
      discardRelease(releaseId, reason),
    onSuccess: (_, vars) => {
      toast.success('Release discarded');
      qc.invalidateQueries({ queryKey: ['release', vars.releaseId] });
      qc.invalidateQueries({ queryKey: ['releases'] });
    },
    onError: (err: any) => {
      toast.error(err?.response?.data?.message || err.message || 'Failed to discard release');
    },
  });
}

export function usePauseRelease() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (releaseId: string) => pauseRelease(releaseId),
    onSuccess: (_, releaseId) => {
      toast.success('Release paused');
      qc.invalidateQueries({ queryKey: ['release', releaseId] });
    },
    onError: (err: any) => {
      toast.error(err?.response?.data?.message || err.message || 'Failed to pause');
    },
  });
}

export function useResumeRelease() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (releaseId: string) => resumeRelease(releaseId),
    onSuccess: (_, releaseId) => {
      toast.success('Release resumed');
      qc.invalidateQueries({ queryKey: ['release', releaseId] });
    },
    onError: (err: any) => {
      toast.error(err?.response?.data?.message || err.message || 'Failed to resume');
    },
  });
}

export function useAbortRelease() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (releaseId: string) => abortRelease(releaseId),
    onSuccess: (_, releaseId) => {
      toast.success('Release abort initiated');
      qc.invalidateQueries({ queryKey: ['release', releaseId] });
    },
    onError: (err: any) => {
      toast.error(err?.response?.data?.message || err.message || 'Failed to abort');
    },
  });
}

export function useImmediateRevert() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ releaseId, requestedBy }: { releaseId: string; requestedBy?: string }) =>
      immediateRevert(releaseId, requestedBy),
    onSuccess: (_, vars) => {
      toast.success('Immediate revert initiated');
      qc.invalidateQueries({ queryKey: ['release', vars.releaseId] });
    },
    onError: (err: any) => {
      toast.error(err?.response?.data?.message || err.message || 'Immediate revert failed');
    },
  });
}

export function useDeleteRelease() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (releaseId: string) => deleteRelease(releaseId),
    onSuccess: () => {
      toast.success('Release deleted');
      qc.invalidateQueries({ queryKey: ['releases'] });
    },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to delete'),
  });
}

export function useUpdateTracker() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ releaseId, updates }: { releaseId: string; updates: Record<string, any> }) =>
      updateTracker(releaseId, updates),
    onSuccess: (_, vars) => {
      toast.success('Release updated');
      qc.invalidateQueries({ queryKey: ['release', vars.releaseId] });
    },
    onError: (err: any) => {
      toast.error(err?.response?.data?.message || err.message || 'Update failed');
    },
  });
}

export function useRestartRelease() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (releaseId: string) => restartRelease(releaseId),
    onSuccess: (_, releaseId) => {
      toast.success('Restart initiated');
      qc.invalidateQueries({ queryKey: ['release', releaseId] });
    },
    onError: (err: any) => {
      toast.error(err?.response?.data?.message || err.message || 'Restart failed');
    },
  });
}

export function useFastForwardRelease() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (releaseId: string) => fastForwardRelease(releaseId),
    onSuccess: (_, releaseId) => {
      toast.success('Fast forward initiated');
      qc.invalidateQueries({ queryKey: ['release', releaseId] });
    },
    onError: (err: any) => {
      toast.error(err?.response?.data?.message || err.message || 'Fast forward failed');
    },
  });
}

export function useImmediateRevertWithSync() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ releaseId, isRevertSync }: { releaseId: string; isRevertSync: boolean }) =>
      immediateRevertRelease(releaseId, isRevertSync),
    onSuccess: (_, vars) => {
      toast.success('Immediate revert initiated');
      qc.invalidateQueries({ queryKey: ['release', vars.releaseId] });
    },
    onError: (err: any) => {
      toast.error(err?.response?.data?.message || err.message || 'Immediate revert failed');
    },
  });
}

export function useReleaseDiff(id: string | undefined, type?: string) {
  return useQuery({
    queryKey: ['release-diff', id, type],
    queryFn: () => fetchReleaseDiff(id!, type),
    enabled: !!id,
  });
}

export function usePodHealth(id: string | undefined) {
  return useQuery({
    queryKey: ['pod-health', id],
    queryFn: () => fetchPodHealth(id!),
    refetchInterval: 10000,
    enabled: !!id,
  });
}

export function useResources(product: string | undefined, service: string | undefined) {
  return useQuery({
    queryKey: ['resources', product, service],
    queryFn: () => fetchResources(product!, service!),
    enabled: !!product && !!service,
  });
}

// ── Mobile Releases hooks ─────────────────────────────────────────

export function useMobileApps() {
  return useQuery({
    queryKey: ['mobile', 'apps'],
    queryFn: () => mobileApi.listApps(),
  });
}

export function useMobileBranches(search?: string) {
  return useQuery({
    queryKey: ['mobile', 'branches', search ?? ''],
    queryFn: () => mobileApi.listBranches(search),
    staleTime: search ? 30_000 : 5 * 60_000,
    placeholderData: keepPreviousData,
  });
}

export function usePreviewVersions(appCatalogIds: number[]) {
  // sort the ids so the cache key is order-independent
  const sortedKey = [...appCatalogIds].sort((a, b) => a - b).join(',');
  return useQuery({
    queryKey: ['mobile', 'versions', 'preview', sortedKey],
    queryFn: () => mobileApi.previewVersions(appCatalogIds),
    enabled: appCatalogIds.length > 0,
    staleTime: 60_000,
  });
}

export function useCreateMobileReleases() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: mobileApi.createReleases,
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['releases'] });
    },
    onError: (err: any) => {
      toast.error(err?.response?.data?.message || err.message || 'Failed to create mobile releases');
    },
  });
}

export function useDispatchMobileReleases() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: mobileApi.dispatchReleases,
    onSuccess: (resp) => {
      toast.success(`Dispatched ${resp.dispatches.length} workflow${resp.dispatches.length === 1 ? '' : 's'}`);
      qc.invalidateQueries({ queryKey: ['releases'] });
      qc.invalidateQueries({ queryKey: ['release'] });
    },
    onError: (err: any) => {
      toast.error(err?.response?.data?.message || err.message || 'Failed to dispatch mobile releases');
    },
  });
}

export function useLiveReleases(category: 'all' | 'backend' | 'mobile' = 'all') {
  return useQuery({
    queryKey: ['releases', 'live', category],
    queryFn: () => mobileApi.liveReleases(category),
    refetchInterval: 10_000,
  });
}

export type ChangelogApp = { name: string; surface: string; platform: string; label: string };

export function useChangelogPreviews(apps: ChangelogApp[], branch: string | undefined) {
  return useQueries({
    queries: apps.map((app) => ({
      queryKey: ['mobile', 'changelog-preview', app.name, app.surface, app.platform, branch],
      queryFn: () => mobileApi.changelogPreview(app.name, app.surface, app.platform, branch!),
      enabled: !!branch,
      staleTime: 60_000,
      placeholderData: keepPreviousData,
    })),
  });
}
