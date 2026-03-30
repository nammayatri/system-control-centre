import React, { useState, useMemo } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import {
  fetchReleaseConfigs, createReleaseConfig, updateReleaseConfig,
  deleteReleaseConfig, fetchProductConfigs,
} from '../../../api';
import type { ReleaseConfig, ProductConfig } from '../../../api';
import { Button } from '../../../shared/ui/button';
import { TableSkeleton } from '../../../shared/ui/skeleton';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { useConfirm } from '../../../shared/ui/confirm-dialog';
import {
  Dialog, DialogContent, DialogHeader, DialogTitle,
  DialogDescription, DialogBody, DialogFooter,
} from '../../../shared/ui/dialog';
import { Search, Plus, RefreshCw, Pencil, Trash2 } from 'lucide-react';
import { cn } from '../../../lib/utils';
import { toast } from 'sonner';

const EMPTY_FORM: Partial<ReleaseConfig> = {
  product: '', service: '', host: '', rollout_strategy: '', slack_channel: '',
};

const truncateJson = (json: string, maxLen = 60): string => {
  if (!json) return '-';
  const s = json.length > maxLen ? json.slice(0, maxLen) + '...' : json;
  return s;
};

const ServiceConfigs: React.FC = () => {
  const queryClient = useQueryClient();
  const confirmAction = useConfirm();
  const [search, setSearch] = useState('');
  const [productFilter, setProductFilter] = useState('');
  const [modalOpen, setModalOpen] = useState(false);
  const [editingConfig, setEditingConfig] = useState<ReleaseConfig | null>(null);
  const [form, setForm] = useState<Partial<ReleaseConfig>>(EMPTY_FORM);

  const { data: configs = [], isLoading, refetch } = useQuery({
    queryKey: ['release-configs', productFilter],
    queryFn: () => fetchReleaseConfigs(productFilter || undefined),
    staleTime: 60000,
  });

  const { data: productConfigs = [] } = useQuery({
    queryKey: ['product-configs'],
    queryFn: fetchProductConfigs,
    staleTime: 300000,
  });

  const productOptions = useMemo(() =>
    [...new Set(productConfigs.map((c: ProductConfig) => c.product).filter(Boolean))],
    [productConfigs]
  );

  const createMut = useMutation({
    mutationFn: (payload: Partial<ReleaseConfig>) => createReleaseConfig(payload),
    onSuccess: () => { toast.success('Service config created'); queryClient.invalidateQueries({ queryKey: ['release-configs'] }); setModalOpen(false); },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to create'),
  });

  const updateMut = useMutation({
    mutationFn: ({ id, payload }: { id: number; payload: Partial<ReleaseConfig> }) => updateReleaseConfig(id, payload),
    onSuccess: () => { toast.success('Service config updated'); queryClient.invalidateQueries({ queryKey: ['release-configs'] }); setModalOpen(false); },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to update'),
  });

  const deleteMut = useMutation({
    mutationFn: (id: number) => deleteReleaseConfig(id),
    onSuccess: () => { toast.success('Service config deleted'); queryClient.invalidateQueries({ queryKey: ['release-configs'] }); },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to delete'),
  });

  const filteredConfigs = useMemo(() => {
    if (!search) return configs;
    const q = search.toLowerCase();
    return configs.filter((c: ReleaseConfig) =>
      c.product.toLowerCase().includes(q) ||
      c.service.toLowerCase().includes(q) ||
      c.host.toLowerCase().includes(q) ||
      (c.slack_channel || '').toLowerCase().includes(q)
    );
  }, [configs, search]);

  const openCreate = () => {
    setEditingConfig(null);
    setForm(EMPTY_FORM);
    setModalOpen(true);
  };

  const openEdit = (cfg: ReleaseConfig) => {
    setEditingConfig(cfg);
    setForm({ ...cfg });
    setModalOpen(true);
  };

  const handleDelete = async (cfg: ReleaseConfig) => {
    if (!cfg.id) return;
    const ok = await confirmAction({
      title: 'Delete Service',
      description: `Are you sure you want to delete the config for "${cfg.service}"? This action cannot be undone.`,
      confirmLabel: 'Delete',
      variant: 'danger',
    });
    if (ok) deleteMut.mutate(cfg.id);
  };

  const handleSubmit = () => {
    if (editingConfig?.id) {
      updateMut.mutate({ id: editingConfig.id, payload: form });
    } else {
      createMut.mutate(form);
    }
  };

  const updateField = (field: keyof ReleaseConfig, value: any) => {
    setForm(prev => ({ ...prev, [field]: value }));
  };

  const inputClass = "w-full h-9 border border-zinc-300 rounded-lg px-3 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150";

  return (
    <div className="flex flex-col w-full">
      <div className="flex items-center justify-between mb-5">
        <h1 className="text-lg font-semibold text-zinc-900">Services</h1>
        <div className="flex items-center gap-3">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-zinc-400" />
            <input type="text" placeholder="Search configs..." value={search} onChange={e => setSearch(e.target.value)}
              className="pl-9 pr-4 h-9 border border-zinc-300 rounded-lg text-sm w-64 outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150" />
          </div>
          <select value={productFilter} onChange={e => setProductFilter(e.target.value)}
            className="border border-zinc-300 rounded-lg px-3 h-9 text-sm text-zinc-600 bg-white cursor-pointer focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent">
            <option value="">All Products</option>
            {productOptions.map((p: string) => <option key={p} value={p}>{p}</option>)}
          </select>
          <Button size="icon" variant="ghost" onClick={() => refetch()}><RefreshCw className="w-4 h-4" /></Button>
          <PermissionGate product="autopilot" permission="RELEASE_CREATE">
            <Button size="sm" onClick={openCreate}><Plus className="w-4 h-4" /> Add Config</Button>
          </PermissionGate>
        </div>
      </div>

      <div className="bg-white border border-zinc-200 rounded-xl overflow-hidden">
        {isLoading ? (
          <TableSkeleton rows={6} cols={5} />
        ) : filteredConfigs.length === 0 ? (
          <div className="p-10 text-center text-sm text-zinc-400">No service configs found.</div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left whitespace-nowrap">
              <thead>
                <tr className="bg-zinc-50 border-b border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                  <th className="py-3 px-4">Product</th>
                  <th className="py-3 px-4">Service</th>
                  <th className="py-3 px-4">Host</th>
                  <th className="py-3 px-4">Rollout Strategy</th>
                  <th className="py-3 px-4">Slack Channel</th>
                  <th className="py-3 px-4 w-24 text-center">Actions</th>
                </tr>
              </thead>
              <tbody className="text-sm">
                {filteredConfigs.map((cfg: ReleaseConfig, idx: number) => (
                  <tr key={cfg.id || idx} className={cn('border-b border-zinc-100 hover:bg-zinc-50 transition-colors duration-150', idx % 2 === 1 ? 'bg-zinc-50/50' : 'bg-white')}>
                    <td className="py-3 px-4 font-medium text-zinc-800">{cfg.product}</td>
                    <td className="py-3 px-4 text-zinc-700">{cfg.service}</td>
                    <td className="py-3 px-4 font-mono text-xs text-zinc-600">{cfg.host || '-'}</td>
                    <td className="py-3 px-4 font-mono text-xs text-zinc-500 max-w-xs truncate" title={cfg.rollout_strategy}>{truncateJson(cfg.rollout_strategy)}</td>
                    <td className="py-3 px-4 text-zinc-600">{cfg.slack_channel || '-'}</td>
                    <td className="py-3 px-4 text-center">
                      <div className="flex items-center justify-center gap-1">
                        <PermissionGate product="autopilot" permission="RELEASE_CREATE">
                          <button onClick={() => openEdit(cfg)} className="p-1.5 rounded-lg text-zinc-400 hover:text-zinc-600 hover:bg-zinc-100 cursor-pointer transition-colors duration-150"><Pencil className="w-3.5 h-3.5" /></button>
                          <button onClick={() => handleDelete(cfg)} className="p-1.5 rounded-lg text-red-400 hover:text-red-600 hover:bg-red-50 cursor-pointer transition-colors duration-150"><Trash2 className="w-3.5 h-3.5" /></button>
                        </PermissionGate>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {/* Create/Edit Modal */}
      <Dialog open={modalOpen} onOpenChange={setModalOpen}>
        <DialogContent className="max-w-lg">
          <DialogHeader>
            <DialogTitle>{editingConfig ? 'Edit Service' : 'Create Service'}</DialogTitle>
            <DialogDescription>{editingConfig ? 'Update the service configuration.' : 'Add a new service configuration.'}</DialogDescription>
          </DialogHeader>
          <DialogBody>
            <div className="space-y-4">
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Product *</label>
                  <select value={form.product || ''} onChange={e => updateField('product', e.target.value)} className={cn(inputClass, 'cursor-pointer')}>
                    <option value="">Select Product</option>
                    {productOptions.map((p: string) => <option key={p} value={p}>{p}</option>)}
                  </select>
                </div>
                <div>
                  <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Service *</label>
                  <input type="text" value={form.service || ''} onChange={e => updateField('service', e.target.value)} className={inputClass} placeholder="e.g. driver-offer-bpp" />
                </div>
              </div>
              <div>
                <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Host</label>
                <input type="text" value={form.host || ''} onChange={e => updateField('host', e.target.value)} className={inputClass} placeholder="e.g. api.example.com" />
              </div>
              <div>
                <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Rollout Strategy (JSON)</label>
                <textarea
                  value={form.rollout_strategy || ''}
                  onChange={e => updateField('rollout_strategy', e.target.value)}
                  rows={5}
                  className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm font-mono resize-y focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150"
                  placeholder='[{"rolloutPercent": 5, "cooloffSeconds": 300, "podPercent": 2}]'
                />
              </div>
              <div>
                <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Slack Channel</label>
                <input type="text" value={form.slack_channel || ''} onChange={e => updateField('slack_channel', e.target.value)} className={inputClass} placeholder="e.g. #releases" />
              </div>
            </div>
          </DialogBody>
          <DialogFooter>
            <Button variant="secondary" size="sm" onClick={() => setModalOpen(false)}>Cancel</Button>
            <Button size="sm" onClick={handleSubmit} loading={createMut.isPending || updateMut.isPending}>
              {editingConfig ? 'Update' : 'Create'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default ServiceConfigs;
