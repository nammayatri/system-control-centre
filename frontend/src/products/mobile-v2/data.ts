import { useMemo } from 'react';
import type { MobileGroupListItem, MobileGroupMemberLite, PlatformBlock } from '../releases/api';
import type { AppCatalogEntry } from '../releases/types';
import { useMobileApps, useMobileGroups, useStoreMonitor } from '../releases/hooks';
import type { Stage } from './model';
import { catalogFor, stageOfMember } from './model';

export type InFlight = { g: MobileGroupListItem; m: MobileGroupMemberLite; stage: Stage };
export type Live = { version: string | null; code: number | null; pct: number | null; paused: boolean };

const DONE: Stage[] = ['live', 'superseded', 'aborted', 'distributed'];

/** Catalog + store monitor + groups, joined per app (catalog id). */
export function useFleet() {
  const appsQ = useMobileApps();
  const groupsQ = useMobileGroups();
  const monitorQ = useStoreMonitor();
  const apps = appsQ.data ?? [];

  // Newest non-terminal build per app across all groups (groups come newest first).
  const inFlight = useMemo(() => {
    const out = new Map<number, InFlight>();
    for (const g of groupsQ.data?.groups ?? []) {
      for (const m of g.members) {
        const stage = stageOfMember(m);
        if (DONE.includes(stage)) continue;
        const id = catalogFor(apps, m.app, m.surface, m.platform)?.id;
        if (id != null && !out.has(id)) out.set(id, { g, m, stage });
      }
    }
    return out;
  }, [groupsQ.data, apps]);

  // Every build of an app, newest first — the app's history.
  const historyOf = (a: AppCatalogEntry) => {
    const rows: InFlight[] = [];
    for (const g of groupsQ.data?.groups ?? []) {
      for (const m of g.members) if (m.app === a.name && m.surface === a.surface && m.platform === a.platform) rows.push({ g, m, stage: stageOfMember(m) });
    }
    return rows;
  };

  const blockFor = (a: AppCatalogEntry): PlatformBlock | null => {
    for (const row of monitorQ.data?.apps ?? []) {
      const b = row.platforms[a.platform];
      if (b?.appCatalogId === a.id) return b;
    }
    return null;
  };

  /** What users have: store production track, falling back to the catalog's last prod build. */
  const liveOf = (a: AppCatalogEntry): Live => {
    const prod = blockFor(a)?.production;
    return {
      version: prod?.version ?? a.latestProdBuild?.version ?? null,
      code: prod?.buildCode ?? a.latestProdBuild?.versionCode ?? null,
      pct: prod?.rolloutPercent ?? null,
      paused: prod?.status === 'halted',
    };
  };

  return { apps, appsLoading: appsQ.isLoading, monitor: monitorQ.data, inFlight, historyOf, blockFor, liveOf };
}
