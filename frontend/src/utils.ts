import axios from 'axios';

declare global {
  interface Window {
    __ENV__?: Record<string, string>;
  }
}

export const API_BASE_URL = window.__ENV__?.VITE_API_BASE_URL || import.meta.env.VITE_API_BASE_URL || 'http://localhost:8012';
export const AUTH_BASE = window.__ENV__?.VITE_AUTH_API_BASE_URL || import.meta.env.VITE_AUTH_API_BASE_URL || API_BASE_URL.replace(/\/api\/?$/, '');

export const apiClient = axios.create({
  baseURL: API_BASE_URL,
  withCredentials: true,
  headers: { 'Content-Type': 'application/json' },
});

export const authClient = axios.create({
  baseURL: AUTH_BASE,
  withCredentials: true,
  headers: { 'Content-Type': 'application/json' },
});

