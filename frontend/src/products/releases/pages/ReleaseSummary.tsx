import React, { useState } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { useRelease, useReleaseEvents, useApproveRelease, useDiscardRelease, usePauseRelease, useResumeRelease, useAbortRelease, useRevertRelease, useImmediateRevert } from '../hooks';
import { TERMINAL_STATUSES } from '../../../api';
import type { RolloutHistoryEvent, RolloutEvent } from '../../../api';
import { StatusBadge, Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { SimpleTooltip } from '../../../shared/ui/tooltip';
import { Copy, RefreshCw, Play, Pause, Square, RotateCcw, Check, X, Zap, Search } from 'lucide-react';
import { cn } from '../../../lib/utils';
import { toast } from 'sonner';

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
        <h3 className="text-sm font-bold text-zinc-700 uppercase tracking-wider">Release Events</h3>
        <div className="relative">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-zinc-400" />
          <input type="text" placeholder="Filter events..." value={eventSearch} onChange={(e) => setEventSearch(e.target.value)}
            className="pl-8 pr-3 py-1.5 border border-zinc-200 rounded-lg text-sm w-56 focus:outline-none focus:ring-2 focus:ring-zinc-800 focus:border-transparent" />
        </div>
      </div>
      {sorted.length > 0 ? (
        <div className="overflow-x-auto">
          <table className="w-full text-sm text-left border-collapse">
            <thead>
              <tr className="bg-zinc-50 border-y border-border text-xs text-zinc-500 font-medium">
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
                  <tr className={cn('border-b border-border-light cursor-pointer hover:bg-zinc-50/50', idx % 2 === 1 && 'bg-zinc-50/30')} onClick={() => toggleRow(idx)}>
                    <td className="py-2 px-3 text-zinc-400"><span className={`inline-block transition-transform text-xs ${expandedRows.has(idx) ? 'rotate-90' : ''}`}>&#9654;</span></td>
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
                    <tr className="border-b border-border-light bg-zinc-50">
                      <td colSpan={6} className="px-6 py-3">
                        <pre className="text-xs font-mono bg-zinc-900 text-emerald-400 p-4 rounded-lg overflow-x-auto max-h-60 whitespace-pre-wrap break-all">{tryFormatJson(evt.data)}</pre>
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

const ReleaseSummary: React.FC = () => {
  const { id, clusterId } = useParams<{ clusterId: string; id: string }>();
  const navigate = useNavigate();
  const [activeTab, setActiveTab] = useState<'summary' | 'history' | 'events'>('summary');

  const { data: release, isLoading, error, refetch } = useRelease(id);
  const { data: events = [] } = useReleaseEvents(id);

  const approveMut = useApproveRelease();
  const discardMut = useDiscardRelease();
  const pauseMut = usePauseRelease();
  const resumeMut = useResumeRelease();
  const abortMut = useAbortRelease();
  const revertMut = useRevertRelease();
  const immRevertMut = useImmediateRevert();

  const doAction = async (label: string, fn: () => Promise<any>) => {
    if (!confirm(`Are you sure you want to ${label}?`)) return;
    try { await fn(); } catch {}
  };

  if (isLoading && !release) return <div className="p-8 text-center text-zinc-400">Loading release...</div>;
  if (error && !release) return <div className="p-8 text-center text-red-500">Release not found</div>;
  if (!release) return null;

  const s = release.status;
  const anyActionLoading = approveMut.isPending || discardMut.isPending || pauseMut.isPending || resumeMut.isPending || abortMut.isPending || revertMut.isPending || immRevertMut.isPending;

  const InfoField = ({ label, value, mono }: { label: string; value?: string; mono?: boolean }) => (
    <div>
      <div className="text-xs font-medium text-zinc-400 uppercase tracking-wider mb-1">{label}</div>
      <div className={cn('border border-border-light rounded-lg px-3 py-2 bg-zinc-50/50 text-sm min-h-[38px] break-all', mono && 'font-mono text-xs')}>{value || '-'}</div>
    </div>
  );

  return (
    <div className="flex flex-col flex-1 w-full pb-12 max-w-6xl">
      {/* Header */}
      <div className="flex items-center justify-between mb-5">
        <div className="flex items-center gap-3">
          <h1 className="text-lg font-bold text-zinc-800">Release Summary</h1>
          <StatusBadge status={release.status} />
          {release.release_context?.revert === 1 && <Badge variant="purple" dot>REVERT</Badge>}
          {release.ab_hs_status && release.ab_hs_status !== 'Uninitiated' && <Badge variant="info">AB: {release.ab_hs_status}</Badge>}
        </div>
        <div className="flex items-center gap-2">
          {/* Action Buttons */}
          {s === 'CREATED' && release.is_approved === 0 && (
            <PermissionGate product="backend-releases" permission="RELEASE_APPROVE">
              <Button size="sm" variant="success" loading={approveMut.isPending} onClick={() => doAction('approve', () => approveMut.mutateAsync({ releaseId: id!, approvedBy: 'admin' }))}><Check className="w-3.5 h-3.5" /> Approve</Button>
            </PermissionGate>
          )}
          {s === 'CREATED' && (
            <PermissionGate product="backend-releases" permission="RELEASE_DISCARD">
              <Button size="sm" variant="ghost" loading={discardMut.isPending} onClick={() => doAction('discard', () => discardMut.mutateAsync({ releaseId: id! }))}><X className="w-3.5 h-3.5" /> Discard</Button>
            </PermissionGate>
          )}
          {(s === 'INPROGRESS' || s === 'RECORDING') && (
            <PermissionGate product="backend-releases" permission="RELEASE_PAUSE">
              <Button size="sm" variant="outline" loading={pauseMut.isPending} onClick={() => doAction('pause', () => pauseMut.mutateAsync(id!))}><Pause className="w-3.5 h-3.5" /> Pause</Button>
              <Button size="sm" variant="danger" loading={abortMut.isPending} onClick={() => doAction('abort', () => abortMut.mutateAsync(id!))}><Square className="w-3.5 h-3.5" /> Abort</Button>
            </PermissionGate>
          )}
          {s === 'PAUSED' && (
            <PermissionGate product="backend-releases" permission="RELEASE_RESUME">
              <Button size="sm" variant="success" loading={resumeMut.isPending} onClick={() => doAction('resume', () => resumeMut.mutateAsync(id!))}><Play className="w-3.5 h-3.5" /> Resume</Button>
              <Button size="sm" variant="danger" loading={abortMut.isPending} onClick={() => doAction('abort', () => abortMut.mutateAsync(id!))}><Square className="w-3.5 h-3.5" /> Abort</Button>
            </PermissionGate>
          )}
          {s === 'RECORDED' && (
            <PermissionGate product="backend-releases" permission="RELEASE_REVERT">
              <Button size="sm" variant="outline" loading={revertMut.isPending} onClick={() => doAction('revert', () => revertMut.mutateAsync({ releaseId: id!, requestedBy: 'admin' }))}><RotateCcw className="w-3.5 h-3.5" /> Revert</Button>
            </PermissionGate>
          )}
          {s === 'COMPLETED' && (
            <PermissionGate product="backend-releases" permission="RELEASE_REVERT">
              <Button size="sm" variant="outline" loading={revertMut.isPending} onClick={() => doAction('revert', () => revertMut.mutateAsync({ releaseId: id!, requestedBy: 'admin' }))}><RotateCcw className="w-3.5 h-3.5" /> Revert</Button>
              <Button size="sm" variant="danger" loading={immRevertMut.isPending} onClick={() => doAction('immediate revert', () => immRevertMut.mutateAsync({ releaseId: id!, requestedBy: 'admin' }))}><Zap className="w-3.5 h-3.5" /> Immediate Revert</Button>
            </PermissionGate>
          )}

          <div className="w-px h-6 bg-zinc-200 mx-1" />
          <SimpleTooltip content="Clone"><Button size="icon" variant="ghost" onClick={() => navigate(`/releases/${clusterId}/${id}/clone`)}><Copy className="w-4 h-4" /></Button></SimpleTooltip>
          <SimpleTooltip content="Refresh"><Button size="icon" variant="ghost" onClick={() => refetch()}><RefreshCw className="w-4 h-4" /></Button></SimpleTooltip>
        </div>
      </div>

      {/* Main Card with Tabs */}
      <div className="bg-white rounded-lg border border-border">
        <div className="flex border-b border-border px-5">
          {(['summary', 'history', 'events'] as const).map(tab => (
            <button key={tab} onClick={() => setActiveTab(tab)}
              className={cn('py-3 px-4 text-sm font-medium border-b-2 transition-colors', activeTab === tab ? 'border-zinc-900 text-zinc-900' : 'border-transparent text-zinc-400 hover:text-zinc-600')}>
              {tab === 'summary' ? 'Summary' : tab === 'history' ? 'Rollout History' : 'Events'}
            </button>
          ))}
        </div>

        {/* Summary */}
        {activeTab === 'summary' && (
          <div className="p-6 grid grid-cols-1 md:grid-cols-3 gap-x-8 gap-y-4">
            <InfoField label="ID" value={release.id} mono />
            <InfoField label="Product" value={release.product} />
            <InfoField label="Service" value={release.service} />
            <InfoField label="Status" value={release.status} />
            <InfoField label="Mode" value={release.mode} />
            <InfoField label="Env" value={release.env} />
            <InfoField label="Old Version" value={release.old_version} mono />
            <InfoField label="New Version" value={release.new_version} mono />
            <InfoField label="Docker Image" value={release.release_context?.docker_image || release.docker_image || ''} mono />
            <InfoField label="Release Tag" value={release.release_tag} mono />
            <InfoField label="Release Manager" value={release.release_manager} />
            <InfoField label="Priority" value={String(release.priority)} />
            <InfoField label="Approved" value={release.is_approved ? 'Yes' : 'No'} />
            <InfoField label="Infra Approved" value={release.is_infra_approved ? 'Yes' : 'No'} />
            <InfoField label="Tracker Type" value={release.tracker_type} />
            <InfoField label="Schedule Time" value={formatDate(release.schedule_time)} mono />
            <InfoField label="Start Time" value={formatDate(release.start_time)} mono />
            <InfoField label="End Time" value={formatDate(release.end_time)} mono />
            <InfoField label="AB HS Status" value={release.ab_hs_status} />
            <InfoField label="ART Recorder" value={release.is_art_recorder ? 'Yes' : 'No'} />
            <InfoField label="Cronjob Suspend" value={release.cronjob_suspend ? 'Yes' : 'No'} />
            <InfoField label="Scale Down Delay" value={release.release_context?.pods_scale_down_delay ? `${release.release_context.pods_scale_down_delay} hrs` : '-'} />
            <InfoField label="Scale Down Status" value={release.release_context?.pods_scale_down_status || '-'} />
            <InfoField label="Cluster" value={release.release_context?.cluster || ''} />
            <InfoField label="Description" value={release.description} />
            <InfoField label="Change Log" value={release.change_log} />
            <InfoField label="Info" value={release.info} />
          </div>
        )}

        {/* History */}
        {activeTab === 'history' && (
          <div className="p-6">
            {release.rollout_strategy?.length > 0 && (
              <div className="mb-6">
                <h3 className="text-sm font-bold text-zinc-700 uppercase tracking-wider mb-3">Rollout Strategy</h3>
                <div className="overflow-x-auto">
                  <table className="w-full text-sm text-left border-collapse">
                    <thead><tr className="bg-zinc-50 border-y border-border text-xs text-zinc-500 font-medium">
                      <th className="py-2 px-4">Stage</th><th className="py-2 px-4">Rollout %</th><th className="py-2 px-4">Cooloff (mins)</th><th className="py-2 px-4">Pods</th>
                    </tr></thead>
                    <tbody>{release.rollout_strategy.map((stage, idx) => (
                      <tr key={idx} className={cn('border-b border-border-light', idx % 2 === 1 && 'bg-zinc-50/30')}>
                        <td className="py-2 px-4 font-medium">{idx + 1}</td><td className="py-2 px-4 font-mono">{stage.rollout}%</td><td className="py-2 px-4 font-mono">{stage.cooloff}</td><td className="py-2 px-4 font-mono">{stage.pods}</td>
                      </tr>
                    ))}</tbody>
                  </table>
                </div>
              </div>
            )}
            <h3 className="text-sm font-bold text-zinc-700 uppercase tracking-wider mb-3">Rollout History</h3>
            {release.rollout_history?.length > 0 ? (
              <div className="overflow-x-auto">
                <table className="w-full text-sm text-left border-collapse">
                  <thead><tr className="bg-zinc-50 border-y border-border text-xs text-zinc-500 font-medium">
                    <th className="py-2 px-3">Start Time</th><th className="py-2 px-3">Rollout %</th><th className="py-2 px-3">End Time</th><th className="py-2 px-3">Decision</th><th className="py-2 px-3">HS Decision</th><th className="py-2 px-3">Manual</th><th className="py-2 px-3">Cooloff</th><th className="py-2 px-3">Pods</th>
                  </tr></thead>
                  <tbody>{release.rollout_history.map((h: RolloutHistoryEvent, idx: number) => (
                    <tr key={idx} className={cn('border-b border-border-light', idx % 2 === 1 && 'bg-zinc-50/30')}>
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
      </div>

      <div className="flex justify-end pt-5">
        <Button variant="secondary" onClick={() => navigate('/releases')}>Back to Releases</Button>
      </div>
    </div>
  );
};

export default ReleaseSummary;
