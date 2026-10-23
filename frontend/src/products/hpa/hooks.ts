import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import * as api from './api';
import type { ApplyAction, ScheduleBody } from './api';
import type { Guardrail } from './types';

export const hpaKeys = {
  overview: (p: string) => ['hpa', 'overview', p] as const,
  service: (p: string, s: string) => ['hpa', 'service', p, s] as const,
  series: (p: string, s: string, from?: string, to?: string) => ['hpa', 'series', p, s, from, to] as const,
  scaleEvents: (p: string, s: string, from?: string, to?: string) => ['hpa', 'scale-events', p, s, from, to] as const,
  history: (p: string, s: string) => ['hpa', 'history', p, s] as const,
  events: (p: string, s: string) => ['hpa', 'events', p, s] as const,
  schedules: (p: string, s?: string) => ['hpa', 'schedules', p, s ?? ''] as const,
  applies: (p: string, s?: string, st?: string) => ['hpa', 'applies', p, s ?? '', st ?? ''] as const,
  apply: (id: string) => ['hpa', 'apply', id] as const,
};

export function useOverview(product: string) {
  return useQuery({
    queryKey: hpaKeys.overview(product),
    queryFn: () => api.fetchOverview(product),
    enabled: !!product,
    refetchInterval: 30000,
    placeholderData: keepPreviousData,
  });
}

export function useServiceDetail(product: string, service: string) {
  return useQuery({
    queryKey: hpaKeys.service(product, service),
    queryFn: () => api.fetchServiceDetail(product, service),
    enabled: !!product && !!service,
    refetchInterval: 15000,
    placeholderData: keepPreviousData,
  });
}

export function useSeries(product: string, service: string, from?: string, to?: string) {
  return useQuery({
    queryKey: hpaKeys.series(product, service, from, to),
    queryFn: () => api.fetchSeries(product, service, from, to),
    enabled: !!product && !!service,
    refetchInterval: 30000,
    placeholderData: keepPreviousData,
  });
}

export function useScaleEvents(product: string, service: string, from?: string, to?: string) {
  return useQuery({
    queryKey: hpaKeys.scaleEvents(product, service, from, to),
    queryFn: () => api.fetchScaleEvents(product, service, from, to),
    enabled: !!product && !!service,
    refetchInterval: 60000,
    placeholderData: keepPreviousData,
  });
}

export function useHistory(product: string, service: string) {
  return useQuery({
    queryKey: hpaKeys.history(product, service),
    queryFn: () => api.fetchHistory(product, service),
    enabled: !!product && !!service,
    refetchInterval: 30000,
  });
}

export function useServiceEvents(product: string, service: string) {
  return useQuery({
    queryKey: hpaKeys.events(product, service),
    queryFn: () => api.fetchServiceEvents(product, service),
    enabled: !!product && !!service,
    refetchInterval: 15000,
  });
}

export function useSchedules(product: string, service?: string) {
  return useQuery({
    queryKey: hpaKeys.schedules(product, service),
    queryFn: () => api.fetchSchedules(product, service),
    enabled: !!product,
    refetchInterval: 30000,
  });
}

export function useApplies(product: string, opts: { service?: string; status?: string } = {}) {
  return useQuery({
    queryKey: hpaKeys.applies(product, opts.service, opts.status),
    queryFn: () => api.fetchApplies(product, { ...opts, limit: 200 }),
    enabled: !!product,
    refetchInterval: 10000,
    placeholderData: keepPreviousData,
  });
}

export function useApply(id: string | null) {
  return useQuery({
    queryKey: hpaKeys.apply(id ?? ''),
    queryFn: () => api.fetchApply(id as string),
    enabled: !!id,
    refetchInterval: 5000,
  });
}

/** Any write can change what every HPA panel shows, so refresh them all. */
function useInvalidateHpa() {
  const qc = useQueryClient();
  return () => qc.invalidateQueries({ queryKey: ['hpa'] });
}

const fail = (e: unknown) => toast.error(api.errorMessage(e));

export function useSaveSchedule(onDone?: () => void) {
  const invalidate = useInvalidateHpa();
  return useMutation({
    mutationFn: ({ id, body }: { id?: string; body: ScheduleBody }) =>
      id ? api.updateSchedule(id, body) : api.createSchedule(body),
    onSuccess: (_d, v) => { toast.success(v.id ? 'Schedule updated' : 'Schedule created'); invalidate(); onDone?.(); },
    onError: fail,
  });
}

export function useScheduleAction() {
  const invalidate = useInvalidateHpa();
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
  const invalidate = useInvalidateHpa();
  return useMutation({
    mutationFn: api.manualApply,
    onSuccess: () => { toast.success('Change queued'); invalidate(); onDone?.(); },
    onError: fail,
  });
}

export function useApplyAction() {
  const invalidate = useInvalidateHpa();
  return useMutation({
    mutationFn: ({ id, action }: { id: string; action: ApplyAction }) => api.applyAction(id, action),
    onSuccess: (_d, v) => { toast.success(`Requested: ${v.action}`); invalidate(); },
    onError: fail,
  });
}

export function useSaveGuardrail(product: string, service: string, onDone?: () => void) {
  const invalidate = useInvalidateHpa();
  return useMutation({
    mutationFn: (g: Guardrail) => api.putGuardrail(product, service, g),
    onSuccess: () => { toast.success('Guardrails saved'); invalidate(); onDone?.(); },
    onError: fail,
  });
}

export function useWatch(product: string, service: string) {
  const invalidate = useInvalidateHpa();
  return useMutation({
    mutationFn: (watched: boolean) => api.putWatch(product, service, watched),
    onSuccess: (_d, watched) => { toast.success(watched ? 'Now sampling this service' : 'Stopped sampling'); invalidate(); },
    onError: fail,
  });
}
