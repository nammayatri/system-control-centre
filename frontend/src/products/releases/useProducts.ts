import { useQuery } from '@tanstack/react-query';
import { fetchProducts, fetchProductConfigs, fetchServices } from './api';

export function useProducts() {
  return useQuery({
    queryKey: ['products'],
    queryFn: fetchProducts,
    staleTime: 300000, // 5 min
  });
}

export function useProductConfigs() {
  return useQuery({
    queryKey: ['product-configs'],
    queryFn: fetchProductConfigs,
    staleTime: 300000,
  });
}

export function useServices(appGroup: string, isNewService?: boolean) {
  return useQuery({
    queryKey: ['services', appGroup, isNewService],
    queryFn: () => fetchServices(appGroup, isNewService ?? false),
    enabled: !!appGroup,
    staleTime: 120000,
  });
}
