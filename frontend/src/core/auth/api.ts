import { apiClient } from '../../lib/api-client';

export interface AuthUser {
  id: string;
  email: string;
  firstName?: string;
  lastName?: string;
  name?: string;
  isSuperadmin?: boolean;
  status?: string;
}

export interface ProductAccess {
  slug: string;
  role: string;
  roleId?: string;
  permissions: string[];
}

export interface AppConfig {
  env: string;
}

export interface LoginResponse {
  token: string;
  person: AuthUser;
  products: ProductAccess[];
  config?: AppConfig;
}

export async function login(email: string, password: string): Promise<LoginResponse> {
  const { data } = await apiClient.post('/auth/login', { email, password });
  if (data.person && !data.person.name) {
    data.person.name = [data.person.firstName, data.person.lastName].filter(Boolean).join(' ');
  }
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
  if (data.person && !data.person.name) {
    data.person.name = [data.person.firstName, data.person.lastName].filter(Boolean).join(' ');
  }
  return data;
}

// ─── Admin: Users ────────────────────────────────────────────────

export async function fetchUsers(): Promise<any[]> {
  const { data } = await apiClient.get('/admin/users');
  return Array.isArray(data) ? data : data.users || [];
}

export async function fetchUser(id: string): Promise<any> {
  const { data } = await apiClient.get(`/admin/users/${id}`);
  return data;
}

export async function createUser(payload: {
  email: string;
  firstName: string;
  lastName: string;
  password: string;
  isSuperadmin?: boolean;
}): Promise<any> {
  const { data } = await apiClient.post('/admin/users', payload);
  return data;
}

export async function updateUser(
  id: string,
  payload: { firstName?: string; lastName?: string; isActive?: boolean; isSuperadmin?: boolean }
): Promise<any> {
  const { data } = await apiClient.put(`/admin/users/${id}`, payload);
  return data;
}

export async function deactivateUser(id: string): Promise<any> {
  const { data } = await apiClient.delete(`/admin/users/${id}`);
  return data;
}

// ─── Admin: User Product Access ──────────────────────────────────

export async function assignRole(
  userId: string,
  payload: { productSlug: string; roleId: string }
): Promise<any> {
  const { data } = await apiClient.post(`/admin/users/${userId}/assign-role`, payload);
  return data;
}

export async function revokeProductAccess(userId: string, productSlug: string): Promise<any> {
  const { data } = await apiClient.delete(`/admin/users/${userId}/product-access/${productSlug}`);
  return data;
}


export async function assignDeploymentRole(
  userId: string,
  payload: { productSlug: string; appGroup: string; roleId: string }
): Promise<any> {
  const { data } = await apiClient.post(`/admin/users/${userId}/assign-deployment-role`, payload);
  return data;
}

export async function revokeDeploymentAccess(
  userId: string,
  productSlug: string,
  appGroup: string
): Promise<any> {
  const { data } = await apiClient.delete(
    `/admin/users/${userId}/deployment-access/${productSlug}/${appGroup}`
  );
  return data;
}

// ─── Admin: Permission Overrides ─────────────────────────────────

export async function addPermissionOverride(
  userId: string,
  payload: { productSlug: string; permissionAction: string; overrideType: 'GRANT' | 'DENY' }
): Promise<any> {
  const { data } = await apiClient.post(`/admin/users/${userId}/permission-override`, payload);
  return data;
}

export async function removePermissionOverride(userId: string, overrideId: string): Promise<any> {
  const { data } = await apiClient.delete(`/admin/users/${userId}/permission-override/${overrideId}`);
  return data;
}

// ─── Admin: Products & Permissions ───────────────────────────────

export async function fetchAdminProducts(): Promise<any[]> {
  const { data } = await apiClient.get('/admin/products');
  return Array.isArray(data) ? data : data.products || [];
}

export async function fetchProductPermissions(slug: string): Promise<string[]> {
  const { data } = await apiClient.get(`/admin/products/${slug}/permissions`);
  return Array.isArray(data) ? data : data.permissions || [];
}

export async function fetchProductRoles(slug: string): Promise<any[]> {
  const { data } = await apiClient.get(`/admin/products/${slug}/roles`);
  return Array.isArray(data) ? data : data.roles || [];
}

// ─── Admin: Roles ────────────────────────────────────────────────

export async function createRole(
  productSlug: string,
  payload: { name: string; description?: string; permissions: string[] }
): Promise<any> {
  const { data } = await apiClient.post(`/admin/products/${productSlug}/roles`, payload);
  return data;
}

export async function updateRole(
  productSlug: string,
  roleId: string,
  payload: { description?: string; permissions: string[] }
): Promise<any> {
  const { data } = await apiClient.put(`/admin/products/${productSlug}/roles/${roleId}`, payload);
  return data;
}
