import type { APRelease } from '../releases/api';

export interface ConfigReleaseItem {
  configType: string;
  version: number;
  patch: unknown | null;
}

export interface ConfigReleaseMeta {
  side: 'BAP' | 'BPP';
  merchantShortId: string;
  city: string;
  items: ConfigReleaseItem[];
  concluded: string[];
}

export function parseConfigReleaseMeta(release: APRelease): ConfigReleaseMeta {
  const m = (release.metadata ?? {}) as Record<string, any>;
  return {
    side: m.side === 'BAP' ? 'BAP' : 'BPP',
    merchantShortId: typeof m.merchantShortId === 'string' ? m.merchantShortId : '',
    city: typeof m.city === 'string' ? m.city : '',
    items: Array.isArray(m.items)
      ? m.items.filter((i: any) => i && typeof i.configType === 'string').map((i: any) => ({ configType: i.configType, version: Number(i.version), patch: i.patch ?? null }))
      : [],
    concluded: Array.isArray(m.concluded) ? m.concluded.filter((c: any) => typeof c === 'string') : [],
  };
}

export function currentRolloutPercent(release: APRelease): number {
  const h = release.rollout_history;
  if (h.length === 0) return 0;
  return h[h.length - 1].rollout;
}
