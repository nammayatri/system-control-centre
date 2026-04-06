import React, { useState, Fragment, useMemo } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { useQuery, useMutation } from '@tanstack/react-query';
import Editor from '@monaco-editor/react';
import ReactDiffViewer from 'react-diff-viewer-continued';
import { fetchConfigMapDetail, updateConfigMap } from '../api';
import { fetchReleaseEvents } from '../../releases/api';
import { Badge } from '../../../shared/ui/badge';
import { StatusBadge } from '../../releases/components/StatusBadge';
import { Button } from '../../../shared/ui/button';
import { CardSkeleton } from '../../../shared/ui/skeleton';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { SimpleTooltip } from '../../../shared/ui/tooltip';
import { useConfirm } from '../../../shared/ui/confirm-dialog';
import { RefreshCw, Copy, Check, Pause, Play, X, Square, RotateCcw, RotateCw, FastForward } from 'lucide-react';
import { cn } from '../../../lib/utils';
import { toast } from 'sonner';

function formatConfigMapContent(raw: string): string {
  try {
    const parsed = JSON.parse(raw);
    if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) {
      return Object.entries(parsed).map(([key, value]) => {
        if (typeof value === 'string') { const indented = value.split('\n').map(line => '  ' + line).join('\n'); return `${key}: |\n${indented}`; }
        return `${key}: ${JSON.stringify(value, null, 2)}`;
      }).join('\n\n');
    }
    return JSON.stringify(parsed, null, 2);
  } catch { return raw; }
}

interface ConfigMapEvent { category: string; label: string; data: string; timestamp: string; }

// IST everywhere — NammaYatri ops convention. Backend stores UTC.
const formatTs = (ts: string) => {
  if (!ts) return '-';
  const d = new Date(ts);
  if (isNaN(d.getTime())) return '-';
  return d.toLocaleString('en-IN', {
    timeZone: 'Asia/Kolkata',
    month: 'short', day: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: true,
  }) + ' IST';
};
const tryFormatJson = (data: string): string => { try { return JSON.stringify(JSON.parse(data), null, 2); } catch { return data; } };

const ConfigMapSummary: React.FC = () => {
  const { id: rawId } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const [activeTab, setActiveTab] = useState('Summary');
  const [expandedRows, setExpandedRows] = useState<Set<number>>(new Set());

  const id = rawId?.includes('&&') ? rawId.split('&&')[1] : rawId || '';

  const { data, isLoading, refetch } = useQuery({
    queryKey: ['configmap-detail', id],
    queryFn: () => fetchConfigMapDetail(id),
    enabled: !!id,
    refetchInterval: 10000,
  });

  const { data: releaseEvents = [] } = useQuery({
    queryKey: ['configmap-events', id],
    queryFn: () => fetchReleaseEvents(id),
    enabled: !!id,
  });

  const actionMut = useMutation({
    mutationFn: async (body: Record<string, unknown>) => {
      return updateConfigMap(id, body);
    },
    onSuccess: () => { toast.success('Action completed'); refetch(); },
    onError: (err: Error) => { toast.error(err.message || 'Action failed'); },
  });

  const confirmAction = useConfirm();
  const handleAction = async (action: string) => {
    const isDanger = ['Abort', 'Discard', 'Revert'].includes(action);
    const ok = await confirmAction({
      title: `${action} ConfigMap Release`,
      description: `Are you sure you want to ${action.toLowerCase()} this ConfigMap release?`,
      confirmLabel: `Yes, ${action}`,
      variant: isDanger ? 'danger' : 'primary',
    });
    if (!ok) return;
    let body: Record<string, unknown> = {};
    switch (action) {
      case 'Approve': body = { is_approved: 1 }; break;
      case 'Pause': body = { status: 'PAUSED' }; break;
      case 'Resume': body = { status: 'INPROGRESS' }; break;
      case 'Discard': body = { status: 'DISCARDED' }; break;
      case 'Abort': body = { status: 'ABORTING' }; break;
      case 'Revert': body = { status: 'revert' }; break;
      case 'Restart': body = { status: 'restart' }; break;
      case 'Fast Forward': body = { current_cool_off: 0 }; break;
    }
    actionMut.mutate(body);
  };

  const toggleRow = (idx: number) => { setExpandedRows(prev => { const next = new Set(prev); if (next.has(idx)) next.delete(idx); else next.add(idx); return next; }); };

  if (isLoading) {
    return (
      <div className="flex flex-col w-full space-y-6">
        <CardSkeleton />
        <CardSkeleton />
      </div>
    );
  }
  if (!data) return <div className="p-10 text-center text-red-500">ConfigMap not found.</div>;

  const tabs = ['Summary', 'Event Data', 'Json Data', 'ConfigMap Diff'];
  const events: ConfigMapEvent[] = releaseEvents.length > 0
    ? releaseEvents.map(e => ({ category: e.category, label: e.label, data: e.data, timestamp: e.timestamp }))
    : (data.events as ConfigMapEvent[] | undefined) || [];
  const sortedEvents = [...events].sort((a, b) => b.timestamp.localeCompare(a.timestamp));

  const beforeSnapshot = events.find(e => e.category === 'SNAPSHOT' && e.label === 'CONFIGMAP_BEFORE');
  const afterSnapshot = events.find(e => e.category === 'SNAPSHOT' && e.label === 'CONFIGMAP_AFTER');

  return (
    <div className="flex flex-col w-full">
      {/* Header */}
      <div className="flex items-start justify-between mb-5">
        <div>
          <div className="flex items-center gap-3 mb-1">
            <h1 className="text-lg font-semibold text-zinc-900">ConfigMap Details</h1>
            <StatusBadge status={data.status} />
          </div>
          <div className="font-mono text-xs text-zinc-500">ID: {data.id}</div>
        </div>
        <div className="flex items-center gap-2">
          {data.status === 'CREATED' && data.is_approved === 0 && (
            <PermissionGate product="autopilot" permission="CONFIG_APPROVE">
              <Button size="sm" variant="success" onClick={() => handleAction('Approve')} loading={actionMut.isPending}><Check className="w-3.5 h-3.5" /> Approve</Button>
            </PermissionGate>
          )}
          {data.status === 'INPROGRESS' && (
            <PermissionGate product="autopilot" permission="CONFIG_EDIT">
              <Button size="sm" variant="outline" className="border-amber-300 text-amber-700 hover:bg-amber-50" onClick={() => handleAction('Pause')} loading={actionMut.isPending}><Pause className="w-3.5 h-3.5" /> Pause</Button>
              <Button size="sm" variant="outline" className="border-amber-300 bg-amber-600 text-white hover:bg-amber-700" onClick={() => handleAction('Fast Forward')} loading={actionMut.isPending}><FastForward className="w-3.5 h-3.5" /> Fast Forward</Button>
              <Button size="sm" variant="danger" onClick={() => handleAction('Abort')} loading={actionMut.isPending}><Square className="w-3.5 h-3.5" /> Abort</Button>
            </PermissionGate>
          )}
          {data.status === 'PAUSED' && (
            <PermissionGate product="autopilot" permission="CONFIG_EDIT">
              <Button size="sm" className="bg-blue-600 text-white hover:bg-blue-700" onClick={() => handleAction('Resume')} loading={actionMut.isPending}><Play className="w-3.5 h-3.5" /> Resume</Button>
              <Button size="sm" variant="danger" onClick={() => handleAction('Abort')} loading={actionMut.isPending}><Square className="w-3.5 h-3.5" /> Abort</Button>
            </PermissionGate>
          )}
          {data.status === 'CREATED' && (
            <PermissionGate product="autopilot" permission="CONFIG_DISCARD">
              <Button size="sm" variant="outline" className="border-red-300 text-red-700 hover:bg-red-50" onClick={() => handleAction('Discard')} loading={actionMut.isPending}><X className="w-3.5 h-3.5" /> Discard</Button>
            </PermissionGate>
          )}
          {data.status === 'COMPLETED' && (
            <PermissionGate product="autopilot" permission="CONFIG_REVERT">
              <Button size="sm" variant="outline" className="border-violet-300 text-violet-700 hover:bg-violet-50" onClick={() => handleAction('Revert')} loading={actionMut.isPending}><RotateCcw className="w-3.5 h-3.5" /> Revert</Button>
            </PermissionGate>
          )}
          <SimpleTooltip content="Clone">
            <Button size="icon" variant="ghost" onClick={() => navigate(`/configmap/new?clone_id=${data.id}`)}><Copy className="w-4 h-4" /></Button>
          </SimpleTooltip>
        </div>
      </div>

      {/* Tabs */}
      <div className="bg-white rounded-xl border border-zinc-200">
        <div className="flex border-b border-zinc-200 px-5">
          {tabs.map(t => (
            <button key={t} onClick={() => setActiveTab(t)}
              className={cn('py-3 px-4 text-sm font-medium border-b-2 transition-colors duration-150 cursor-pointer', activeTab === t ? 'border-zinc-900 text-zinc-900' : 'border-transparent text-zinc-400 hover:text-zinc-600')}>
              {t}
            </button>
          ))}
        </div>

        {activeTab === 'Summary' && (
          <div className="p-6 grid grid-cols-1 md:grid-cols-4 gap-4">
            {[
              { title: 'APP GROUP', rows: [{ label: 'App Group', value: data.appGroup }, { label: 'Description', value: data.description }, { label: 'Release Manager', value: data.release_manager }, { label: 'Name', value: data.name }, { label: 'Change log', value: data.change_log }] },
              { title: 'TIME SCHEDULE', rows: [{ label: 'Created at', value: data.date_created }, { label: 'Scheduled time', value: data.schedule_time }, { label: 'Last Updated', value: data.last_updated }, { label: 'Start time', value: data.start_time }, { label: 'End time', value: data.end_time }] },
              { title: 'META DATA', rows: [{ label: 'Priority', value: String(data.priority) }, { label: 'Env', value: data.env }, { label: 'Approved', value: data.is_approved === 1 ? 'Yes' : 'No' }, { label: 'Slack Thread Id', value: data.slack_thread_id }] },
              { title: 'K8S INFO', rows: [{ label: 'Id', value: data.id }, { label: 'Cluster', value: data.cluster }] },
            ].map((card, ci) => (
              <div key={ci} className="bg-zinc-50 rounded-xl border border-zinc-100 p-4 text-sm">
                <h3 className="font-semibold text-zinc-500 uppercase text-[11px] tracking-wider mb-3">{card.title}</h3>
                <dl className="space-y-2.5">
                  {card.rows.map((r, ri) => (
                    <div key={ri}>
                      <dt className="text-zinc-400 text-xs">{r.label}</dt>
                      <dd className="text-zinc-800 font-medium mt-0.5 break-all">{r.value || '-'}</dd>
                    </div>
                  ))}
                </dl>
              </div>
            ))}
          </div>
        )}

        {activeTab === 'Event Data' && (
          <div className="overflow-x-auto">
            <table className="w-full text-sm text-left">
              <thead><tr className="bg-zinc-50 border-b border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                <th className="px-3 py-3 w-8"></th>
                {['#', 'Timestamp', 'Category', 'Label', 'Value'].map(h => <th key={h} className="px-4 py-3">{h}</th>)}
              </tr></thead>
              <tbody>
                {sortedEvents.map((ev, i) => (
                  <Fragment key={i}>
                    <tr className={cn('border-b border-zinc-100 hover:bg-zinc-100 cursor-pointer transition-colors duration-150', i % 2 === 1 ? 'bg-zinc-50' : 'bg-white')} onClick={() => toggleRow(i)}>
                      <td className="px-3 py-2 text-zinc-400"><span className={`inline-block transition-transform duration-200 text-xs ${expandedRows.has(i) ? 'rotate-90' : ''}`}>&#9654;</span></td>
                      <td className="px-4 py-2 text-zinc-400 font-mono text-xs">{i + 1}</td>
                      <td className="px-4 py-2 font-mono text-xs text-zinc-500 whitespace-nowrap">{formatTs(ev.timestamp)}</td>
                      <td className="px-4 py-2"><Badge variant={ev.category === 'BUSINESS' ? 'info' : ev.category === 'NOTIFICATION' ? 'success' : 'default'} size="sm">{ev.category}</Badge></td>
                      <td className="px-4 py-2 text-zinc-600">{ev.label}</td>
                      <td className="px-4 py-2 text-zinc-500 max-w-sm truncate" title={ev.data}>{ev.data?.slice(0, 40)}{(ev.data?.length || 0) > 40 ? '...' : ''}</td>
                    </tr>
                    {expandedRows.has(i) && (
                      <tr className="bg-zinc-50 border-b border-zinc-100"><td colSpan={6} className="px-6 py-3"><pre className="text-xs font-mono bg-zinc-50 text-zinc-800 border border-zinc-200 p-4 rounded-lg overflow-x-auto max-h-60 whitespace-pre-wrap break-all">{tryFormatJson(ev.data)}</pre></td></tr>
                    )}
                  </Fragment>
                ))}
                {sortedEvents.length === 0 && <tr><td colSpan={6} className="px-4 py-8 text-center text-sm text-zinc-400">No events logged.</td></tr>}
              </tbody>
            </table>
          </div>
        )}

        {activeTab === 'Json Data' && (
          <div className="p-0">
            <Editor height="60vh" defaultLanguage="json" theme="light" value={JSON.stringify(data, null, 2)}
              options={{ readOnly: true, minimap: { enabled: false }, fontSize: 13, lineNumbers: 'on', scrollBeyondLastLine: false, wordWrap: 'on', automaticLayout: true }} />
          </div>
        )}

        {activeTab === 'ConfigMap Diff' && (
          <div className="p-0">
            {(beforeSnapshot || afterSnapshot) ? (
              <div className="overflow-hidden">
                <ReactDiffViewer
                  oldValue={beforeSnapshot?.data ? formatConfigMapContent(beforeSnapshot.data) : ''}
                  newValue={afterSnapshot?.data ? formatConfigMapContent(afterSnapshot.data) : ''}
                  splitView={true}
                  leftTitle="Before"
                  rightTitle="After"
                  useDarkTheme={false}
                />
              </div>
            ) : data?.file ? (
              <Editor height="60vh" defaultLanguage="yaml" theme="light" value={formatConfigMapContent(data.file)}
                options={{ readOnly: true, minimap: { enabled: false }, fontSize: 13, lineNumbers: 'on', scrollBeyondLastLine: false, wordWrap: 'on', automaticLayout: true }} />
            ) : (
              <div className="p-6 text-sm text-zinc-400">No ConfigMap diff available. Snapshots are captured when the workflow runs.</div>
            )}
          </div>
        )}
      </div>

      <div className="flex justify-end pt-5">
        <Button variant="secondary" onClick={() => navigate('/configmap')}>Back to ConfigMaps</Button>
      </div>
    </div>
  );
};

export default ConfigMapSummary;
