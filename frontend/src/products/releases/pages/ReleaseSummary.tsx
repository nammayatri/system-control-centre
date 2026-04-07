import React, { useState, useEffect } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useAuth } from '../../../core/auth/AuthContext';
import {
  useRelease, useReleaseEvents, useApproveRelease, useDiscardRelease,
  usePauseRelease, useResumeRelease, useAbortRelease, useRevertRelease,
  useImmediateRevert, useDeleteRelease, useRestartRelease,
  useFastForwardRelease, useImmediateRevertWithSync,
  useReleaseDiff, usePodHealth, useResources, useUpdateTracker,
} from '../hooks';
import type { RolloutHistoryEvent, RolloutEvent, RolloutStrategyEvent, PodInfo } from '../api';
import { Badge } from '../../../shared/ui/badge';
import { StatusBadge } from '../components/StatusBadge';
import { Button } from '../../../shared/ui/button';
import { CardSkeleton } from '../../../shared/ui/skeleton';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { SimpleTooltip } from '../../../shared/ui/tooltip';
import {
  Copy, RefreshCw, Play, Pause, Square, RotateCcw, Check, X, Zap,
  Search, Trash2, ChevronRight as ChevronRightIcon, FastForward, RotateCw,
  ExternalLink, Network, BarChart3, Pencil, Lock, Save, Info,
} from 'lucide-react';
import { cn } from '../../../lib/utils';
import { useConfirm } from '../../../shared/ui/confirm-dialog';
import { toast } from 'sonner';
import ReactDiffViewer from 'react-diff-viewer-continued';
import YAML from 'yaml';

// NammaYatri ops run on IST — format all timestamps in Asia/Kolkata so
// dashboard users outside India still see the same values as on-call India.
// Backend stores UTC; this is a display-only transform.
const formatDate = (d?: string) => {
  if (!d) return '-';
  const date = new Date(d);
  if (isNaN(date.getTime())) return '-';
  return date.toLocaleString('en-IN', {
    timeZone: 'Asia/Kolkata',
    month: 'short',
    day: '2-digit',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    hour12: true,
  }) + ' IST';
};

const tryFormatJson = (data: string): string => {
  try { return JSON.stringify(JSON.parse(data), null, 2); }
  catch { return data; }
};

/** Events Tab */
const ReleaseEventsTab: React.FC<{ events: RolloutEvent[] }> = ({ events }) => {
  const [expandedRows, setExpandedRows] = useState<Set<number>>(new Set());
  const [eventSearch, setEventSearch] = useState('');

  const toggleRow = (idx: number) => {
    setExpandedRows(prev => { const next = new Set(prev); if (next.has(idx)) next.delete(idx); else next.add(idx); return next; });
  };

  const sorted = [...events]
    .sort((a, b) => b.timestamp.localeCompare(a.timestamp))
    .filter(e => !eventSearch || e.label?.toLowerCase().includes(eventSearch.toLowerCase()) || e.category?.toLowerCase().includes(eventSearch.toLowerCase()) || e.data?.toLowerCase().includes(eventSearch.toLowerCase()));

  return (
    <div className="p-4 sm:p-6">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 mb-4">
        <h3 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider">Release Events</h3>
        <div className="relative">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-zinc-400" />
          <input type="text" placeholder="Filter events..." value={eventSearch} onChange={(e) => setEventSearch(e.target.value)}
            className="pl-8 pr-3 h-10 sm:h-9 border border-zinc-300 rounded-lg text-sm w-full sm:w-56 focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150" />
        </div>
      </div>
      {sorted.length > 0 ? (
        <div className="overflow-x-auto -mx-4 sm:mx-0">
          <table className="w-full text-sm text-left border-collapse">
            <thead>
              <tr className="bg-zinc-50 border-y border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                <th className="py-2 px-3 w-8"></th>
                <th className="py-2 px-3">#</th>
                <th className="py-2 px-3">Timestamp</th>
                <th className="py-2 px-3">Category</th>
                <th className="py-2 px-3">Label</th>
                <th className="py-2 px-3">Value</th>
              </tr>
            </thead>
            <tbody>
              {sorted.map((evt, idx) => (
                <React.Fragment key={idx}>
                  <tr className={cn('border-b border-zinc-100 cursor-pointer hover:bg-zinc-100 transition-colors duration-150', idx % 2 === 1 ? 'bg-zinc-50' : 'bg-white')} onClick={() => toggleRow(idx)}>
                    <td className="py-2 px-3 text-zinc-400"><span className={`inline-block transition-transform duration-200 text-xs ${expandedRows.has(idx) ? 'rotate-90' : ''}`}>&#9654;</span></td>
                    <td className="py-2 px-3 text-zinc-400 font-mono text-xs">{idx + 1}</td>
                    <td className="py-2 px-3 font-mono text-xs text-zinc-500 whitespace-nowrap">{formatDate(evt.timestamp)}</td>
                    <td className="py-2 px-3">
                      <Badge variant={evt.category === 'BUSINESS' ? 'info' : evt.category === 'DECISION_ENGINE' ? 'purple' : evt.category === 'NOTIFICATION' ? 'success' : 'default'} size="sm">
                        {evt.category}
                      </Badge>
                    </td>
                    <td className="py-2 px-3 font-mono text-xs">{evt.label}</td>
                    <td className="py-2 px-3 text-xs text-zinc-500 max-w-xs truncate" title={evt.data}>{evt.data?.slice(0, 40)}{(evt.data?.length || 0) > 40 ? '...' : ''}</td>
                  </tr>
                  {expandedRows.has(idx) && (
                    <tr className="border-b border-zinc-100 bg-zinc-50">
                      <td colSpan={6} className="px-6 py-3">
                        <pre className="text-xs font-mono bg-zinc-50 text-zinc-800 border border-zinc-200 p-4 rounded-lg overflow-x-auto max-h-60 whitespace-pre-wrap break-all">{tryFormatJson(evt.data)}</pre>
                      </td>
                    </tr>
                  )}
                </React.Fragment>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <p className="text-sm text-zinc-400">No events recorded.</p>
      )}
    </div>
  );
};

/** ENV Diff Tab */
// Backend now returns YAML directly (matching production autopilot behavior).
// No JSON-to-YAML conversion needed -- just pass through, with fallback for legacy JSON data.
const formatDiff = (raw: string): string => {
  if (!raw) return '';
  // If it looks like JSON (legacy data before YAML migration), convert it
  const trimmed = raw.trim();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    try {
      let data = raw;
      // Handle double-encoded JSON
      try {
        const firstParse = JSON.parse(data);
        if (typeof firstParse === 'string') data = firstParse;
        else return YAML.stringify(firstParse, { indent: 2 });
      } catch { /* not JSON wrapper */ }
      const parsed = JSON.parse(data);
      return YAML.stringify(parsed, { indent: 2 });
    } catch { /* not JSON, fall through */ }
  }
  // Already YAML from backend, return as-is
  return raw;
};

type DiffType = 'deployment';
const DIFF_TYPE_LABELS: Record<DiffType, string> = {
  deployment: 'Deployment',
};

const EnvDiffTab: React.FC<{ releaseId: string }> = ({ releaseId }) => {
  const [diffType, setDiffType] = useState<DiffType>('deployment');
  const { data: diff, isLoading, error } = useReleaseDiff(releaseId, diffType);

  return (
    <div className="p-4 sm:p-6">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2 mb-4">
        <h3 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider">Deployment Diff</h3>
        {diff?.message && <span className="text-xs text-zinc-400">{diff.message}</span>}
      </div>
      {isLoading ? (
        <div className="animate-pulse space-y-3"><div className="h-4 bg-zinc-100 rounded w-1/3" /><div className="h-64 bg-zinc-100 rounded" /></div>
      ) : error || !diff ? (
        <p className="text-sm text-zinc-400">No diff data available.</p>
      ) : !diff.oldfile && !diff.newfile ? (
        <div><p className="text-sm text-zinc-400">No {DIFF_TYPE_LABELS[diffType]} diff data available.</p>{diff.message && <p className="text-xs text-zinc-400 mt-1">{diff.message}</p>}</div>
      ) : (
        <div className="border border-zinc-200 rounded-lg overflow-hidden text-xs sm:text-sm overflow-x-auto">
          <ReactDiffViewer
            oldValue={formatDiff(diff.oldfile)}
            newValue={formatDiff(diff.newfile)}
            splitView={true}
            leftTitle={`${DIFF_TYPE_LABELS[diffType]} — Before`}
            rightTitle={`${DIFF_TYPE_LABELS[diffType]} — After`}
            useDarkTheme={false}
          />
        </div>
      )}
    </div>
  );
};

/** Deployment Status Card — old vs new version pod counts */
const DeploymentStatusCard: React.FC<{ release: any; pods: PodInfo[] }> = ({ release, pods }) => {
  const oldVersion = release.old_version;
  const newVersion = release.new_version;

  const oldPods = pods.filter(p => p.version === oldVersion);
  const newPods = pods.filter(p => p.version === newVersion);
  const otherPods = pods.filter(p => p.version !== oldVersion && p.version !== newVersion);

  return (
    <div className="border border-zinc-200 rounded-lg p-4 mb-6">
      <h3 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider mb-3">Deployment Status</h3>
      <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
        <div className="flex items-center gap-3 border border-zinc-100 rounded-lg px-4 py-3">
          <span className="w-2 h-2 rounded-full bg-zinc-400 flex-shrink-0" />
          <div className="min-w-0">
            <div className="text-[10px] font-medium text-zinc-500 uppercase tracking-wider">Old Version</div>
            <div className="text-sm font-mono font-medium text-zinc-800 truncate">{oldVersion || '-'}</div>
          </div>
          <div className="ml-auto text-right flex-shrink-0">
            <span className="text-lg font-bold text-zinc-900">{oldPods.length}</span>
            <span className="text-xs text-zinc-500 ml-1">{oldPods.length === 1 ? 'pod' : 'pods'} running</span>
          </div>
        </div>
        <div className="flex items-center gap-3 border border-zinc-100 rounded-lg px-4 py-3">
          <span className="w-2 h-2 rounded-full bg-emerald-500 flex-shrink-0" />
          <div className="min-w-0">
            <div className="text-[10px] font-medium text-zinc-500 uppercase tracking-wider">New Version</div>
            <div className="text-sm font-mono font-medium text-zinc-800 truncate">{newVersion || '-'}</div>
          </div>
          <div className="ml-auto text-right flex-shrink-0">
            <span className="text-lg font-bold text-zinc-900">{newPods.length}</span>
            <span className="text-xs text-zinc-500 ml-1">{newPods.length === 1 ? 'pod' : 'pods'} running</span>
          </div>
        </div>
      </div>
      {otherPods.length > 0 && (
        <div className="mt-2 text-xs text-zinc-400">{otherPods.length} pod(s) with unknown/other versions</div>
      )}
    </div>
  );
};

/** Pod Health Section (in Summary tab) */
const PodHealthSection: React.FC<{ releaseId: string; release: any }> = ({ releaseId, release }) => {
  const { data: podData, isLoading } = usePodHealth(releaseId);

  if (isLoading) return <div className="animate-pulse space-y-2"><div className="h-20 bg-zinc-100 rounded" /></div>;
  if (!podData) return null;

  const { pods, summary } = podData;
  const summaryCards = [
    { label: 'Total', value: summary.total, color: 'bg-zinc-400' },
    { label: 'Running', value: summary.running, color: 'bg-emerald-500' },
    { label: 'Pending', value: summary.pending, color: 'bg-amber-500' },
    { label: 'Failed', value: summary.failed, color: 'bg-red-500' },
  ];

  const podStatusVariant = (status: string): 'success' | 'warning' | 'danger' | 'default' | 'muted' => {
    const s = status.toLowerCase();
    if (s === 'running') return 'success';
    if (s === 'pending' || s === 'containercreating') return 'warning';
    if (s === 'failed' || s === 'crashloopbackoff' || s === 'error') return 'danger';
    if (s === 'terminated' || s === 'completed') return 'muted';
    return 'default';
  };

  return (
    <>
      {/* Deployment Status — old vs new version pod counts */}
      <DeploymentStatusCard release={release} pods={pods} />

      <div className="border border-zinc-200 rounded-lg p-4 mb-6">
        <h3 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider mb-4">Pods</h3>
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-4">
          {summaryCards.map((card) => (
            <div key={card.label} className="border border-zinc-100 rounded-lg px-3 py-2">
              <div className="text-[10px] font-medium text-zinc-500 uppercase tracking-wider mb-1">{card.label}</div>
              <div className="flex items-center gap-1.5">
                <span className={cn('w-1.5 h-1.5 rounded-full', card.color)} />
                <span className="text-lg font-bold text-zinc-900">{card.value}</span>
              </div>
            </div>
          ))}
        </div>
        {pods.length > 0 && (
          <div className="overflow-x-auto -mx-4 sm:mx-0">
            <table className="w-full text-sm text-left border-collapse">
              <thead>
                <tr className="bg-zinc-50 border-y border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                  <th className="py-2 px-3">Name</th>
                  <th className="py-2 px-3">Status</th>
                  <th className="py-2 px-3">Ready</th>
                  <th className="py-2 px-3">Restarts</th>
                  <th className="py-2 px-3">Age</th>
                  <th className="py-2 px-3">Version</th>
                </tr>
              </thead>
              <tbody>
                {pods.map((pod, idx) => (
                  <tr key={pod.name} className={cn('border-b border-zinc-100', idx % 2 === 1 ? 'bg-zinc-50/50' : 'bg-white')}>
                    <td className="py-2 px-3 font-mono text-xs text-zinc-700">{pod.name}</td>
                    <td className="py-2 px-3"><Badge variant={podStatusVariant(pod.status)} size="sm">{pod.status}</Badge></td>
                    <td className="py-2 px-3 text-xs text-zinc-600">{pod.ready}</td>
                    <td className="py-2 px-3 font-mono text-xs text-zinc-600">{pod.restarts}</td>
                    <td className="py-2 px-3 text-xs text-zinc-500">{pod.age}</td>
                    <td className="py-2 px-3 font-mono text-xs text-zinc-600">{pod.version}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </>
  );
};

/** Resources Section (in Summary tab) */
const ResourcesSection: React.FC<{ product: string; service: string }> = ({ product, service }) => {
  const { data: resources, isLoading } = useResources(product, service);

  if (isLoading) return <div className="animate-pulse"><div className="h-16 bg-zinc-100 rounded" /></div>;
  if (!resources) return null;

  const items = [
    { label: 'CPU Requests', value: resources.cpu_requests },
    { label: 'CPU Limits', value: resources.cpu_limits },
    { label: 'Memory Requests', value: resources.memory_requests },
    { label: 'Memory Limits', value: resources.memory_limits },
  ];

  return (
    <div className="border border-zinc-200 rounded-lg p-4">
      <h3 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider mb-4">Resources</h3>
      <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
        {items.map((item) => (
          <div key={item.label} className="border border-zinc-100 rounded-lg px-3 py-2">
            <div className="text-[10px] font-medium text-zinc-500 uppercase tracking-wider mb-1">{item.label}</div>
            <div className="text-sm font-mono font-medium text-zinc-800">{item.value || '-'}</div>
          </div>
        ))}
      </div>
    </div>
  );
};

/** Rollout History (inline in Summary tab) */
const RolloutHistoryInline: React.FC<{ history: RolloutHistoryEvent[] }> = ({ history }) => {
  if (!history?.length) return null;

  return (
    <div className="border border-zinc-200 rounded-lg p-4 mb-6">
      <h3 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider mb-3">Rollout History</h3>
      <div className="overflow-x-auto -mx-4 sm:mx-0">
        <table className="w-full text-sm text-left border-collapse">
          <thead>
            <tr className="bg-zinc-50 border-y border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
              <th className="py-2 px-3">#</th>
              <th className="py-2 px-3">Start Time</th>
              <th className="py-2 px-3">Rollout %</th>
              <th className="py-2 px-3">End Time</th>
              <th className="py-2 px-3">Decision</th>
              <th className="py-2 px-3">HS Decision</th>
              <th className="py-2 px-3">Manual Override</th>
              <th className="py-2 px-3">Cooloff (min)</th>
              <th className="py-2 px-3">
                <span className="flex items-center gap-1">
                  Min Pods
                  <span title="Minimum number of new pods at this stage. Actual count = max(this floor, factor-based target, old-pod prediction). Default 2 = at least 2 pods." className="cursor-help text-zinc-400 hover:text-zinc-600"><Info className="w-3 h-3" /></span>
                </span>
              </th>
            </tr>
          </thead>
          <tbody>
            {history.map((h, idx) => (
              <tr key={idx} className={cn('border-b border-zinc-100', idx % 2 === 1 ? 'bg-zinc-50/50' : 'bg-white')}>
                <td className="py-2 px-3 text-xs font-medium text-zinc-500">{idx + 1}</td>
                <td className="py-2 px-3 font-mono text-xs">{formatDate(h.started_at)}</td>
                <td className="py-2 px-3 font-mono font-medium">{h.rollout}%</td>
                <td className="py-2 px-3 font-mono text-xs">{formatDate(h.completed_at)}</td>
                <td className="py-2 px-3">
                  <Badge variant={h.last_decision === 'Continue' ? 'success' : h.last_decision === 'Abort' ? 'danger' : h.last_decision === 'Wait' ? 'warning' : 'default'} size="sm">
                    {h.last_decision || '-'}
                  </Badge>
                </td>
                <td className="py-2 px-3">
                  <Badge variant={h.last_decision_hs === 'Continue' ? 'success' : h.last_decision_hs === 'Abort' ? 'danger' : h.last_decision_hs === 'Wait' ? 'warning' : 'default'} size="sm">
                    {h.last_decision_hs || '-'}
                  </Badge>
                </td>
                <td className="py-2 px-3">
                  <Badge variant={h.manual_override ? 'warning' : 'default'} size="sm">
                    {h.manual_override ? 'Yes' : 'No'}
                  </Badge>
                </td>
                <td className="py-2 px-3 font-mono">{h.cooloff}m</td>
                <td className="py-2 px-3 font-mono">{h.pods}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
};

/** K8s Context Card */
const K8sContextCard: React.FC<{ releaseContext: any }> = ({ releaseContext }) => {
  if (!releaseContext) return null;

  const ctx = releaseContext;
  const hasData = ctx.cluster || ctx.namespace || ctx.deployment_name || ctx.vs_name || ctx.pods_scale_down_status;
  if (!hasData) return null;

  const fields = [
    { label: 'Cluster', value: ctx.cluster },
    { label: 'Namespace', value: ctx.namespace },
    { label: 'Deployment Name', value: ctx.deployment_name },
    { label: 'VS Name', value: ctx.vs_name },
    { label: 'Scale Down Status', value: ctx.pods_scale_down_status },
    { label: 'Scale Down Timestamp', value: ctx.pods_scale_down_timestamp ? formatDate(ctx.pods_scale_down_timestamp) : '' },
  ].filter(f => f.value);

  if (fields.length === 0) return null;

  return (
    <div className="border border-zinc-200 rounded-lg p-4 mb-6">
      <h3 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider mb-3">K8s Context</h3>
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-4 sm:gap-x-6 gap-y-3">
        {fields.map(f => (
          <div key={f.label}>
            <div className="text-[11px] font-medium text-zinc-500 uppercase tracking-wider mb-1">{f.label}</div>
            <div className="border border-zinc-100 rounded-lg px-3 py-2 bg-zinc-50 text-sm font-mono text-xs min-h-[38px] break-all">{f.value}</div>
          </div>
        ))}
      </div>
    </div>
  );
};

/** Editable Rollout Strategy (inline in Summary) */
const RolloutStrategyTab: React.FC<{
  releaseId: string;
  strategy: RolloutStrategyEvent[];
  historyLength: number;
  status: string;
}> = ({ releaseId, strategy, historyLength, status }) => {
  const [stages, setStages] = useState<RolloutStrategyEvent[]>([]);
  const [isEditing, setIsEditing] = useState(false);
  const [hasChanges, setHasChanges] = useState(false);
  const updateMut = useUpdateTracker();

  useEffect(() => {
    setStages(strategy.map(s => ({ ...s })));
    setHasChanges(false);
    setIsEditing(false);
  }, [strategy]);

  const canEdit = status === 'CREATED' || status === 'INPROGRESS' || status === 'PAUSED';

  const handleStageChange = (idx: number, field: keyof RolloutStrategyEvent, value: number) => {
    setStages(prev => {
      const next = [...prev];
      next[idx] = { ...next[idx], [field]: value };
      return next;
    });
    setHasChanges(true);
  };

  const addStage = () => {
    const lastStage = stages[stages.length - 1];
    setStages(prev => [...prev, { rollout: Math.min((lastStage?.rollout || 0) + 25, 100), cooloff: lastStage?.cooloff || 60, pods: lastStage?.pods || 1 }]);
    setHasChanges(true);
  };

  const removeStage = (idx: number) => {
    if (idx < historyLength) return; // can't remove completed stages
    const futureStages = stages.filter((_, i) => i >= historyLength);
    if (futureStages.length <= 1) return; // keep at least 1 future stage
    setStages(prev => prev.filter((_, i) => i !== idx));
    setHasChanges(true);
  };

  const handleSave = async () => {
    try {
      await updateMut.mutateAsync({
        releaseId,
        updates: {
          rolloutStrategy: stages.map(s => ({
            rolloutPercent: s.rollout,
            cooloffMinutes: s.cooloff,
            podPercent: s.pods,
          })),
        },
      });
      setHasChanges(false);
      setIsEditing(false);
      toast.success('Rollout strategy updated');
    } catch (err: any) { toast.error(err?.response?.data?.message || err.message || 'Failed to update strategy'); }
  };

  const handleCancel = () => {
    setStages(strategy.map(s => ({ ...s })));
    setHasChanges(false);
    setIsEditing(false);
  };

  if (!stages.length) return null;

  return (
    <div className="border border-zinc-200 rounded-lg p-4 mb-6">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 mb-4">
        <h3 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider">Rollout Strategy</h3>
        <div className="flex items-center gap-2 flex-wrap">
          {canEdit && !isEditing && (
            <PermissionGate product="autopilot" permission="RELEASE_UPDATE">
              <Button size="sm" variant="outline" onClick={() => setIsEditing(true)}>
                <Pencil className="w-3.5 h-3.5" /> Update Stages
              </Button>
            </PermissionGate>
          )}
          {isEditing && hasChanges && (
            <>
              <Button size="sm" variant="outline" onClick={handleCancel}>Cancel</Button>
              <Button size="sm" loading={updateMut.isPending} onClick={handleSave}>
                <Save className="w-3.5 h-3.5" /> Save
              </Button>
            </>
          )}
          {isEditing && !hasChanges && (
            <Button size="sm" variant="outline" onClick={handleCancel}>Done</Button>
          )}
        </div>
      </div>

      <div className="overflow-x-auto -mx-4 sm:mx-0 rounded-lg sm:border border-zinc-200">
        <table className="w-full text-sm min-w-[600px]">
          <thead>
            <tr className="bg-zinc-50 border-b border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
              <th className="py-2.5 px-4 text-left w-20">#</th>
              <th className="py-2.5 px-4 text-left">Rollout %</th>
              <th className="py-2.5 px-4 text-left">Cooloff (min)</th>
              <th className="py-2.5 px-4 text-left">
                <span className="flex items-center gap-1">
                  Min Pods
                  <span title="Minimum number of new pods at this stage. Actual count = max(this floor, factor-based target, old-pod prediction). Default 2 = at least 2 pods." className="cursor-help text-zinc-400 hover:text-zinc-600"><Info className="w-3 h-3" /></span>
                </span>
              </th>
              <th className="py-2.5 px-4 text-left w-32">Progress</th>
              {isEditing && <th className="py-2.5 px-4 w-12"></th>}
            </tr>
          </thead>
          <tbody>
            {stages.map((stage, idx) => {
              const isLocked = idx < historyLength;
              const canRemove = isEditing && !isLocked && stages.filter((_, i) => i >= historyLength).length > 1;

              return (
                <tr key={idx} className={cn('border-b border-zinc-100 transition-colors', isLocked ? 'bg-zinc-50/60' : 'bg-white hover:bg-zinc-50/40')}>
                  <td className="py-2.5 px-4">
                    <div className="flex items-center gap-1.5">
                      {isLocked && <Lock className="w-3 h-3 text-zinc-400" />}
                      <span className={cn('text-xs font-bold', isLocked ? 'text-zinc-400' : 'text-zinc-600')}>Stage {idx + 1}</span>
                    </div>
                  </td>
                  <td className="py-2.5 px-4">
                    {isEditing && !isLocked ? (
                      <input type="number" min={1} max={100} value={stage.rollout}
                        onChange={(e) => handleStageChange(idx, 'rollout', parseInt(e.target.value) || 0)}
                        className="w-20 h-8 border border-zinc-300 rounded-lg px-3 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-zinc-400" />
                    ) : (
                      <span className="text-sm font-mono font-semibold text-zinc-800">{stage.rollout}%</span>
                    )}
                  </td>
                  <td className="py-2.5 px-4">
                    {isEditing && !isLocked ? (
                      <input type="number" min={0} value={stage.cooloff}
                        onChange={(e) => handleStageChange(idx, 'cooloff', parseInt(e.target.value) || 0)}
                        className="w-20 h-8 border border-zinc-300 rounded-lg px-3 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-zinc-400" />
                    ) : (
                      <span className="text-sm font-mono text-zinc-600">{stage.cooloff}m</span>
                    )}
                  </td>
                  <td className="py-2.5 px-4">
                    {isEditing && !isLocked ? (
                      <input type="number" min={1} value={stage.pods}
                        onChange={(e) => handleStageChange(idx, 'pods', parseInt(e.target.value) || 1)}
                        className="w-16 h-8 border border-zinc-300 rounded-lg px-3 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-zinc-400" />
                    ) : (
                      <span className="text-sm font-mono text-zinc-600">{stage.pods}</span>
                    )}
                  </td>
                  <td className="py-2.5 px-4">
                    <div className="w-full bg-zinc-100 rounded-full h-2">
                      <div className={cn('h-2 rounded-full transition-all duration-300', isLocked ? 'bg-green-500' : 'bg-blue-500')}
                        style={{ width: `${stage.rollout}%` }} />
                    </div>
                  </td>
                  {isEditing && (
                    <td className="py-2.5 px-4">
                      {canRemove && (
                        <button onClick={() => removeStage(idx)} className="p-1.5 rounded-lg text-red-400 hover:text-red-600 hover:bg-red-50 cursor-pointer transition-colors">
                          <Trash2 className="w-3.5 h-3.5" />
                        </button>
                      )}
                    </td>
                  )}
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {isEditing && (
        <Button type="button" variant="secondary" size="sm" onClick={addStage} className="mt-2 w-full">
          + Add Stage
        </Button>
      )}

      {!canEdit && (
        <p className="text-xs text-zinc-400 mt-3">Strategy is read-only for {status} releases.</p>
      )}
    </div>
  );
};

const ReleaseSummary: React.FC = () => {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const [activeTab, setActiveTab] = useState<'summary' | 'events' | 'env-diff' | 'json'>('summary');
  // Edit dialog removed — now uses full /releases/:id/edit page

  const { data: release, isLoading, isFetching, error, refetch } = useRelease(id);
  const { data: events = [] } = useReleaseEvents(id);
  const qc = useQueryClient();
  // Round 8 audit M9: use the authenticated user's email instead of the
  // hardcoded "admin" string for approve/revert/restart audit attribution.
  const { user: authUser } = useAuth();
  const actor = authUser?.email || 'admin';
  const handleRefresh = async () => {
    // Refresh both the release and its event log so the UI shows fully fresh state.
    await Promise.all([
      refetch(),
      qc.invalidateQueries({ queryKey: ['release-events', id] }),
      qc.invalidateQueries({ queryKey: ['release-pods', id] }),
      qc.invalidateQueries({ queryKey: ['release-resources', id] }),
    ]);
  };

  // Revert sync checkbox defaults based on release.sync_enabled
  const [revertSyncChecked, setRevertSyncChecked] = useState(false);
  useEffect(() => {
    if (release) {
      setRevertSyncChecked(release.sync_enabled === 'true');
    }
  }, [release?.sync_enabled]);

  const approveMut = useApproveRelease();
  const discardMut = useDiscardRelease();
  const pauseMut = usePauseRelease();
  const resumeMut = useResumeRelease();
  const abortMut = useAbortRelease();
  const revertMut = useRevertRelease();
  const immRevertMut = useImmediateRevert();
  const deleteMut = useDeleteRelease();
  const restartMut = useRestartRelease();
  const fastForwardMut = useFastForwardRelease();
  const immRevertSyncMut = useImmediateRevertWithSync();
  const updateTrackerMut = useUpdateTracker();

  const confirmAction = useConfirm();

  const KIBANA_URL = import.meta.env.VITE_KIBANA_URL || '';
  const KIALI_URL = import.meta.env.VITE_KIALI_URL || '';
  const GRAFANA_URL = import.meta.env.VITE_GRAFANA_URL || '';

  // Capitalise the first letter of a string for titles/buttons.
  const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

  /** doAction takes a SHORT verb (e.g. "fast forward", "approve") for the
   *  modal title + confirm-button label, and an OPTIONAL longer description
   *  shown in the body. Previously the verb and description were the same
   *  long string, which produced an unreadable modal title and a giant
   *  button label for fast-forward. */
  const doAction = async (
    label: string,
    fn: () => Promise<any>,
    isDanger = false,
    description?: string,
  ) => {
    const ok = await confirmAction({
      title: `${cap(label)} Release`,
      description:
        description ??
        `Are you sure you want to ${label} this release? This action cannot be undone.`,
      confirmLabel: cap(label),
      variant: isDanger ? 'danger' : 'primary',
    });
    if (!ok) return;
    try { await fn(); } catch (err: any) {
      // individual mutation onError handlers fire their own toasts;
      // this is a safety net for any future mutation added without onError
      console.error('[doAction]', err);
    }
  };

  const doImmediateRevert = async () => {
    const ok = await confirmAction({
      title: 'Immediate Revert',
      description: 'This will instantly swap the image and bypass normal rollout pipeline. This action cannot be undone.',
      confirmLabel: 'Immediate Revert',
      variant: 'danger',
    });
    if (!ok) return;
    try {
      await immRevertSyncMut.mutateAsync({ releaseId: id!, isRevertSync: revertSyncChecked });
    } catch (err: any) { console.error('[doImmediateRevert]', err); }
  };

  if (isLoading && !release) {
    return (
      <div className="flex flex-col flex-1 w-full pb-12 space-y-6">
        <CardSkeleton />
        <CardSkeleton />
      </div>
    );
  }
  if (error && !release) return <div className="p-8 text-center text-red-500">Release not found</div>;
  if (!release) return null;

  const s = release.status;

  const InfoField = ({ label, value, mono }: { label: string; value?: string; mono?: boolean }) => (
    <div>
      <div className="text-[11px] font-medium text-zinc-500 uppercase tracking-wider mb-1">{label}</div>
      <div className={cn('border border-zinc-100 rounded-lg px-3 py-2 bg-zinc-50 text-sm min-h-[38px] break-all', mono && 'font-mono text-xs')}>{value || '-'}</div>
    </div>
  );

  const tabs = [
    { key: 'summary' as const, label: 'Summary' },
    { key: 'events' as const, label: 'Events' },
    { key: 'env-diff' as const, label: 'ENV Diff' },
    { key: 'json' as const, label: 'JSON Data' },
  ];

  // Build extra info fields conditionally
  const dockerImage = release.docker_image || release.release_context?.docker_image || '';
  const category = release.tracker_type || '';
  const releaseTag = release.release_tag || '';
  const globalId = release.global_id || '';
  const newService = release.new_service;
  const cronjobSuspend = release.cronjob_suspend;

  return (
    <div className="flex flex-col flex-1 w-full pb-12">
      {/* Breadcrumb */}
      <div className="flex items-center text-sm text-zinc-500 font-medium mb-3 sm:mb-4 flex-wrap gap-y-1">
        <Link to="/releases" className="hover:text-zinc-700 transition-colors duration-150">Releases</Link>
        <ChevronRightIcon className="w-4 h-4 mx-1 text-zinc-300 shrink-0" />
        <span className="text-zinc-600">{release.release_context?.cluster || release.env || ''}</span>
        <ChevronRightIcon className="w-4 h-4 mx-1 text-zinc-300 shrink-0" />
        <span className="font-mono text-xs text-zinc-800 truncate max-w-[150px] sm:max-w-[200px]">{release.release_tag || id}</span>
        {(s === 'CREATED' || s === 'INPROGRESS' || s === 'PAUSED') && (
          <PermissionGate product="autopilot" permission="RELEASE_UPDATE">
            <button
              onClick={() => navigate(`/releases/${id}/edit`)}
              className="p-1 ml-1 rounded text-zinc-400 hover:text-zinc-700 hover:bg-zinc-100 transition-colors duration-150 cursor-pointer"
              aria-label="Edit release"
            >
              <Pencil className="w-3.5 h-3.5" />
            </button>
          </PermissionGate>
        )}
      </div>

      {/* Header */}
      <div className="flex flex-col gap-3 mb-4 sm:mb-5">
        <div className="flex items-center gap-2 sm:gap-3 flex-wrap">
          <h1 className="text-lg sm:text-xl font-semibold text-zinc-900">Release Summary</h1>
          <StatusBadge status={release.status} />
          {release.release_context?.revert === 1 && <Badge variant="purple" dot>REVERT</Badge>}
          {release.ab_hs_status && release.ab_hs_status !== 'Uninitiated' && <Badge variant="info">AB: {release.ab_hs_status}</Badge>}
          {KIBANA_URL && (
            <a href={KIBANA_URL} target="_blank" rel="noopener" className="text-xs text-zinc-500 border border-zinc-200 rounded px-2 py-1 hover:bg-zinc-50 inline-flex items-center gap-1">
              <ExternalLink className="w-3 h-3" /> Logs
            </a>
          )}
          {KIALI_URL && (
            <a href={KIALI_URL} target="_blank" rel="noopener" className="text-xs text-zinc-500 border border-zinc-200 rounded px-2 py-1 hover:bg-zinc-50 inline-flex items-center gap-1">
              <Network className="w-3 h-3" /> Mesh
            </a>
          )}
          {GRAFANA_URL && (
            <a href={GRAFANA_URL} target="_blank" rel="noopener" className="text-xs text-zinc-500 border border-zinc-200 rounded px-2 py-1 hover:bg-zinc-50 inline-flex items-center gap-1">
              <BarChart3 className="w-3 h-3" /> Metrics
            </a>
          )}
        </div>
        <div className="flex items-center gap-2 flex-wrap sm:justify-end">
          {s === 'CREATED' && release.is_approved === 0 && (
            <PermissionGate product="autopilot" permission="RELEASE_APPROVE">
              <Button size="sm" variant="success" loading={approveMut.isPending} onClick={() => doAction('approve', () => approveMut.mutateAsync({ releaseId: id!, approvedBy: actor }))}><Check className="w-3.5 h-3.5" /> Approve</Button>
            </PermissionGate>
          )}
          {s === 'CREATED' && (
            <PermissionGate product="autopilot" permission="RELEASE_DISCARD">
              <Button size="sm" variant="outline" className="border-red-300 text-red-700 hover:bg-red-50" loading={discardMut.isPending} onClick={() => doAction('discard', () => discardMut.mutateAsync({ releaseId: id! }), true)}><X className="w-3.5 h-3.5" /> Discard</Button>
            </PermissionGate>
          )}
          {(s === 'INPROGRESS') && (
            <>
              <PermissionGate product="autopilot" permission="RELEASE_PAUSE">
                <Button size="sm" variant="outline" className="border-amber-300 text-amber-700 hover:bg-amber-50" loading={pauseMut.isPending} onClick={() => doAction('pause', () => pauseMut.mutateAsync(id!))}><Pause className="w-3.5 h-3.5" /> Pause</Button>
                <Button size="sm" variant="danger" loading={abortMut.isPending} onClick={() => doAction('abort', () => abortMut.mutateAsync(id!), true)}><Square className="w-3.5 h-3.5" /> Abort</Button>
              </PermissionGate>
              <PermissionGate product="autopilot" permission="RELEASE_UPDATE">
                <Button size="sm" variant="outline" className="border-amber-300 bg-amber-600 text-white hover:bg-amber-700" loading={fastForwardMut.isPending} onClick={() => doAction('fast forward', () => fastForwardMut.mutateAsync(id!), false, 'Skip the current cooloff and advance to the next rollout step. The runner will pick up the change on its next poll.')}><FastForward className="w-3.5 h-3.5" /> Fast Forward</Button>
              </PermissionGate>
            </>
          )}
          {s === 'PAUSED' && (
            <PermissionGate product="autopilot" permission="RELEASE_RESUME">
              <Button size="sm" className="bg-blue-600 text-white hover:bg-blue-700" loading={resumeMut.isPending} onClick={() => doAction('resume', () => resumeMut.mutateAsync(id!))}><Play className="w-3.5 h-3.5" /> Resume</Button>
              <Button size="sm" variant="danger" loading={abortMut.isPending} onClick={() => doAction('abort', () => abortMut.mutateAsync(id!), true)}><Square className="w-3.5 h-3.5" /> Abort</Button>
            </PermissionGate>
          )}
          {s === 'COMPLETED' && (
            <>
              <PermissionGate product="autopilot" permission="RELEASE_REVERT">
                <Button size="sm" variant="outline" className="border-violet-300 text-violet-700 hover:bg-violet-50" loading={revertMut.isPending} onClick={() => doAction('revert', () => revertMut.mutateAsync({ releaseId: id!, requestedBy: actor }), true)}><RotateCcw className="w-3.5 h-3.5" /> Revert</Button>
              </PermissionGate>
              <PermissionGate product="autopilot" permission="RELEASE_REVERT">
                <div className="flex items-center gap-2">
                  <Button size="sm" variant="danger" loading={immRevertSyncMut.isPending} onClick={doImmediateRevert}><Zap className="w-3.5 h-3.5" /> Immediate Revert</Button>
                  <label className="flex items-center gap-1.5 text-xs text-zinc-500 cursor-pointer">
                    <input type="checkbox" checked={revertSyncChecked} onChange={(e) => setRevertSyncChecked(e.target.checked)} className="rounded border-zinc-300 accent-zinc-900" />
                    Also revert in other cloud
                  </label>
                </div>
              </PermissionGate>
            </>
          )}
          {(s === 'ABORTED' || s === 'USER_ABORTED' || s === 'GCLT_ABORTED' || s === 'REVERTED') && (
            <PermissionGate product="autopilot" permission="RELEASE_CREATE">
              <Button size="sm" variant="outline" className="border-blue-300 text-blue-700 hover:bg-blue-50" loading={restartMut.isPending} onClick={() => doAction('restart', () => restartMut.mutateAsync(id!))}><RotateCw className="w-3.5 h-3.5" /> Restart</Button>
            </PermissionGate>
          )}

          <div className="w-px h-6 bg-zinc-200 mx-1" />
          <PermissionGate product="autopilot" permission="RELEASE_DELETE">
            <SimpleTooltip content="Delete"><Button size="icon" variant="ghost" className="text-red-500 hover:bg-red-50" loading={deleteMut.isPending} onClick={() => doAction('delete', async () => { await deleteMut.mutateAsync(id!); navigate('/releases'); }, true, 'Delete this release tracker permanently. This removes the audit trail and cannot be undone.')}><Trash2 className="w-4 h-4" /></Button></SimpleTooltip>
          </PermissionGate>
          <SimpleTooltip content="Clone"><Button size="icon" variant="ghost" onClick={() => navigate(`/releases/${id}/clone`)}><Copy className="w-4 h-4" /></Button></SimpleTooltip>
          <SimpleTooltip content="Refresh"><Button size="icon" variant="ghost" onClick={handleRefresh} aria-label="Refresh"><RefreshCw className={`w-4 h-4 ${isFetching ? 'animate-spin' : ''}`} /></Button></SimpleTooltip>
        </div>
      </div>

      {/* Main Card with Tabs */}
      <div className="bg-white rounded-xl border border-zinc-200">
        <div className="flex border-b border-zinc-200 px-2 sm:px-5 overflow-x-auto">
          {tabs.map(tab => (
            <button key={tab.key} onClick={() => setActiveTab(tab.key)}
              className={cn('py-3 px-3 sm:px-4 text-sm font-medium border-b-2 transition-colors duration-150 cursor-pointer whitespace-nowrap', activeTab === tab.key ? 'border-zinc-900 text-zinc-900' : 'border-transparent text-zinc-400 hover:text-zinc-600')}>
              {tab.label}
            </button>
          ))}
        </div>

        {/* Summary */}
        {activeTab === 'summary' && (
          <div className="p-4 sm:p-6">
            {/* Info Cards */}
            <div className="grid grid-cols-1 md:grid-cols-3 gap-3 sm:gap-4 mb-6">
              {[
                {
                  title: 'TIME SCHEDULE',
                  rows: [
                    { label: 'Created at', value: formatDate(release.date_created) },
                    { label: 'Scheduled time', value: formatDate(release.schedule_time) },
                    { label: 'Last Updated', value: formatDate(release.last_updated) },
                    { label: 'Start time', value: formatDate(release.start_time) },
                    { label: 'End time', value: formatDate(release.end_time) },
                  ],
                },
                {
                  title: 'META DATA',
                  rows: [
                    { label: 'Priority', value: String(release.priority ?? 0) },
                    { label: 'Env', value: release.env },
                    { label: 'Mode', value: release.mode },
                    { label: 'Approved', value: release.is_approved ? 'Yes' : 'No' },
                    { label: 'Approved By', value: release.is_approved ? (release.release_manager || '-') : '-' },
                    { label: 'Info', value: release.info },
                  ],
                },
                {
                  title: 'K8S INFO',
                  rows: [
                    { label: 'Release ID', value: release.id },
                    { label: 'Cluster', value: release.release_context?.cluster },
                    { label: 'Category', value: category },
                    { label: 'Rollout Strategy', value: release.rollout_strategy ? (Array.isArray(release.rollout_strategy) ? `${release.rollout_strategy.length} stages` : 'Custom') : '-' },
                    { label: 'Pods Scale Down Status', value: release.release_context?.pods_scale_down_status },
                    { label: 'Global ID', value: release.global_id },
                  ],
                },
              ].map((card, ci) => (
                <div key={ci} className="bg-zinc-50 rounded-xl border border-zinc-100 p-4 text-sm">
                  <h3 className="font-semibold text-zinc-500 uppercase text-[11px] tracking-wider mb-3">{card.title}</h3>
                  <dl className="space-y-2.5">
                    {card.rows.map((r, ri) => (
                      <div key={ri}>
                        <dt className="text-zinc-400 text-xs">{r.label}</dt>
                        <dd className={cn('text-zinc-800 font-medium mt-0.5 break-all', r.label === 'Release ID' && 'font-mono text-xs')}>{r.value || '-'}</dd>
                      </div>
                    ))}
                  </dl>
                </div>
              ))}
            </div>

            {/* Pod Health + Deployment Status */}
            <PodHealthSection releaseId={id!} release={release} />

            {/* Rollout History (inline) */}
            <RolloutHistoryInline history={release.rollout_history} />

            {/* Rollout Strategy (inline editable) */}
            <RolloutStrategyTab
              releaseId={id!}
              strategy={release.rollout_strategy}
              historyLength={release.rollout_history?.length || 0}
              status={s}
            />

            {/* Release Details — consolidated (no duplicate data) */}
            <div className="border border-zinc-200 rounded-lg p-4 mb-6">
              <h3 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider mb-4">Release Details</h3>
              <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-x-4 sm:gap-x-6 gap-y-3">
                <InfoField label="App Group" value={release.appGroup} />
                <InfoField label="Service" value={release.service} />
                <InfoField label="Old Version" value={release.old_version} mono />
                <InfoField label="New Version" value={release.new_version} mono />
                <InfoField label="Docker Image" value={dockerImage} mono />
                <InfoField label="Release Manager" value={release.release_manager || '-'} />
                <InfoField label="Infra Approved" value={release.is_infra_approved ? 'Yes' : 'No'} />
                {release.description && <InfoField label="Description" value={release.description} />}
                {release.change_log && <InfoField label="Change Log" value={release.change_log} />}
                {globalId && <InfoField label="Global ID" value={globalId} mono />}
              </div>
            </div>
          </div>
        )}

        {/* Events */}
        {activeTab === 'events' && <ReleaseEventsTab events={events} />}

        {/* ENV Diff */}
        {activeTab === 'env-diff' && <EnvDiffTab releaseId={id!} />}

        {/* JSON Data */}
        {activeTab === 'json' && (
          <div className="p-4 sm:p-6">
            <pre className="bg-zinc-50 border border-zinc-200 rounded-lg p-3 sm:p-4 text-[11px] sm:text-xs font-mono text-zinc-700 overflow-auto max-h-[600px] whitespace-pre-wrap break-all">
              {JSON.stringify(release, null, 2)}
            </pre>
          </div>
        )}
      </div>

      <div className="flex justify-end pt-5">
        <Button variant="secondary" onClick={() => navigate('/releases')}>Back to Releases</Button>
      </div>

    </div>
  );
};

export default ReleaseSummary;
