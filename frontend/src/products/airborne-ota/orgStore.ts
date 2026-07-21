import { useSyncExternalStore } from 'react';

// Selected airborne organisation, shared between the sidebar (outside the
// ThemeWrapper) and the pages (inside) — hence a module store, not context.
const STORAGE_KEY = 'ota_org';

let org: string = (() => {
  try {
    return localStorage.getItem(STORAGE_KEY) ?? '';
  } catch {
    return '';
  }
})();

const listeners = new Set<() => void>();

export function setOtaOrg(value: string) {
  if (value === org) return;
  org = value;
  try {
    localStorage.setItem(STORAGE_KEY, value);
  } catch {
    /* ignore */
  }
  listeners.forEach((l) => l());
}

export function useOtaOrg(): string {
  return useSyncExternalStore(
    (cb) => {
      listeners.add(cb);
      return () => listeners.delete(cb);
    },
    () => org,
  );
}

// Stored org if still available, else the first known org.
export function resolveOrg(stored: string, available: string[]): string {
  if (stored && available.includes(stored)) return stored;
  return available[0] ?? '';
}
