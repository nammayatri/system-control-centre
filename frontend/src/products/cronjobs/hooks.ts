import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import * as api from './api';
import type { EnvChange } from './types';

export const cronKeys = {
  namespaces: ['cronjobs', 'namespaces'] as const,
  list: (ns: string) => ['cronjobs', 'list', ns] as const,
  one: (ns: string, name: string) => ['cronjobs', 'one', ns, name] as const,
};

export function useNamespaces() {
  return useQuery({ queryKey: cronKeys.namespaces, queryFn: api.fetchNamespaces, staleTime: 300000 });
}

export function useCronJobs(namespace: string) {
  return useQuery({
    queryKey: cronKeys.list(namespace),
    queryFn: () => api.fetchCronJobs(namespace),
    enabled: !!namespace,
    refetchInterval: 20000,
    placeholderData: keepPreviousData,
  });
}

export function useCronJob(namespace: string, name: string) {
  return useQuery({
    queryKey: cronKeys.one(namespace, name),
    queryFn: () => api.fetchCronJob(namespace, name),
    enabled: !!namespace && !!name,
    refetchInterval: 15000,
  });
}

const fail = (e: unknown) => toast.error(api.errorMessage(e), { duration: 8000 });

/** Any write can change both the list and the detail, so refresh everything cronjob-related. */
function useInvalidate() {
  const qc = useQueryClient();
  return () => qc.invalidateQueries({ queryKey: ['cronjobs'] });
}

export function useValidate() {
  return useMutation({
    mutationFn: ({ namespace, yaml }: { namespace: string; yaml: string }) => api.validateManifest(namespace, yaml),
    onError: fail,
  });
}

export function useCreate(onDone?: (name: string) => void) {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: ({ namespace, yaml }: { namespace: string; yaml: string }) => api.createCronJob(namespace, yaml),
    onSuccess: (r) => { toast.success(`Created ${r.name}`); invalidate(); onDone?.(r.name); },
    onError: fail,
  });
}

export function useUpdateSchedule(namespace: string, name: string, onDone?: () => void) {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: ({ schedule, timeZone }: { schedule: string; timeZone?: string }) =>
      api.updateSchedule(namespace, name, schedule, timeZone),
    onSuccess: () => { toast.success('Schedule updated'); invalidate(); onDone?.(); },
    onError: fail,
  });
}

export function useSuspend(namespace: string, name: string) {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (suspend: boolean) => api.setSuspend(namespace, name, suspend),
    onSuccess: (_d, suspend) => { toast.success(suspend ? 'Suspended' : 'Resumed'); invalidate(); },
    onError: fail,
  });
}

export function useUpdateEnv(namespace: string, name: string, onDone?: () => void) {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (change: EnvChange) => api.updateEnv(namespace, name, change),
    onSuccess: () => { toast.success('Environment updated'); invalidate(); onDone?.(); },
    onError: fail,
  });
}

export function useUpdateImage(namespace: string, name: string, onDone?: () => void) {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: ({ container, image }: { container: string; image: string }) => api.updateImage(namespace, name, container, image),
    onSuccess: () => { toast.success('Image updated — applies from the next run'); invalidate(); onDone?.(); },
    onError: fail,
  });
}

export function useDelete(namespace: string, name: string, onDone?: () => void) {
  const invalidate = useInvalidate();
  return useMutation({
    mutationFn: (force: boolean) => api.deleteCronJob(namespace, name, force),
    onSuccess: () => { toast.success(`Deleted ${name}`); invalidate(); onDone?.(); },
    onError: fail,
  });
}
