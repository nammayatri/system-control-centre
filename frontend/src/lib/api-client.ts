/**
 * Axios client with auth token injection and 401 handling.
 * All API calls throughout the app should use this client.
 */

import axios from 'axios';
import { API_BASE_URL, AUTH_BASE, TOKEN_KEY } from './constants';

export const apiClient = axios.create({
  baseURL: API_BASE_URL,
  headers: { 'Content-Type': 'application/json' },
});

export const authClient = axios.create({
  baseURL: AUTH_BASE,
  headers: { 'Content-Type': 'application/json' },
});

// Inject auth token into every request
apiClient.interceptors.request.use((config) => {
  const token = localStorage.getItem(TOKEN_KEY);
  if (token) {
    config.headers.Authorization = `Bearer ${token}`;
  }
  return config;
});

// Handle 401 — clear ALL auth state + redirect to login.
// Round 8 audit H3: previously only sc_token was cleared, leaving stale
// auth_user / auth_products in localStorage AND react-query cache full of
// the previous user's data. On a multi-user laptop the next user could see
// the previous user's release list / configmap data until a hard refresh.
apiClient.interceptors.response.use(
  (response) => response,
  (error) => {
    if (error.response?.status === 401) {
      try {
        localStorage.removeItem(TOKEN_KEY);
        localStorage.removeItem('auth_user');
        localStorage.removeItem('auth_products');
        localStorage.removeItem('sc_user');
        localStorage.removeItem('sc_products');
      } catch {}
      if (window.location.pathname !== '/login') {
        // Preserve the intended destination so login can return there.
        const returnTo = encodeURIComponent(window.location.pathname + window.location.search);
        window.location.href = `/login?returnTo=${returnTo}`;
      }
    }
    return Promise.reject(error);
  }
);
