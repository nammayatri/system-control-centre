import React, { useState } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import {
  useRelease, useReleaseEvents, useApproveRelease, useDiscardRelease,
  usePauseRelease, useResumeRelease, useAbortRelease, useRevertRelease,
  useImmediateRevert, useDeleteRelease, useRestartRelease,
  useFastForwardRelease, useImmediateRevertWithSync,
  useReleaseDiff, usePodHealth, useResources, useUpdateTracker,
} from '../hooks';
import type { RolloutHistoryEvent, RolloutEvent } from '../../../api';
import { StatusBadge, Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { CardSkeleton } from '../../../shared/ui/skeleton';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { SimpleTooltip } from '../../../shared/ui/tooltip';
import {
  Copy, RefreshCw, Play, Pause, Square, RotateCcw, Check, X, Zap,
  Search, Trash2, ChevronRight as ChevronRightIcon, FastForward, RotateCw,
  ExternalLink, Network, BarChart3, Pencil,
} from 'lucide-react';
import { cn } from '../../../lib/utils';
import { useConfirm } from '../../../shared/ui/confirm-dialog';
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogBody, DialogFooter } from '../../../shared/ui/dialog';
import { toast } from 'sonner';
import ReactDiffViewer from 'react-diff-viewer-continued';

const formatDate = (d?: string) => {
  if (!d) return '-';
  const date = new Date(d);
  return date.toLocaleString('en-US', { month: 'short', day: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: true });
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
    <div className="p-6">
      <div className="flex items-center justify-between mb-4">
        <h3 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider">Release Events</h3>
        <div className="relative">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-zinc-400" />
          <input type="text" placeholder="Filter events..." value={eventSearch} onChange={(e) => setEventSearch(e.target.value)}
            className="pl-8 pr-3 h-9 border border-zinc-300 rounded-lg text-sm w-56 focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150" />
        </div>
      </div>
      {sorted.length > 0 ? (
        <div className="overflow-x-auto">
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
// Pretty-print JSON string for diff viewer
const prettyJson = (raw: string): string => {
  if (!raw) return '';
  try {
    return JSON.stringify(JSON.parse(raw), null, 2);
  } catch {
    return raw;
  }
};

const EnvDiffTab: React.FC<{ releaseId: string }> = ({ releaseId }) => {
  const { data: diff, isLoading, error } = useReleaseDiff(releaseId);

  if (isLoading) return <div className="p-6"><div className="animate-pulse space-y-3"><div className="h-4 bg-zinc-100 rounded w-1/3" /><div className="h-64 bg-zinc-100 rounded" /></div></div>;
  if (error || !diff) return <div className="p-6"><p className="text-sm text-zinc-400">No diff data available.</p></div>;
  if (!diff.oldfile && !diff.newfile) return <div className="p-6"><p className="text-sm text-zinc-400">No diff data available.</p>{diff.message && <p className="text-xs text-zinc-400 mt-1">{diff.message}</p>}</div>;

  const oldFormatted = prettyJson(diff.oldfile);
  const newFormatted = prettyJson(diff.newfile);

  return (
    <div className="p-6">
      <div className="flex items-center justify-between mb-4">
        <h3 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider">Deployment Diff</h3>
        {diff.message && <span className="text-xs text-zinc-400">{diff.message}</span>}
      </div>
      <div className="border border-zinc-200 rounded-lg overflow-hidden">
        <ReactDiffViewer
          oldValue={oldFormatted}
          newValue={newFormatted}
          splitView={true}
          leftTitle="Before"
          rightTitle="After"
          useDarkTheme={false}
        />
      </div>
    </div>
  );
};

/** Pod Health Section (in Summary tab) */
const PodHealthSection: React.FC<{ releaseId: string }> = ({ releaseId }) => {
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
    <div className="border border-zinc-100 rounded-xl p-5 mb-6">
      <h3 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider mb-4">Pods</h3>
      <div className="grid grid-cols-4 gap-3 mb-4">
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
        <div className="overflow-x-auto">
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
                <tr key={pod.name} className={cn('border-b border-zinc-100', idx % 2 === 1 ? 'bg-zinc-50' : 'bg-white')}>
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
    <div className="border border-zinc-100 rounded-xl p-5">
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

const ReleaseSummary: React.FC = () => {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const [activeTab, setActiveTab] = useState<'summary' | 'history' | 'events' | 'env-diff' | 'json'>('summary');
  const [revertSyncChecked, setRevertSyncChecked] = useState(true);
  const [editOpen, setEditOpen] = useState(false);
  const [editForm, setEditForm] = useState({ description: '', change_log: '', priority: 0, mode: 'AUTO' });

  const { data: release, isLoading, error, refetch } = useRelease(id);
  const { data: events = [] } = useReleaseEvents(id);

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

  const doAction = async (label: string, fn: () => Promise<any>, isDanger = false) => {
    const ok = await confirmAction({
      title: `${label.charAt(0).toUpperCase() + label.slice(1)} Release`,
      description: `Are you sure you want to ${label} this release? This action cannot be undone.`,
      confirmLabel: label.charAt(0).toUpperCase() + label.slice(1),
      variant: isDanger ? 'danger' : 'primary',
    });
    if (!ok) return;
    try { await fn(); } catch {}
  };

  // Custom confirm for immediate revert with checkbox
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
    } catch {}
  };

  if (isLoading && !release) {
    return (
      <div className="flex flex-col flex-1 w-full pb-12 max-w-6xl space-y-6">
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
    { key: 'history' as const, label: 'Rollout History' },
    { key: 'events' as const, label: 'Events' },
    { key: 'env-diff' as const, label: 'ENV Diff' },
    { key: 'json' as const, label: 'JSON Data' },
  ];

  return (
    <div className="flex flex-col flex-1 w-full pb-12 max-w-6xl">
      {/* Breadcrumb */}
      <div className="flex items-center text-sm text-zinc-500 font-medium mb-4">
        <Link to="/releases" className="hover:text-zinc-700 transition-colors duration-150">Releases</Link>
        <ChevronRightIcon className="w-4 h-4 mx-1 text-zinc-300" />
        <span className="text-zinc-600">{release.release_context?.cluster || release.env || ''}</span>
        <ChevronRightIcon className="w-4 h-4 mx-1 text-zinc-300" />
        <span className="font-mono text-xs text-zinc-800 truncate max-w-[200px]">{release.release_tag || id}</span>
        <PermissionGate product="autopilot" permission="RELEASE_UPDATE">
          <button
            onClick={() => {
              setEditForm({
                description: release.description || '',
                change_log: release.change_log || '',
                priority: release.priority || 0,
                mode: release.mode || 'AUTO',
              });
              setEditOpen(true);
            }}
            className="p-1 rounded text-zinc-400 hover:text-zinc-700 hover:bg-zinc-100 transition-colors duration-150 cursor-pointer"
          >
            <Pencil className="w-3.5 h-3.5" />
          </button>
        </PermissionGate>
      </div>

      {/* Header */}
      <div className="flex items-center justify-between mb-5">
        <div className="flex items-center gap-3">
          <h1 className="text-lg font-semibold text-zinc-900">Release Summary</h1>
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
        <div className="flex items-center gap-2">
          {s === 'CREATED' && release.is_approved === 0 && (
            <PermissionGate product="autopilot" permission="RELEASE_APPROVE">
              <Button size="sm" variant="success" loading={approveMut.isPending} onClick={() => doAction('approve', () => approveMut.mutateAsync({ releaseId: id!, approvedBy: 'admin' }))}><Check className="w-3.5 h-3.5" /> Approve</Button>
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
                <Button size="sm" variant="outline" className="border-amber-300 bg-amber-600 text-white hover:bg-amber-700" loading={fastForwardMut.isPending} onClick={() => doAction('fast forward (skip current cooloff and advance to next rollout step)', () => fastForwardMut.mutateAsync(id!))}><FastForward className="w-3.5 h-3.5" /> Fast Forward</Button>
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
                <Button size="sm" variant="outline" className="border-violet-300 text-violet-700 hover:bg-violet-50" loading={revertMut.isPending} onClick={() => doAction('revert', () => revertMut.mutateAsync({ releaseId: id!, requestedBy: 'admin' }), true)}><RotateCcw className="w-3.5 h-3.5" /> Revert</Button>
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
            <SimpleTooltip content="Delete"><Button size="icon" variant="ghost" className="text-red-500 hover:bg-red-50" loading={deleteMut.isPending} onClick={() => doAction('delete this release', async () => { await deleteMut.mutateAsync(id!); navigate('/releases'); }, true)}><Trash2 className="w-4 h-4" /></Button></SimpleTooltip>
          </PermissionGate>
          <SimpleTooltip content="Clone"><Button size="icon" variant="ghost" onClick={() => navigate(`/releases/${id}/clone`)}><Copy className="w-4 h-4" /></Button></SimpleTooltip>
          <SimpleTooltip content="Refresh"><Button size="icon" variant="ghost" onClick={() => refetch()}><RefreshCw className="w-4 h-4" /></Button></SimpleTooltip>
        </div>
      </div>

      {/* Main Card with Tabs */}
      <div className="bg-white rounded-xl border border-zinc-200">
        <div className="flex border-b border-zinc-200 px-5">
          {tabs.map(tab => (
            <button key={tab.key} onClick={() => setActiveTab(tab.key)}
              className={cn('py-3 px-4 text-sm font-medium border-b-2 transition-colors duration-150 cursor-pointer', activeTab === tab.key ? 'border-zinc-900 text-zinc-900' : 'border-transparent text-zinc-400 hover:text-zinc-600')}>
              {tab.label}
            </button>
          ))}
        </div>

        {/* Summary */}
        {activeTab === 'summary' && (
          <div className="p-6">
            {/* Pod Health */}
            <PodHealthSection releaseId={id!} />

            {/* Two-column info cards */}
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6 mb-6">
              {/* Release Info */}
              <div className="border border-zinc-100 rounded-xl p-5">
                <h3 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider mb-4">Release Info</h3>
                <div className="grid grid-cols-2 gap-x-6 gap-y-3">
                  <InfoField label="ID" value={release.id} mono />
                  <InfoField label="Product" value={release.product} />
                  <InfoField label="Service" value={release.service} />
                  <InfoField label="Status" value={release.status} />
                  <InfoField label="Env" value={release.env} />
                  <InfoField label="Mode" value={release.mode} />
                  <InfoField label="Tracker Type" value={release.tracker_type} />
                  <InfoField label="Old Version" value={release.old_version} mono />
                  <InfoField label="New Version" value={release.new_version} mono />
                  <InfoField label="Docker Image" value={release.release_context?.docker_image || release.docker_image || ''} mono />
                  <InfoField label="Cluster" value={release.release_context?.cluster || ''} />
                  <InfoField label="Approved" value={release.is_approved ? 'Yes' : 'No'} />
                  <InfoField label="Infra Approved" value={release.is_infra_approved ? 'Yes' : 'No'} />
                </div>
              </div>

              {/* Timeline */}
              <div className="border border-zinc-100 rounded-xl p-5">
                <h3 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider mb-4">Timeline</h3>
                <div className="grid grid-cols-2 gap-x-6 gap-y-3">
                  <InfoField label="Release Tag" value={release.release_tag} mono />
                  <InfoField label="Created" value={formatDate(release.date_created)} mono />
                  <InfoField label="Release Manager" value={release.release_manager} />
                  <InfoField label="Schedule Time" value={formatDate(release.schedule_time)} mono />
                  <InfoField label="Start Time" value={formatDate(release.start_time)} mono />
                  <InfoField label="End Time" value={formatDate(release.end_time)} mono />
                  <InfoField label="Priority" value={String(release.priority)} />
                  <InfoField label="AB HS Status" value={release.ab_hs_status} />
                  <InfoField label="Cronjob Suspend" value={release.cronjob_suspend ? 'Yes' : 'No'} />
                  <InfoField label="Scale Down Delay" value={release.release_context?.pods_scale_down_delay ? `${release.release_context.pods_scale_down_delay} hrs` : '-'} />
                  <InfoField label="Scale Down Status" value={release.release_context?.pods_scale_down_status || '-'} />
                </div>
              </div>
            </div>

            {/* Details - full width */}
            <div className="border border-zinc-100 rounded-xl p-5 mb-6">
              <h3 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider mb-4">Details</h3>
              <div className="grid grid-cols-1 md:grid-cols-3 gap-x-6 gap-y-3">
                <InfoField label="Description" value={release.description} />
                <InfoField label="Change Log" value={release.change_log} />
                <InfoField label="Info" value={release.info} />
              </div>
            </div>

            {/* Resources */}
            <ResourcesSection product={release.product} service={release.service} />
          </div>
        )}

        {/* History */}
        {activeTab === 'history' && (
          <div className="p-6">
            {release.rollout_strategy?.length > 0 && (
              <div className="mb-6">
                <h3 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider mb-3">Rollout Strategy</h3>
                <div className="overflow-x-auto">
                  <table className="w-full text-sm text-left border-collapse">
                    <thead><tr className="bg-zinc-50 border-y border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                      <th className="py-2 px-4">Stage</th><th className="py-2 px-4">Rollout %</th><th className="py-2 px-4">Cooloff (mins)</th><th className="py-2 px-4">Pods</th>
                    </tr></thead>
                    <tbody>{release.rollout_strategy.map((stage, idx) => (
                      <tr key={idx} className={cn('border-b border-zinc-100', idx % 2 === 1 ? 'bg-zinc-50' : 'bg-white')}>
                        <td className="py-2 px-4 font-medium">{idx + 1}</td><td className="py-2 px-4 font-mono">{stage.rollout}%</td><td className="py-2 px-4 font-mono">{stage.cooloff}</td><td className="py-2 px-4 font-mono">{stage.pods}</td>
                      </tr>
                    ))}</tbody>
                  </table>
                </div>
              </div>
            )}
            <h3 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider mb-3">Rollout History</h3>
            {release.rollout_history?.length > 0 ? (
              <div className="overflow-x-auto">
                <table className="w-full text-sm text-left border-collapse">
                  <thead><tr className="bg-zinc-50 border-y border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                    <th className="py-2 px-3">Start Time</th><th className="py-2 px-3">Rollout %</th><th className="py-2 px-3">End Time</th><th className="py-2 px-3">Decision</th><th className="py-2 px-3">HS Decision</th><th className="py-2 px-3">Manual</th><th className="py-2 px-3">Cooloff</th><th className="py-2 px-3">Pods</th>
                  </tr></thead>
                  <tbody>{release.rollout_history.map((h: RolloutHistoryEvent, idx: number) => (
                    <tr key={idx} className={cn('border-b border-zinc-100', idx % 2 === 1 ? 'bg-zinc-50' : 'bg-white')}>
                      <td className="py-2 px-3 font-mono text-xs">{formatDate(h.started_at)}</td>
                      <td className="py-2 px-3 font-mono font-medium">{h.rollout}%</td>
                      <td className="py-2 px-3 font-mono text-xs">{formatDate(h.completed_at)}</td>
                      <td className="py-2 px-3"><Badge variant={h.last_decision === 'Continue' ? 'success' : h.last_decision === 'Abort' ? 'danger' : h.last_decision === 'Wait' ? 'warning' : 'default'} size="sm">{h.last_decision || '-'}</Badge></td>
                      <td className="py-2 px-3"><Badge variant={h.last_decision_hs === 'Continue' ? 'success' : h.last_decision_hs === 'Abort' ? 'danger' : h.last_decision_hs === 'Wait' ? 'warning' : 'default'} size="sm">{h.last_decision_hs || '-'}</Badge></td>
                      <td className="py-2 px-3 text-sm">{h.manual_override ? 'Yes' : 'No'}</td>
                      <td className="py-2 px-3 font-mono">{h.cooloff}</td>
                      <td className="py-2 px-3 font-mono">{h.pods}</td>
                    </tr>
                  ))}</tbody>
                </table>
              </div>
            ) : <p className="text-sm text-zinc-400">No rollout history yet.</p>}
          </div>
        )}

        {/* Events */}
        {activeTab === 'events' && <ReleaseEventsTab events={events} />}

        {/* ENV Diff */}
        {activeTab === 'env-diff' && <EnvDiffTab releaseId={id!} />}

        {/* JSON Data */}
        {activeTab === 'json' && (
          <div className="p-6">
            <pre className="bg-zinc-50 border border-zinc-200 rounded-lg p-4 text-xs font-mono text-zinc-700 overflow-auto max-h-[600px] whitespace-pre-wrap">
              {JSON.stringify(release, null, 2)}
            </pre>
          </div>
        )}
      </div>

      <div className="flex justify-end pt-5">
        <Button variant="secondary" onClick={() => navigate('/releases')}>Back to Releases</Button>
      </div>

      {/* Edit Release Dialog */}
      <Dialog open={editOpen} onOpenChange={setEditOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Edit Release</DialogTitle>
          </DialogHeader>
          <DialogBody className="space-y-4">
            <div>
              <label className="text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5 block">Description</label>
              <textarea
                value={editForm.description}
                onChange={(e) => setEditForm(f => ({ ...f, description: e.target.value }))}
                rows={2}
                className="w-full border border-zinc-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150"
              />
            </div>
            <div>
              <label className="text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5 block">Change Log</label>
              <textarea
                value={editForm.change_log}
                onChange={(e) => setEditForm(f => ({ ...f, change_log: e.target.value }))}
                rows={2}
                className="w-full border border-zinc-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150"
              />
            </div>
            <div>
              <label className="text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5 block">Priority</label>
              <input
                type="number"
                min={0}
                max={9}
                value={editForm.priority}
                onChange={(e) => setEditForm(f => ({ ...f, priority: parseInt(e.target.value) || 0 }))}
                className="w-full h-9 border border-zinc-300 rounded-lg px-3 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150"
              />
            </div>
            <div>
              <label className="text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5 block">Mode</label>
              <select
                value={editForm.mode}
                onChange={(e) => setEditForm(f => ({ ...f, mode: e.target.value }))}
                className="w-full h-9 border border-zinc-300 rounded-lg px-3 text-sm cursor-pointer focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150"
              >
                <option value="AUTO">AUTO</option>
                <option value="MANUAL">MANUAL</option>
              </select>
            </div>
          </DialogBody>
          <DialogFooter>
            <Button variant="secondary" size="sm" onClick={() => setEditOpen(false)}>Cancel</Button>
            <Button
              size="sm"
              loading={updateTrackerMut.isPending}
              onClick={async () => {
                await updateTrackerMut.mutateAsync({
                  releaseId: id!,
                  updates: {
                    description: editForm.description,
                    change_log: editForm.change_log,
                    priority: editForm.priority,
                    mode: editForm.mode,
                  },
                });
                setEditOpen(false);
              }}
            >
              Save
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default ReleaseSummary;
