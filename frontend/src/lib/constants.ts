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

// Deployment behaviour is keyed off useAuth().buildType ('debug' | 'release'),
// sourced from the mobile_build_type server_config (NOT the env label). The
// env label (useAuth().env) is cosmetic only — never branch on it. Changing a
// deployment's build type is a config update, no redeploy.

// Mirror of backend's Products.Autopilot.Types.Workflow.ReleaseCategory ADT.
// These strings are persisted in deployment_config.product_type and are the
// canonical wire format for the trackerType field in /releases/create.
export type ProductType = 'BackendService' | 'BackendScheduler' | 'BackendConfig' | 'VSEdit';

export const PRODUCT_TYPES: { value: ProductType; label: string }[] = [
  { value: 'BackendService', label: 'Backend Service' },
  { value: 'BackendScheduler', label: 'Backend Scheduler' },
  { value: 'BackendConfig', label: 'Backend Config' },
];

export const SERVICE_TYPES: { value: string; label: string }[] = [
  { value: 'SERVICE', label: 'Backend Service' },
  { value: 'SCHEDULER', label: 'Backend Scheduler' },
  { value: 'CUSTOM', label: 'Backend Config' },
];

// Map any legacy / shorthand product_type value to its canonical ADT name.
// Tolerates pre-rename data ('SERVICE', 'SCHEDULER') so old DB rows still
// resolve correctly until they're migrated.
export function normalizeProductType(raw: string | null | undefined): ProductType {
  const v = String(raw || '').trim();
  switch (v.toLowerCase()) {
    case 'backendscheduler':
    case 'scheduler':
      return 'BackendScheduler';
    case 'backendconfig':
    case 'config':
      return 'BackendConfig';
    case 'vsedit':
      return 'VSEdit';
    case 'backendservice':
    case 'service':
    case '':
    default:
      return 'BackendService';
  }
}
