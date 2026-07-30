// Airborne OTA types. Upstream (airborne) payloads are proxied verbatim by the
// SCC backend, so release/package/file shapes are typed tolerantly: known
// fields optional + an index-signature escape hatch.

// ── Access (live airborne app list, no local mapping) ──────────────

export interface OtaAccessApp {
  appRef: string;        // composite id "<org>~<app>" — the URL :app segment
  org: string;
  app: string;
  permissions: string[]; // caller's effective OTA_* set for this app
}

export interface OtaAccessResp {
  apps: OtaAccessApp[];
  upstreamReachable: boolean;
}

export interface OtaHealthResp {
  // never throws upstream — status names the cause instead.
  // ok | degraded (host up, authenticated path broken) | down | not-configured
  status: 'ok' | 'degraded' | 'down' | 'not-configured' | string;
  configured?: boolean;
  upstream?: unknown;
  upstreamError?: string | null;
  // Deep probe (/api/users): PAT + Keycloak + airborne DB. The cheap ping is a
  // static 200 upstream, so this is the only real availability signal.
  deep?: { checked?: boolean; ok?: boolean; error?: string | null };
  // Folded-in probe of the separate analytics host (Phase 4). configured=false
  // means analytics isn't wired in this env — not an alarm.
  analytics?: { configured?: boolean; ok?: boolean };
  // Last daily PAT re-issue. "unknown" = no tick yet in the serving process.
  keepalive?: { state?: 'ok' | 'failed' | 'unknown'; at?: string; error?: string | null };
  [key: string]: unknown;
}

// ── Releases (airborne-shaped, tolerant) ───────────────────────────

// experiment.status values (airborne serializes lowercase — compare uppercased).
export type OtaReleaseStatus = 'CREATED' | 'INPROGRESS' | 'CONCLUDED' | 'DISCARDED';

// Variants are plain variant-id strings upstream, not objects.
export interface OtaExperiment {
  experiment_id?: string;
  experiment_variants?: {
    control?: string;
    experimentals?: string[];
  };
  package_version?: number;
  config_version?: string;
  created_at?: string;
  traffic_percentage?: number;
  status?: string;
  [k: string]: unknown;
}

export interface OtaReleaseConfig {
  boot_timeout?: number;
  release_config_timeout?: number;
  properties?: Record<string, unknown>;
  [key: string]: unknown;
}

export interface OtaRelease {
  id?: string;
  created_at?: string;
  experiment?: OtaExperiment;
  package?: { name?: string; version?: number | string; tag?: string; [k: string]: unknown };
  config?: OtaReleaseConfig;
  // File keys ("<path>@version:<n>") or file objects, depending on upstream.
  resources?: unknown[];
  [key: string]: unknown;
}

export interface OtaReleaseDetail extends OtaRelease {}

// Airborne list envelope ({data, total_items, total_pages}).
export interface OtaListEnvelope<T> {
  data?: T[];
  total_items?: number;
  total_pages?: number;
  [key: string]: unknown;
}

// ── Packages / files (tolerant) ────────────────────────────────────

export interface OtaPackage {
  index?: string;
  tag?: string;
  version?: number;
  files?: string[];
  [key: string]: unknown;
}

export interface OtaFile {
  id?: string;
  file_path?: string;
  url?: string;
  version?: number | string;
  tag?: string;
  size?: number;
  checksum?: string;
  status?: string;
  created_at?: string;
  [key: string]: unknown;
}

export interface OtaFilesResp {
  files?: OtaFile[];
  total?: number;
  page?: number;
  per_page?: number;
  [key: string]: unknown;
}

// Files grouped by path (GET /files/groups). Upstream paginates by GROUP, so
// a group always carries its complete version history — this cannot be
// reconstructed by grouping the flat list client-side.
export interface OtaFileGroupVersion {
  version: number;
  url: string;
  size: number;
  checksum: string;
  created_at: string;
}

export interface OtaFileGroupTag {
  tag: string;
  version: number;
}

export interface OtaFileGroup {
  file_path: string;
  versions?: OtaFileGroupVersion[];
  tags?: OtaFileGroupTag[];
  total_versions?: number;
}

export interface OtaFileGroupsResp {
  groups?: OtaFileGroup[];
  total_items?: number;
  total_pages?: number;
}

// One chosen file VERSION. The airborne file chooser selects (path, version)
// pairs; the create APIs take the "<path>@version:<n>" key built from them.
export interface OtaSelectedFile {
  file_path: string;
  version: number;
  url?: string;
  tag?: string;
}

export interface OtaTagInfo {
  tag: string;
  count: number;
}

export interface OtaTagsResp {
  data?: OtaTagInfo[];
  total_items?: number;
  total_pages?: number;
}

// ── Requests ───────────────────────────────────────────────────────

export interface OtaRampReq {
  trafficPercentage: number;
  changeReason?: string;
  // Clobber guard: the traffic % that was actually on screen. The backend
  // re-reads upstream and 409s if it moved. Omit to skip the check.
  expectedTrafficPercentage?: number;
}

export interface OtaConcludeReq {
  chosenVariant: string;
  changeReason?: string;
}

// ── Create / update payloads (Phase 2) ─────────────────────────────

// Airborne CreateReleaseRequest — also the body for release update (PUT).
// package_id is "version:<n>" or "tag:<t>"; resources are file keys
// ("<file_path>@version:<n>" or "<file_path>@tag:<t>").
export interface OtaCreateReleaseReq {
  config: {
    boot_timeout: number;
    release_config_timeout: number;
    properties?: Record<string, unknown>;
  };
  package_id?: string;
  // Required: airborne 400s on package_id without a package block; important/lazy
  // are the release's file split (file keys; both empty ≠ all-important).
  package: {
    important: string[];
    lazy: string[];
    properties?: Record<string, unknown>;
    [key: string]: unknown;
  };
  dimensions?: Record<string, unknown>;
  resources?: string[];
  [key: string]: unknown;
}

// index + files are file keys.
export interface OtaCreatePackageReq {
  index: string;
  tag?: string;
  files: string[];
}

export interface OtaCreateFileReq {
  file_path: string;
  url: string;
  tag?: string;
  size?: number;
  checksum?: string;
  // Free-form JSON stored alongside the file (upstream FileRequest.metadata).
  metadata?: unknown;
}

// Resolved SDK config from /serve-config — opaque airborne Value.
export type OtaServeConfig = Record<string, unknown>;

// ── Targeting & config (Phase 3) ───────────────────────────────────

export interface OtaDimension {
  dimension: string;
  position: number;
  schema?: Record<string, unknown>;
  description?: string;
  change_reason?: string;
  mandatory?: boolean | null;
  dimension_type?: 'standard' | 'cohort';
  depends_on?: string | null;
  [key: string]: unknown;
}

export interface OtaCreateDimensionReq {
  dimension: string;
  description: string;
  // "schema" accepts only "string" upstream — omit and let the default apply.
  dimension_type?: 'standard' | 'cohort';
  depends_on?: string;
}

// PUT /dimensions/:dim — position is the only mutable field; change_reason is
// stamped server-side (client note optional).
export interface OtaUpdateDimensionReq {
  position: number;
  change_reason?: string;
}

// Cohort schema: enum lists cohort names in priority order (index 0 highest);
// "otherwise" is reserved and has no definitions entry. Groups are entries
// whose definition object has an "in" key; the rest are checkpoints.
export interface OtaCohortSchema {
  type?: string;
  enum?: string[];
  definitions?: Record<string, Record<string, unknown>>;
  [key: string]: unknown;
}

export type OtaCheckpointComparator = 'semver_gt' | 'semver_ge' | 'str_gt' | 'str_ge';

export interface OtaCheckpointReq {
  name: string;
  value: string;
  comparator: OtaCheckpointComparator;
}

export interface OtaGroupReq {
  name: string;
  members: string[];
}

// priority_map values are absolute indices into the FULL cohort enum.
export interface OtaCohortPriorityResp {
  priority_map?: Record<string, number>;
  [key: string]: unknown;
}

// Properties schema: flat dotted-key map of bare names (no config.properties.
// prefix on the wire). All three node fields are required on PUT.
export interface OtaPropertyNode {
  description: string;
  default_value: unknown;
  schema: Record<string, unknown>;
}

export interface OtaPropertiesSchemaResp {
  properties?: Record<string, OtaPropertyNode>;
  [key: string]: unknown;
}

export interface OtaPropertyExperiment {
  dimensions?: Record<string, unknown>;
  experiment_id?: string;
  status?: string; // Superposition status, or the synthetic literal "DEFAULT"
  properties?: Record<string, unknown>;
  [key: string]: unknown;
}

export interface OtaPropertiesListResp {
  properties?: OtaPropertyExperiment[];
  [key: string]: unknown;
}

// Release views: saved dimension filters ({key, value} pairs, duplicates allowed).
export interface OtaViewDimension {
  key: string;
  value: unknown;
}

export interface OtaReleaseView {
  id: string;
  name: string;
  dimensions?: OtaViewDimension[];
  created_at?: string;
  [key: string]: unknown;
}

export interface OtaViewsResp {
  data?: OtaReleaseView[];
  total_items?: number | null;
  total_pages?: number | null;
  [key: string]: unknown;
}

export interface OtaSaveViewReq {
  name: string;
  dimensions: OtaViewDimension[];
}

// ── Analytics (Phase 4) ────────────────────────────────────────────

// Every analytics endpoint wraps its payload as { success, data, timestamp }.
export interface OtaAnalyticsEnvelope<T> {
  success?: boolean;
  data?: T;
  timestamp?: string;
  [key: string]: unknown;
}

// One bucket of the adoption time series (all counts are u64 upstream).
export interface OtaAdoptionBucket {
  time_slot: string; // RFC3339 UTC
  download_success: number;
  download_failures: number;
  apply_success: number;
  apply_failures: number;
  rollbacks_initiated: number;
  rollbacks_completed: number;
  rollback_failures: number;
  update_checks: number;
  update_available: number;
  [key: string]: unknown;
}

export interface OtaAdoptionMetrics {
  org_id?: string;
  app_id?: string;
  release_id?: string;
  time_breakdown?: OtaAdoptionBucket[];
  [key: string]: unknown;
}

export interface OtaVersion {
  js_version: string;
  device_count: number;
  percentage: number;
}

// Upstream `data` is an array that ALWAYS holds exactly one element.
export interface OtaVersionDistribution {
  org_id?: string;
  app_id?: string;
  versions?: OtaVersion[];
  total_devices?: number;
  [key: string]: unknown;
}

export interface OtaActiveDay {
  date: string; // "YYYY-MM-DD"
  active_devices: number;
}

export interface OtaActiveDevices {
  daily_breakdown?: OtaActiveDay[];
  // MAX single-day unique devices over the window, NOT a period sum.
  total_active_devices?: number;
  [key: string]: unknown;
}

export interface OtaFailureError {
  error_code: string;
  count: number;
  percentage: number;
}

export interface OtaFailureMetrics {
  release_id?: string | null;
  total_failures?: number;
  // Degenerate upstream (100 if any failures else 0) — do not present as a rate.
  failure_rate?: number;
  common_errors?: OtaFailureError[];
  [key: string]: unknown;
}

// Averages over the window. Upstream currently stubs these to 0.
export interface OtaPerformanceMetrics {
  org_id?: string;
  app_id?: string;
  release_id?: string | null;
  avg_download_time_ms?: number;
  avg_apply_time_ms?: number;
  avg_download_size_bytes?: number;
  [key: string]: unknown;
}

// interval is auto-derived from range width (HOUR if ≤24h else DAY).
export type OtaAnalyticsInterval = 'HOUR' | 'DAY';

// ── App create (org-scoped, product-level OTA_APP_MANAGE) ──────────

export interface OtaCreateAppReq {
  org: string;
  app: string;
}

// ── Audit trail (SCC-side airborne_events) ─────────────────────────

// outcome: "unknown" covers an intent row (upstreamStatus 0) written when the
// upstream call threw mid-flight — the mutation may or may not have applied.
export interface OtaEvent {
  id: number;
  actor: string;
  org?: string | null;
  app?: string | null;
  action: string;
  endpoint: string;
  request?: unknown;
  upstreamStatus?: number | null;
  upstreamRequestId?: string | null;
  createdAt: string;
  outcome: 'ok' | 'failed' | 'unknown';
}

export interface OtaEventsResp {
  data?: OtaEvent[];
  total_items?: number;
  total_pages?: number;
  page?: number;
}

export interface OtaAdoptionParams {
  interval: OtaAnalyticsInterval;
  start_date: string; // epoch millis (string)
  end_date: string; // epoch millis (string)
  date: string; // epoch millis (string) — the single day for HOUR mode
  release_id?: string;
}
