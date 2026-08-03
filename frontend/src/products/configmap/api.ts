import { apiClient } from '../../lib/api-client';
import type { APConfigMap, ConfigReviewVerdict, ConfigReviewResp } from '../releases/api';
import { fetchAPConfigMaps, fetchConfigMapDetail, updateConfigMap, createConfigMap, fetchConfigMapNames, fetchConfigMapData } from '../releases/api';

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

export type { ConfigReviewVerdict, ConfigReviewResp };

export async function fetchConfigReview(id: string): Promise<ConfigReviewResp> {
  const { data } = await apiClient.get(`/tracker/configmap/${encodeURIComponent(id)}/ai/review`);
  return data;
}

export async function runConfigReview(id: string, force = false): Promise<ConfigReviewResp> {
  const { data } = await apiClient.post(`/tracker/configmap/${encodeURIComponent(id)}/ai/review`, { force });
  return data;
}

export async function acknowledgeConfigReview(id: string): Promise<any> {
  return updateConfigMap(id, { ack_ai_review: true });
}
