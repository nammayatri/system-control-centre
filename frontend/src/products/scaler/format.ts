import type { Variant } from '../hpa/format';
import type { InstanceMode, ScaleChange, TargetKind } from './types';

export const kindLabel = (k: TargetKind): string => (k === 'REDIS' ? 'Valkey' : 'AlloyDB read pool');

export const modeLabel = (m: InstanceMode): string =>
  m === 'CLUSTER' ? 'Cluster' : m === 'CLUSTER_DISABLED' ? 'Standalone' : 'Read pool';

/** What a mode scales by. */
export const unitLabel = (m: InstanceMode): string => (m === 'CLUSTER' ? 'shards' : m === 'READ_POOL' ? 'nodes' : 'replicas');

export function stateVariant(state: string): Variant {
  switch (state) {
    case 'ACTIVE': case 'READY': return 'success';
    case 'CREATING': case 'UPDATING': case 'BOOTSTRAPPING': case 'MAINTENANCE': return 'info';
    case 'DELETING': case 'STOPPED': return 'warning';
    case 'FAILED': return 'danger';
    default: return 'muted';
  }
}

export function stateLabel(state: string): string {
  return state.charAt(0) + state.slice(1).toLowerCase();
}

/** One short phrase per thing the change does, for badges. */
export function describeChange(c: ScaleChange, kind?: TargetKind): string[] {
  const out: string[] = [];
  if (c.units != null) out.push(`Scale to ${c.units} ${kind === 'DB' ? 'node' : 'shard'}${c.units === 1 ? '' : 's'}`);
  if (c.replicas != null) out.push(`${c.replicas} replica${c.replicas === 1 ? '' : 's'}`);
  if (c.blockScaleIn) out.push('Block scale-in');
  if (c.shrinkOnEnd) out.push('Shrink back at the end');
  return out;
}

/** Friendly names for the autoscaler's settings; unknown keys show as written. */
const SETTING_LABELS: Record<string, { label: string; hint?: string }> = {
  minSize: { label: 'Minimum shards', hint: 'The autoscaler never scales below this.' },
  maxSize: { label: 'Maximum shards' },
  scaleOutLimit: { label: 'Most shards to add at once' },
  scaleInLimit: { label: 'Most shards to remove at once' },
  minNodeCount: { label: 'Minimum nodes', hint: 'The autoscaler never scales below this.' },
  maxNodeCount: { label: 'Maximum nodes' },
  stepSize: { label: 'Nodes to add or remove per step' },
  scaleOutCoolingMinutes: { label: 'Wait after scaling out (minutes)' },
  scaleInCoolingMinutes: { label: 'Wait after scaling in (minutes)' },
  minFreeMemoryPercent: { label: 'Free memory to keep (%)' },
  scalingMethod: { label: 'Scaling method' },
};
export const settingLabel = (key: string): { label: string; hint?: string } => SETTING_LABELS[key] ?? { label: key };

export const OPERATORS: { value: string; label: string }[] = [
  { value: 'greaterThan', label: 'is above' },
  { value: 'greaterThanInclusive', label: 'is at or above' },
  { value: 'lessThan', label: 'is below' },
  { value: 'lessThanInclusive', label: 'is at or below' },
  { value: 'equal', label: 'equals' },
  { value: 'notEqual', label: 'is not' },
];
