import React, { useState, useEffect, useCallback } from 'react';
import { useRefreshAnimation } from '../../../shared/hooks';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useAuth } from '../../../core/auth/AuthContext';
import {
  useRelease, useReleaseEvents, useApproveRelease, useDiscardRelease,
  usePauseRelease, useResumeRelease, useAbortRelease, useRevertRelease,
  useImmediateRevert, useDeleteRelease, useRestartRelease,
  useFastForwardRelease, useImmediateRevertWithSync,
  useReleaseDiff, usePodHealth, useResources, useUpdateTracker,
  useMobileApps, useDispatchMobileReleases, useMobileRollout,
  useRolloutRestartDeployment,
} from '../hooks';
import { formatBuildCode, versionWithBuild } from '../utils';
import type { RolloutHistoryEvent, RolloutEvent, RolloutStrategyEvent, PodInfo, ABValidationStatus } from '../api';
import { AB_STATUS_LABELS, AB_STATUS_COLORS } from '../api';
import type { LatestBuild } from '../types';
import { ABValidationModal } from '../components/ABValidationModal';
import { Badge } from '../../../shared/ui/badge';
import { StatusBadge } from '../components/StatusBadge';
import { isFirebaseInternal, FirebaseInternalBadge } from '../components/FirebaseBadge';
import { Button } from '../../../shared/ui/button';
import { CardSkeleton } from '../../../shared/ui/skeleton';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { AiReleasePanel } from '../components/AiReleasePanel';
import { MobileRolloutPanel } from '../components/MobileRolloutPanel';
import { BrandLogo } from '../components/BrandLogo';
import { SimpleTooltip } from '../../../shared/ui/tooltip';
import {
  Copy, RefreshCw, Play, Pause, Square, RotateCcw, Check, X, Zap,
  Search, Trash2, ChevronRight as ChevronRightIcon, FastForward, RotateCw,
  ExternalLink, Network, BarChart3, Pencil, Lock, Save, Info,
  Undo2, ArrowUpRight, Apple, GitBranch, Send, Flame,
} from 'lucide-react';
import { cn } from '../../../lib/utils';
import { useConfirm } from '../../../shared/ui/confirm-dialog';
import { toast } from 'sonner';
import ReactDiffViewer from 'react-diff-viewer-continued';
import YAML from 'yaml';

const AndroidIcon = ({ className }: { className?: string }) => (
  <svg viewBox="0 0 24 24" fill="currentColor" className={className}>
    <path d="M17.6 9.48l1.84-3.18c.16-.31.04-.69-.27-.85a.637.637 0 00-.83.22l-1.88 3.24a11.463 11.463 0 00-8.92 0L5.66 5.67c-.19-.29-.58-.38-.87-.2-.28.18-.37.54-.19.83L6.4 9.48A10.78 10.78 0 003 16h18a10.78 10.78 0 00-3.4-6.52zM8.86 13a.98.98 0 110-1.96.98.98 0 010 1.96zm6.28 0a.98.98 0 110-1.96.98.98 0 010 1.96z"/>
  </svg>
);

// Format in Asia/Kolkata so dashboard users worldwide see the same timestamps as on-call India.
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

// Backend returns YAML; legacy records may still be (double-encoded) JSON — convert those to YAML.
const formatDiff = (raw: string): string => {
  if (!raw) return '';
  const trimmed = raw.trim();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    try {
      let data = raw;
      try {
        const firstParse = JSON.parse(data);
        if (typeof firstParse === 'string') data = firstParse;
        else return YAML.stringify(firstParse, { indent: 2 });
      } catch { /* not a JSON string wrapper */ }
      const parsed = JSON.parse(data);
      return YAML.stringify(parsed, { indent: 2 });
    } catch { /* fall through — treat as YAML */ }
  }
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
          <div className="border border-zinc-200 rounded-md -mx-4 sm:mx-0 max-h-96 overflow-y-auto overflow-x-auto">
            <table className="w-full text-sm text-left border-collapse">
              <thead className="sticky top-0 z-10">
                <tr className="bg-zinc-50 border-b border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider shadow-[0_1px_0_rgb(228_228_231)]">
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

const RolloutStrategyTab: React.FC<{
  releaseId: string;
  strategy: RolloutStrategyEvent[];
  historyLength: number;
  status: string;
  appGroup: string;
}> = ({ releaseId, strategy, historyLength, status, appGroup }) => {
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
            podCount: s.pods,
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
            <PermissionGate product="autopilot" permission="RELEASE_UPDATE" appGroup={appGroup}>
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

/**
 * Mobile-only summary panel rendered when the release category is
 * 'MobileBuild'. Mobile releases don't have K8s pods/diff/strategy, so
 * the regular summary cards (PodHealth, Rollout etc.) are skipped above
 * and this section takes their place.
 *
 * Source of fields:
 *   - The release's `release_context` and `metadata` (loose JSON blobs)
 *     may contain dispatch/run identifiers populated by the mobile
 *     workflow as it progresses.
 *   - `tracker_type` ('MobileBuild') gates rendering.
 *   - The fine-grained `MobileBuildWFStatus` event timeline is derived
 *     from the BUSINESS-category events in the release event log
 *     (GH_DISPATCHED / RUN_ID_RESOLVED / MATRIX_JOB_UPDATED / TAG_PUSHED
 *     etc.) — we filter them and render in chronological order.
 *
 * Each block hides itself if its source field is missing — so a freshly
 * created mobile release that hasn't been dispatched yet shows only the
 * basic header + the (empty) timeline.
 */
const formatShortDate = (d: string) => {
  const date = new Date(d);
  if (isNaN(date.getTime())) return '';
  return date.toLocaleDateString('en-IN', { month: 'short', day: '2-digit' });
};

const PrevBuildBadge = ({ build, label, platform }: { build: LatestBuild; label: string; platform?: string }) => {
  // Show the store track (prod / internal / testflight) over the generic "RELEASE"
  // label. Pre-store_track rows fall back by platform: iOS = TestFlight, Android = prod.
  const track =
    build.track ?? (label === 'release' ? (platform === 'ios' ? 'testflight' : 'production') : null);
  const trackLabel =
    track === 'production'
      ? 'prod'
      : track === 'internal'
        ? 'internal'
        : track === 'testflight'
          ? 'testflight'
          : null;
  const isLive = track === 'production';
  const display = label === 'debug' ? label : trackLabel ?? label;
  return (
    <span
      className={cn(
        'inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium',
        label === 'debug'
          ? 'bg-amber-50 text-amber-700 border border-amber-200'
          : trackLabel && !isLive
            ? 'bg-sky-50 text-sky-700 border border-sky-200'
            : 'bg-emerald-50 text-emerald-700 border border-emerald-200',
      )}
    >
      <span className="uppercase">{display}</span>
      <span className="font-mono">v{build.version}</span>
      {build.versionCode != null && (
        <span className="text-[9px] opacity-70">{formatBuildCode(build.versionCode)}</span>
      )}
      {build.completedAt && (
        <span className="opacity-60">{formatShortDate(build.completedAt)}</span>
      )}
    </span>
  );
};

const MobileReleaseDetailSection: React.FC<{
  release: any;
  events: RolloutEvent[];
}> = ({ release, events }) => {
  const { data: apps = [] } = useMobileApps();
  // The mobile workflow stores fine-grained state in the `target_state`
  // column on the backend, but the public ReleaseTracker JSON doesn't
  // expose that field. Both `release_context` and `metadata` may carry
  // workflow-populated breadcrumbs (run_id, tag_pushed, matrix job
  // status, dispatched workflow URL); read defensively from either.
  const ctx = release.release_context || {};
  const meta = release.metadata || {};

  const ghRunUrl: string | undefined =
    meta.github_run_url ||
    meta.gh_run_url ||
    meta.expected_run_url ||
    ctx.github_run_url ||
    ctx.expected_run_url;
  const matrixJobStatus: string | undefined =
    meta.matrix_job_status || ctx.matrix_job_status || ctx.mb_matrix_job_status;
  const tagPushed: string | undefined =
    meta.tag_pushed || ctx.tag_pushed || ctx.mbc_tag_pushed;
  // The MobileBuildContext stores GitHub repo on the AppCatalog row, not
  // on the release. We surface it from the metadata fallback only. If
  // neither field is present, the tag link is rendered as plain text.
  const githubRepo: string | undefined = meta.github_repo || ctx.github_repo;

  // Workflow-stage event timeline. We pick up any BUSINESS-category
  // event the mobile workflow is known to log, in the order they were
  // emitted. New labels added on the backend appear here automatically
  // because the filter is permissive (label-prefix match).
  const MOBILE_LABELS = new Set([
    'GH_DISPATCHED',
    'RUN_ID_RESOLVED',
    'MATRIX_JOB_UPDATED',
    'STORE_SUBMITTED',
    'TAG_PUSHED',
    'BUILD_STARTED',
    'BUILD_COMPLETED',
    'MOBILE_RELEASE_CREATED',
  ]);
  const stageEvents = events
    .filter(
      e =>
        MOBILE_LABELS.has(e.label) ||
        e.label?.startsWith('MB_') ||
        e.label?.startsWith('MOBILE_'),
    )
    .sort((a, b) => a.timestamp.localeCompare(b.timestamp));

  const matchedApp = apps.find(
    a => a.name === release.appGroup && a.surface === release.service && a.platform === release.env,
  );

  const matrixVariant = (s?: string): 'success' | 'warning' | 'danger' | 'default' | 'muted' => {
    if (!s) return 'muted';
    const lc = s.toLowerCase();
    if (lc === 'success' || lc === 'completed' || lc === 'passed') return 'success';
    if (lc === 'in_progress' || lc === 'running' || lc === 'queued' || lc === 'pending') return 'warning';
    if (lc === 'failure' || lc === 'failed' || lc === 'cancelled' || lc === 'timed_out') return 'danger';
    return 'default';
  };

  return (
    <div className="border border-zinc-200 rounded-lg p-4 mb-6">
      <h3 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider mb-3">Mobile Build</h3>

      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-4 sm:gap-x-6 gap-y-3 mb-4">
        <div>
          <div className="text-[11px] font-medium text-zinc-500 uppercase tracking-wider mb-1">App</div>
          <div className="border border-zinc-100 rounded-lg px-3 py-2 bg-zinc-50 text-sm min-h-[38px] break-all">{release.appGroup || '-'}</div>
        </div>
        <div>
          <div className="text-[11px] font-medium text-zinc-500 uppercase tracking-wider mb-1">Surface</div>
          <div className="border border-zinc-100 rounded-lg px-3 py-2 bg-zinc-50 text-sm min-h-[38px] break-all">{release.service || '-'}</div>
        </div>
        <div>
          <div className="text-[11px] font-medium text-zinc-500 uppercase tracking-wider mb-1">Platform</div>
          <div className="border border-zinc-100 rounded-lg px-3 py-2 bg-zinc-50 text-sm min-h-[38px] break-all">{release.env || '-'}</div>
        </div>
        <div>
          <div className="text-[11px] font-medium text-zinc-500 uppercase tracking-wider mb-1">Version</div>
          <div className="border border-zinc-100 rounded-lg px-3 py-2 bg-zinc-50 text-sm font-mono text-xs min-h-[38px] break-all">{versionWithBuild(release) || '-'}</div>
        </div>
        <div>
          <div className="text-[11px] font-medium text-zinc-500 uppercase tracking-wider mb-1">Matrix Job Status</div>
          <div className="min-h-[38px] flex items-center">
            <Badge variant={matrixVariant(matrixJobStatus)} size="sm">
              {matrixJobStatus || 'pending'}
            </Badge>
          </div>
        </div>
        {ghRunUrl && (
          <div>
            <div className="text-[11px] font-medium text-zinc-500 uppercase tracking-wider mb-1">GitHub Workflow Run</div>
            <a
              href={ghRunUrl}
              target="_blank"
              rel="noopener"
              className="inline-flex items-center gap-1.5 text-sm text-blue-700 hover:underline border border-zinc-100 rounded-lg px-3 py-2 bg-zinc-50 min-h-[38px] break-all"
            >
              <ExternalLink className="w-3.5 h-3.5 shrink-0" />
              <span className="truncate">{ghRunUrl}</span>
            </a>
          </div>
        )}
        {tagPushed && (
          <div>
            <div className="text-[11px] font-medium text-zinc-500 uppercase tracking-wider mb-1">Pushed Tag</div>
            {githubRepo ? (
              <a
                href={`https://github.com/${githubRepo}/releases/tag/${encodeURIComponent(tagPushed)}`}
                target="_blank"
                rel="noopener"
                className="inline-flex items-center gap-1.5 text-sm text-blue-700 hover:underline border border-zinc-100 rounded-lg px-3 py-2 bg-zinc-50 font-mono text-xs min-h-[38px] break-all"
              >
                <ExternalLink className="w-3.5 h-3.5 shrink-0" />
                {tagPushed}
              </a>
            ) : (
              <div className="border border-zinc-100 rounded-lg px-3 py-2 bg-zinc-50 text-sm font-mono text-xs min-h-[38px] break-all">{tagPushed}</div>
            )}
          </div>
        )}
        {release.sourceRef && (
          <div>
            <div className="text-[11px] font-medium text-zinc-500 uppercase tracking-wider mb-1">Source Branch</div>
            <div className="inline-flex items-center gap-1.5 border border-zinc-100 rounded-lg px-3 py-2 bg-zinc-50 text-sm font-mono text-xs min-h-[38px] break-all">
              <GitBranch className="w-3.5 h-3.5 text-zinc-400 shrink-0" />
              {release.sourceRef}
            </div>
          </div>
        )}
      </div>

      {matchedApp && (matchedApp.latestReleaseBuild || matchedApp.latestDebugBuild) && (
        <div className="flex items-center gap-2 flex-wrap mt-1 mb-3">
          <span className="text-[11px] font-medium text-zinc-500 uppercase tracking-wider">Latest builds:</span>
          {matchedApp.latestReleaseBuild && (
            <PrevBuildBadge build={matchedApp.latestReleaseBuild} label="release" platform={matchedApp.platform} />
          )}
          {matchedApp.latestDebugBuild && (
            <PrevBuildBadge build={matchedApp.latestDebugBuild} label="debug" platform={matchedApp.platform} />
          )}
        </div>
      )}

      {release.env === 'ios' && release.status === 'COMPLETED' && (
        <div className="mt-4 rounded-lg border border-blue-100 bg-blue-50 px-4 py-3 text-xs text-blue-900 leading-relaxed">
          <strong className="font-semibold">iOS note:</strong>{' '}
          This build is now uploaded to App Store Connect. Apple's processing
          typically takes 5–30 min before it appears in TestFlight.
        </div>
      )}

      <div className="mt-4">
        <h4 className="text-[11px] font-semibold text-zinc-500 uppercase tracking-wider mb-2">Workflow Stages</h4>
        {stageEvents.length === 0 ? (
          <p className="text-xs text-zinc-400">No workflow stage events recorded yet.</p>
        ) : (
          <ol className="space-y-1.5">
            {stageEvents.map((evt, idx) => (
              <li key={idx} className="flex items-start gap-3 text-xs">
                <span className="inline-block w-1.5 h-1.5 rounded-full bg-violet-500 mt-1.5 shrink-0" />
                <span className="font-mono text-zinc-500 whitespace-nowrap">{formatDate(evt.timestamp)}</span>
                <span className="font-mono text-zinc-800 font-medium">{evt.label}</span>
              </li>
            ))}
          </ol>
        )}
      </div>
    </div>
  );
};

const ReleaseSummary: React.FC = () => {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const [activeTab, setActiveTab] = useState<'summary' | 'events' | 'env-diff' | 'json'>('summary');
  const [showABModal, setShowABModal] = useState(false);

  const { data: release, isLoading, isFetching, error, refetch } = useRelease(id);

  const { data: events = [] } = useReleaseEvents(id);
  const qc = useQueryClient();
  const { user: authUser } = useAuth();
  const actor = authUser?.email || 'admin';
  const doRefresh = useCallback(async () => {
    await Promise.all([
      refetch(),
      qc.invalidateQueries({ queryKey: ['release-events', id] }),
      qc.invalidateQueries({ queryKey: ['release-pods', id] }),
      qc.invalidateQueries({ queryKey: ['release-resources', id] }),
    ]);
  }, [refetch, qc, id]);
  const { spinning: refreshSpinning, onRefresh: handleRefresh } = useRefreshAnimation(isFetching, doRefresh);

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
  const rolloutRestartMut = useRolloutRestartDeployment();
  const fastForwardMut = useFastForwardRelease();
  // Mobile promote→rollout detail, used to derive the top-level status badge +
  // gate the rollout-runner action buttons. `enabled` is read off the (possibly
  // still-loading) release so the hook stays above the early returns; it shares
  // the ['mobile-rollout', id] cache with the rollout panel below (deduped).
  const rolloutQ = useMobileRollout(id, release?.tracker_type === 'MobileBuild');
  const immRevertSyncMut = useImmediateRevertWithSync();
  const updateTrackerMut = useUpdateTracker();
  const dispatchMobileMut = useDispatchMobileReleases();
  const { data: mobileApps = [] } = useMobileApps();

  const confirmAction = useConfirm();

  const KIBANA_URL = import.meta.env.VITE_KIBANA_URL || '';
  const KIALI_URL = import.meta.env.VITE_KIALI_URL || '';
  const GRAFANA_URL = import.meta.env.VITE_GRAFANA_URL || '';

  const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

  // `label` is a short verb ("approve", "fast forward") used as title/confirm label;
  // `description` overrides the generic confirmation body for action-specific wording.
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
      // Safety net — individual mutations fire their own error toasts.
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
    // ENV diff is K8s-specific (compares deployment YAML before/after).
    // Mobile builds don't deploy YAML, so hide the tab for them.
    ...(release.tracker_type === 'MobileBuild'
      ? []
      : [{ key: 'env-diff' as const, label: 'ENV Diff' }]),
    { key: 'json' as const, label: 'JSON Data' },
  ];

  const dockerImage = release.docker_image || release.release_context?.docker_image || '';
  const category = release.tracker_type || '';
  const releaseTag = release.release_tag || '';
  const globalId = release.global_id || '';
  const newService = release.new_service;
  const cronjobSuspend = release.cronjob_suspend;

  // Mobile-revert derived values. State for the modal is declared near
  // the other useState calls above so it lives ABOVE the !release
  // early-return (rules of hooks). These are pure reads of `release`.
  const isMobile = category === 'MobileBuild';

  // Operator-facing badge for a mobile release in the promote→rollout lifecycle.
  // We override the raw engine status only when it's the misleading one —
  // INPROGRESS (nothing's progressing — it's awaiting a human; and it is NOT a
  // "pause") — or for a promotable store-sync snapshot (a COMPLETED row that can
  // still be promoted). Terminal states (ABORTED/REVERTED/DISCARDED) and a
  // genuinely-building release keep their truthful raw StatusBadge, so an aborted
  // row left at MBTagPushed never reads "Ready to promote".
  const rollout = isMobile ? rolloutQ.data : undefined;
  // An internal/TestFlight snapshot is only "promotable" when the BACKEND says so
  // (rdPromotable) — i.e. not already live on production. Otherwise it's not offered the
  // promote flow and the header doesn't read "Ready to promote".
  const isPromotableSnapshot =
    (rollout?.rdStoreTrack === 'internal' || rollout?.rdStoreTrack === 'testflight') &&
    !!rollout?.rdPromotable;
  // The one canonical backend displayStatus (rollout.rdStatusLabel) — null while the
  // build is still 'building' so the generic runner controls stay shown until it's
  // sitting on the store (same behaviour the old mobileDisplayStatus null gave).
  const mobileStatus =
    rollout && (s === 'INPROGRESS' || isPromotableSnapshot) && rollout.rdPhase !== 'building'
      ? { label: rollout.rdStatusLabel, variant: rollout.rdStatusVariant }
      : null;
  // While the build sits in a lifecycle stage, the generic Pause / Fast-Forward
  // (rollout-runner) controls don't apply — the real action is Promote/Rollout in
  // the Store panel.
  const inMobileLifecycle = !!mobileStatus;

  const matchedMobileApp = isMobile
    ? mobileApps.find(
        a => a.name === release.appGroup && a.surface === release.service && a.platform === release.env,
      )
    : undefined;
  const crashlyticsUrl = (() => {
    if (!isMobile) return '';
    const fbProject = matchedMobileApp?.firebaseProjectId || '_';
    const pkg = matchedMobileApp?.packageName;
    const platform = release.env;
    const version = release.new_version;
    const versionCode = release.release_context?.version_code;
    if (pkg && platform) {
      const base = `https://console.firebase.google.com/project/${fbProject}/crashlytics/app/${platform}:${pkg}/issues`;
      const params = new URLSearchParams({ state: 'open', time: '7d', types: 'crash', tag: 'all', sort: 'eventCount' });
      if (version && versionCode) {
        params.set('versions', `${version} (${versionCode})`);
      }
      return `${base}?${params.toString()}`;
    }
    return `https://console.firebase.google.com/project/${fbProject}/crashlytics`;
  })();

  // Revert-chain banner data (mobile-only for now; backend revert uses
  // a different mechanism). `revertsReleaseId` = "this row IS a revert
  // of X"; `metadata.reverted_by` = "X has been reverted by this row".
  const revertsTarget = release.revertsReleaseId || null;
  const revertedByTarget = release.metadata?.reverted_by || null;

  return (
    <div className="flex flex-col flex-1 w-full pb-12">
      <div className="flex items-center text-sm text-zinc-500 font-medium mb-3 sm:mb-4 flex-wrap gap-y-1">
        <Link to={isMobile ? '/mobile/releases' : '/backend/releases'} className="hover:text-zinc-700 transition-colors duration-150">Releases</Link>
        <ChevronRightIcon className="w-4 h-4 mx-1 text-zinc-300 shrink-0" />
        <span className="text-zinc-600">{release.release_context?.cluster || release.env || ''}</span>
        <ChevronRightIcon className="w-4 h-4 mx-1 text-zinc-300 shrink-0" />
        <span className="font-mono text-xs text-zinc-800 truncate max-w-[150px] sm:max-w-[200px]">{release.release_tag || id}</span>
        {!isMobile && (s === 'CREATED' || s === 'INPROGRESS' || s === 'PAUSED') && (
          <PermissionGate product="autopilot" permission="RELEASE_UPDATE" appGroup={release.appGroup}>
            <button
              onClick={() => navigate(`/backend/releases/${id}/edit`)}
              className="p-1 ml-1 rounded text-zinc-400 hover:text-zinc-700 hover:bg-zinc-100 transition-colors duration-150 cursor-pointer"
              aria-label="Edit release"
            >
              <Pencil className="w-3.5 h-3.5" />
            </button>
          </PermissionGate>
        )}
      </div>

      {/* Revert-chain banners (mobile). These render above the title so the
          relationship between bad/revert releases is the first thing operators
          see when triaging. */}
      {isMobile && revertsTarget && (
        <div className="mb-3 rounded-lg border border-violet-200 bg-violet-50 px-4 py-2.5 text-xs text-violet-900 flex items-center gap-2">
          <Undo2 className="w-4 h-4 shrink-0 text-violet-600" />
          <span>
            This is a revert of release{' '}
            <Link
              to={`/mobile/releases/${revertsTarget}`}
              className="font-mono font-medium hover:underline"
            >
              {revertsTarget.slice(0, 8)}
            </Link>
            {release.commitSha && (
              <>
                . Built from commit{' '}
                <code className="font-mono">{release.commitSha.slice(0, 7)}</code>.
              </>
            )}
          </span>
        </div>
      )}
      {isMobile && revertedByTarget && (
        <div className="mb-3 rounded-lg border border-amber-200 bg-amber-50 px-4 py-2.5 text-xs text-amber-900 flex items-center gap-2">
          <ArrowUpRight className="w-4 h-4 shrink-0 text-amber-600" />
          <span>
            This release was reverted by{' '}
            <Link
              to={`/mobile/releases/${revertedByTarget}`}
              className="font-mono font-medium hover:underline"
            >
              {revertedByTarget.slice(0, 8)}
            </Link>
            .
          </span>
        </div>
      )}

      <div className="flex flex-col gap-3 mb-4 sm:mb-5">
        <div className="flex items-center gap-2 sm:gap-3 flex-wrap">
          {isMobile && (
            <BrandLogo
              brand={release.appGroup || ''}
              surface={release.service === 'driver' ? 'driver' : undefined}
              size="lg"
            />
          )}
          <div className="flex flex-col">
            <span className="text-[10px] font-semibold uppercase tracking-wider text-zinc-400">Release Summary</span>
            <h1 className="text-lg sm:text-xl font-semibold text-zinc-900 flex items-baseline gap-2 flex-wrap">
              <span>{release.appGroup || 'Release'}</span>
              {release.service && <span className="text-sm font-normal text-zinc-400">{release.service}</span>}
              {versionWithBuild(release) && (
                <span className="font-mono text-base font-medium text-zinc-500">v{versionWithBuild(release)}</span>
              )}
            </h1>
          </div>
          {mobileStatus ? (
            <Badge variant={mobileStatus.variant} dot>{mobileStatus.label}</Badge>
          ) : (
            <StatusBadge status={release.status} />
          )}
          {/* Store track (Internal / TestFlight / Production) — surfaces which track the
              build sits on, e.g. an un-promotable internal build below production. */}
          {isMobile && rollout?.rdStoreTrack && (
            <Badge
              variant={
                rollout.rdStoreTrack === 'production'
                  ? 'success'
                  : rollout.rdStoreTrack === 'testflight'
                    ? 'info'
                    : 'blue'
              }
            >
              {rollout.rdStoreTrack === 'production'
                ? 'Production'
                : rollout.rdStoreTrack === 'testflight'
                  ? 'TestFlight'
                  : 'Internal'}
            </Badge>
          )}
          {isFirebaseInternal(release) && <FirebaseInternalBadge />}
          {(release.release_context?.revert === 1 || revertsTarget) && <Badge variant="purple" dot>REVERT</Badge>}
          {isMobile && release.release_context?.build_type === 'debug' && (
            <Badge variant="warning" dot>DEBUG</Badge>
          )}
          {/* AB validation is a backend-release concept (canary / A-B rollout
              health) — it does not apply to mobile builds, so hide the whole
              block (status badges + the "AB Validate" action) when isMobile. */}
          {!isMobile && (
            <>
              {release.ab_hs_status && release.ab_hs_status !== 'Uninitiated' && <Badge variant="info">AB: {release.ab_hs_status}</Badge>}
              {release.abValidationStatus && release.abValidationStatus !== 'UNASSIGNED' && (
                <span className={cn('px-2 py-0.5 rounded text-xs font-medium', AB_STATUS_COLORS[release.abValidationStatus as ABValidationStatus])}>
                  {AB_STATUS_LABELS[release.abValidationStatus as ABValidationStatus] ?? release.abValidationStatus}
                </span>
              )}
              <PermissionGate product="autopilot" permission="AB_VALIDATION_EDIT" appGroup={release.appGroup}>
                <button
                  onClick={() => setShowABModal(true)}
                  className="text-xs text-zinc-500 border border-zinc-200 rounded px-2 py-1 hover:bg-zinc-50"
                >
                  AB Validate
                </button>
              </PermissionGate>
            </>
          )}
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
          {/* Crashlytics is production telemetry — only meaningful for release
              builds. Debug (Firebase/TestFlight) builds don't report to it. */}
          {isMobile && release.release_context?.build_type !== 'debug' && (
            <a
              href={crashlyticsUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="text-xs font-medium text-white bg-orange-500 hover:bg-orange-600 rounded-md px-2.5 py-1 inline-flex items-center gap-1.5 transition-colors duration-150 shadow-sm"
            >
              <Flame className="w-3.5 h-3.5" />
              Crashlytics
              {matchedMobileApp?.packageName && (
                <span className="opacity-80 font-normal">· {versionWithBuild(release) || release.appGroup}</span>
              )}
              <ExternalLink className="w-3 h-3 opacity-70" />
            </a>
          )}
        </div>
        <div className="flex items-center gap-2 flex-wrap sm:justify-end">
          {s === 'CREATED' && release.is_approved === 0 && (
            <PermissionGate product="autopilot" permission="RELEASE_APPROVE" appGroup={release.appGroup}>
              <Button size="sm" variant="success" loading={approveMut.isPending} onClick={() => doAction('approve', () => approveMut.mutateAsync({ releaseId: id!, approvedBy: actor }))}><Check className="w-3.5 h-3.5" /> Approve</Button>
            </PermissionGate>
          )}
          {s === 'CREATED' && isMobile && !!release.is_approved && (
            <PermissionGate product="autopilot" permission="MOBILE_DISPATCH" appGroup={release.appGroup}>
              <Button size="sm" variant="outline" className="border-emerald-300 text-emerald-700 hover:bg-emerald-50" loading={dispatchMobileMut.isPending} onClick={() => doAction('dispatch', () => dispatchMobileMut.mutateAsync([id!]), false, 'This will dispatch the GitHub workflow for this release. The runner will pick it up and start the build.')}><Send className="w-3.5 h-3.5" /> Dispatch</Button>
            </PermissionGate>
          )}
          {s === 'CREATED' && (
            <PermissionGate product="autopilot" permission="RELEASE_DISCARD" appGroup={release.appGroup}>
              <Button size="sm" variant="outline" className="border-red-300 text-red-700 hover:bg-red-50" loading={discardMut.isPending} onClick={() => doAction('discard', () => discardMut.mutateAsync({ releaseId: id! }), true)}><X className="w-3.5 h-3.5" /> Discard</Button>
            </PermissionGate>
          )}
          {(s === 'INPROGRESS') && (
            <>
              <PermissionGate product="autopilot" permission="RELEASE_PAUSE" appGroup={release.appGroup}>
                {/* Pause/Fast-Forward are rollout-runner controls. They don't apply
                    to a mobile build held on the store awaiting Promote — the real
                    action lives in the Store release panel below. Abort stays
                    (cancel the release). */}
                {!inMobileLifecycle && (
                  <Button size="sm" variant="outline" className="border-amber-300 text-amber-700 hover:bg-amber-50" loading={pauseMut.isPending} onClick={() => doAction('pause', () => pauseMut.mutateAsync(id!))}><Pause className="w-3.5 h-3.5" /> Pause</Button>
                )}
                {/* Abort visibility is BE-driven (rdAbortable): shown only while the
                    build is still Building. A rejected / on-store / terminal build can't
                    be un-shipped, so Abort is hidden. Non-mobile keeps the INPROGRESS rule. */}
                {(!isMobile || !!rollout?.rdAbortable) && (
                  <Button size="sm" variant="danger" loading={abortMut.isPending} onClick={() => doAction('abort', () => abortMut.mutateAsync(id!), true)}><Square className="w-3.5 h-3.5" /> Abort</Button>
                )}
              </PermissionGate>
              {!isMobile && (
                <PermissionGate product="autopilot" permission="RELEASE_UPDATE" appGroup={release.appGroup}>
                  <Button size="sm" variant="outline" className="border-amber-300 bg-amber-600 text-white hover:bg-amber-700" loading={fastForwardMut.isPending} onClick={() => doAction('fast forward', () => fastForwardMut.mutateAsync(id!), false, 'Skip the current cooloff and advance to the next rollout step. The runner will pick up the change on its next poll.')}><FastForward className="w-3.5 h-3.5" /> Fast Forward</Button>
                </PermissionGate>
              )}
            </>
          )}
          {s === 'PAUSED' && (
            <PermissionGate product="autopilot" permission="RELEASE_RESUME" appGroup={release.appGroup}>
              <Button size="sm" className="bg-blue-600 text-white hover:bg-blue-700" loading={resumeMut.isPending} onClick={() => doAction('resume', () => resumeMut.mutateAsync(id!))}><Play className="w-3.5 h-3.5" /> Resume</Button>
              <Button size="sm" variant="danger" loading={abortMut.isPending} onClick={() => doAction('abort', () => abortMut.mutateAsync(id!), true)}><Square className="w-3.5 h-3.5" /> Abort</Button>
            </PermissionGate>
          )}
          {s === 'COMPLETED' && !isMobile && (
            <>
              <PermissionGate product="autopilot" permission="RELEASE_REVERT" appGroup={release.appGroup}>
                <Button size="sm" variant="outline" className="border-violet-300 text-violet-700 hover:bg-violet-50" loading={revertMut.isPending} onClick={() => doAction('revert', () => revertMut.mutateAsync({ releaseId: id!, requestedBy: actor, isRevertSync: revertSyncChecked }), true)}><RotateCcw className="w-3.5 h-3.5" /> Revert</Button>
              </PermissionGate>
              <PermissionGate product="autopilot" permission="RELEASE_REVERT" appGroup={release.appGroup}>
                {release.env_override_data ? (
                  <SimpleTooltip content="Immediate Revert is disabled when the release has env changes. Use normal Revert to restore env + image together.">
                    <Button size="sm" variant="danger" disabled><Zap className="w-3.5 h-3.5" /> Immediate Revert</Button>
                  </SimpleTooltip>
                ) : (
                  <Button size="sm" variant="danger" loading={immRevertSyncMut.isPending} onClick={doImmediateRevert}><Zap className="w-3.5 h-3.5" /> Immediate Revert</Button>
                )}
              </PermissionGate>
              {/* Single shared "Also revert in other cloud" checkbox — applies to both
                  Revert and Immediate Revert. Only meaningful when the original
                  release had sync_enabled, but always shown so operators can opt in
                  consistently across the two buttons. */}
              <PermissionGate product="autopilot" permission="RELEASE_REVERT" appGroup={release.appGroup}>
                <label className="flex items-center gap-1.5 text-xs text-zinc-500 cursor-pointer">
                  <input type="checkbox" checked={revertSyncChecked} onChange={(e) => setRevertSyncChecked(e.target.checked)} className="rounded border-zinc-300 accent-zinc-900" />
                  Also revert in other cloud
                </label>
              </PermissionGate>
              <PermissionGate product="autopilot" permission="RELEASE_UPDATE" appGroup={release.appGroup}>
                <Button size="sm" variant="outline" className="border-blue-300 text-blue-700 hover:bg-blue-50" loading={rolloutRestartMut.isPending} onClick={() => doAction('restart deployment', () => rolloutRestartMut.mutateAsync({ releaseId: id!, requestedBy: actor }), false, 'This will perform a kubectl rollout restart on the current deployment, bouncing all pods. Use this to pick up new secrets/configmaps or recover from pod crashes.')}>
                  <RotateCw className="w-3.5 h-3.5" /> Restart Deployment
                </Button>
              </PermissionGate>
            </>
          )}
          {/* Mobile releases use a dedicated revert flow: opens a modal,
              loads a draft from the BE, lets the operator review the
              previous-good commit + auto-generated changelog, and POSTs
              a new release row with source_ref pointing at the previous
              good tag. The K8s-specific "Immediate Revert" and
              "Also revert in other cloud" controls don't apply. */}
          {s === 'COMPLETED' && isMobile && !revertedByTarget
            && !revertsTarget
            && release.release_context?.build_type !== 'debug' && (
            <PermissionGate product="autopilot" permission="RELEASE_REVERT" appGroup={release.appGroup}>
              <Button
                size="sm"
                variant="outline"
                className="border-violet-300 text-violet-700 hover:bg-violet-50"
                onClick={() => navigate(`/mobile/releases/${id}/revert`)}
              >
                <Undo2 className="w-3.5 h-3.5" /> Revert
              </Button>
            </PermissionGate>
          )}
          {/* Restart is backend-only: it restarts a k8s Deployment. Mobile builds
              are GitHub Actions runs with no k8s deployment, so the endpoint fails
              for them — hide it until a mobile restart (re-dispatch) is built.
              See docs/MOBILE_RELEASE_FUTURE_SCOPE.md → "Mobile build restart". */}
          {!isMobile && (s === 'ABORTED' || s === 'USER_ABORTED' || s === 'GCLT_ABORTED' || s === 'REVERTED') && (
            <PermissionGate product="autopilot" permission="RELEASE_CREATE" appGroup={release.appGroup}>
              <Button size="sm" variant="outline" className="border-blue-300 text-blue-700 hover:bg-blue-50" loading={restartMut.isPending} onClick={() => doAction('restart', () => restartMut.mutateAsync(id!))}><RotateCw className="w-3.5 h-3.5" /> Restart</Button>
            </PermissionGate>
          )}

          <div className="w-px h-6 bg-zinc-200 mx-1" />
          <PermissionGate product="autopilot" permission="RELEASE_DELETE" appGroup={release.appGroup}>
            <SimpleTooltip content="Delete"><Button size="icon" variant="ghost" className="text-red-500 hover:bg-red-50" loading={deleteMut.isPending} onClick={() => doAction('delete', async () => { await deleteMut.mutateAsync(id!); navigate(isMobile ? '/mobile/releases' : '/backend/releases'); }, true, 'Delete this release tracker permanently. This removes the audit trail and cannot be undone.')}><Trash2 className="w-4 h-4" /></Button></SimpleTooltip>
          </PermissionGate>
          {!isMobile && <SimpleTooltip content="Clone"><Button size="icon" variant="ghost" onClick={() => navigate(`/backend/releases/${id}/clone`)}><Copy className="w-4 h-4" /></Button></SimpleTooltip>}
          <SimpleTooltip content="Refresh"><Button size="icon" variant="ghost" onClick={handleRefresh} aria-label="Refresh"><RefreshCw className={`w-4 h-4 ${refreshSpinning ? 'animate-spin' : ''}`} /></Button></SimpleTooltip>
        </div>
      </div>

      <div className="bg-white rounded-xl border border-zinc-200">
        <div className="flex border-b border-zinc-200 px-2 sm:px-5 overflow-x-auto">
          {tabs.map(tab => (
            <button key={tab.key} onClick={() => setActiveTab(tab.key)}
              className={cn('py-3 px-3 sm:px-4 text-sm font-medium border-b-2 transition-colors duration-150 cursor-pointer whitespace-nowrap', activeTab === tab.key ? 'border-zinc-900 text-zinc-900' : 'border-transparent text-zinc-400 hover:text-zinc-600')}>
              {tab.label}
            </button>
          ))}
        </div>

        {activeTab === 'summary' && (
          <div className="p-4 sm:p-6">
            {/* AI panel is a mobile PROD-build feature only — hidden for mobile
                debug builds and for backend (non-mobile) releases. */}
            {isMobile && release.release_context?.build_type !== 'debug' && (
              <div className="mb-6">
                <AiReleasePanel releaseId={id!} />
              </div>
            )}
            {/* Promote-to-review + staged-rollout controls. Self-hiding when
                staged rollout is disabled or the build isn't done — release
                (non-debug) mobile builds only. */}
            {isMobile && release.release_context?.build_type !== 'debug' && (
              <div className="mb-6">
                <MobileRolloutPanel
                  releaseId={id!}
                  aiNotes={{
                    app: release.appGroup,
                    surface: release.service,
                    platform: release.env,
                    branch: release.sourceRef || 'main',
                    versionName: release.new_version,
                    // Match the create-time AI-summary cache key: iOS had no build
                    // code yet (workflow assigns it), so its summary was keyed with
                    // an empty code; Android used the entered code.
                    versionCode:
                      release.env === 'ios'
                        ? ''
                        : release.release_context?.version_code != null
                          ? String(release.release_context.version_code)
                          : '',
                  }}
                />
              </div>
            )}
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
                    { label: 'Approved By', value: release.is_approved ? (release.approved_by || release.release_manager || '-') : '-' },
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

            {/* Mobile releases skip the K8s-specific summary blocks. They have
                no pods, no rollout strategy, no env diff — instead we show a
                workflow-stage timeline + GH run link below. The Release Details
                block at the bottom still renders for both categories. */}
            {category === 'MobileBuild' ? (
              <MobileReleaseDetailSection release={release} events={events} />
            ) : (
              <>
                <PodHealthSection releaseId={id!} release={release} />

                <RolloutHistoryInline history={release.rollout_history} />

                <RolloutStrategyTab
                  releaseId={id!}
                  strategy={release.rollout_strategy}
                  historyLength={release.rollout_history?.length || 0}
                  status={s}
                  appGroup={release.appGroup}
                />
              </>
            )}

            <div className="border border-zinc-200 rounded-lg p-4 mb-6">
              <h3 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider mb-4">Release Details</h3>
              <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-x-4 sm:gap-x-6 gap-y-3">
                {category === 'MobileBuild' ? (
                  <>
                    <InfoField label="App" value={release.appGroup} />
                    <InfoField label="Surface" value={release.service} />
                    <div>
                      <div className="text-[11px] font-medium text-zinc-500 uppercase tracking-wider mb-1">Platform</div>
                      <div className="border border-zinc-100 rounded-lg px-3 py-2 bg-zinc-50 text-sm min-h-[38px] flex items-center gap-2">
                        {release.env === 'android' ? (
                          <span className="inline-flex items-center gap-1.5 rounded px-2.5 py-1 text-[11px] font-bold uppercase tracking-wide bg-[#3DDC84]/15 text-[#1B8A4F] border border-[#3DDC84]/30">
                            <AndroidIcon className="w-3.5 h-3.5" />
                            Android
                          </span>
                        ) : release.env === 'ios' ? (
                          <span className="inline-flex items-center gap-1.5 rounded px-2.5 py-1 text-[11px] font-bold uppercase tracking-wide bg-zinc-500/15 text-zinc-700 border border-zinc-400/30">
                            <Apple className="w-3.5 h-3.5" />
                            iOS
                          </span>
                        ) : (
                          <span className="text-sm">{release.env || '-'}</span>
                        )}
                      </div>
                    </div>
                    <InfoField label="Version" value={versionWithBuild(release)} mono />
                  </>
                ) : (
                  <>
                    <InfoField label="App Group" value={release.appGroup} />
                    <InfoField label="Service" value={release.service} />
                    <InfoField label="Old Version" value={release.old_version} mono />
                    <InfoField label="New Version" value={release.new_version} mono />
                    <InfoField label="Docker Image" value={dockerImage} mono />
                  </>
                )}
                <InfoField label="Release Manager" value={release.release_manager || '-'} />
                <InfoField label="Infra Approved" value={release.is_infra_approved ? 'Yes' : 'No'} />
                {release.description && <InfoField label="Description" value={release.description} />}
                {release.change_log && <InfoField label="Change Log" value={release.change_log} />}
                {globalId && <InfoField label="Global ID" value={globalId} mono />}
              </div>
            </div>
          </div>
        )}

        {activeTab === 'events' && <ReleaseEventsTab events={events} />}

        {activeTab === 'env-diff' && <EnvDiffTab releaseId={id!} />}

        {activeTab === 'json' && (
          <div className="p-4 sm:p-6">
            <pre className="bg-zinc-50 border border-zinc-200 rounded-lg p-3 sm:p-4 text-[11px] sm:text-xs font-mono text-zinc-700 overflow-auto max-h-[600px] whitespace-pre-wrap break-all">
              {JSON.stringify(release, null, 2)}
            </pre>
          </div>
        )}
      </div>

      <div className="flex justify-end pt-5">
        <Button variant="secondary" onClick={() => navigate(isMobile ? '/mobile/releases' : '/backend/releases')}>Back to Releases</Button>
      </div>

      {showABModal && release && (
        <ABValidationModal
          releaseId={release.id}
          currentStatus={release.abValidationStatus ?? null}
          abValidation={release.abValidation ?? null}
          onClose={() => setShowABModal(false)}
        />
      )}
    </div>
  );
};

export default ReleaseSummary;
