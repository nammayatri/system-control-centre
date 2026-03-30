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

// Handle 401 — redirect to login
apiClient.interceptors.response.use(
  (response) => response,
  (error) => {
    if (error.response?.status === 401) {
      localStorage.removeItem(TOKEN_KEY);
      if (window.location.pathname !== '/login') {
        window.location.href = '/login';
      }
    }
    return Promise.reject(error);
  }
);
