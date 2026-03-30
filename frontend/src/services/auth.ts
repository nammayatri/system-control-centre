import { apiClient } from './api';

export interface AuthUser {
  id: string;
  email: string;
  name: string;
  status: string;
}

export interface ProductAccess {
  slug: string;
  role: string;
  permissions: string[];
}

export interface LoginResponse {
  token: string;
  person: AuthUser;
  products: ProductAccess[];
}

export async function login(email: string, password: string): Promise<LoginResponse> {
  const { data } = await apiClient.post('/auth/login', { email, password });
  return data;
}

export async function logout(): Promise<void> {
  try {
    await apiClient.post('/auth/logout');
  } catch {
    // ignore logout errors
  }
}

export async function getProfile(): Promise<LoginResponse> {
  const { data } = await apiClient.get('/auth/me');
  return data;
}

// Admin API calls
export async function fetchUsers(): Promise<any[]> {
  const { data } = await apiClient.get('/admin/users');
  return Array.isArray(data) ? data : data.users || [];
}

export async function fetchUser(id: string): Promise<any> {
  const { data } = await apiClient.get(`/admin/users/${id}`);
  return data;
}

export async function createUser(payload: any): Promise<any> {
  const { data } = await apiClient.post('/admin/users', payload);
  return data;
}

export async function updateUser(id: string, payload: any): Promise<any> {
  const { data } = await apiClient.put(`/admin/users/${id}`, payload);
  return data;
}

export async function deactivateUser(id: string): Promise<any> {
  const { data } = await apiClient.post(`/admin/users/${id}/deactivate`);
  return data;
}

export async function addProductAccess(userId: string, payload: { productSlug: string; roleId: string }): Promise<any> {
  const { data } = await apiClient.post(`/admin/users/${userId}/products`, payload);
  return data;
}

export async function removeProductAccess(userId: string, productSlug: string): Promise<any> {
  const { data } = await apiClient.delete(`/admin/users/${userId}/products/${productSlug}`);
  return data;
}

export async function addPermissionOverride(userId: string, payload: { productSlug: string; permission: string; type: 'GRANT' | 'DENY' }): Promise<any> {
  const { data } = await apiClient.post(`/admin/users/${userId}/permissions`, payload);
  return data;
}

export async function removePermissionOverride(userId: string, overrideId: string): Promise<any> {
  const { data } = await apiClient.delete(`/admin/users/${userId}/permissions/${overrideId}`);
  return data;
}

export async function fetchRoles(): Promise<any[]> {
  const { data } = await apiClient.get('/admin/roles');
  return Array.isArray(data) ? data : data.roles || [];
}

export async function fetchRole(id: string): Promise<any> {
  const { data } = await apiClient.get(`/admin/roles/${id}`);
  return data;
}

export async function updateRole(id: string, payload: any): Promise<any> {
  const { data } = await apiClient.put(`/admin/roles/${id}`, payload);
  return data;
}

export async function fetchAdminProducts(): Promise<any[]> {
  const { data } = await apiClient.get('/admin/products');
  return Array.isArray(data) ? data : data.products || [];
}
