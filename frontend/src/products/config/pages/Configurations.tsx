import React, { useState, useMemo } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { apiClient } from '../../../lib/api-client';
import { Button } from '../../../shared/ui/button';
import { TableSkeleton } from '../../../shared/ui/skeleton';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { Badge } from '../../../shared/ui/badge';
import { SimpleTooltip } from '../../../shared/ui/tooltip';
import { Save, X, RefreshCw, Search, ChevronDown, ChevronRight, Info } from 'lucide-react';
import { toast } from 'sonner';
import { cn } from '../../../lib/utils';

interface ConfigItem {
  key: string;
  value: string;
  type: string;       // "bool" | "int" | "double" | "text" | "json"
  default: string;
  description: string;
  product: string | null;
  enabled: boolean;
  id: number;
}

interface ConfigGroup {
  name: string;
  configs: ConfigItem[];
}

interface GroupedResponse {
  groups: ConfigGroup[];
}

const Configurations: React.FC = () => {
  const queryClient = useQueryClient();
  const [search, setSearch] = useState('');
  const [selectedConfig, setSelectedConfig] = useState<ConfigItem | null>(null);
  const [modalValue, setModalValue] = useState('');
  const [modalEnabled, setModalEnabled] = useState(true);
  const [collapsedGroups, setCollapsedGroups] = useState<Set<string>>(new Set());
  const [validationError, setValidationError] = useState('');

  const { data, isLoading, refetch } = useQuery({
    queryKey: ['server-configs'],
    queryFn: async () => {
      const res = await apiClient.get('/server-config');
      return res.data as GroupedResponse;
    },
  });

  const groups = data?.groups ?? [];

  const saveMut = useMutation({
    mutationFn: async (params: { name: string; value: string; enabled: string }) => {
      await apiClient.post('/server-config', params);
    },
    onSuccess: (_: void, params) => {
      toast.success(`Saved: ${params.name}`);
      setSelectedConfig(null);
      queryClient.invalidateQueries({ queryKey: ['server-configs'] });
    },
    onError: (err: Error) => { toast.error(err.message || 'Failed to save'); },
  });

  const openConfigModal = (cfg: ConfigItem) => {
    setSelectedConfig(cfg);
    setModalValue(cfg.value || '');
    setModalEnabled(cfg.enabled);
    setValidationError('');
  };

  const validateValue = (type: string, value: string): string => {
    switch (type) {
      case 'bool':
        if (!['true', 'false', '1', '0', 'yes', 'no'].includes(value.toLowerCase())) {
          return 'Must be true or false';
        }
        return '';
      case 'int':
        if (!/^-?\d+$/.test(value.trim())) return 'Must be an integer';
        return '';
      case 'double':
        if (isNaN(Number(value.trim())) || value.trim() === '') return 'Must be a number';
        return '';
      default:
        return '';
    }
  };

  const handleModalUpdate = () => {
    if (!selectedConfig) return;
    const err = validateValue(selectedConfig.type, modalValue);
    if (err) {
      setValidationError(err);
      return;
    }
    saveMut.mutate({
      name: selectedConfig.key,
      value: modalValue,
      enabled: modalEnabled ? '1' : '0',
    });
  };

  const toggleGroup = (name: string) => {
    setCollapsedGroups(prev => {
      const next = new Set(prev);
      if (next.has(name)) next.delete(name);
      else next.add(name);
      return next;
    });
  };

  const filteredGroups = useMemo(() => {
    if (!search) return groups;
    const q = search.toLowerCase();
    return groups
      .map(g => ({
        ...g,
        configs: g.configs.filter(c =>
          c.key.toLowerCase().includes(q) ||
          c.description.toLowerCase().includes(q) ||
          (c.product || '').toLowerCase().includes(q) ||
          (c.value || '').toLowerCase().includes(q)
        ),
      }))
      .filter(g => g.configs.length > 0);
  }, [groups, search]);

  const productBadgeVariant = (product: string | null): 'info' | 'muted' => {
    return product ? 'info' : 'muted';
  };

  const typeBadgeVariant = (type: string): 'default' | 'purple' | 'warning' | 'success' => {
    switch (type) {
      case 'bool': return 'purple';
      case 'int': case 'double': return 'warning';
      case 'json': return 'success';
      default: return 'default';
    }
  };

  const renderValueInput = () => {
    if (!selectedConfig) return null;
    const { type } = selectedConfig;

    if (type === 'bool') {
      return (
        <div className="space-y-1.5">
          <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider">Value</label>
          <div className="flex items-center gap-3">
            <button
              type="button"
              onClick={() => { setModalValue(modalValue === 'true' ? 'false' : 'true'); setValidationError(''); }}
              className={cn(
                'relative inline-flex h-6 w-11 items-center rounded-full transition-colors duration-200 cursor-pointer',
                modalValue === 'true' ? 'bg-emerald-500' : 'bg-zinc-300'
              )}
            >
              <span className={cn(
                'inline-block h-4 w-4 rounded-full bg-white transition-transform duration-200 shadow-sm',
                modalValue === 'true' ? 'translate-x-6' : 'translate-x-1'
              )} />
            </button>
            <span className="text-sm text-zinc-600 font-mono">{modalValue}</span>
          </div>
        </div>
      );
    }

    if (type === 'int' || type === 'double') {
      return (
        <div className="space-y-1.5">
          <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider">Value</label>
          <input
            type="number"
            step={type === 'double' ? 'any' : '1'}
            value={modalValue}
            onChange={e => { setModalValue(e.target.value); setValidationError(''); }}
            className="w-full h-9 rounded-lg border border-zinc-300 px-3 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150"
          />
          {validationError && <p className="text-xs text-red-500">{validationError}</p>}
        </div>
      );
    }

    // text or json
    return (
      <div className="space-y-1.5">
        <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider">Value</label>
        <textarea
          value={modalValue}
          onChange={e => { setModalValue(e.target.value); setValidationError(''); }}
          rows={type === 'json' ? 8 : 4}
          className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm font-mono resize-y focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150"
        />
        {validationError && <p className="text-xs text-red-500">{validationError}</p>}
      </div>
    );
  };

  return (
    <div className="flex flex-col w-full">
      {/* Header */}
      <div className="flex items-center justify-between mb-5">
        <h1 className="text-lg font-semibold text-zinc-900">Server Configurations</h1>
        <div className="flex items-center gap-3">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-zinc-400" />
            <input
              type="text"
              placeholder="Search configs..."
              value={search}
              onChange={e => setSearch(e.target.value)}
              className="pl-9 pr-4 h-9 border border-zinc-300 rounded-lg text-sm w-64 outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150"
            />
          </div>
          <Button size="icon" variant="ghost" onClick={() => refetch()}>
            <RefreshCw className="w-4 h-4" />
          </Button>
        </div>
      </div>

      {/* Grouped configs */}
      {isLoading ? (
        <div className="bg-white rounded-xl border border-zinc-200 overflow-hidden">
          <TableSkeleton rows={8} cols={4} />
        </div>
      ) : filteredGroups.length === 0 ? (
        <div className="bg-white rounded-xl border border-zinc-200 p-10 text-center text-sm text-zinc-400">
          No configurations found.
        </div>
      ) : (
        <div className="space-y-3">
          {filteredGroups.map(group => {
            const isCollapsed = collapsedGroups.has(group.name);
            return (
              <div key={group.name} className="bg-white rounded-xl border border-zinc-200 overflow-hidden">
                {/* Group header */}
                <button
                  type="button"
                  onClick={() => toggleGroup(group.name)}
                  className="w-full flex items-center justify-between px-4 py-3 bg-zinc-50 border-b border-zinc-200 cursor-pointer hover:bg-zinc-100 transition-colors duration-150"
                >
                  <div className="flex items-center gap-2">
                    {isCollapsed
                      ? <ChevronRight className="w-4 h-4 text-zinc-400" />
                      : <ChevronDown className="w-4 h-4 text-zinc-400" />}
                    <span className="text-sm font-semibold text-zinc-700">{group.name}</span>
                    <span className="text-[10px] text-zinc-400 font-medium">{group.configs.length} configs</span>
                  </div>
                </button>

                {/* Config rows */}
                {!isCollapsed && (
                  <table className="w-full text-left">
                    <thead>
                      <tr className="border-b border-zinc-100 text-[11px] text-zinc-400 font-medium uppercase tracking-wider">
                        <th className="px-4 py-2 w-64">Name</th>
                        <th className="px-4 py-2 w-20">Type</th>
                        <th className="px-4 py-2">Value</th>
                        <th className="px-4 py-2 w-28">Product</th>
                        <th className="px-4 py-2 w-20">Status</th>
                      </tr>
                    </thead>
                    <tbody className="text-sm">
                      {group.configs.map((cfg, i) => (
                        <tr
                          key={cfg.key}
                          className={cn(
                            'border-b border-zinc-50 hover:bg-zinc-50 cursor-pointer transition-colors duration-150',
                            i % 2 === 1 ? 'bg-zinc-25' : 'bg-white'
                          )}
                          onClick={() => openConfigModal(cfg)}
                        >
                          <td className="px-4 py-2.5">
                            <div className="flex items-center gap-1.5">
                              <span className="font-medium text-zinc-800">{cfg.key}</span>
                              {cfg.description && (
                                <SimpleTooltip content={cfg.description}>
                                  <Info className="w-3.5 h-3.5 text-zinc-300 hover:text-zinc-500 transition-colors" />
                                </SimpleTooltip>
                              )}
                            </div>
                          </td>
                          <td className="px-4 py-2.5">
                            <Badge variant={typeBadgeVariant(cfg.type)} size="sm">{cfg.type}</Badge>
                          </td>
                          <td className="px-4 py-2.5">
                            {cfg.type === 'bool' ? (
                              <span className={cn(
                                'inline-flex items-center gap-1.5 text-xs font-medium',
                                cfg.value === 'true' ? 'text-emerald-600' : 'text-zinc-400'
                              )}>
                                <span className={cn(
                                  'w-1.5 h-1.5 rounded-full',
                                  cfg.value === 'true' ? 'bg-emerald-500' : 'bg-zinc-300'
                                )} />
                                {cfg.value}
                              </span>
                            ) : (
                              <span className="text-zinc-600 font-mono text-xs block truncate max-w-md">
                                {cfg.value || cfg.default || '-'}
                              </span>
                            )}
                          </td>
                          <td className="px-4 py-2.5">
                            <Badge variant={productBadgeVariant(cfg.product)} size="sm">
                              {cfg.product || 'global'}
                            </Badge>
                          </td>
                          <td className="px-4 py-2.5">
                            <span className={cn(
                              'inline-flex items-center gap-1.5 px-2 py-0.5 rounded-md text-[10px] font-medium uppercase border',
                              cfg.enabled
                                ? 'bg-emerald-50 text-emerald-700 border-emerald-200'
                                : 'bg-red-50 text-red-700 border-red-200'
                            )}>
                              <span className={cn('w-1.5 h-1.5 rounded-full', cfg.enabled ? 'bg-emerald-500' : 'bg-red-500')} />
                              {cfg.enabled ? 'On' : 'Off'}
                            </span>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                )}
              </div>
            );
          })}
        </div>
      )}

      {/* Edit Modal */}
      {selectedConfig && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40" onClick={() => setSelectedConfig(null)}>
          <div className="bg-white rounded-xl border border-zinc-200 shadow-xl w-full max-w-lg mx-4" onClick={e => e.stopPropagation()}>
            <div className="flex items-center justify-between px-6 pt-5 pb-2">
              <div>
                <h2 className="text-base font-semibold text-zinc-900">{selectedConfig.key}</h2>
                {selectedConfig.description && (
                  <p className="text-xs text-zinc-400 mt-0.5">{selectedConfig.description}</p>
                )}
              </div>
              <button onClick={() => setSelectedConfig(null)} className="p-1 rounded-lg hover:bg-zinc-100 text-zinc-400 hover:text-zinc-600 cursor-pointer transition-colors duration-150">
                <X className="w-5 h-5" />
              </button>
            </div>

            <div className="px-6 py-4 space-y-4">
              {/* Metadata row */}
              <div className="flex items-center gap-2">
                <Badge variant={typeBadgeVariant(selectedConfig.type)} size="sm">{selectedConfig.type}</Badge>
                <Badge variant={productBadgeVariant(selectedConfig.product)} size="sm">
                  {selectedConfig.product || 'global'}
                </Badge>
                {selectedConfig.default && (
                  <span className="text-[10px] text-zinc-400">default: <span className="font-mono">{selectedConfig.default}</span></span>
                )}
              </div>

              {/* Enable toggle */}
              <div className="space-y-1.5">
                <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider">Enabled</label>
                <button
                  type="button"
                  onClick={() => setModalEnabled(!modalEnabled)}
                  className={cn(
                    'relative inline-flex h-6 w-11 items-center rounded-full transition-colors duration-200 cursor-pointer',
                    modalEnabled ? 'bg-emerald-500' : 'bg-zinc-300'
                  )}
                >
                  <span className={cn(
                    'inline-block h-4 w-4 rounded-full bg-white transition-transform duration-200 shadow-sm',
                    modalEnabled ? 'translate-x-6' : 'translate-x-1'
                  )} />
                </button>
              </div>

              {/* Value input (type-aware) */}
              {renderValueInput()}
            </div>

            <div className="flex items-center justify-end gap-3 px-6 pb-5 pt-2 border-t border-zinc-100">
              <Button variant="secondary" onClick={() => setSelectedConfig(null)}>Cancel</Button>
              <PermissionGate product="config-manager" permission="SERVICE_CONFIG_EDIT">
                <Button onClick={handleModalUpdate} loading={saveMut.isPending}>Update</Button>
              </PermissionGate>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

export default Configurations;
