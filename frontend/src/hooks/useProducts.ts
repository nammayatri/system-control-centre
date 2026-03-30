import { useQuery } from '@tanstack/react-query';
import { fetchProducts, fetchProductConfigs, fetchServices } from '../services/releases';

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

export function useServices(product: string, isNewService?: boolean) {
  return useQuery({
    queryKey: ['services', product, isNewService],
    queryFn: () => fetchServices(product, isNewService ?? false),
    enabled: !!product,
    staleTime: 120000,
  });
}
