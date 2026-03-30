import React, { useState, useMemo } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { fetchProductConfigs, createProductConfig, updateProductConfig, deleteProductConfig } from '../../../api';
import type { ProductConfig } from '../../../api';
import { Button } from '../../../shared/ui/button';
import { Badge } from '../../../shared/ui/badge';
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

const EMPTY_FORM: Partial<ProductConfig> = {
  product: '', cluster: '', namespace: '', vs_name: '',
  product_acronym: '', product_type: 'SERVICE', sync_cluster: '', need_infra_approval: 0,
};

const ProductConfigs: React.FC = () => {
  const queryClient = useQueryClient();
  const confirmAction = useConfirm();
  const [search, setSearch] = useState('');
  const [modalOpen, setModalOpen] = useState(false);
  const [editingConfig, setEditingConfig] = useState<ProductConfig | null>(null);
  const [form, setForm] = useState<Partial<ProductConfig>>(EMPTY_FORM);

  const { data: configs = [], isLoading, refetch } = useQuery({
    queryKey: ['product-configs'],
    queryFn: fetchProductConfigs,
    staleTime: 60000,
  });

  const createMut = useMutation({
    mutationFn: (payload: Partial<ProductConfig>) => createProductConfig(payload),
    onSuccess: () => { toast.success('Product config created'); queryClient.invalidateQueries({ queryKey: ['product-configs'] }); setModalOpen(false); },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to create'),
  });

  const updateMut = useMutation({
    mutationFn: ({ id, payload }: { id: number; payload: Partial<ProductConfig> }) => updateProductConfig(id, payload),
    onSuccess: () => { toast.success('Product config updated'); queryClient.invalidateQueries({ queryKey: ['product-configs'] }); setModalOpen(false); },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to update'),
  });

  const deleteMut = useMutation({
    mutationFn: (id: number) => deleteProductConfig(id),
    onSuccess: () => { toast.success('Product config deleted'); queryClient.invalidateQueries({ queryKey: ['product-configs'] }); },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to delete'),
  });

  const filteredConfigs = useMemo(() => {
    if (!search) return configs;
    const q = search.toLowerCase();
    return configs.filter((c: ProductConfig) =>
      c.product.toLowerCase().includes(q) ||
      c.namespace.toLowerCase().includes(q) ||
      c.vs_name.toLowerCase().includes(q) ||
      (c.product_acronym || '').toLowerCase().includes(q)
    );
  }, [configs, search]);

  const openCreate = () => {
    setEditingConfig(null);
    setForm(EMPTY_FORM);
    setModalOpen(true);
  };

  const openEdit = (cfg: ProductConfig) => {
    setEditingConfig(cfg);
    setForm({ ...cfg });
    setModalOpen(true);
  };

  const handleDelete = async (cfg: ProductConfig) => {
    if (!cfg.id) return;
    const ok = await confirmAction({
      title: 'Delete Product',
      description: `Are you sure you want to delete the config for "${cfg.product}"? This action cannot be undone.`,
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

  const updateField = (field: keyof ProductConfig, value: any) => {
    setForm(prev => ({ ...prev, [field]: value }));
  };

  const inputClass = "w-full h-9 border border-zinc-300 rounded-lg px-3 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150";

  return (
    <div className="flex flex-col w-full">
      <div className="flex items-center justify-between mb-5">
        <h1 className="text-lg font-semibold text-zinc-900">Products</h1>
        <div className="flex items-center gap-3">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-zinc-400" />
            <input type="text" placeholder="Search configs..." value={search} onChange={e => setSearch(e.target.value)}
              className="pl-9 pr-4 h-9 border border-zinc-300 rounded-lg text-sm w-64 outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150" />
          </div>
          <Button size="icon" variant="ghost" onClick={() => refetch()}><RefreshCw className="w-4 h-4" /></Button>
          <PermissionGate product="autopilot" permission="RELEASE_CREATE">
            <Button size="sm" onClick={openCreate}><Plus className="w-4 h-4" /> Add Config</Button>
          </PermissionGate>
        </div>
      </div>

      <div className="bg-white border border-zinc-200 rounded-xl overflow-hidden">
        {isLoading ? (
          <TableSkeleton rows={6} cols={7} />
        ) : filteredConfigs.length === 0 ? (
          <div className="p-10 text-center text-sm text-zinc-400">No product configs found.</div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left whitespace-nowrap">
              <thead>
                <tr className="bg-zinc-50 border-b border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                  <th className="py-3 px-4">Product</th>
                  <th className="py-3 px-4">Namespace</th>
                  <th className="py-3 px-4">VS Name</th>
                  <th className="py-3 px-4">Acronym</th>
                  <th className="py-3 px-4">Type</th>
                  <th className="py-3 px-4">Sync Cluster</th>
                  <th className="py-3 px-4">Infra Approval</th>
                  <th className="py-3 px-4 w-24 text-center">Actions</th>
                </tr>
              </thead>
              <tbody className="text-sm">
                {filteredConfigs.map((cfg: ProductConfig, idx: number) => (
                  <tr key={cfg.id || idx} className={cn('border-b border-zinc-100 hover:bg-zinc-50 transition-colors duration-150', idx % 2 === 1 ? 'bg-zinc-50/50' : 'bg-white')}>
                    <td className="py-3 px-4 font-medium text-zinc-800">{cfg.product}</td>
                    <td className="py-3 px-4 font-mono text-xs text-zinc-600">{cfg.namespace}</td>
                    <td className="py-3 px-4 font-mono text-xs text-zinc-600">{cfg.vs_name}</td>
                    <td className="py-3 px-4 text-zinc-600">{cfg.product_acronym || '-'}</td>
                    <td className="py-3 px-4"><Badge variant={cfg.product_type === 'SCHEDULER' ? 'purple' : 'default'} size="sm">{cfg.product_type}</Badge></td>
                    <td className="py-3 px-4 font-mono text-xs text-zinc-500">{cfg.sync_cluster || '-'}</td>
                    <td className="py-3 px-4">
                      <Badge variant={cfg.need_infra_approval ? 'warning' : 'muted'} size="sm">
                        {cfg.need_infra_approval ? 'Required' : 'No'}
                      </Badge>
                    </td>
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
            <DialogTitle>{editingConfig ? 'Edit Product' : 'Create Product'}</DialogTitle>
            <DialogDescription>{editingConfig ? 'Update the product configuration.' : 'Add a new product configuration.'}</DialogDescription>
          </DialogHeader>
          <DialogBody>
            <div className="space-y-4">
              <div>
                <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Product *</label>
                <input type="text" value={form.product || ''} onChange={e => updateField('product', e.target.value)} className={inputClass} placeholder="e.g. NAMMA_YATRI" />
              </div>
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Cluster *</label>
                  <input type="text" value={form.cluster || ''} onChange={e => updateField('cluster', e.target.value)} className={inputClass} placeholder="e.g. EULER_UAT" />
                </div>
                <div>
                  <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Namespace *</label>
                  <input type="text" value={form.namespace || ''} onChange={e => updateField('namespace', e.target.value)} className={inputClass} placeholder="e.g. atlas" />
                </div>
              </div>
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">VS Name</label>
                  <input type="text" value={form.vs_name || ''} onChange={e => updateField('vs_name', e.target.value)} className={inputClass} />
                </div>
                <div>
                  <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Acronym</label>
                  <input type="text" value={form.product_acronym || ''} onChange={e => updateField('product_acronym', e.target.value)} className={inputClass} />
                </div>
              </div>
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Product Type</label>
                  <select value={form.product_type || 'SERVICE'} onChange={e => updateField('product_type', e.target.value)} className={cn(inputClass, 'cursor-pointer')}>
                    <option value="SERVICE">SERVICE</option>
                    <option value="SCHEDULER">SCHEDULER</option>
                  </select>
                </div>
                <div>
                  <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Sync Cluster</label>
                  <input type="text" value={form.sync_cluster || ''} onChange={e => updateField('sync_cluster', e.target.value)} className={inputClass} />
                </div>
              </div>
              <label className="flex items-center gap-2.5 cursor-pointer">
                <input type="checkbox" checked={!!form.need_infra_approval} onChange={e => updateField('need_infra_approval', e.target.checked ? 1 : 0)} className="rounded border-zinc-300 accent-zinc-900" />
                <span className="text-sm text-zinc-700">Requires Infra Approval</span>
              </label>
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

export default ProductConfigs;
