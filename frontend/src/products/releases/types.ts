// ── Mobile release types ─────────────────────────────────────────
// Types for the mobile-release flow (React Native apps released via
// GitHub Actions). Backend release types still live in api.ts for
// historical reasons; this file is the home for new mobile-only types.

export type AppCatalogEntry = {
  id: number;
  name: string;
  surface: 'customer' | 'driver';
  platform: 'android' | 'ios';
  githubRepo: string;
  workflowPath: string;
  packageName: string | null;
  displayLabel: string | null;
  enabled: boolean;
  createdAt: string;
};

export type MobileDestination = 'GooglePlay' | 'Firebase';

export type CreateMobileReleasesItem = {
  appCatalogId: number;
  versionName: string | null;
  versionCode: number | null;
};

export type CreateMobileReleasesReq = {
  releaseGroupLabel?: string;
  changeLog: string;
  destination: MobileDestination;
  items: CreateMobileReleasesItem[];
};

export type CreateMobileReleasesResp = {
  releaseGroupId: string;
  releases: { id: string; appCatalogId: number; status: string }[];
};

export type DispatchInfo = {
  dispatchId: string;
  workflowPath: string;
  releaseIdsInDisp: string[];
  expectedRunUrl: string | null;
};

export type DispatchMobileReleasesResp = { dispatches: DispatchInfo[] };

export type VersionPreviewItem = {
  appCatalogId: number;
  nextVersionName?: string;
  nextVersionCode?: number;
  source?: string;
  err?: string;
};

export type LiveReleasesResp = {
  backend: {
    appGroup: string;
    service: string;
    env: string;
    liveVersion: string;
    rolloutState: string | null;
    updatedAt: string;
  }[];
  mobile: {
    app: string;
    surface: string;
    platform: string;
    liveVersion: string;
    versionCode: number | null;
    tagPushed: string | null;
    releasedAt: string;
  }[];
};
