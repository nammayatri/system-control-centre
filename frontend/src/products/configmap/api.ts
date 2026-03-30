import { apiClient } from '../../lib/api-client';
import type { APConfigMap } from '../../api';
import { fetchAPConfigMaps, fetchConfigMapDetail, updateConfigMap, createConfigMap, fetchConfigMapNames, fetchConfigMapData } from '../../api';

export {
  fetchAPConfigMaps,
  fetchConfigMapDetail,
  updateConfigMap,
  createConfigMap,
  fetchConfigMapNames,
  fetchConfigMapData,
};

export type { APConfigMap };

export async function fetchSecondaryConfigMap(product: string, name: string): Promise<string> {
  const { data } = await apiClient.get('/configmap/secondary', { params: { PRODUCT: product, NAME: name } });
  return data?.configMap || '';
}
