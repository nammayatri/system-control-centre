// Wire types for the capacity scaler API (backend: Products.Autopilot.Scaler.*).
// Schedule timing and the apply state machine are shared with the HPA scheduler.
import type { ApplyEvent, ApplyStatus, ScheduleKind } from '../hpa/types';

export type { ApplyEvent, ApplyStatus, ScheduleKind };

/** REDIS: a Memorystore for Valkey instance. DB: an AlloyDB read pool. */
export type TargetKind = 'REDIS' | 'DB';

/** CLUSTER scales by shards, CLUSTER_DISABLED (standalone) by replicas, READ_POOL by nodes. */
export type InstanceMode = 'CLUSTER' | 'CLUSTER_DISABLED' | 'READ_POOL';

export interface Target {
  id: string;
  kind: TargetKind;
  name: string;
  project: string;
  location: string;
  /** The AlloyDB cluster; null for Valkey. */
  parent: string | null;
  /** The Memorystore instance id or the AlloyDB read-pool instance id. */
  resource: string;
  autoscalerJob: string | null;
  autoscalerLocation: string | null;
}

export interface InstanceState { mode: InstanceMode; state: string; units: number; replicas: number }

export interface ScaleChange {
  units?: number;
  replicas?: number;
  blockScaleIn: boolean;
  shrinkOnEnd: boolean;
}

export interface Guardrail {
  maxUnits: number | null;
  maxReplicas: number | null;
  maxStep: number | null;
  frozen: boolean;
  frozenReason: string | null;
}

export interface TargetRow {
  target: Target;
  state: InstanceState | null;
  cloudError: string | null;
  schedules: number;
  activeSchedules: number;
  windowOpen: boolean;
  inflight: { id: string; status: ApplyStatus }[];
}

export interface ScheduleWindow { windowOpen: boolean; nextStart: string | null; error?: string }

export interface Schedule {
  id: string; targetKind: TargetKind; targetId: string; name: string;
  status: 'ACTIVE' | 'PAUSED' | 'EXPIRED';
  timing: ScheduleKind; change: ScaleChange;
  createdBy: string; createdAt: string; updatedAt: string;
  window: ScheduleWindow;
  applies?: Apply[];
}

export interface ScaleSnapshot { units: number; replicas: number; minimum: number | null }
export interface ScaleAfter {
  targetUnits: number | null; targetReplicas: number | null;
  pinIntent: number | null; pinned: number | null; operation: string | null; shrinkDeadline: string | null;
}

export interface Apply {
  id: string; scheduleId: string | null; trigger: 'SCHEDULED' | 'MANUAL';
  targetKind: TargetKind; targetId: string;
  status: ApplyStatus; step: string | null;
  change: ScaleChange;
  beforeSpec: ScaleSnapshot | null; afterSpec: ScaleAfter | null;
  windowStart: string | null; windowEnd: string | null;
  attempt: number; deferCount: number;
  claimedBy: string | null; observeUntil: string | null;
  rollbackReason: string | null; error: string | null;
  createdBy: string; createdAt: string; updatedAt: string; finishedAt: string | null;
}

export interface AutoscalerSummary { configured: boolean; ok?: boolean; error?: string; state?: string; heldBy?: string | null }

export interface TargetDetail {
  target: Target;
  state: InstanceState | null;
  cloudError: string | null;
  guardrail: Guardrail;
  schedules: Schedule[];
  applies: Apply[];
  events: ApplyEvent[];
  autoscaler: AutoscalerSummary;
}

export interface Preview {
  state: InstanceState;
  valid: boolean;
  issues: string[];
  plan: { units: number | null; replicas: number | null; noop: boolean; summary: string } | null;
  refusedBecause: string[];
  autoscaler: null | { ok: boolean; error?: string; minimum?: number; wouldPin?: boolean; jobState?: string };
  overlaps: string[];
}

export interface DiscoverItem { cluster: string | null; resource: string; state: InstanceState; registered: boolean }

export type KeyKind = { type: 'int'; min: number; max: number } | { type: 'enum'; options: string[] };

/** One autoscaler config entry: settings plus the scaling rules. Only whitelisted keys are editable. */
export type AutoscalerEntry = Record<string, unknown> & { scalingRules?: ScalingRule[] };

export interface ScalingCondition { fact: string; operator: string; value: number }
export interface ScalingRule {
  name: string;
  conditions: { any?: ScalingCondition[]; all?: ScalingCondition[] };
  event: { type: 'OUT' | 'IN'; params?: Record<string, unknown> };
}

export interface HistoryItem {
  id: number; ts: string; actor: string; action: 'EDIT' | 'REVERT' | 'PAUSE' | 'RESUME'; note: string | null;
  before: AutoscalerEntry | null; after: AutoscalerEntry | null;
}

export interface AutoscalerView {
  ok: boolean;
  error?: string;
  job?: string; jobLocation?: string; state?: string; schedule?: string;
  /** The payload as read; sent back with an edit so a change in between is detected. */
  data?: string;
  entry?: AutoscalerEntry;
  editable?: { key: string; kind: KeyKind }[];
  heldBy?: string | null;
  history: HistoryItem[];
}
