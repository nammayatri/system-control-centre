import { useEffect } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useProducts } from '../releases/useProducts';

/** The selected product (app group), kept in the URL; defaults to the first one the user can see. */
export function useProductParam(): { product: string; setProduct: (p: string) => void; products: string[]; loading: boolean } {
  const [params, setParams] = useSearchParams();
  const { data: products = [], isLoading } = useProducts();
  const fromUrl = params.get('product') ?? '';
  const product = fromUrl || products[0] || '';
  useEffect(() => {
    if (!fromUrl && products[0]) setParams({ product: products[0] }, { replace: true });
  }, [fromUrl, products, setParams]);
  return { product, setProduct: (p) => setParams({ product: p }), products, loading: isLoading };
}
