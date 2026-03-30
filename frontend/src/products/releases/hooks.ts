import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
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
} from './api';
import { toast } from 'sonner';

export function useReleases(from: string, to: string) {
  return useQuery({
    queryKey: ['releases', from, to],
    queryFn: () => fetchAPReleases(from, to),
    refetchInterval: 60000,
    enabled: !!from && !!to,
  });
}

export function useRelease(id: string | undefined) {
  return useQuery({
    queryKey: ['release', id],
    queryFn: () => fetchReleaseDetails(id!),
    refetchInterval: 10000,
    enabled: !!id,
  });
}

export function useReleaseEvents(id: string | undefined) {
  return useQuery({
    queryKey: ['release-events', id],
    queryFn: () => fetchReleaseEvents(id!),
    refetchInterval: 10000,
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
    mutationFn: ({ releaseId, requestedBy, info, immediate }: { releaseId: string; requestedBy?: string; info?: string; immediate?: boolean }) =>
      revertRelease(releaseId, requestedBy, info, immediate),
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
