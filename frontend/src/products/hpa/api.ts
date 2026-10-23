import { apiClient } from '../../lib/api-client';
import type {
  Apply, ApplyEvent, Guardrail, HealthPolicy, HpaChange, Overview, Preview, ScaleEvent, Schedule,
  ScheduleKind, Series, ServiceDetail, Snapshot,
} from './types';

const enc = encodeURIComponent;
const svc = (product: string, service: string) => `/hpa/service/${enc(product)}/${enc(service)}`;

export async function fetchOverview(product: string): Promise<Overview> {
  return (await apiClient.get(`/hpa/overview/${enc(product)}`)).data;
}
export async function fetchServiceDetail(product: string, service: string): Promise<ServiceDetail> {
  return (await apiClient.get(svc(product, service))).data;
}
export async function fetchSeries(product: string, service: string, from?: string, to?: string): Promise<Series> {
  return (await apiClient.get(`${svc(product, service)}/series`, { params: { from, to } })).data;
}
export async function fetchScaleEvents(product: string, service: string, from?: string, to?: string): Promise<ScaleEvent[]> {
  return (await apiClient.get(`${svc(product, service)}/scale-events`, { params: { from, to } })).data.events;
}
export async function fetchHistory(product: string, service: string): Promise<Snapshot[]> {
  return (await apiClient.get(`${svc(product, service)}/history`)).data.snapshots;
}
export async function fetchServiceEvents(product: string, service: string): Promise<ApplyEvent[]> {
  return (await apiClient.get(`${svc(product, service)}/events`)).data.events;
}
export async function putGuardrail(product: string, service: string, g: Guardrail): Promise<void> {
  await apiClient.put(`${svc(product, service)}/guardrail`, g);
}
export async function putWatch(product: string, service: string, watched: boolean): Promise<void> {
  await apiClient.put(`${svc(product, service)}/watch`, { watched });
}

export async function fetchSchedules(product: string, service?: string): Promise<Schedule[]> {
  return (await apiClient.get('/hpa/schedules', { params: { product, service } })).data.schedules;
}
export interface ScheduleBody {
  product: string; service: string; name: string; kind: ScheduleKind; change: HpaChange; healthPolicy?: HealthPolicy;
}
export async function previewChange(body: {
  product: string; service: string; hpa?: string; change: HpaChange; kind?: ScheduleKind;
}): Promise<Preview> {
  return (await apiClient.post('/hpa/schedules/preview', body)).data;
}
export async function createSchedule(body: ScheduleBody): Promise<{ id: string }> {
  return (await apiClient.post('/hpa/schedules', body)).data;
}
export async function updateSchedule(id: string, body: ScheduleBody): Promise<{ id: string }> {
  return (await apiClient.put(`/hpa/schedules/${enc(id)}`, body)).data;
}
export async function pauseSchedule(id: string): Promise<void> { await apiClient.post(`/hpa/schedules/${enc(id)}/pause`); }
export async function resumeSchedule(id: string): Promise<void> { await apiClient.post(`/hpa/schedules/${enc(id)}/resume`); }
export async function deleteSchedule(id: string): Promise<void> { await apiClient.delete(`/hpa/schedules/${enc(id)}`); }

export async function fetchApplies(product: string, opts: { service?: string; status?: string; limit?: number } = {}): Promise<Apply[]> {
  return (await apiClient.get('/hpa/applies', { params: { product, ...opts } })).data.applies;
}
export async function fetchApply(id: string): Promise<{ apply: Apply; events: ApplyEvent[] }> {
  return (await apiClient.get(`/hpa/applies/${enc(id)}`)).data;
}
export async function manualApply(body: {
  product: string; service: string; hpa?: string; change: HpaChange; healthPolicy?: HealthPolicy; endAt?: string;
}): Promise<{ applyIds: string[] }> {
  return (await apiClient.post('/hpa/applies', body)).data;
}
export type ApplyAction = 'restore' | 'rollback' | 'cancel' | 'acknowledge';
export async function applyAction(id: string, action: ApplyAction): Promise<void> {
  await apiClient.post(`/hpa/applies/${enc(id)}/${action}`);
}

/** The server's message for a failed request, for toasts. */
export function errorMessage(e: any): string {
  return e?.response?.data?.message || e?.message || 'Request failed';
}
