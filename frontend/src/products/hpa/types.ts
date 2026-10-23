// Wire types for the HPA scheduler API (backend: Products.Autopilot.Hpa.*).

export type ApplyStatus =
  | 'PENDING' | 'APPLYING' | 'OBSERVING' | 'APPLIED' | 'RESTORING' | 'RESTORED'
  | 'ROLLING_BACK' | 'ROLLED_BACK' | 'FAILED' | 'NEEDS_ATTENTION' | 'SKIPPED';

export const TERMINAL_APPLY: ApplyStatus[] = ['RESTORED', 'ROLLED_BACK', 'FAILED', 'SKIPPED'];

export type HpaRole = 'SERVING' | 'DRAINING' | 'UNROUTED' | 'UNKNOWN';

export type MetricTarget =
  | { type: 'Utilization'; averageUtilization: number }
  | { type: 'AverageValue'; averageValue: string }
  | { type: 'Value'; value: string };

export interface MetricTargetChange { key: string; target: MetricTarget }

export interface ScalingPolicy { type: 'Pods' | 'Percent'; value: number; periodSeconds: number }
export interface ScalingRules {
  stabilizationWindowSeconds?: number;
  selectPolicy?: 'Max' | 'Min' | 'Disabled';
  policies?: ScalingPolicy[];
}

export interface HpaChange {
  minReplicas?: number;
  maxReplicas?: number;
  metricTargets?: MetricTargetChange[];
  scaleUp?: ScalingRules;
  scaleDown?: ScalingRules;
}

export type ScheduleKind =
  | { kind: 'ONCE'; startAt: string; endAt?: string | null }
  | { kind: 'WEEKLY'; days: number[]; startTime: string; durationMinutes: number; utcOffsetMinutes: number };

export interface PromCheck { name: string; query: string; op: 'GT' | 'LT'; threshold: number }

export interface HealthPolicy {
  autoRollback: boolean;
  observeSeconds: number;
  maxUnavailablePct: number;
  graceSeconds: number;
  rollbackOnScalingInactive: boolean;
  promChecks: PromCheck[];
}

export const DEFAULT_HEALTH_POLICY: HealthPolicy = {
  autoRollback: true,
  observeSeconds: 300,
  maxUnavailablePct: 50,
  graceSeconds: 180,
  rollbackOnScalingInactive: true,
  promChecks: [],
};

export interface Guardrail {
  maxReplicasCap: number | null;
  minReplicasFloor: number | null;
  maxStepPct: number | null;
  frozen: boolean;
  frozenReason: string | null;
}

export interface HpaSpec {
  scaleTargetRef: { kind: string; name: string };
  minReplicas: number;
  maxReplicas: number;
  metrics: any[];
  behavior?: { scaleUp?: ScalingRules; scaleDown?: ScalingRules };
}

export interface HpaStatus {
  currentReplicas: number;
  desiredReplicas: number;
  lastScaleTime: string | null;
  conditions: { type: string; status: string; reason?: string | null; message?: string | null }[];
}

export interface ResolvedHpa {
  name: string;
  namespace: string;
  version: string;
  trafficWeight: number | null;
  role: HpaRole;
  editable: boolean;
  notEditableReason: string | null;
  spec: HpaSpec;
  status: HpaStatus;
  metricSummary: string[];
  cpuUtilization: number | null;
  memoryUtilization: number | null;
  validationIssues: string[];
  annotations: Record<string, string>;
  resourceVersion: string;
}

export interface Resolution {
  hpas: ResolvedHpa[];
  serving: string[];
  reason: string;
  multipleHpas: boolean;
  warnings: string[];
}

export interface OverviewServing {
  name: string; version: string; role: HpaRole;
  minReplicas: number; maxReplicas: number; currentReplicas: number; desiredReplicas: number;
  metrics: string[]; editable: boolean; notEditableReason: string | null;
}

export interface OverviewService {
  service: string; host: string; hpaCount: number;
  serving: OverviewServing[]; reason: string; warnings: string[];
  schedules: number; activeSchedules: number; windowOpen: boolean; nextWindowStart: string | null;
  inflight: { id: string; status: ApplyStatus; hpaName: string }[];
  watched: boolean; frozen: boolean;
}

export interface Overview {
  product: string; namespace: string; clusterError: string | null; services: OverviewService[];
}

export interface ScheduleTiming {
  windowOpen: boolean;
  currentWindow: { start: string; end: string | null } | null;
  nextStart: string | null;
  error?: string;
}

export interface Schedule {
  id: string; appGroup: string; service: string; name: string;
  status: 'ACTIVE' | 'PAUSED' | 'EXPIRED';
  kind: ScheduleKind; change: HpaChange; healthPolicy: HealthPolicy;
  createdBy: string; createdAt: string; updatedAt: string;
  timing: ScheduleTiming;
  applies?: Apply[];
}

export interface Apply {
  id: string; scheduleId: string | null; trigger: 'SCHEDULED' | 'MANUAL';
  appGroup: string; service: string; namespace: string; hpaName: string;
  status: ApplyStatus; step: string | null;
  change: HpaChange; healthPolicy: HealthPolicy;
  beforeSpec: HpaSpec | null; afterSpec: HpaSpec | null;
  windowStart: string | null; windowEnd: string | null;
  attempt: number; deferCount: number;
  claimedBy: string | null; observeUntil: string | null; unhealthySince: string | null;
  rollbackReason: string | null; error: string | null;
  createdBy: string; createdAt: string; updatedAt: string; finishedAt: string | null;
}

export interface ApplyEvent {
  id: number; applyId: string | null; scheduleId: string | null;
  ts: string; kind: string; message: string; data: any;
}

export interface ServiceDetail {
  product: string; service: string; host: string; namespace: string;
  baseline: { minReplicas: number; maxReplicas: number };
  resolution: Resolution;
  guardrail: Guardrail;
  schedules: Schedule[];
  applies: Apply[];
  watched: boolean;
}

export interface SeriesPoint {
  ts: string; hpaName: string; min: number | null; max: number | null; current: number | null; desired: number | null;
  cpuPct: number | null; memoryPct: number | null;
}
/** `none`: no metrics endpoint configured here; `error`: the endpoint failed; `prometheus`: history returned. Nothing is stored by this app. */
export interface Series { from: string; to: string; bucketSeconds: number; source: 'none' | 'error' | 'prometheus'; note?: string; points: SeriesPoint[] }

export interface ScaleEvent {
  uid: string; hpaName: string; type: string | null; reason: string; message: string;
  newSize: number | null; count: number; firstTs: string; lastTs: string;
}

export interface DiffEntry { path: string; old: any; new: any }
export interface Snapshot {
  id: number; hpaName: string; ts: string; spec: HpaSpec; source: 'OBSERVED' | 'APPLY' | 'RESTORE' | 'ROLLBACK' | 'BEFORE';
  managedBy: string | null; applyId: string | null; resourceVersion: string | null;
  diff: DiffEntry[]; previousSnapshot: number | null;
}

export interface TargetPreview {
  hpa: string; version: string; role: HpaRole; notEditableReason: string | null;
  before: HpaSpec; after: HpaSpec | null;
  errors: string[]; guardrailIssues: string[]; noop: boolean; diff: DiffEntry[];
}

export interface Preview {
  targets: TargetPreview[]; blocking: string[]; warnings: string[]; reason: string;
  timing: null | { problems: string[]; windowOpenNow: boolean; nextStarts: string[]; overlaps: string[] };
}
