import React, { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import Editor from '@monaco-editor/react';
import { fetchProductConfigs, fetchServices, fetchCurrentVS, lockAndEditVS, applyVSEdit, revertVSEdit } from '../../../api';
import type { ProductConfig } from '../../../api';
import { Button } from '../../../shared/ui/button';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { cn } from '../../../lib/utils';
import { toast } from 'sonner';
import { Lock, Play, RotateCcw } from 'lucide-react';
import { useConfirm } from '../../../shared/ui/confirm-dialog';

const EditVS: React.FC = () => {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const confirmAction = useConfirm();

  const [product, setProduct] = useState('');
  const [service, setService] = useState('');
  const [vsData, setVsData] = useState('');
  const [trackerId, setTrackerId] = useState<string | null>(null);
  const [isLocked, setIsLocked] = useState(false);

  const { data: productConfigs = [] } = useQuery({
    queryKey: ['product-configs'],
    queryFn: fetchProductConfigs,
    staleTime: 300000,
  });

  const products = [...new Set(productConfigs.map((c: ProductConfig) => c.product).filter(Boolean))];

  const { data: services = [] } = useQuery({
    queryKey: ['services', product],
    queryFn: () => fetchServices(product, false),
    enabled: !!product,
    staleTime: 120000,
  });

  const { data: currentVS, isLoading: loadingVS, refetch: refetchVS } = useQuery({
    queryKey: ['current-vs', product, service],
    queryFn: () => fetchCurrentVS(product, service),
    enabled: !!product && !!service,
  });

  useEffect(() => {
    if (currentVS) setVsData(currentVS);
  }, [currentVS]);

  const lockMut = useMutation({
    mutationFn: () => lockAndEditVS({ product, service, env: 'UAT', vsName: '', lockedBy: 'admin', oldVsData: vsData }),
    onSuccess: (data) => {
      toast.success('VS locked for editing');
      setTrackerId(data.message?.includes('Tracker ID:') ? data.message.split('Tracker ID: ')[1] : data.id);
      setIsLocked(true);
    },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to lock VS'),
  });

  const applyMut = useMutation({
    mutationFn: () => applyVSEdit(trackerId!, vsData),
    onSuccess: () => {
      toast.success('VS edit applied');
      queryClient.invalidateQueries({ queryKey: ['vs-edits'] });
      navigate(`/vs-editor/${trackerId}`);
    },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to apply VS edit'),
  });

  const revertMut = useMutation({
    mutationFn: () => revertVSEdit(trackerId!),
    onSuccess: () => {
      toast.success('VS edit reverted');
      setIsLocked(false);
      setTrackerId(null);
      refetchVS();
    },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to revert VS edit'),
  });

  const handleLock = async () => {
    if (!product || !service) { toast.error('Select product and service first'); return; }
    lockMut.mutate();
  };

  const handleApply = async () => {
    const ok = await confirmAction({
      title: 'Apply VS Edit',
      description: 'Are you sure you want to apply this VS change? This will update the live VirtualService.',
      confirmLabel: 'Apply',
      variant: 'primary',
    });
    if (ok) applyMut.mutate();
  };

  const handleRevert = async () => {
    const ok = await confirmAction({
      title: 'Revert VS Edit',
      description: 'Are you sure you want to revert to the original VS? This will discard your changes.',
      confirmLabel: 'Revert',
      variant: 'danger',
    });
    if (ok) revertMut.mutate();
  };

  const inputClass = "w-full h-9 border border-zinc-300 rounded-lg px-3 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150";

  return (
    <div className="flex flex-col flex-1 w-full pb-12 max-w-6xl">
      <div className="flex items-center justify-between mb-5">
        <h1 className="text-lg font-semibold text-zinc-900">VS Editor</h1>
      </div>

      {/* Selection */}
      <div className="bg-white rounded-xl border border-zinc-200 p-6 mb-6">
        <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div>
            <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Product *</label>
            <select value={product} onChange={e => { setProduct(e.target.value); setService(''); setVsData(''); setIsLocked(false); setTrackerId(null); }} disabled={isLocked} className={cn(inputClass, 'cursor-pointer', isLocked && 'bg-zinc-50 cursor-not-allowed')}>
              <option value="">Select Product</option>
              {products.map(p => <option key={p} value={p}>{p}</option>)}
            </select>
          </div>
          <div>
            <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Service *</label>
            <select value={service} onChange={e => { setService(e.target.value); setVsData(''); setIsLocked(false); setTrackerId(null); }} disabled={!product || services.length === 0 || isLocked}
              className={cn(inputClass, 'cursor-pointer', (!product || services.length === 0 || isLocked) && 'bg-zinc-50 cursor-not-allowed')}>
              <option value="">Select Service</option>
              {services.map((s: string) => <option key={s} value={s}>{s}</option>)}
            </select>
          </div>
        </div>
      </div>

      {/* Editor */}
      {product && service && (
        <div className="bg-white rounded-xl border border-zinc-200">
          <div className="px-6 py-4 border-b border-zinc-100 flex items-center justify-between">
            <div className="flex items-center gap-3">
              <h2 className="text-base font-semibold text-zinc-900">VirtualService Data</h2>
              {isLocked && (
                <span className="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-md text-[10px] font-medium uppercase tracking-wide bg-amber-50 text-amber-700 border border-amber-200">
                  <Lock className="w-3 h-3" /> Locked
                </span>
              )}
              {loadingVS && <span className="text-xs text-zinc-400">Loading...</span>}
            </div>
            <div className="flex items-center gap-2">
              {!isLocked && (
                <PermissionGate product="autopilot" permission="RELEASE_CREATE">
                  <Button size="sm" variant="outline" loading={lockMut.isPending} onClick={handleLock}>
                    <Lock className="w-3.5 h-3.5" /> Lock & Edit
                  </Button>
                </PermissionGate>
              )}
              {isLocked && trackerId && (
                <>
                  <PermissionGate product="autopilot" permission="RELEASE_CREATE">
                    <Button size="sm" variant="success" loading={applyMut.isPending} onClick={handleApply}>
                      <Play className="w-3.5 h-3.5" /> Apply
                    </Button>
                    <Button size="sm" variant="danger" loading={revertMut.isPending} onClick={handleRevert}>
                      <RotateCcw className="w-3.5 h-3.5" /> Revert
                    </Button>
                  </PermissionGate>
                </>
              )}
            </div>
          </div>
          <div className="border-t border-zinc-100">
            <Editor
              height="500px"
              defaultLanguage="json"
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
