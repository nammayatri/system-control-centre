// ── Mobile release types ─────────────────────────────────────────
// Types for the mobile-release flow (React Native apps released via
// GitHub Actions). Backend release types still live in api.ts for
// historical reasons; this file is the home for new mobile-only types.

export type LatestBuild = {
  version: string;
  versionCode?: number;
  tagPushed?: string;
  commitSha?: string;
  completedAt: string;
};

export type AppCatalogEntry = {
  id: number;
  name: string;
  surface: 'customer' | 'driver';
  platform: 'android' | 'ios';
  githubRepo: string;
  workflowPath: string;
  packageName: string | null;
  displayLabel: string | null;
  firebaseProjectId: string | null;
  enabled: boolean;
  createdAt: string;
  latestReleaseBuild?: LatestBuild | null;
  latestDebugBuild?: LatestBuild | null;
};

// Build type is fixed per deployment env (master = debug, production =
// release) via the backend's mobile_build_type config flag. The frontend
// only reads it back for display (e.g. the DEBUG badge); it is never sent.
export type BuildType = 'debug' | 'release';

export type CreateMobileReleasesItem = {
  appCatalogId: number;
  versionName: string | null;
  versionCode: number | null;
};

// Store destination for provider (driver) PROD Android builds — mirrors the
// `destination` choice on provider-prod-apk-gen.yaml. Only sent when a
// provider + Android app is in a release build; ignored otherwise.
export type MobileDestination = 'GooglePlay' | 'Firebase';

export type CreateMobileReleasesReq = {
  releaseGroupLabel?: string;
  changeLog: string;
  sourceRef?: string | null;
  items: CreateMobileReleasesItem[];
  destination?: MobileDestination | null;
};

export type BranchInfo = {
  name: string;
  sha: string;
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

/**
 * One row in the `/mobile/versions/preview` response.
 *
 * Discriminated by which fields are set, matching the backend's per-platform
 * response shape:
 *
 *  - Android success: `nextVersionName` + `nextVersionCode` + `source = "play_console"`.
 *  - iOS success: `nextVersionNumber` + `source = "app_store_connect"`.
 *  - Error: `err` carries the stable tag from the resolver.
 */
export type VersionPreviewItem = {
  appCatalogId: number;
  // Android — two fields
  nextVersionName?: string;
  nextVersionCode?: number;
  // iOS — one field (build number is computed by the workflow itself)
  nextVersionNumber?: string;
  source?: string;
  err?: string;
};

export type CommitInfo = {
  ciSha: string;
  ciShortSha: string;
  ciMessage: string;
  ciSubject: string;
  ciAuthorLogin: string;
  ciHtmlUrl: string;
  ciPrNumber: number | null;
};

export type ChangelogPreviewResp = {
  cpCommits: CommitInfo[];
  cpAheadBy: number;
  cpStatus: string;
  cpBaseTag?: string | null;
  cpBaseVersion?: string | null;
  cpCompareUrl?: string | null;
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
