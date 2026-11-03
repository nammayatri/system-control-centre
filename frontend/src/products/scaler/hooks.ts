import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import * as api from './api';
import type { ApplyAction, ScheduleBody, TargetBody } from './api';
import type { Guardrail, Target, TargetKind } from './types';

export const scalerKeys = {
  targets: (kind?: TargetKind) => ['scaler', 'targets', kind ?? 'ALL'] as const,
  target: (kind: TargetKind, id: string) => ['scaler', 'target', kind, id] as const,
  autoscaler: (kind: TargetKind, id: string) => ['scaler', 'autoscaler', kind, id] as const,
  apply: (id: string) => ['scaler', 'apply', id] as const,
};

export function useTargets(kind?: TargetKind) {
  return useQuery({
    queryKey: scalerKeys.targets(kind),
    queryFn: () => api.fetchTargets(kind),
    refetchInterval: 30000,
    placeholderData: keepPreviousData,
  });
}

export function useTarget(kind: TargetKind, id: string) {
  return useQuery({
    queryKey: scalerKeys.target(kind, id),
    queryFn: () => api.fetchTarget(kind, id),
    enabled: !!id,
    // A resize takes minutes; keep the live state fresh while someone is watching.
    refetchInterval: 15000,
    placeholderData: keepPreviousData,
  });
}

export function useAutoscaler(kind: TargetKind, id: string, enabled: boolean) {
  return useQuery({
    queryKey: scalerKeys.autoscaler(kind, id),
    queryFn: () => api.fetchAutoscaler(kind, id),
    enabled: enabled && !!id,
  });
}

export function useApply(id: string | null) {
  return useQuery({
    queryKey: scalerKeys.apply(id ?? ''),
    queryFn: () => api.fetchApply(id as string),
    enabled: !!id,
    refetchInterval: 10000,
  });
}

/** Any write can change what every scaler panel shows, so refresh them all. */
function useInvalidate() {
  const qc = useQueryClient();
  return () => qc.invalidateQueries({ queryKey: ['scaler'] });
}

const fail = (e: unknown) => toast.error(api.errorMessage(e));

export function useAddTarget(onDone?: (id: string) => void) {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (b: TargetBody) => api.addTarget(b),
    onSuccess: (d) => { toast.success('Target added'); invalidate(); onDone?.(d.id); },
    onError: fail,
  });
}

export function useEditTarget(t: Pick<Target, 'kind' | 'id'>, onDone?: () => void) {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (b: { name: string; autoscalerJob?: string; autoscalerLocation?: string }) => api.editTarget(t, b),
    onSuccess: () => { toast.success('Target updated'); invalidate(); onDone?.(); },
    onError: fail,
  });
}

export function useDeleteTarget(onDone?: () => void) {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (t: Pick<Target, 'kind' | 'id'>) => api.deleteTarget(t),
    onSuccess: () => { toast.success('Target removed'); invalidate(); onDone?.(); },
    onError: fail,
  });
}

export function useSaveSchedule(onDone?: () => void) {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: ({ id, body }: { id?: string; body: ScheduleBody }) =>
      id ? api.updateSchedule(id, body) : api.createSchedule(body),
    onSuccess: (_d, v) => { toast.success(v.id ? 'Schedule updated' : 'Schedule created'); invalidate(); onDone?.(); },
    onError: fail,
  });
}

export function useScheduleAction() {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: ({ id, action }: { id: string; action: 'pause' | 'resume' | 'delete' }) =>
      action === 'pause' ? api.pauseSchedule(id) : action === 'resume' ? api.resumeSchedule(id) : api.deleteSchedule(id),
    onSuccess: (_d, v) => {
      toast.success({ pause: 'Schedule paused', resume: 'Schedule resumed', delete: 'Schedule deleted' }[v.action]);
      invalidate();
    },
    onError: fail,
  });
}

export function useManualApply(onDone?: () => void) {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: api.manualApply,
    onSuccess: () => { toast.success('Change queued'); invalidate(); onDone?.(); },
    onError: fail,
  });
}

export function useApplyAction() {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: ({ id, action }: { id: string; action: ApplyAction }) => api.applyAction(id, action),
    onSuccess: (_d, v) => { toast.success(`Requested: ${v.action}`); invalidate(); },
    onError: fail,
  });
}

export function useSaveGuardrail(t: Pick<Target, 'kind' | 'id'>, onDone?: () => void) {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (g: Guardrail) => api.putGuardrail(t, g),
    onSuccess: () => { toast.success('Guardrails saved'); invalidate(); onDone?.(); },
    onError: fail,
  });
}

export function useEditAutoscaler(t: Pick<Target, 'kind' | 'id'>, onDone?: () => void) {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (b: { set: Record<string, unknown>; rules?: unknown; expectedData: string; note?: string }) => api.editAutoscaler(t, b),
    onSuccess: () => { toast.success('Autoscaler updated'); invalidate(); onDone?.(); },
    onError: (e) => { fail(e); invalidate(); },
  });
}

export function useRevertAutoscaler(t: Pick<Target, 'kind' | 'id'>) {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: ({ historyId, expectedData }: { historyId: number; expectedData: string }) => api.revertAutoscaler(t, historyId, expectedData),
    onSuccess: () => { toast.success('Change reverted'); invalidate(); },
    onError: (e) => { fail(e); invalidate(); },
  });
}

export function usePauseAutoscaler(t: Pick<Target, 'kind' | 'id'>) {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: ({ paused, note }: { paused: boolean; note?: string }) => api.pauseAutoscaler(t, paused, note),
    onSuccess: (_d, v) => { toast.success(v.paused ? 'Autoscaler paused' : 'Autoscaler resumed'); invalidate(); },
    onError: fail,
  });
}
