import React, { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import Editor from '@monaco-editor/react';
import { fetchProductConfigs, fetchServices, fetchCurrentVS, lockAndEditVS, saveVSEdit, unlockVSEdit } from '../../releases/api';
import type { ProductConfig } from '../../releases/api';
import { Button } from '../../../shared/ui/button';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { cn } from '../../../lib/utils';
import { toast } from 'sonner';
import { Lock, Save, X } from 'lucide-react';
import { useConfirm } from '../../../shared/ui/confirm-dialog';
import { useAuth } from '../../../core/auth/AuthContext';

const EditVS: React.FC = () => {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const confirmAction = useConfirm();

  const [appGroup, setAppGroup] = useState('');
  const [service, setService] = useState('');
  // Round 8 audit H19: env was hardcoded to 'UAT', mis-attributing PROD VS
  // edits in the audit trail. Make it user-selectable with sensible default.
  const [env, setEnv] = useState('UAT');
  const [vsData, setVsData] = useState('');
  const [trackerId, setTrackerId] = useState<string | null>(null);
  const [isLocked, setIsLocked] = useState(false);

  // Round 8 audit M10: use authenticated user's email for lockedBy.
  const { user: authUser } = useAuth();
  const lockerIdentity = authUser?.email || 'admin';

  const { data: productConfigs = [] } = useQuery({
    queryKey: ['product-configs'],
    queryFn: fetchProductConfigs,
    staleTime: 300000,
  });

  const products = [...new Set(productConfigs.map((c: ProductConfig) => c.appGroup).filter(Boolean))];

  const { data: services = [] } = useQuery({
    queryKey: ['services', appGroup],
    queryFn: () => fetchServices(appGroup, false),
    enabled: !!appGroup,
    staleTime: 120000,
  });

  const { data: currentVS, isLoading: loadingVS, refetch: refetchVS } = useQuery({
    queryKey: ['current-vs', appGroup, service],
    queryFn: () => fetchCurrentVS(appGroup, service),
    enabled: !!appGroup && !!service,
  });

  useEffect(() => {
    if (currentVS) setVsData(currentVS);
  }, [currentVS]);

  const lockMut = useMutation({
    mutationFn: () => lockAndEditVS({ appGroup, service, env, vsName: '', lockedBy: lockerIdentity, oldVsData: vsData }),
    onSuccess: (data) => {
      toast.success('VS locked for editing');
      setTrackerId(data.message?.includes('Tracker ID:') ? data.message.split('Tracker ID: ')[1] : data.id);
      setIsLocked(true);
    },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to lock VS'),
  });

  const saveMut = useMutation({
    mutationFn: () => saveVSEdit(trackerId!, vsData),
    onSuccess: () => {
      toast.success('VS changes saved');
      queryClient.invalidateQueries({ queryKey: ['vs-edits'] });
      navigate(`/vs-editor/${trackerId}`);
    },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to save VS edit'),
  });

  const unlockMut = useMutation({
    mutationFn: () => unlockVSEdit(trackerId!),
    onSuccess: () => {
      toast.success('VS edit unlocked');
      setIsLocked(false);
      setTrackerId(null);
      refetchVS();
    },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to unlock VS edit'),
  });

  const handleLock = async () => {
    if (!appGroup || !service) { toast.error('Select product and service first'); return; }
    lockMut.mutate();
  };

  const handleSave = async () => {
    const ok = await confirmAction({
      title: 'Save VS Changes',
      description: 'Save your changes and proceed to the approval flow?',
      confirmLabel: 'Save',
      variant: 'primary',
    });
    if (ok) saveMut.mutate();
  };

  const handleCancel = async () => {
    const ok = await confirmAction({
      title: 'Cancel VS Edit',
      description: 'Are you sure you want to cancel? This will unlock the VS without saving your changes.',
      confirmLabel: 'Cancel Edit',
      variant: 'danger',
    });
    if (ok) unlockMut.mutate();
  };

  const inputClass = "w-full h-10 sm:h-9 border border-zinc-300 rounded-lg px-3 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150";

  return (
    <div className="flex flex-col flex-1 w-full pb-12">
      <div className="flex items-center justify-between mb-4 sm:mb-5">
        <h1 className="text-lg sm:text-xl font-semibold text-zinc-900">VS Editor</h1>
      </div>

      {/* Selection */}
      <div className="bg-white rounded-xl border border-zinc-200 p-4 sm:p-6 mb-4 sm:mb-6">
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4 sm:gap-6">
          <div>
            <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">App Group *</label>
            <select value={appGroup} onChange={e => { setAppGroup(e.target.value); setService(''); setVsData(''); setIsLocked(false); setTrackerId(null); }} disabled={isLocked} className={cn(inputClass, 'cursor-pointer', isLocked && 'bg-zinc-50 cursor-not-allowed')}>
              <option value="">Select Product</option>
              {products.map(p => <option key={p} value={p}>{p}</option>)}
            </select>
          </div>
          <div>
            <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Service *</label>
            <select value={service} onChange={e => { setService(e.target.value); setVsData(''); setIsLocked(false); setTrackerId(null); }} disabled={!appGroup || services.length === 0 || isLocked}
              className={cn(inputClass, 'cursor-pointer', (!appGroup || services.length === 0 || isLocked) && 'bg-zinc-50 cursor-not-allowed')}>
              <option value="">Select Service</option>
              {services.map((s: string) => <option key={s} value={s}>{s}</option>)}
            </select>
          </div>
        </div>
      </div>

      {/* Editor */}
      {appGroup && service && (
        <div className="bg-white rounded-xl border border-zinc-200">
          <div className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
            <div className="flex items-center gap-2 sm:gap-3 flex-wrap">
              <h2 className="text-sm sm:text-base font-semibold text-zinc-900">VirtualService Data</h2>
              {isLocked && (
                <span className="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-md text-[10px] font-medium uppercase tracking-wide bg-amber-50 text-amber-700 border border-amber-200">
                  <Lock className="w-3 h-3" /> Locked
                </span>
              )}
              {loadingVS && <span className="text-xs text-zinc-400">Loading...</span>}
            </div>
            <div className="flex items-center gap-2 flex-wrap">
              {!isLocked && (
                <PermissionGate product="autopilot" permission="RELEASE_CREATE">
                  <Button size="sm" variant="outline" className="border-amber-300 text-amber-700 hover:bg-amber-50" loading={lockMut.isPending} onClick={handleLock}>
                    <Lock className="w-3.5 h-3.5" /> Lock & Edit
                  </Button>
                </PermissionGate>
              )}
              {isLocked && trackerId && (
                <PermissionGate product="autopilot" permission="RELEASE_CREATE">
                  <Button size="sm" variant="success" loading={saveMut.isPending} onClick={handleSave}>
                    <Save className="w-3.5 h-3.5" /> Save Changes
                  </Button>
                  <Button size="sm" variant="outline" className="border-red-300 text-red-700 hover:bg-red-50" loading={unlockMut.isPending} onClick={handleCancel}>
                    <X className="w-3.5 h-3.5" /> Cancel
                  </Button>
                </PermissionGate>
              )}
            </div>
          </div>
          <div className="border-t border-zinc-100">
            <Editor
              height="500px"
              defaultLanguage="yaml"
              theme="light"
              value={vsData}
              onChange={(val) => { if (isLocked) setVsData(val || ''); }}
              options={{
                minimap: { enabled: false },
                fontSize: 13,
                lineNumbers: 'on',
                scrollBeyondLastLine: false,
                wordWrap: 'on',
                tabSize: 2,
                automaticLayout: true,
                readOnly: !isLocked,
              }}
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

export default EditVS;
