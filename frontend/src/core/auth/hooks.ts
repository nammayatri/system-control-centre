import { useMutation, useQuery } from '@tanstack/react-query';
import { login, getProfile } from './api';

export function useLogin() {
  return useMutation({
    mutationFn: ({ email, password }: { email: string; password: string }) =>
      login(email, password),
    onError: (err: any) => {
      // LoginPage uses useAuth().login directly and handles errors itself,
      // but if this hook is ever used standalone, errors surface here.
      console.error('[useLogin]', err?.response?.data?.message || err.message);
    },
  });
}

export function useProfile() {
  return useQuery({
    queryKey: ['auth-profile'],
    queryFn: getProfile,
    retry: false,
    staleTime: 300000,
  });
}
