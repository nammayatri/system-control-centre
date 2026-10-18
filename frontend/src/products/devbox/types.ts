// Devbox Releases — shapes returned by backend/src/Products/Devbox/Routes.hs.

export type DevboxStatus = 'QUEUED' | 'RUNNING' | 'READY' | 'FAILED' | 'STOPPING' | 'STOPPED';
export type DevboxStage = 'preparing' | 'sync' | 'build' | 'start' | 'data' | 'cc' | 'ready';
export type DataSource = 'master' | 'prod' | 'prod_international';
export type StatusFilter = 'all' | 'running' | 'in_progress' | 'stopped';

export interface DevboxRelease {
  id: string;
  workspace: string;
  status: DevboxStatus;
  stage: DevboxStage;
  currentAction: 'spawn' | 'stop';
  backendBranch: string;
  backendSha: string;
  ccBranch: string | null;
  ccSha: string | null;
  frontendBranch: string | null;
  frontendSha: string | null;
  buildAndroid: boolean;
  buildIos: boolean;
  dataSource: DataSource;
  dataVersion: string | null;
  devboxName: string | null;
  devboxHost: string | null;
  devboxUser: string | null;
  backendUrl: string | null;
  ccUrl: string | null;
  ghRunId: number | null;
  ghRunUrl: string | null;
  error: string | null;
  createdBy: string;
  stoppedBy: string | null;
  stopReason: 'user' | 'expired' | 'failed' | null;
  createdAt: string;
  updatedAt: string;
  readyAt: string | null;
  expiresAt: string;
  stoppedAt: string | null;
  /** App builds asked for, as 'app:platform' (rider:android, driver:ios, …). */
  appBuilds: string[];
}

export interface DevboxEvent {
  id: number;
  releaseId: string;
  stage: string;
  label: 'started' | 'done' | 'skipped' | 'failed' | 'info';
  payload: Record<string, unknown>;
  ghStepUrl: string | null;
  createdAt: string;
}

export interface DevboxBuild {
  id: number;
  releaseId: string;
  app: 'rider' | 'driver';
  platform: 'android' | 'ios';
  status: 'QUEUED' | 'RUNNING' | 'DONE' | 'FAILED' | 'CANCELLED';
  ghRunId: number | null;
  ghRunUrl: string | null;
  downloadUrl: string | null;
  buildNumber: string | null;
  error: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface FilterCounts {
  all: number;
  running: number;
  inProgress: number;
  stopped: number;
}

export interface ReleasesResp {
  releases: DevboxRelease[];
  total: number;
  counts: FilterCounts;
  page: number;
  count: number;
  /** The caller's active releases, and the limit (server config devbox_max_active_per_user). */
  mineActive: number;
  maxActive: number;
}

export interface BranchOption {
  name: string;
  sha: string;
}

export type BranchRepo = 'backend' | 'cc' | 'app';

export interface ReleaseDetailResp {
  release: DevboxRelease;
  events: DevboxEvent[];
  builds: DevboxBuild[];
  canStop: boolean;
}

export interface BranchStatusResp {
  branch: string;
  active: DevboxRelease | null;
}

export interface CreateReleaseReq {
  backendBranch: string;
  ccBranch?: string;
  frontendBranch?: string;
  buildAndroid: boolean;
  buildIos: boolean;
  dataSource: DataSource;
  dataVersion?: string;
  workspace?: string;
  appBuilds?: string[];
}

/** The app builds a release can ask for (ny-react-native debug workflows). */
export const APP_BUILDS: { key: string; label: string; where: string }[] = [
  { key: 'rider:android', label: 'Rider · Android', where: 'Firebase' },
  { key: 'driver:android', label: 'Driver · Android', where: 'Firebase' },
  { key: 'rider:ios', label: 'Rider · iOS', where: 'TestFlight' },
  { key: 'driver:ios', label: 'Driver · iOS', where: 'TestFlight' },
];

/** A release that still holds its workspace (and counts towards the 2-per-person limit). */
export const ACTIVE_STATUSES: DevboxStatus[] = ['QUEUED', 'RUNNING', 'READY', 'STOPPING'];

/** The stage dots, in order, with the GitHub step each one is. */
export const STAGES: { key: DevboxStage; label: string }[] = [
  { key: 'preparing', label: 'Preparing' },
  { key: 'sync', label: 'Sync' },
  { key: 'build', label: 'Build' },
  { key: 'start', label: 'Start' },
  { key: 'data', label: 'Data' },
  { key: 'cc', label: 'Control centre' },
  { key: 'ready', label: 'Ready' },
];
