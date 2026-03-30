import React, { useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { apiClient } from '../../../lib/api-client';
import { Button } from '../../../shared/ui/button';
import { TableSkeleton } from '../../../shared/ui/skeleton';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { Plus, Save, X, RefreshCw, Search } from 'lucide-react';
import { toast } from 'sonner';
import { cn } from '../../../lib/utils';

interface ServerConfig {
  id: number;
  type: string;
  name: string;
  value: string;
  enabled: number;
}

interface EditingRow {
  configType: string;
  name: string;
  value: string;
  enabled: number;
  isNew?: boolean;
}

const Configurations: React.FC = () => {
  const queryClient = useQueryClient();
  const [newRow, setNewRow] = useState<EditingRow | null>(null);
  const [search, setSearch] = useState('');
  const [selectedConfig, setSelectedConfig] = useState<ServerConfig | null>(null);
  const [modalValue, setModalValue] = useState('');
  const [modalEnabled, setModalEnabled] = useState(1);

  const { data: configs = [], isLoading, refetch } = useQuery({
    queryKey: ['server-configs'],
    queryFn: async () => { const res = await apiClient.get('/server-config'); return res.data.configs || []; },
  });

  const saveMut = useMutation({
    mutationFn: async (row: EditingRow) => {
      await apiClient.post('/server-config', { name: row.name, type: row.configType, value: row.value, enabled: String(row.enabled) });
    },
    onSuccess: (_, row) => {
      toast.success(`Saved: ${row.name}`);
      setNewRow(null);
      setSelectedConfig(null);
      queryClient.invalidateQueries({ queryKey: ['server-configs'] });
    },
    onError: (err: any) => { toast.error(err.message || 'Failed to save'); },
  });

  const openConfigModal = (cfg: ServerConfig) => {
    setSelectedConfig(cfg);
    setModalValue(cfg.value || '');
    setModalEnabled(cfg.enabled);
  };

  const handleModalUpdate = () => {
    if (!selectedConfig) return;
    saveMut.mutate({ configType: selectedConfig.type, name: selectedConfig.name, value: modalValue, enabled: modalEnabled });
  };

  const filtered = configs.filter((c: ServerConfig) =>
    !search || c.name.toLowerCase().includes(search.toLowerCase()) || (c.type || '').toLowerCase().includes(search.toLowerCase()) || (c.value || '').toLowerCase().includes(search.toLowerCase())
  );

  const inputClass = "h-9 border border-zinc-300 rounded-lg px-3 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150";

  return (
    <div className="flex flex-col w-full">
      {/* Header */}
      <div className="flex items-center justify-between mb-5">
        <h1 className="text-lg font-semibold text-zinc-900">Server Configurations</h1>
        <div className="flex items-center gap-3">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-zinc-400" />
            <input type="text" placeholder="Search configs..." value={search} onChange={e => setSearch(e.target.value)}
              className="pl-9 pr-4 h-9 border border-zinc-300 rounded-lg text-sm w-64 outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150" />
          </div>
          <Button size="icon" variant="ghost" onClick={() => refetch()}><RefreshCw className="w-4 h-4" /></Button>
          <PermissionGate product="backend-releases" permission="SERVICE_CONFIG_EDIT">
            <Button size="sm" onClick={() => setNewRow({ configType: '', name: '', value: '', enabled: 1, isNew: true })} disabled={!!newRow}>
              <Plus className="w-4 h-4" /> Add Config
            </Button>
          </PermissionGate>
        </div>
      </div>

      {/* Table */}
      <div className="bg-white rounded-xl border border-zinc-200 overflow-hidden">
        {isLoading ? (
          <TableSkeleton rows={6} cols={4} />
        ) : (
          <table className="w-full text-left">
            <thead>
              <tr className="bg-zinc-50 border-b border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                <th className="px-4 py-3 w-28">Type</th>
                <th className="px-4 py-3 w-56">Name</th>
                <th className="px-4 py-3">Value</th>
                <th className="px-4 py-3 w-24">Enabled</th>
              </tr>
            </thead>
            <tbody className="text-sm">
              {newRow && (
                <tr className="bg-sky-50/50 border-b border-zinc-100">
                  <td className="px-4 py-2"><input value={newRow.configType} onChange={e => setNewRow({ ...newRow, configType: e.target.value })} placeholder="Type" className={cn(inputClass, 'w-full')} /></td>
                  <td className="px-4 py-2"><input value={newRow.name} onChange={e => setNewRow({ ...newRow, name: e.target.value })} placeholder="Config name" className={cn(inputClass, 'w-full')} /></td>
                  <td className="px-4 py-2"><input value={newRow.value} onChange={e => setNewRow({ ...newRow, value: e.target.value })} placeholder="Value" className={cn(inputClass, 'w-full')} /></td>
                  <td className="px-4 py-2">
                    <div className="flex items-center gap-2">
                      <select value={newRow.enabled} onChange={e => setNewRow({ ...newRow, enabled: Number(e.target.value) })} className={cn(inputClass, 'w-16 cursor-pointer')}>
                        <option value={1}>Yes</option><option value={0}>No</option>
                      </select>
                      <button onClick={() => newRow.name && saveMut.mutate(newRow)} disabled={!newRow.name || saveMut.isPending} className="p-1.5 rounded-lg bg-emerald-600 hover:bg-emerald-700 disabled:opacity-50 disabled:pointer-events-none text-white cursor-pointer transition-colors duration-150"><Save className="w-3.5 h-3.5" /></button>
                      <button onClick={() => setNewRow(null)} className="p-1.5 rounded-lg bg-zinc-200 hover:bg-zinc-300 text-zinc-600 cursor-pointer transition-colors duration-150"><X className="w-3.5 h-3.5" /></button>
                    </div>
                  </td>
                </tr>
              )}
              {filtered.map((cfg: ServerConfig, i: number) => (
                <tr key={cfg.id} className={cn('border-b border-zinc-100 hover:bg-zinc-100 cursor-pointer transition-colors duration-150', i % 2 === 1 ? 'bg-zinc-50' : 'bg-white')} onClick={() => openConfigModal(cfg)}>
                  <td className="px-4 py-2.5 text-zinc-500">{cfg.type || '-'}</td>
                  <td className="px-4 py-2.5 font-medium text-zinc-800">{cfg.name}</td>
                  <td className="px-4 py-2.5"><span className="text-zinc-600 font-mono text-xs block truncate max-w-md">{cfg.value || '-'}</span></td>
                  <td className="px-4 py-2.5">
                    <span className={cn('inline-flex items-center gap-1.5 px-2 py-0.5 rounded-md text-[10px] font-medium uppercase border', cfg.enabled ? 'bg-emerald-50 text-emerald-700 border-emerald-200' : 'bg-red-50 text-red-700 border-red-200')}>
                      <span className={cn('w-1.5 h-1.5 rounded-full', cfg.enabled ? 'bg-emerald-500' : 'bg-red-500')} />
                      {cfg.enabled ? 'Yes' : 'No'}
                    </span>
                  </td>
                </tr>
              ))}
              {filtered.length === 0 && !newRow && (
                <tr><td colSpan={4} className="px-4 py-10 text-center text-sm text-zinc-400">No configurations found.</td></tr>
              )}
            </tbody>
          </table>
        )}
      </div>

      {/* Edit Modal */}
      {selectedConfig && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40" onClick={() => setSelectedConfig(null)}>
          <div className="bg-white rounded-xl border border-zinc-200 shadow-xl w-full max-w-lg mx-4" onClick={e => e.stopPropagation()}>
            <div className="flex items-center justify-between px-6 pt-5 pb-2">
              <h2 className="text-base font-semibold text-zinc-900">{selectedConfig.name}</h2>
              <button onClick={() => setSelectedConfig(null)} className="p-1 rounded-lg hover:bg-zinc-100 text-zinc-400 hover:text-zinc-600 cursor-pointer transition-colors duration-150"><X className="w-5 h-5" /></button>
            </div>
            <div className="px-6 py-4 space-y-4">
              <div>
                <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Enable Flag</label>
                <input type="number" min={0} max={1} value={modalEnabled} onChange={e => setModalEnabled(Number(e.target.value))} className={cn(inputClass, 'w-48')} />
              </div>
              <div>
                <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Config Value</label>
                <textarea value={modalValue} onChange={e => setModalValue(e.target.value)} rows={8} className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm font-mono text-xs resize-y focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150" />
              </div>
            </div>
            <div className="flex items-center justify-end gap-3 px-6 pb-5 pt-2 border-t border-zinc-100">
              <Button variant="secondary" onClick={() => setSelectedConfig(null)}>Cancel</Button>
              <Button onClick={handleModalUpdate} loading={saveMut.isPending}>Update</Button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

export default Configurations;
