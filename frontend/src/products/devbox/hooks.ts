import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import {
  createDevboxRelease,
  fetchBranches,
  fetchBranchStatus,
  fetchDevboxRelease,
  fetchDevboxReleases,
  stopDevboxRelease,
} from './api';
import { ACTIVE_STATUSES, type BranchRepo, type CreateReleaseReq, type StatusFilter } from './types';

const keys = {
  all: ['devbox'] as const,
  list: (filter: StatusFilter, q: string, page: number) => ['devbox', 'list', filter, q, page] as const,
  detail: (id: string) => ['devbox', 'detail', id] as const,
  branch: (branch: string) => ['devbox', 'branch', branch] as const,
  branches: (repo: BranchRepo, q: string) => ['devbox', 'branches', repo, q] as const,
};

/** The table. Refreshes every 10 s so stages move without a reload (the poller runs at the same pace). */
export function useDevboxReleases(filter: StatusFilter, q: string, page: number, count = 20) {
  return useQuery({
    queryKey: keys.list(filter, q, page),
    queryFn: () => fetchDevboxReleases({ filter, q, page, count }),
    placeholderData: keepPreviousData,
    refetchInterval: 10_000,
  });
}

/** One release. Refreshes every 5 s while it is still moving, then stops. */
export function useDevboxRelease(id: string | undefined) {
  return useQuery({
    queryKey: keys.detail(id ?? ''),
    queryFn: () => fetchDevboxRelease(id!),
    enabled: !!id,
    refetchInterval: (query) => {
      const st = query.state.data?.release.status;
      return st && ACTIVE_STATUSES.includes(st) && st !== 'READY' ? 5_000 : 30_000;
    },
  });
}

/** Is this backend branch already running? (the form's banner) */
export function useBranchStatus(branch: string) {
  return useQuery({
    queryKey: keys.branch(branch),
    queryFn: () => fetchBranchStatus(branch),
    enabled: branch.trim().length > 0,
    staleTime: 5_000,
  });
}

/** Branch picker suggestions; searches once 2+ characters are typed. */
export function useBranches(repo: BranchRepo, q: string) {
  return useQuery({
    queryKey: keys.branches(repo, q),
    queryFn: () => fetchBranches(repo, q),
    enabled: q.trim().length >= 2,
    staleTime: 30_000,
    retry: false,
  });
}

export function useCreateDevboxRelease() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (req: CreateReleaseReq) => createDevboxRelease(req),
    onSuccess: () => qc.invalidateQueries({ queryKey: keys.all }),
  });
}

export function useStopDevboxRelease() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => stopDevboxRelease(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: keys.all }),
  });
}
