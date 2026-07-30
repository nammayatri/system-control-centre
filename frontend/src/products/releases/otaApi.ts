// OTA-inside-mobile-releases API (docs/OTA_MOBILE_RELEASE_INTEGRATION.md §5.4).
// The five SCC endpoints below own push tracking + composed release creation;
// everything else about releases (status, ramp/conclude/discard, dimensions,
// analytics) reuses the airborne-ota product's api functions directly.
import { useQuery } from '@tanstack/react-query';
import { apiClient } from '../../lib/api-client';

export interface OtaPushRow {
  id: string;
  appName: string;
  platform: string;
  airborneAppRef: string;
  env: string;
  status: 'DISPATCHED' | 'RUNNING' | 'BUNDLE_PUSHED' | 'FAILED';
  requestedBump: string;
  sourceRef: string;
  externalRunId?: number;
  runUrl?: string;
  commitSha?: string;
  finalVersion?: string;
  packageVersion?: number;
  resolvedVia?: 'tag' | 'baseline' | 'manual';
  error?: string;
  dispatchedBy: string;
  dispatchedAt: string;
  updatedAt: string;
}

export interface OtaLinkRow {
  linkId: string;
  airborneAppRef: string;
  airborneReleaseId: string;
  packageVersion: number;
  dimensions?: Record<string, unknown>;
  createdBy: string;
  createdAt: string;
  groupId: string;
  groupLabel?: string;
  sourceRef: string;
}

export interface OtaCapableApp {
  appName: string;
  platform: string;
  airborneAppRef: string;
  pushEligible: boolean;
  ineligibleReason?: string;
  /** Build replaced on the store — composer nudges version targeting. */
  superseded?: boolean;
  /** Reason the build's state (draft/building/discarded/failed) forbids
   *  creating pushes/releases. Operate verbs on ongoing releases stay live. */
  releaseBlocked?: string;
}

export interface OtaActivePush {
  groupId: string;
  dispatchedBy: string;
  dispatchedAt: string;
}

export interface OtaGroupResp {
  available: boolean;
  groupSourceRef?: string;
  activePush?: OtaActivePush;
  rows: OtaPushRow[];
  links: OtaLinkRow[];
  capableApps: OtaCapableApp[];
}

export interface OtaDispatchReq {
  versionBump: 'patch' | 'minor' | 'major';
  apps?: string[];
  platforms?: string[];
  notifySlack?: boolean;
  /** CI runner pool; omit falls back to "ios-debug". */
  runner?: string;
}

/** Runner pools declared by consumer-airborne-ota.yaml (choice options). */
export const OTA_RUNNER_POOLS = ['ios-debug', 'rasmalai-new'] as const;

export interface OtaReleaseReq {
  dimensions?: Record<string, unknown>;
  initialTrafficPercent?: number;
  config?: {
    bootTimeout?: number;
    releaseConfigTimeout?: number;
    properties?: Record<string, unknown>;
  };
  lazyFiles?: string[];
}

export interface OtaReleaseResp {
  released: boolean;
  ramped: boolean;
  airborneReleaseId: string;
  link: OtaLinkRow;
  firstRelease?: boolean;
}

// The 409 body of the create endpoint (SCC's own preflight — upstream only
// emits a generic 400 for this).
export interface OtaOngoingConflict {
  code: 'ONGOING_RELEASE_EXISTS';
  message: string;
  ongoing: Array<{
    airborneReleaseId: string;
    status: string;
    packageVersion?: number;
    trafficPercentage?: number;
    dimensions?: Record<string, unknown>;
    link?: OtaLinkRow;
  }>;
}

export async function fetchGroupOta(groupId: string): Promise<OtaGroupResp> {
  const { data } = await apiClient.get(`/mobile/groups/${encodeURIComponent(groupId)}/ota`);
  return data;
}

export async function dispatchGroupOta(
  groupId: string,
  body: OtaDispatchReq,
): Promise<{ dispatched: number; rows: OtaPushRow[] }> {
  const { data } = await apiClient.post(
    `/mobile/groups/${encodeURIComponent(groupId)}/ota/dispatch`,
    body,
  );
  return data;
}

export interface OtaRunStep {
  name: string;
  status: string; // queued | in_progress | completed
  conclusion?: string; // success | failure | cancelled | skipped …
  startedAt?: string;
  completedAt?: string;
}

export interface OtaRunJob {
  name: string;
  status: string; // queued | in_progress | completed
  conclusion?: string; // success | failure | cancelled | skipped …
  htmlUrl: string;
  startedAt?: string;
  completedAt?: string;
  steps: OtaRunStep[];
}

/** Live CI job matrix of a push's workflow run (proxied from GitHub). */
export async function fetchOtaPushJobs(pushId: string): Promise<{ jobs: OtaRunJob[] }> {
  const { data } = await apiClient.get(`/mobile/ota/pushes/${encodeURIComponent(pushId)}/jobs`);
  return data;
}

export async function releaseOtaPush(pushId: string, body: OtaReleaseReq): Promise<OtaReleaseResp> {
  const { data } = await apiClient.post(
    `/mobile/ota/pushes/${encodeURIComponent(pushId)}/release`,
    body,
  );
  return data;
}

export async function cancelOtaPush(pushId: string): Promise<OtaPushRow> {
  const { data } = await apiClient.post(`/mobile/ota/pushes/${encodeURIComponent(pushId)}/cancel`);
  return data;
}

export async function attachOtaPackage(pushId: string, packageVersion: number): Promise<OtaPushRow> {
  const { data } = await apiClient.post(
    `/mobile/ota/pushes/${encodeURIComponent(pushId)}/attach-package`,
    { packageVersion },
  );
  return data;
}

// Poll fast only while a push is in flight; the GET itself drives backend
// convergence (no server-side poller).
export function useGroupOta(groupId: string | undefined, enabled = true) {
  return useQuery({
    queryKey: ['mobile-group-ota', groupId],
    queryFn: () => fetchGroupOta(groupId!),
    enabled: !!groupId && enabled,
    retry: false,
    refetchInterval: (query) => (query.state.data?.activePush ? 15_000 : false),
  });
}

// ── Provenance (git-tag ledger, doc §11b) ───────────────────────────

export type OtaRelation = 'identical' | 'ahead' | 'behind' | 'diverged' | 'unknown';

export interface OtaProvAnchor {
  commitSha?: string;
  sourceRef?: string;
  resolvedVia: 'scc' | 'native-tag' | 'adopted' | 'none';
}

export interface OtaProvPkg {
  packageVersion: number;
  commitSha?: string;
  repoTag?: string;
  relation: OtaRelation;
  aheadBy?: number;
  behindBy?: number;
}

export interface OtaProvResp {
  anchor: OtaProvAnchor;
  packages: OtaProvPkg[];
}

export async function resolveOtaProvenance(
  groupId: string,
  airborneAppRef: string,
  packages: Array<{ version: number; tag?: string }>,
): Promise<OtaProvResp> {
  const { data } = await apiClient.post(
    `/mobile/groups/${encodeURIComponent(groupId)}/ota/provenance`,
    { airborneAppRef, packages },
  );
  return data;
}

export async function adoptOtaBranch(
  groupId: string,
  airborneAppRef: string,
  branch: string,
  acknowledgeMismatch = false,
): Promise<OtaProvAnchor> {
  const { data } = await apiClient.post(
    `/mobile/groups/${encodeURIComponent(groupId)}/ota/adopt-branch`,
    { airborneAppRef, branch, acknowledgeMismatch },
  );
  return data;
}

// ── Build-level provenance (release-scoped — works without OTA/groups) ──

export interface ReleaseProvResp extends OtaProvAnchor {
  /** Previous build's tag from the ledger — the changelog base for store-sync
   *  rows (prev-tag → this-tag = "what shipped in this build"). */
  previousTag?: string;
}

/** Resolve (and server-side backfill) the anchor commit for one mobile build. */
export async function fetchReleaseProvenance(releaseId: string): Promise<ReleaseProvResp> {
  const { data } = await apiClient.get(`/mobile/releases/${encodeURIComponent(releaseId)}/provenance`);
  return data;
}

export async function adoptReleaseBranch(
  releaseId: string,
  branch: string,
  acknowledgeMismatch = false,
): Promise<OtaProvAnchor> {
  const { data } = await apiClient.post(`/mobile/releases/${encodeURIComponent(releaseId)}/adopt-branch`, {
    branch,
    acknowledgeMismatch,
  });
  return data;
}

// Package-born release (no push row) — lineage-gated server-side.
export interface OtaPackageReleaseReq extends OtaReleaseReq {
  airborneAppRef: string;
  packageVersion: number;
  packageTag?: string;
}

export async function releaseOtaPackage(
  groupId: string,
  body: OtaPackageReleaseReq,
): Promise<OtaReleaseResp> {
  const { data } = await apiClient.post(
    `/mobile/groups/${encodeURIComponent(groupId)}/ota/release`,
    body,
  );
  return data;
}

// 409 body when the picked branch does not contain the build commit.
export interface OtaBranchMismatch {
  code: 'BRANCH_NOT_CONTAINING';
  message: string;
  relation: string;
  aheadBy?: number;
  behindBy?: number;
}

// Verdicts are immutable (sha pairs), so cache aggressively client-side too.
export function useOtaProvenance(
  groupId: string | undefined,
  airborneAppRef: string,
  packages: Array<{ version: number; tag?: string }>,
  enabled = true,
) {
  const versionsKey = packages.map((p) => p.version).sort((a, b) => a - b).join(',');
  return useQuery({
    queryKey: ['mobile-ota-prov', groupId, airborneAppRef, versionsKey],
    queryFn: () => resolveOtaProvenance(groupId!, airborneAppRef, packages),
    enabled: !!groupId && enabled && packages.length > 0,
    retry: false,
    staleTime: 5 * 60_000,
  });
}
