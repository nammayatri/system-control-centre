import { apiClient } from '../../lib/api-client';
import type {
  Apply, ApplyEvent, AutoscalerView, DiscoverItem, Guardrail, Preview, ScaleChange, Schedule, ScheduleKind, Target, TargetDetail,
  TargetKind, TargetRow,
} from './types';

export { errorMessage } from '../hpa/api';

const enc = encodeURIComponent;
const tp = (kind: TargetKind, id: string) => `/scaler/targets/${enc(kind)}/${enc(id)}`;

// ── Targets ─────────────────────────────────────────────────────────────────
export async function fetchTargets(kind?: TargetKind): Promise<TargetRow[]> {
  return (await apiClient.get('/scaler/targets', { params: { kind } })).data.targets;
}
export async function discover(kind: TargetKind, project: string, location: string): Promise<{ items: DiscoverItem[]; error?: string }> {
  return (await apiClient.get('/scaler/discover', { params: { kind, project, location } })).data;
}
export interface TargetBody {
  kind: TargetKind; name: string; project: string; location: string; cluster?: string; resource: string;
  autoscalerJob?: string; autoscalerLocation?: string;
}
export async function addTarget(body: TargetBody): Promise<{ id: string }> {
  return (await apiClient.post('/scaler/targets', body)).data;
}
export async function editTarget(t: Pick<Target, 'kind' | 'id'>, body: { name: string; autoscalerJob?: string; autoscalerLocation?: string }): Promise<void> {
  await apiClient.put(tp(t.kind, t.id), body);
}
export async function deleteTarget(t: Pick<Target, 'kind' | 'id'>): Promise<void> {
  await apiClient.delete(tp(t.kind, t.id));
}
export async function fetchTarget(kind: TargetKind, id: string): Promise<TargetDetail> {
  return (await apiClient.get(tp(kind, id))).data;
}
export async function putGuardrail(t: Pick<Target, 'kind' | 'id'>, g: Guardrail): Promise<void> {
  await apiClient.put(`${tp(t.kind, t.id)}/guardrail`, g);
}

// ── The autoscaler that drives a target ─────────────────────────────────────
export async function fetchAutoscaler(kind: TargetKind, id: string): Promise<AutoscalerView> {
  return (await apiClient.get(`${tp(kind, id)}/autoscaler`)).data;
}
export async function editAutoscaler(
  t: Pick<Target, 'kind' | 'id'>,
  body: { set: Record<string, unknown>; rules?: unknown; expectedData: string; note?: string },
): Promise<void> {
  await apiClient.put(`${tp(t.kind, t.id)}/autoscaler`, body);
}
export async function revertAutoscaler(t: Pick<Target, 'kind' | 'id'>, historyId: number, expectedData: string): Promise<void> {
  await apiClient.post(`${tp(t.kind, t.id)}/autoscaler/revert`, { historyId, expectedData });
}
export async function pauseAutoscaler(t: Pick<Target, 'kind' | 'id'>, paused: boolean, note?: string): Promise<void> {
  await apiClient.post(`${tp(t.kind, t.id)}/autoscaler/${paused ? 'pause' : 'resume'}`, { note: note ?? '' });
}

// ── Schedules ───────────────────────────────────────────────────────────────
export interface ScheduleBody {
  targetKind: TargetKind; targetId: string; name: string; timing: ScheduleKind; change: ScaleChange;
}
export async function previewChange(body: { targetKind: TargetKind; targetId: string; change: ScaleChange; timing?: ScheduleKind }): Promise<Preview> {
  return (await apiClient.post('/scaler/schedules/preview', body)).data;
}
export async function createSchedule(body: ScheduleBody): Promise<{ id: string }> {
  return (await apiClient.post('/scaler/schedules', body)).data;
}
export async function updateSchedule(id: string, body: ScheduleBody): Promise<{ id: string }> {
  return (await apiClient.put(`/scaler/schedules/${enc(id)}`, body)).data;
}
export async function pauseSchedule(id: string): Promise<void> { await apiClient.post(`/scaler/schedules/${enc(id)}/pause`); }
export async function resumeSchedule(id: string): Promise<void> { await apiClient.post(`/scaler/schedules/${enc(id)}/resume`); }
export async function deleteSchedule(id: string): Promise<void> { await apiClient.delete(`/scaler/schedules/${enc(id)}`); }

// ── Applies ─────────────────────────────────────────────────────────────────
export async function fetchApply(id: string): Promise<{ apply: Apply; events: ApplyEvent[] }> {
  return (await apiClient.get(`/scaler/applies/${enc(id)}`)).data;
}
export async function manualApply(body: { targetKind: TargetKind; targetId: string; change: ScaleChange; endAt?: string }): Promise<{ id: string }> {
  return (await apiClient.post('/scaler/applies', body)).data;
}
export type ApplyAction = 'restore' | 'rollback' | 'cancel' | 'acknowledge';
export async function applyAction(id: string, action: ApplyAction): Promise<void> {
  await apiClient.post(`/scaler/applies/${enc(id)}/${action}`);
}
export type { Schedule };
