import { useCallback, useEffect, useSyncExternalStore } from 'react';
import { apiClient } from '../../lib/api-client';

// Pinned apps (app_catalog ids) + the Pinned / All scope.
// Pins persist per account via GET/PUT /mobile/me/pins; browser storage is an
// instant-paint cache so the first frame isn't empty. Scope stays per browser.

const PINS_KEY = 'mr2_pins';
const SCOPE_KEY = 'mr2_scope';
export type Scope = 'pinned' | 'all';

type Snapshot = { pins: Set<number>; scope: Scope; synced: boolean };
const listeners = new Set<() => void>();

function readLocal(): Snapshot {
  let pins: number[] = [];
  let scope: Scope = 'pinned';
  try {
    const raw = JSON.parse(localStorage.getItem(PINS_KEY) || '[]');
    if (Array.isArray(raw)) pins = raw.filter((x) => typeof x === 'number');
    if (localStorage.getItem(SCOPE_KEY) === 'all') scope = 'all';
  } catch {
    /* unavailable or corrupt → defaults */
  }
  return { pins: new Set(pins), scope, synced: false };
}

let snap = readLocal();
function set(next: Snapshot) {
  snap = next;
  try {
    localStorage.setItem(PINS_KEY, JSON.stringify([...next.pins]));
    localStorage.setItem(SCOPE_KEY, next.scope);
  } catch {
    /* ignore */
  }
  listeners.forEach((l) => l());
}
const subscribe = (l: () => void) => {
  listeners.add(l);
  return () => listeners.delete(l);
};

// Writes are serialized so a fast toggle sequence can't land out of order.
let saving: Promise<unknown> = Promise.resolve();
function save(pins: Set<number>) {
  saving = saving.then(() => apiClient.put('/mobile/me/pins', { appCatalogIds: [...pins] })).catch(() => {
    /* keep the local copy; the next change or load retries */
  });
}

let loading = false;
async function loadServer() {
  if (loading || snap.synced) return;
  loading = true;
  try {
    const { data } = await apiClient.get<{ appCatalogIds: number[] }>('/mobile/me/pins');
    const server = new Set(data.appCatalogIds);
    // First time on this account: carry over pins chosen in this browser.
    if (!server.size && snap.pins.size) {
      set({ ...snap, synced: true });
      save(snap.pins);
    } else {
      set({ ...snap, pins: server, synced: true });
    }
  } catch {
    /* offline / older backend → stay on the local copy */
  } finally {
    loading = false;
  }
}

export function usePins() {
  const s = useSyncExternalStore(subscribe, () => snap);
  useEffect(() => { void loadServer(); }, []);
  const write = useCallback((pins: Set<number>) => { set({ ...snap, pins }); save(pins); }, []);
  const toggle = useCallback((id: number) => {
    const pins = new Set(snap.pins);
    pins.has(id) ? pins.delete(id) : pins.add(id);
    write(pins);
  }, [write]);
  const clear = useCallback(() => write(new Set()), [write]);
  const setScope = useCallback((scope: Scope) => set({ ...snap, scope }), []);
  const inScope = useCallback((id: number | undefined) => s.scope === 'all' || (id != null && s.pins.has(id)), [s]);
  return { pins: s.pins, scope: s.scope, synced: s.synced, toggle, clear, setScope, inScope };
}
