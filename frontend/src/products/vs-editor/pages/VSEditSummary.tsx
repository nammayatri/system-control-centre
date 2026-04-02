import React from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { fetchVSEditDetail, applyVSEdit, revertVSEdit, unlockVSEdit } from '../../../api';
import { StatusBadge, Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { CardSkeleton } from '../../../shared/ui/skeleton';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { useConfirm } from '../../../shared/ui/confirm-dialog';
import { Play, RotateCcw, Unlock, ChevronRight as ChevronRightIcon, RefreshCw } from 'lucide-react';
import { cn } from '../../../lib/utils';
import { toast } from 'sonner';
import ReactDiffViewer from 'react-diff-viewer-continued';

const formatDate = (d?: string) => {
  if (!d) return '-';
  const date = new Date(d);
  return date.toLocaleString('en-US', { month: 'short', day: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: true });
};

const VSEditSummary: React.FC = () => {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const confirmAction = useConfirm();

  const { data: edit, isLoading, error, refetch } = useQuery({
    queryKey: ['vs-edit', id],
    queryFn: () => fetchVSEditDetail(id!),
    enabled: !!id,
    refetchInterval: 10000,
  });

  const applyMut = useMutation({
    mutationFn: () => applyVSEdit(id!, edit?.new_vs_data || ''),
    onSuccess: () => { toast.success('VS edit applied'); queryClient.invalidateQueries({ queryKey: ['vs-edit', id] }); },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to apply'),
  });

  const revertMut = useMutation({
    mutationFn: () => revertVSEdit(id!),
    onSuccess: () => { toast.success('VS edit reverted'); queryClient.invalidateQueries({ queryKey: ['vs-edit', id] }); },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to revert'),
  });

  const unlockMut = useMutation({
    mutationFn: () => unlockVSEdit(id!),
    onSuccess: () => { toast.success('VS edit unlocked'); queryClient.invalidateQueries({ queryKey: ['vs-edit', id] }); },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to unlock'),
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

  if (isLoading) return <div className="flex flex-col flex-1 w-full pb-12 space-y-6"><CardSkeleton /><CardSkeleton /></div>;
  if (error || !edit) return <div className="p-8 text-center text-red-500">VS Edit not found</div>;

  const InfoField = ({ label, value, mono }: { label: string; value?: string; mono?: boolean }) => (
    <div>
      <div className="text-[11px] font-medium text-zinc-500 uppercase tracking-wider mb-1">{label}</div>
      <div className={cn('border border-zinc-100 rounded-lg px-3 py-2 bg-zinc-50 text-sm min-h-[38px] break-all', mono && 'font-mono text-xs')}>{value || '-'}</div>
    </div>
  );

  const isEditable = edit.status === 'LOCKED' || edit.status === 'CREATED' || edit.status === 'VS_APPLIED';

  return (
    <div className="flex flex-col flex-1 w-full pb-12">
      {/* Breadcrumb */}
      <div className="flex items-center text-sm text-zinc-500 font-medium mb-4">
        <Link to="/vs-editor" className="hover:text-zinc-700 transition-colors duration-150">VS Edits</Link>
        <ChevronRightIcon className="w-4 h-4 mx-1 text-zinc-300" />
        <span className="font-mono text-xs text-zinc-800 truncate max-w-[200px]">{edit.id}</span>
      </div>

      {/* Header */}
      <div className="flex items-center justify-between mb-5">
        <div className="flex items-center gap-3">
          <h1 className="text-lg font-semibold text-zinc-900">VS Edit Summary</h1>
          <StatusBadge status={edit.status} />
        </div>
        <div className="flex items-center gap-2">
          {isEditable && (
            <PermissionGate product="autopilot" permission="RELEASE_CREATE">
              <Button size="sm" variant="success" loading={applyMut.isPending} onClick={() => doAction('Apply', () => applyMut.mutateAsync())}>
                <Play className="w-3.5 h-3.5" /> Apply
              </Button>
              <Button size="sm" variant="outline" className="border-violet-300 text-violet-700 hover:bg-violet-50" loading={revertMut.isPending} onClick={() => doAction('Revert', () => revertMut.mutateAsync(), true)}>
                <RotateCcw className="w-3.5 h-3.5" /> Revert
              </Button>
              <Button size="sm" variant="outline" loading={unlockMut.isPending} onClick={() => doAction('Unlock', () => unlockMut.mutateAsync())}>
                <Unlock className="w-3.5 h-3.5" /> Unlock
              </Button>
            </PermissionGate>
          )}
          <Button size="icon" variant="ghost" onClick={() => refetch()}><RefreshCw className="w-4 h-4" /></Button>
        </div>
      </div>

      {/* Info Card */}
      <div className="bg-white rounded-xl border border-zinc-200 mb-6">
        <div className="p-6">
          <div className="grid grid-cols-2 md:grid-cols-3 gap-x-6 gap-y-3">
            <InfoField label="ID" value={edit.id} mono />
            <InfoField label="Product" value={edit.appGroup} />
            <InfoField label="Service" value={edit.service} />
            <InfoField label="VS Name" value={edit.vs_name} />
            <InfoField label="Status" value={edit.status} />
            <InfoField label="Created By" value={edit.created_by} />
            <InfoField label="Created At" value={formatDate(edit.created_at)} mono />
            <InfoField label="Updated At" value={formatDate(edit.updated_at)} mono />
          </div>
        </div>
      </div>

      {/* Diff View */}
      {(edit.old_vs_data || edit.new_vs_data) && (
        <div className="bg-white rounded-xl border border-zinc-200">
          <div className="px-6 py-4 border-b border-zinc-100">
            <h2 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider">VS Data Diff</h2>
          </div>
          <div className="overflow-hidden">
            <ReactDiffViewer
              oldValue={edit.old_vs_data || ''}
              newValue={edit.new_vs_data || ''}
              splitView={true}
              leftTitle="Old VS Data"
              rightTitle="New VS Data"
              useDarkTheme={false}
            />
          </div>
        </div>
      )}

      <div className="flex justify-end pt-5">
        <Button variant="secondary" onClick={() => navigate('/vs-editor')}>Back to VS Edits</Button>
      </div>
    </div>
  );
};

export default VSEditSummary;
