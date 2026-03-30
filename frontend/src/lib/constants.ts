declare global {
  interface Window {
    __ENV__?: Record<string, string>;
  }
}

export const API_BASE_URL =
  window.__ENV__?.VITE_API_BASE_URL ||
  import.meta.env.VITE_API_BASE_URL ||
  'http://localhost:8012';

export const AUTH_BASE =
  window.__ENV__?.VITE_AUTH_API_BASE_URL ||
  import.meta.env.VITE_AUTH_API_BASE_URL ||
  API_BASE_URL.replace(/\/api\/?$/, '');

export const TOKEN_KEY = 'sc_token';
export const USER_KEY = 'sc_user';
export const PRODUCTS_KEY = 'sc_products';
