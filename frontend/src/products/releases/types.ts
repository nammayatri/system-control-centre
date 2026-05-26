// ── Mobile release types ─────────────────────────────────────────
// Types for the mobile-release flow (React Native apps released via
// GitHub Actions). Backend release types still live in api.ts for
// historical reasons; this file is the home for new mobile-only types.

export type LatestBuild = {
  version: string;
  versionCode?: number;
  destination?: string;
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
  debugWorkflowPath: string | null;
  packageName: string | null;
  displayLabel: string | null;
  firebaseProjectId: string | null;
  enabled: boolean;
  createdAt: string;
  latestReleaseBuild?: LatestBuild | null;
  latestDebugBuild?: LatestBuild | null;
};

// Mirror of the backend ADT. Android destinations on the left, iOS on the
// right — must stay in sync with `MobileDestination` in
// `backend/src/Products/Autopilot/Mobile/Types.hs`.
export type MobileDestination =
  | 'GooglePlay' // Android: Google Play production track.
  | 'Firebase' // Android: Firebase App Distribution.
  | 'TestFlight' // iOS: TestFlight beta channel.
  | 'AppStore'; // iOS: App Store (production).

export type BuildType = 'debug' | 'release';

/** Given a build type + platform, return the implied destination. */
export const destinationFor = (
  buildType: BuildType,
  platform: 'android' | 'ios',
): MobileDestination =>
  buildType === 'debug'
    ? platform === 'ios' ? 'TestFlight' : 'Firebase'
    : platform === 'ios' ? 'AppStore' : 'GooglePlay';

/** UI helper: which destinations are valid for a given platform. */
export const destinationsForPlatform = (
  platform: 'android' | 'ios',
): MobileDestination[] =>
  platform === 'ios' ? ['TestFlight', 'AppStore'] : ['GooglePlay', 'Firebase'];

export type CreateMobileReleasesItem = {
  appCatalogId: number;
  versionName: string | null;
  versionCode: number | null;
};

export type CreateMobileReleasesReq = {
  releaseGroupLabel?: string;
  changeLog: string;
  destination: MobileDestination;
  sourceRef?: string | null;
  items: CreateMobileReleasesItem[];
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
