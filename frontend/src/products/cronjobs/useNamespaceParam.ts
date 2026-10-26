import { useEffect } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useNamespaces } from './hooks';

/** The selected namespace, kept in the URL; defaults to the first one configured. */
export function useNamespaceParam(): { namespace: string; setNamespace: (n: string) => void; namespaces: string[]; loading: boolean } {
  const [params, setParams] = useSearchParams();
  const { data: namespaces = [], isLoading } = useNamespaces();
  const fromUrl = params.get('namespace') ?? '';
  const namespace = fromUrl || namespaces[0] || '';
  useEffect(() => {
    if (!fromUrl && namespaces[0]) setParams({ namespace: namespaces[0] }, { replace: true });
  }, [fromUrl, namespaces, setParams]);
  return { namespace, setNamespace: (n) => setParams({ namespace: n }), namespaces, loading: isLoading };
}
