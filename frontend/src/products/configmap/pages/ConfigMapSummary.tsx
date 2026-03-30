import React, { useState, Fragment } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import Editor from '@monaco-editor/react';
import { apiClient } from '../../../lib/api-client';
import { StatusBadge, Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { SimpleTooltip } from '../../../shared/ui/tooltip';
import { RefreshCw, Copy } from 'lucide-react';
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

const formatTs = (ts: string) => { if (!ts) return '-'; const d = new Date(ts); return d.toLocaleString('en-US', { month: 'short', day: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: true }); };
const tryFormatJson = (data: string): string => { try { return JSON.stringify(JSON.parse(data), null, 2); } catch { return data; } };

const ConfigMapSummary: React.FC = () => {
  const { clusterId } = useParams<{ clusterId: string }>();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [activeTab, setActiveTab] = useState('Summary');
  const [expandedRows, setExpandedRows] = useState<Set<number>>(new Set());

  const id = clusterId?.split('&&')[1] || '';
  const cluster = clusterId?.split('&&')[0] || '';

  const { data, isLoading, refetch } = useQuery({
    queryKey: ['configmap-detail', id],
    queryFn: async () => { const res = await apiClient.get(`/tracker/configmap/${id}`); return res.data; },
    enabled: !!id,
    refetchInterval: 10000,
  });

  const actionMut = useMutation({
    mutationFn: async (body: Record<string, unknown>) => {
      await apiClient.put(`/tracker/configmap/${id}`, body);
    },
    onSuccess: () => { toast.success('Action completed'); refetch(); },
    onError: (err: any) => { toast.error(err.message || 'Action failed'); },
  });

  const handleAction = (action: string) => {
    if (!confirm(`Are you sure you want to ${action}?`)) return;
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

  if (isLoading) return <div className="p-10 text-center text-zinc-400">Loading ConfigMap...</div>;
  if (!data) return <div className="p-10 text-center text-red-500">ConfigMap not found.</div>;

  const tabs = ['Summary', 'Event Data', 'Json Data', 'ConfigMap Diff'];
  const events: ConfigMapEvent[] = data.events || [];
  const sortedEvents = [...events].sort((a, b) => b.timestamp.localeCompare(a.timestamp));

  return (
    <div className="flex flex-col w-full max-w-6xl">
      {/* Header */}
      <div className="flex items-start justify-between mb-5">
        <div>
          <div className="flex items-center gap-3 mb-1">
            <h1 className="text-lg font-bold text-zinc-800">ConfigMap Details</h1>
            <StatusBadge status={data.status} />
          </div>
          <div className="font-mono text-xs text-zinc-500">ID: {data.id}</div>
        </div>
        <div className="flex items-center gap-2">
          {data.status === 'CREATED' && data.is_approved === 0 && (
            <PermissionGate product="config-manager" permission="CONFIG_APPROVE">
              <Button size="sm" variant="success" onClick={() => handleAction('Approve')} loading={actionMut.isPending}>Approve</Button>
            </PermissionGate>
          )}
          {data.status === 'INPROGRESS' && (
            <PermissionGate product="config-manager" permission="CONFIG_EDIT">
              <Button size="sm" variant="outline" onClick={() => handleAction('Pause')}>Pause</Button>
              <Button size="sm" variant="outline" onClick={() => handleAction('Fast Forward')}>Fast Forward</Button>
              <Button size="sm" variant="danger" onClick={() => handleAction('Abort')}>Abort</Button>
            </PermissionGate>
          )}
          {data.status === 'PAUSED' && (
            <PermissionGate product="config-manager" permission="CONFIG_EDIT">
              <Button size="sm" variant="success" onClick={() => handleAction('Resume')}>Continue</Button>
              <Button size="sm" variant="danger" onClick={() => handleAction('Abort')}>Abort</Button>
            </PermissionGate>
          )}
          {data.status === 'CREATED' && data.is_approved !== 0 && (
            <PermissionGate product="config-manager" permission="CONFIG_DISCARD">
              <Button size="sm" variant="ghost" onClick={() => handleAction('Discard')}>Discard</Button>
            </PermissionGate>
          )}
          {['COMPLETED', 'RECORDED'].includes(data.status) && (
            <PermissionGate product="config-manager" permission="CONFIG_REVERT">
              <Button size="sm" variant="outline" onClick={() => handleAction('Revert')}><RefreshCw className="w-3.5 h-3.5" /> Revert</Button>
            </PermissionGate>
          )}
          <SimpleTooltip content="Clone">
            <Button size="icon" variant="ghost" onClick={() => navigate(`/configmap/new?clone_id=${data.id}`)}><Copy className="w-4 h-4" /></Button>
          </SimpleTooltip>
        </div>
      </div>

      {/* Tabs */}
      <div className="bg-white rounded-lg border border-border">
        <div className="flex border-b border-border px-5">
          {tabs.map(t => (
            <button key={t} onClick={() => setActiveTab(t)}
              className={cn('py-3 px-4 text-sm font-medium border-b-2 transition-colors cursor-pointer', activeTab === t ? 'border-zinc-900 text-zinc-900' : 'border-transparent text-zinc-400 hover:text-zinc-600')}>
              {t}
            </button>
          ))}
        </div>

        {activeTab === 'Summary' && (
          <div className="p-6 grid grid-cols-1 md:grid-cols-4 gap-4">
            {[
              { title: 'PRODUCT', rows: [{ label: 'Product', value: data.product }, { label: 'Description', value: data.description }, { label: 'Release Manager', value: data.release_manager }, { label: 'Name', value: data.name }, { label: 'Change log', value: data.change_log }] },
              { title: 'TIME SCHEDULE', rows: [{ label: 'Created at', value: data.date_created }, { label: 'Scheduled time', value: data.schedule_time }, { label: 'Last Updated', value: data.last_updated }, { label: 'Start time', value: data.start_time }, { label: 'End time', value: data.end_time }] },
              { title: 'META DATA', rows: [{ label: 'Priority', value: data.priority }, { label: 'Env', value: data.env }, { label: 'Approved', value: data.is_approved === 1 ? 'Yes' : 'No' }, { label: 'Slack Thread Id', value: data.slack_thread_id }] },
              { title: 'K8S INFO', rows: [{ label: 'Id', value: data.id }, { label: 'Cluster', value: data.cluster }] },
            ].map((card, ci) => (
              <div key={ci} className="bg-zinc-50/50 rounded-lg border border-border-light p-4 text-sm">
                <h3 className="font-bold text-zinc-500 uppercase text-xs tracking-widest mb-3">{card.title}</h3>
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
              <thead><tr className="bg-zinc-50 border-b border-border text-xs text-zinc-500 font-medium">
                <th className="px-3 py-3 w-8"></th>
                {['#', 'Timestamp', 'Category', 'Label', 'Value'].map(h => <th key={h} className="px-4 py-3">{h}</th>)}
              </tr></thead>
              <tbody>
                {sortedEvents.map((ev, i) => (
                  <Fragment key={i}>
                    <tr className={cn('border-b border-border-light hover:bg-zinc-50/50 cursor-pointer', i % 2 === 1 && 'bg-zinc-50/30')} onClick={() => toggleRow(i)}>
                      <td className="px-3 py-2 text-zinc-400"><span className={`inline-block transition-transform text-xs ${expandedRows.has(i) ? 'rotate-90' : ''}`}>&#9654;</span></td>
                      <td className="px-4 py-2 text-zinc-400 font-mono text-xs">{i + 1}</td>
                      <td className="px-4 py-2 font-mono text-xs text-zinc-500 whitespace-nowrap">{formatTs(ev.timestamp)}</td>
                      <td className="px-4 py-2"><Badge variant={ev.category === 'BUSINESS' ? 'info' : ev.category === 'NOTIFICATION' ? 'success' : 'default'} size="sm">{ev.category}</Badge></td>
                      <td className="px-4 py-2 text-zinc-600">{ev.label}</td>
                      <td className="px-4 py-2 text-zinc-500 max-w-sm truncate" title={ev.data}>{ev.data?.slice(0, 40)}{(ev.data?.length || 0) > 40 ? '...' : ''}</td>
                    </tr>
                    {expandedRows.has(i) && (
                      <tr className="bg-zinc-50"><td colSpan={6} className="px-6 py-3"><pre className="text-xs font-mono bg-zinc-900 text-emerald-400 p-4 rounded-lg overflow-x-auto max-h-60 whitespace-pre-wrap break-all">{tryFormatJson(ev.data)}</pre></td></tr>
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
            {data?.file ? (
              <Editor height="60vh" defaultLanguage="yaml" theme="light" value={formatConfigMapContent(data.file)}
                options={{ readOnly: true, minimap: { enabled: false }, fontSize: 13, lineNumbers: 'on', scrollBeyondLastLine: false, wordWrap: 'on', automaticLayout: true }} />
            ) : (
              <div className="p-6 text-sm text-zinc-400">No ConfigMap file content available.</div>
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
