import React, { useState, useMemo } from 'react';
import { useLocation } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { apiClient } from '../../../lib/api-client';
import { Button } from '../../../shared/ui/button';
import { TableSkeleton } from '../../../shared/ui/skeleton';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { useAuth } from '../../../core/auth/AuthContext';
import { Badge } from '../../../shared/ui/badge';
import { SimpleTooltip } from '../../../shared/ui/tooltip';
import { Save, X, RefreshCw, Search, ChevronDown, ChevronRight, Info } from 'lucide-react';
import { toast } from 'sonner';
import { useConfirm } from '../../../shared/ui/confirm-dialog';
import { cn } from '../../../lib/utils';
import { useRefreshAnimation } from '../../../shared/hooks';
import { isMobileServerConfig, isHiddenServerConfig, isReleaseOnlyServerConfig } from '../../server-config-filter';

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
  const location = useLocation();
  const { buildType } = useAuth();
  // Debug deployment (mobile_build_type='debug'); release-only configs (store
  // sync, version preview) are no-ops here, so hide them.
  const debugEnv = buildType === 'debug';
  const filter: 'backend' | 'mobile' = location.pathname.startsWith('/mobile') ? 'mobile' : 'backend';
  const [search, setSearch] = useState('');
  const [selectedConfig, setSelectedConfig] = useState<ConfigItem | null>(null);
  const [modalValue, setModalValue] = useState('');
  const [modalEnabled, setModalEnabled] = useState(true);
  const [collapsedGroups, setCollapsedGroups] = useState<Set<string>>(new Set());
  const [validationError, setValidationError] = useState('');

  const { data, isLoading, isFetching, refetch } = useQuery({
    queryKey: ['server-configs'],
    queryFn: async () => {
      const res = await apiClient.get('/server-config');
      return res.data as GroupedResponse;
    },
  });
  const { spinning: refreshSpinning, onRefresh: handleRefresh } = useRefreshAnimation(isFetching, refetch);

  const groups = useMemo(() => {
    const raw = data?.groups ?? [];
    const filtered = raw
      .map(g => ({
        ...g,
        configs: g.configs.filter(c =>
          !isHiddenServerConfig(c.key) &&
          !(debugEnv && isReleaseOnlyServerConfig(c.key)) &&
          (filter === 'mobile' ? isMobileServerConfig(c.key) : !isMobileServerConfig(c.key))
        ),
      }))
      .filter(g => g.configs.length > 0);

    // Mobile tab: collapse all sub-groups into one "Mobile" group (single section).
    if (filter === 'mobile') {
      const configs = filtered.flatMap(g => g.configs);
      return configs.length > 0 ? [{ name: 'Mobile', configs }] : [];
    }
    return filtered;
  }, [data, filter, debugEnv]);

  const saveMut = useMutation({
    mutationFn: async (params: { name: string; value: string; enabled: string }) => {
      await apiClient.post('/server-config', params);
    },
    onSuccess: (_: void, params) => {
      toast.success(`Saved: ${params.name}`);
      setSelectedConfig(null);
      queryClient.invalidateQueries({ queryKey: ['server-configs'] });
    },
    onError: (err: any) => { toast.error(err?.response?.data?.message || err.message || 'Failed to save'); },
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

  const confirmAction = useConfirm();
  const handleModalUpdate = async () => {
    if (!selectedConfig) return;
    const err = validateValue(selectedConfig.type, modalValue);
    if (err) {
      setValidationError(err);
      return;
    }
    // Server config flags drive live runtime behaviour (decision engine, kill switches) — confirm writes.
    const ok = await confirmAction({
      title: `Update ${selectedConfig.key}`,
      description: `Set "${selectedConfig.key}" to "${modalValue}"? This affects production behaviour immediately.`,
      confirmLabel: 'Update',
      variant: 'primary',
    });
    if (!ok) return;
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
            className="w-full h-10 sm:h-9 rounded-lg border border-zinc-300 px-3 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150"
          />
          {validationError && <p className="text-xs text-red-500">{validationError}</p>}
        </div>
      );
    }

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
    <div className="flex flex-col w-full pb-12">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 mb-4 sm:mb-5">
        <h1 className="text-lg sm:text-xl font-semibold text-zinc-900">
          {filter === 'mobile' ? 'Mobile Server Config' : 'Backend Server Config'}
        </h1>
        <div className="flex items-center gap-2 sm:gap-3">
          <div className="relative flex-1 sm:flex-none">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-zinc-400" />
            <input
              type="text"
              placeholder="Search configs..."
              value={search}
              onChange={e => setSearch(e.target.value)}
              className="pl-9 pr-4 h-10 sm:h-9 w-full sm:w-64 border border-zinc-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150"
            />
          </div>
          <Button size="icon" variant="ghost" onClick={handleRefresh} aria-label="Refresh">
            <RefreshCw className={`w-4 h-4 ${refreshSpinning ? 'animate-spin' : ''}`} />
          </Button>
        </div>
      </div>

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

                {!isCollapsed && (
                  <>
                    <div className="hidden md:block overflow-x-auto">
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
                                i % 2 === 1 ? 'bg-zinc-50/50' : 'bg-white'
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
                    </div>

                    <div className="md:hidden divide-y divide-zinc-100">
                      {group.configs.map(cfg => (
                        <div
                          key={cfg.key}
                          onClick={() => openConfigModal(cfg)}
                          className="p-4 cursor-pointer hover:bg-zinc-50 active:bg-zinc-100 transition-colors"
                        >
                          <div className="flex items-start justify-between gap-2 mb-2">
                            <div className="text-sm font-medium text-zinc-800 break-all min-w-0 flex-1">{cfg.key}</div>
                            <span className={cn(
                              'inline-flex items-center gap-1.5 px-2 py-0.5 rounded-md text-[10px] font-medium uppercase border shrink-0',
                              cfg.enabled
                                ? 'bg-emerald-50 text-emerald-700 border-emerald-200'
                                : 'bg-red-50 text-red-700 border-red-200'
                            )}>
                              <span className={cn('w-1.5 h-1.5 rounded-full', cfg.enabled ? 'bg-emerald-500' : 'bg-red-500')} />
                              {cfg.enabled ? 'On' : 'Off'}
                            </span>
                          </div>
                          <div className="flex items-center gap-2 mb-2 flex-wrap">
                            <Badge variant={typeBadgeVariant(cfg.type)} size="sm">{cfg.type}</Badge>
                            <Badge variant={productBadgeVariant(cfg.product)} size="sm">{cfg.product || 'global'}</Badge>
                          </div>
                          <div className="text-xs text-zinc-600 font-mono break-all">
                            {cfg.value || cfg.default || '-'}
                          </div>
                          {cfg.description && (
                            <div className="text-xs text-zinc-400 mt-1">{cfg.description}</div>
                          )}
                        </div>
                      ))}
                    </div>
                  </>
                )}
              </div>
            );
          })}
        </div>
      )}

      {selectedConfig && (
        <div className="fixed inset-0 z-50 flex items-end sm:items-center justify-center bg-black/50" onClick={() => setSelectedConfig(null)}>
          <div
            className="bg-white rounded-t-2xl sm:rounded-xl border-t sm:border border-zinc-200 w-full sm:max-w-lg sm:mx-4 max-h-[92vh] flex flex-col"
            onClick={e => e.stopPropagation()}
          >
            <div className="flex items-start justify-between px-4 sm:px-6 pt-4 sm:pt-5 pb-2 shrink-0">
              <div className="min-w-0 flex-1 pr-3">
                <h2 className="text-sm sm:text-base font-semibold text-zinc-900 break-all">{selectedConfig.key}</h2>
                {selectedConfig.description && (
                  <p className="text-xs text-zinc-400 mt-0.5">{selectedConfig.description}</p>
                )}
              </div>
              <button
                onClick={() => setSelectedConfig(null)}
                className="w-9 h-9 -mr-2 flex items-center justify-center rounded-lg hover:bg-zinc-100 text-zinc-400 hover:text-zinc-600 cursor-pointer transition-colors duration-150 shrink-0"
                aria-label="Close"
              >
                <X className="w-5 h-5" />
              </button>
            </div>

            <div className="px-4 sm:px-6 py-4 space-y-4 overflow-y-auto flex-1">
              <div className="flex items-center gap-2 flex-wrap">
                <Badge variant={typeBadgeVariant(selectedConfig.type)} size="sm">{selectedConfig.type}</Badge>
                <Badge variant={productBadgeVariant(selectedConfig.product)} size="sm">
                  {selectedConfig.product || 'global'}
                </Badge>
                {selectedConfig.default && (
                  <span className="text-[10px] text-zinc-400">default: <span className="font-mono break-all">{selectedConfig.default}</span></span>
                )}
              </div>

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

              {renderValueInput()}
            </div>

            <div className="flex flex-col-reverse sm:flex-row sm:items-center sm:justify-end gap-2 sm:gap-3 px-4 sm:px-6 py-3 sm:py-4 border-t border-zinc-100 shrink-0 bg-zinc-50 rounded-b-2xl sm:rounded-b-xl">
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
