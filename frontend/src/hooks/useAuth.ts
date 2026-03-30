import { useMutation, useQuery } from '@tanstack/react-query';
import { login, getProfile } from '../services/auth';

export function useLogin() {
  return useMutation({
    mutationFn: ({ email, password }: { email: string; password: string }) =>
      login(email, password),
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
