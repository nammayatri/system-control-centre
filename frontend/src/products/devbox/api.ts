import { apiClient } from '../../lib/api-client';
import type {
  BranchStatusResp,
  CreateReleaseReq,
  DevboxRelease,
  ReleaseDetailResp,
  ReleasesResp,
  StatusFilter,
} from './types';

export async function fetchDevboxReleases(params: {
  filter: StatusFilter;
  q?: string;
  page: number;
  count: number;
}): Promise<ReleasesResp> {
  const { data } = await apiClient.get('/devbox/releases', {
    params: { filter: params.filter, q: params.q || undefined, page: params.page, count: params.count },
  });
  return data;
}

export async function fetchDevboxRelease(id: string): Promise<ReleaseDetailResp> {
  const { data } = await apiClient.get(`/devbox/releases/${encodeURIComponent(id)}`);
  return data;
}

export async function fetchBranchStatus(branch: string): Promise<BranchStatusResp> {
  const { data } = await apiClient.get('/devbox/branch-status', { params: { branch } });
  return data;
}

export async function createDevboxRelease(req: CreateReleaseReq): Promise<{ release: DevboxRelease }> {
  const { data } = await apiClient.post('/devbox/releases', req);
  return data;
}

export async function stopDevboxRelease(id: string): Promise<{ release: DevboxRelease }> {
  const { data } = await apiClient.post(`/devbox/releases/${encodeURIComponent(id)}/stop`);
  return data;
}

/** The server's error message, and the running release it points at (409 BRANCH_ACTIVE / WORKSPACE_ACTIVE). */
export function devboxError(err: unknown): { message: string; code?: string; release?: DevboxRelease } {
  const e = err as { response?: { data?: { message?: string; code?: string; release?: DevboxRelease } }; message?: string };
  const d = e?.response?.data;
  return { message: d?.message || e?.message || 'Request failed', code: d?.code, release: d?.release };
}
