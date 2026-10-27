import { apiClient } from '../../lib/api-client';
import type { CreateResult, CronJobDetail, CronJobSummary, EnvChange, ValidateResult } from './types';

const enc = encodeURIComponent;

export async function fetchNamespaces(): Promise<string[]> {
  return (await apiClient.get('/cronjob-namespaces')).data.namespaces;
}
export async function fetchCronJobs(namespace: string): Promise<CronJobSummary[]> {
  return (await apiClient.get('/cronjobs', { params: { namespace } })).data.cronjobs;
}
export async function fetchCronJob(namespace: string, name: string): Promise<CronJobDetail> {
  return (await apiClient.get(`/cronjobs/${enc(name)}`, { params: { namespace } })).data;
}
export async function validateManifest(namespace: string, yaml: string): Promise<ValidateResult> {
  return (await apiClient.post('/cronjobs/validate', { namespace, yaml })).data;
}
export async function createCronJob(namespace: string, yaml: string): Promise<CreateResult> {
  return (await apiClient.post('/cronjobs', { namespace, yaml })).data;
}
export async function updateSchedule(namespace: string, name: string, schedule: string, timeZone?: string): Promise<void> {
  await apiClient.put(`/cronjobs/${enc(name)}/schedule`, { namespace, schedule, timeZone });
}
export async function setSuspend(namespace: string, name: string, suspend: boolean): Promise<void> {
  await apiClient.put(`/cronjobs/${enc(name)}/suspend`, { namespace, suspend });
}
export async function updateEnv(namespace: string, name: string, change: EnvChange): Promise<void> {
  await apiClient.put(`/cronjobs/${enc(name)}/env`, { namespace, ...change });
}
export async function updateImage(namespace: string, name: string, container: string, image: string): Promise<void> {
  await apiClient.put(`/cronjobs/${enc(name)}/image`, { namespace, container, image });
}
export async function deleteCronJob(namespace: string, name: string, force: boolean): Promise<void> {
  await apiClient.delete(`/cronjobs/${enc(name)}`, { params: { namespace, force } });
}

export function errorMessage(e: any): string {
  return e?.response?.data?.message || e?.message || 'Request failed';
}
