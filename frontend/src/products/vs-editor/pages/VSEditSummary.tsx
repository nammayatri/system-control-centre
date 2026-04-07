import React, { useState, Fragment } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import Editor from '@monaco-editor/react';
import ReactDiffViewer from 'react-diff-viewer-continued';
import { fetchVSEditDetail, applyVSEdit, unlockVSEdit, fetchReleaseEvents } from '../../releases/api';
import { Badge } from '../../../shared/ui/badge';
import { StatusBadge } from '../../releases/components/StatusBadge';
import { Button } from '../../../shared/ui/button';
import { CardSkeleton } from '../../../shared/ui/skeleton';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { useConfirm } from '../../../shared/ui/confirm-dialog';
import { Play, Unlock, Check, X, ChevronRight as ChevronRightIcon, RefreshCw } from 'lucide-react';
import { apiClient } from '../../../lib/api-client';
import { cn } from '../../../lib/utils';
import { toast } from 'sonner';

// IST everywhere — NammaYatri ops convention. Backend stores UTC.
const formatDate = (d?: string) => {
  if (!d) return '-';
  const date = new Date(d);
  if (isNaN(date.getTime())) return '-';
  return date.toLocaleString('en-IN', {
    timeZone: 'Asia/Kolkata',
    month: 'short', day: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit', hour12: true,
  }) + ' IST';
};

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

const VSEditSummary: React.FC = () => {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const confirmAction = useConfirm();
  const [activeTab, setActiveTab] = useState('Summary');
  const [expandedRows, setExpandedRows] = useState<Set<number>>(new Set());

  const { data: edit, isLoading, error, refetch } = useQuery({
    queryKey: ['vs-edit', id],
    queryFn: () => fetchVSEditDetail(id!),
    enabled: !!id,
    refetchInterval: 10000,
  });

  const { data: vsEvents = [] } = useQuery({
    queryKey: ['vs-events', id],
    queryFn: () => fetchReleaseEvents(id!),
    enabled: !!id,
  });

  const applyMut = useMutation({
    mutationFn: () => {
      const newVsFromEvent = vsEvents.find(e => e.category === 'SNAPSHOT' && e.label === 'VS_NEW');
      return applyVSEdit(id!, newVsFromEvent?.data || edit?.new_vs_data || '');
    },
    onSuccess: () => { toast.success('VS edit applied'); queryClient.invalidateQueries({ queryKey: ['vs-edit', id] }); },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to apply'),
  });

  const unlockMut = useMutation({
    mutationFn: () => unlockVSEdit(id!),
    onSuccess: () => { toast.success('VS edit unlocked'); queryClient.invalidateQueries({ queryKey: ['vs-edit', id] }); },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to unlock'),
  });

  const approveMut = useMutation({
    mutationFn: () => apiClient.put(`/vs-edit-tracker/${encodeURIComponent(id!)}`, { approvedBy: 'admin' }).then(r => r.data),
    onSuccess: () => { toast.success('VS edit approved'); queryClient.invalidateQueries({ queryKey: ['vs-edit', id] }); },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to approve'),
  });

  const discardMut = useMutation({
    mutationFn: () => apiClient.put(`/vs-edit-tracker/${encodeURIComponent(id!)}`, { status: 'DISCARDED' }).then(r => r.data),
    onSuccess: () => { toast.success('VS edit discarded'); queryClient.invalidateQueries({ queryKey: ['vs-edit', id] }); },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to discard'),
  });

  const doAction = async (label: string, fn: () => Promise<any>, isDanger = false) => {
    const ok = await confirmAction({
      title: `${label} VS Edit`,
      description: `Are you sure you want to ${label.toLowerCase()} this VS edit?`,
      confirmLabel: label,
      variant: isDanger ? 'danger' : 'primary',
    });
    if (!ok) return;
    try { await fn(); } catch {}
  };

  const toggleRow = (idx: number) => { setExpandedRows(prev => { const next = new Set(prev); if (next.has(idx)) next.delete(idx); else next.add(idx); return next; }); };

  if (isLoading) return <div className="flex flex-col flex-1 w-full pb-12 space-y-6"><CardSkeleton /><CardSkeleton /></div>;
  if (error || !edit) return <div className="p-8 text-center text-red-500">VS Edit not found</div>;

  const InfoField = ({ label, value, mono }: { label: string; value?: string; mono?: boolean }) => (
    <div>
      <div className="text-[11px] font-medium text-zinc-500 uppercase tracking-wider mb-1">{label}</div>
      <div className={cn('border border-zinc-100 rounded-lg px-3 py-2 bg-zinc-50 text-sm min-h-[38px] break-all', mono && 'font-mono text-xs')}>{value || '-'}</div>
    </div>
  );

  const tabs = ['Summary', 'Event Data', 'Json Data', 'VS Diff'];
  const sortedEvents = [...vsEvents].sort((a: any, b: any) => (b.timestamp || '').localeCompare(a.timestamp || ''));

  const oldVsEvent = vsEvents.find((e: any) => e.category === 'SNAPSHOT' && e.label === 'VS_OLD');
  const newVsEvent = vsEvents.find((e: any) => e.category === 'SNAPSHOT' && e.label === 'VS_NEW');

  return (
    <div className="flex flex-col flex-1 w-full pb-12">
      {/* Breadcrumb */}
      <div className="flex items-center text-sm text-zinc-500 font-medium mb-3 sm:mb-4 flex-wrap gap-y-1">
        <Link to="/vs-editor" className="hover:text-zinc-700 transition-colors duration-150">VS Edits</Link>
        <ChevronRightIcon className="w-4 h-4 mx-1 text-zinc-300 shrink-0" />
        <span className="font-mono text-xs text-zinc-800 truncate max-w-[150px] sm:max-w-[200px]">{edit.id}</span>
      </div>

      {/* Header */}
      <div className="flex flex-col gap-3 mb-4 sm:mb-5">
        <div className="flex items-center gap-2 sm:gap-3 flex-wrap">
          <h1 className="text-lg sm:text-xl font-semibold text-zinc-900">VS Edit Summary</h1>
          <StatusBadge status={edit.status} />
        </div>
        <div className="flex items-center gap-2 flex-wrap">
          {edit.status === 'LOCKED' && (
            <PermissionGate product="autopilot" permission="RELEASE_CREATE">
              <Button size="sm" variant="outline" loading={unlockMut.isPending}
                onClick={() => doAction('Unlock', () => unlockMut.mutateAsync())}>
                <Unlock className="w-3.5 h-3.5" /> Unlock
              </Button>
            </PermissionGate>
          )}

          {edit.status === 'CREATED' && !edit.approved_by && (
            <PermissionGate product="autopilot" permission="RELEASE_CREATE">
              <Button size="sm" variant="success" loading={approveMut.isPending}
                onClick={() => doAction('Approve', () => approveMut.mutateAsync())}>
                <Check className="w-3.5 h-3.5" /> Approve
              </Button>
              <Button size="sm" variant="outline" className="border-red-300 text-red-700 hover:bg-red-50"
                loading={discardMut.isPending}
                onClick={() => doAction('Discard', () => discardMut.mutateAsync(), true)}>
                <X className="w-3.5 h-3.5" /> Discard
              </Button>
            </PermissionGate>
          )}

          {edit.status === 'CREATED' && edit.approved_by && (
            <PermissionGate product="autopilot" permission="RELEASE_CREATE">
              <Button size="sm" variant="success" loading={applyMut.isPending}
                onClick={() => doAction('Apply', () => applyMut.mutateAsync())}>
                <Play className="w-3.5 h-3.5" /> Apply
              </Button>
              <Button size="sm" variant="outline" className="border-red-300 text-red-700 hover:bg-red-50"
                loading={discardMut.isPending}
                onClick={() => doAction('Discard', () => discardMut.mutateAsync(), true)}>
                <X className="w-3.5 h-3.5" /> Discard
              </Button>
            </PermissionGate>
          )}

          <Button size="icon" variant="ghost" onClick={() => refetch()}><RefreshCw className="w-4 h-4" /></Button>
        </div>
      </div>

      {/* Tabs */}
      <div className="bg-white rounded-xl border border-zinc-200">
        <div className="flex border-b border-zinc-200 px-2 sm:px-5 overflow-x-auto">
          {tabs.map(t => (
            <button key={t} onClick={() => setActiveTab(t)}
              className={cn('py-3 px-3 sm:px-4 text-sm font-medium border-b-2 transition-colors duration-150 cursor-pointer whitespace-nowrap', activeTab === t ? 'border-zinc-900 text-zinc-900' : 'border-transparent text-zinc-400 hover:text-zinc-600')}>
              {t}
            </button>
          ))}
        </div>

        {activeTab === 'Summary' && (
          <div className="p-4 sm:p-6">
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-4 sm:gap-x-6 gap-y-3">
              <InfoField label="ID" value={edit.id} mono />
              <InfoField label="App Group" value={edit.appGroup} />
              <InfoField label="Service" value={edit.service} />
              <InfoField label="VS Name" value={edit.vs_name} />
              <InfoField label="Status" value={edit.status} />
              <InfoField label="Created By" value={edit.created_by} />
              <InfoField label="Approved By" value={edit.approved_by} />
              <InfoField label="Locked By" value={edit.locked_by} />
              <InfoField label="Created At" value={formatDate(edit.created_at)} mono />
              <InfoField label="Updated At" value={formatDate(edit.updated_at)} mono />
            </div>
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
                {sortedEvents.map((ev: any, i: number) => (
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
            <Editor height="60vh" defaultLanguage="json" theme="light" value={JSON.stringify(edit, null, 2)}
              options={{ readOnly: true, minimap: { enabled: false }, fontSize: 13, lineNumbers: 'on', scrollBeyondLastLine: false, wordWrap: 'on', automaticLayout: true }} />
          </div>
        )}

        {activeTab === 'VS Diff' && (
          <div className="p-0">
            {(oldVsEvent || newVsEvent) ? (
              <div className="overflow-x-auto text-xs sm:text-sm">
                <ReactDiffViewer
                  oldValue={oldVsEvent?.data || edit.old_vs_data || ''}
                  newValue={newVsEvent?.data || edit.new_vs_data || ''}
                  splitView={true}
                  leftTitle="Old VS Data"
                  rightTitle="New VS Data"
                  useDarkTheme={false}
                />
              </div>
            ) : (
              <div className="p-6 text-sm text-zinc-400">No VS diff available. Snapshots are captured when the VS is locked/edited.</div>
            )}
          </div>
        )}
      </div>

      <div className="flex justify-end pt-5">
        <Button variant="secondary" onClick={() => navigate('/vs-editor')}>Back to VS Edits</Button>
      </div>
    </div>
  );
};

export default VSEditSummary;
