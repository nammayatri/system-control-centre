import React, { useState, useMemo } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import {
  fetchProductConfigs, createProductConfig, updateProductConfig, deleteProductConfig,
  fetchReleaseConfigs, createReleaseConfig, updateReleaseConfig, deleteReleaseConfig,
} from '../../releases/api';
import type { ProductConfig, ReleaseConfig } from '../../releases/api';
import { Button } from '../../../shared/ui/button';
import { Badge } from '../../../shared/ui/badge';
import { TableSkeleton } from '../../../shared/ui/skeleton';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { useConfirm } from '../../../shared/ui/confirm-dialog';
import {
  Dialog, DialogContent, DialogHeader, DialogTitle,
  DialogDescription, DialogBody, DialogFooter,
} from '../../../shared/ui/dialog';
import { Search, Plus, RefreshCw, Pencil, Trash2, ChevronRight, ChevronDown } from 'lucide-react';
import { cn } from '../../../lib/utils';
import { toast } from 'sonner';

// ── Types ────────────────────────────────────────────────────────────

interface GroupWithServices {
  group: ProductConfig;
  services: ReleaseConfig[];
}

// ── Empty forms ──────────────────────────────────────────────────────

const EMPTY_GROUP_FORM: Partial<ProductConfig> = {
  appGroup: '', cluster: '', namespace: '', vs_name: '',
  product_acronym: '', product_type: 'SERVICE', sync_cluster: '', need_infra_approval: 0,
};

const EMPTY_SERVICE_FORM: Partial<ReleaseConfig> = {
  appGroup: '', service: '', host: '', rollout_strategy: '',
  serviceType: 'SERVICE',
  revert_strategy: '', decision_config: '',
};

// ── Helpers ──────────────────────────────────────────────────────────

const truncateJson = (json: string, maxLen = 50): string => {
  if (!json) return '-';
  return json.length > maxLen ? json.slice(0, maxLen) + '...' : json;
};

function typeBadgeVariant(type: string): 'blue' | 'warning' | 'purple' | 'default' {
  switch (type) {
    case 'SERVICE': return 'blue';
    case 'SCHEDULER': return 'warning';
    case 'CUSTOM': return 'purple';
    default: return 'default';
  }
}

// ── Component ────────────────────────────────────────────────────────

const DeploymentConfig: React.FC = () => {
  const queryClient = useQueryClient();
  const confirmAction = useConfirm();

  // State
  const [search, setSearch] = useState('');
  const [expandedGroups, setExpandedGroups] = useState<Set<string>>(new Set());

  // Group modal state
  const [groupModalOpen, setGroupModalOpen] = useState(false);
  const [editingGroup, setEditingGroup] = useState<ProductConfig | null>(null);
  const [groupForm, setGroupForm] = useState<Partial<ProductConfig>>(EMPTY_GROUP_FORM);

  // Service modal state
  const [serviceModalOpen, setServiceModalOpen] = useState(false);
  const [editingService, setEditingService] = useState<ReleaseConfig | null>(null);
  const [serviceForm, setServiceForm] = useState<Partial<ReleaseConfig>>(EMPTY_SERVICE_FORM);

  // ── Queries ──────────────────────────────────────────────────────

  const { data: groupConfigs = [], isLoading: groupsLoading, isFetching: groupsFetching, refetch: refetchGroups } = useQuery({
    queryKey: ['product-configs'],
    queryFn: fetchProductConfigs,
    staleTime: 60000,
  });

  const { data: serviceConfigs = [], isLoading: servicesLoading, isFetching: servicesFetching, refetch: refetchServices } = useQuery({
    queryKey: ['release-configs'],
    queryFn: () => fetchReleaseConfigs(),
    staleTime: 60000,
  });

  const isLoading = groupsLoading || servicesLoading;
  const isFetching = groupsFetching || servicesFetching;

  const refetchAll = async () => {
    await Promise.all([refetchGroups(), refetchServices()]);
  };

  // ── Group mutations ──────────────────────────────────────────────

  const createGroupMut = useMutation({
    mutationFn: (payload: Partial<ProductConfig>) => createProductConfig(payload),
    onSuccess: () => { toast.success('Deployment group created'); queryClient.invalidateQueries({ queryKey: ['product-configs'] }); setGroupModalOpen(false); },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to create group'),
  });

  const updateGroupMut = useMutation({
    mutationFn: ({ id, payload }: { id: number; payload: Partial<ProductConfig> }) => updateProductConfig(id, payload),
    onSuccess: () => { toast.success('Deployment group updated'); queryClient.invalidateQueries({ queryKey: ['product-configs'] }); setGroupModalOpen(false); },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to update group'),
  });

  const deleteGroupMut = useMutation({
    mutationFn: (id: number) => deleteProductConfig(id),
    onSuccess: () => { toast.success('Deployment group deleted'); queryClient.invalidateQueries({ queryKey: ['product-configs'] }); },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to delete group'),
  });

  // ── Service mutations ────────────────────────────────────────────

  const createServiceMut = useMutation({
    mutationFn: (payload: Partial<ReleaseConfig>) => createReleaseConfig(payload),
    onSuccess: () => { toast.success('Service config created'); queryClient.invalidateQueries({ queryKey: ['release-configs'] }); setServiceModalOpen(false); },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to create service'),
  });

  const updateServiceMut = useMutation({
    mutationFn: ({ id, payload }: { id: number; payload: Partial<ReleaseConfig> }) => updateReleaseConfig(id, payload),
    onSuccess: () => { toast.success('Service config updated'); queryClient.invalidateQueries({ queryKey: ['release-configs'] }); setServiceModalOpen(false); },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to update service'),
  });

  const deleteServiceMut = useMutation({
    mutationFn: (id: number) => deleteReleaseConfig(id),
    onSuccess: () => { toast.success('Service config deleted'); queryClient.invalidateQueries({ queryKey: ['release-configs'] }); },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to delete service'),
  });

  // ── Build grouped data ───────────────────────────────────────────

  const groupedData: GroupWithServices[] = useMemo(() => {
    const q = search.toLowerCase();
    return groupConfigs
      .map((group: ProductConfig) => {
        const services = serviceConfigs.filter((s: ReleaseConfig) => s.appGroup === group.appGroup);
        return { group, services };
      })
      .filter(({ group, services }) => {
        if (!q) return true;
        const groupMatch =
          group.appGroup.toLowerCase().includes(q) ||
          group.namespace.toLowerCase().includes(q) ||
          group.vs_name.toLowerCase().includes(q) ||
          (group.product_acronym || '').toLowerCase().includes(q) ||
          (group.cluster || '').toLowerCase().includes(q);
        const serviceMatch = services.some((s: ReleaseConfig) =>
          s.service.toLowerCase().includes(q) ||
          s.host.toLowerCase().includes(q)
        );
        return groupMatch || serviceMatch;
      });
  }, [groupConfigs, serviceConfigs, search]);

  // ── Expand / collapse ────────────────────────────────────────────

  const toggleGroup = (appGroupVal: string) => {
    setExpandedGroups(prev => {
      const next = new Set(prev);
      if (next.has(appGroupVal)) next.delete(appGroupVal);
      else next.add(appGroupVal);
      return next;
    });
  };

  // ── Group CRUD handlers ──────────────────────────────────────────

  const openCreateGroup = () => {
    setEditingGroup(null);
    setGroupForm(EMPTY_GROUP_FORM);
    setGroupModalOpen(true);
  };

  const openEditGroup = (cfg: ProductConfig) => {
    setEditingGroup(cfg);
    setGroupForm({ ...cfg });
    setGroupModalOpen(true);
  };

  const handleDeleteGroup = async (cfg: ProductConfig) => {
    if (!cfg.id) return;
    const ok = await confirmAction({
      title: 'Delete Deployment Group',
      description: `Are you sure you want to delete "${cfg.appGroup}"? This will not delete associated services but they will become orphaned.`,
      confirmLabel: 'Delete',
      variant: 'danger',
    });
    if (ok) deleteGroupMut.mutate(cfg.id);
  };

  const handleGroupSubmit = () => {
    if (editingGroup?.id) {
      updateGroupMut.mutate({ id: editingGroup.id, payload: groupForm });
    } else {
      createGroupMut.mutate(groupForm);
    }
  };

  // ── Service CRUD handlers ────────────────────────────────────────

  const openCreateService = (parentProduct: string) => {
    setEditingService(null);
    setServiceForm({ ...EMPTY_SERVICE_FORM, appGroup: parentProduct });
    setServiceModalOpen(true);
  };

  const openEditService = (cfg: ReleaseConfig) => {
    setEditingService(cfg);
    setServiceForm({ ...cfg });
    setServiceModalOpen(true);
  };

  const handleDeleteService = async (cfg: ReleaseConfig) => {
    if (!cfg.id) return;
    const ok = await confirmAction({
      title: 'Delete Service',
      description: `Are you sure you want to delete "${cfg.service}"? This action cannot be undone.`,
      confirmLabel: 'Delete',
      variant: 'danger',
    });
    if (ok) deleteServiceMut.mutate(cfg.id);
  };

  const handleServiceSubmit = () => {
    if (editingService?.id) {
      updateServiceMut.mutate({ id: editingService.id, payload: serviceForm });
    } else {
      createServiceMut.mutate(serviceForm);
    }
  };

  // ── Shared styles ────────────────────────────────────────────────

  const inputClass = "w-full h-10 sm:h-9 border border-zinc-300 rounded-lg px-3 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150";
  const productOptions = useMemo(() =>
    [...new Set(groupConfigs.map((c: ProductConfig) => c.appGroup).filter(Boolean))],
    [groupConfigs]
  );

  // ── Render ───────────────────────────────────────────────────────

  return (
    <div className="flex flex-col w-full pb-12">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 mb-4 sm:mb-5">
        <h1 className="text-lg sm:text-xl font-semibold text-zinc-900">Deployment Config</h1>
        <div className="flex items-center gap-2 sm:gap-3 flex-wrap">
          <div className="relative flex-1 sm:flex-none min-w-0">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-zinc-400" />
            <input
              type="text"
              placeholder="Search groups or services..."
              value={search}
              onChange={e => setSearch(e.target.value)}
              className="pl-9 pr-4 h-10 sm:h-9 w-full sm:w-72 border border-zinc-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150"
            />
          </div>
          <Button size="icon" variant="ghost" onClick={refetchAll} aria-label="Refresh">
            <RefreshCw className={`w-4 h-4 ${isFetching ? 'animate-spin' : ''}`} />
          </Button>
          <PermissionGate product="autopilot" permission="RELEASE_CREATE">
            <Button size="md" onClick={openCreateGroup}>
              <Plus className="w-4 h-4" /> Add Group
            </Button>
          </PermissionGate>
        </div>
      </div>

      {/* Table — desktop */}
      <div className="bg-white border border-zinc-200 rounded-xl overflow-hidden">
        {isLoading ? (
          <TableSkeleton rows={8} cols={7} />
        ) : groupedData.length === 0 ? (
          <div className="p-10 text-center text-sm text-zinc-400">
            {search ? 'No matching groups or services found.' : 'No deployment groups configured.'}
          </div>
        ) : (
          <div className="hidden lg:block overflow-x-auto">
            <table className="w-full text-left whitespace-nowrap">
              <thead>
                <tr className="bg-zinc-50 border-b border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                  <th className="py-3 px-4 w-10"></th>
                  <th className="py-3 px-4">App Group</th>
                  <th className="py-3 px-4">Cluster</th>
                  <th className="py-3 px-4">Namespace</th>
                  <th className="py-3 px-4">VS Name</th>
                  <th className="py-3 px-4">Acronym</th>
                  <th className="py-3 px-4">Type</th>
                  <th className="py-3 px-4">Sync Cluster</th>
                  <th className="py-3 px-4">Slack</th>
                  <th className="py-3 px-4">Infra Approval</th>
                  <th className="py-3 px-4">VS Locked</th>
                  <th className="py-3 px-4 w-24 text-center">Actions</th>
                </tr>
              </thead>
              <tbody className="text-sm">
                {groupedData.map(({ group, services }, gIdx) => {
                  const isExpanded = expandedGroups.has(group.appGroup);
                  return (
                    <React.Fragment key={group.id || group.appGroup}>
                      {/* Group row */}
                      <tr
                        className={cn(
                          'border-b border-zinc-200 hover:bg-zinc-50/80 transition-colors duration-150 cursor-pointer',
                          gIdx % 2 === 1 ? 'bg-zinc-50/30' : 'bg-white'
                        )}
                        onClick={() => toggleGroup(group.appGroup)}
                      >
                        <td className="py-3 px-4">
                          <button
                            className="p-0.5 rounded text-zinc-400 hover:text-zinc-600 transition-colors"
                            onClick={e => { e.stopPropagation(); toggleGroup(group.appGroup); }}
                          >
                            {isExpanded
                              ? <ChevronDown className="w-4 h-4" />
                              : <ChevronRight className="w-4 h-4" />
                            }
                          </button>
                        </td>
                        <td className="py-3 px-4">
                          <span className="font-semibold text-zinc-900">{group.appGroup}</span>
                          <span className="ml-2 text-xs text-zinc-400">
                            {services.length} service{services.length !== 1 ? 's' : ''}
                          </span>
                        </td>
                        <td className="py-3 px-4 font-mono text-xs text-zinc-600">{group.cluster || '-'}</td>
                        <td className="py-3 px-4 font-mono text-xs text-zinc-600">{group.namespace || '-'}</td>
                        <td className="py-3 px-4 font-mono text-xs text-zinc-600">{group.vs_name || '-'}</td>
                        <td className="py-3 px-4 text-zinc-600">{group.product_acronym || '-'}</td>
                        <td className="py-3 px-4">
                          <Badge variant={typeBadgeVariant(group.product_type)} size="sm">
                            {group.product_type || '-'}
                          </Badge>
                        </td>
                        <td className="py-3 px-4 text-xs text-zinc-500">
                          {group.sync_cluster || '-'}
                        </td>
                        <td className="py-3 px-4 font-mono text-xs text-zinc-500">
                          {group.slack_channel || '-'}
                        </td>
                        <td className="py-3 px-4">
                          <Badge variant={group.need_infra_approval ? 'warning' : 'default'} size="sm">
                            {group.need_infra_approval ? 'Yes' : 'No'}
                          </Badge>
                        </td>
                        <td className="py-3 px-4">
                          {group.vs_locked_by ? (
                            <Badge variant="danger" size="sm">{group.vs_locked_by}</Badge>
                          ) : (
                            <span className="text-xs text-zinc-400">-</span>
                          )}
                        </td>
                        <td className="py-3 px-4 text-center">
                          <div className="flex items-center justify-center gap-1" onClick={e => e.stopPropagation()}>
                            <PermissionGate product="autopilot" permission="RELEASE_CREATE">
                              <button
                                onClick={() => openEditGroup(group)}
                                className="p-1.5 rounded-lg text-zinc-400 hover:text-zinc-600 hover:bg-zinc-100 cursor-pointer transition-colors duration-150"
                              >
                                <Pencil className="w-3.5 h-3.5" />
                              </button>
                              <button
                                onClick={() => handleDeleteGroup(group)}
                                className="p-1.5 rounded-lg text-red-400 hover:text-red-600 hover:bg-red-50 cursor-pointer transition-colors duration-150"
                              >
                                <Trash2 className="w-3.5 h-3.5" />
                              </button>
                            </PermissionGate>
                          </div>
                        </td>
                      </tr>

                      {/* Service sub-header (expanded) */}
                      {isExpanded && services.length > 0 && (
                        <tr className="bg-zinc-100/60 border-b border-zinc-200">
                          <td className="py-2 px-4"></td>
                          <td className="py-2 px-4 text-[11px] font-semibold text-zinc-500 uppercase tracking-wider">Service</td>
                          <td className="py-2 px-4 text-[11px] font-semibold text-zinc-500 uppercase tracking-wider">Host</td>
                          <td className="py-2 px-4 text-[11px] font-semibold text-zinc-500 uppercase tracking-wider">Type</td>
                          <td className="py-2 px-4 text-[11px] font-semibold text-zinc-500 uppercase tracking-wider">Rollout Strategy</td>
                          <td className="py-2 px-4 text-[11px] font-semibold text-zinc-500 uppercase tracking-wider">Revert Strategy</td>
                          <td className="py-2 px-4" colSpan={4}></td>
                          <td className="py-2 px-4 text-[11px] font-semibold text-zinc-500 uppercase tracking-wider text-center">Actions</td>
                        </tr>
                      )}

                      {/* Service rows (expanded) */}
                      {isExpanded && services.map((svc, sIdx) => (
                        <tr
                          key={svc.id || svc.service}
                          className={cn(
                            'border-b border-zinc-100 hover:bg-zinc-50/60 transition-colors duration-150',
                            'bg-zinc-50/20'
                          )}
                        >
                          <td className="py-2.5 px-4"></td>
                          <td className="py-2.5 px-4">
                            <div className="flex items-center">
                              <div className="border-l-2 border-zinc-200 h-5 mr-3"></div>
                              <span className="text-zinc-700">{svc.service}</span>
                            </div>
                          </td>
                          <td className="py-2.5 px-4 font-mono text-xs text-zinc-600">{svc.host || '-'}</td>
                          <td className="py-2.5 px-4">
                            {svc.serviceType ? (
                              <Badge variant={typeBadgeVariant(svc.serviceType)} size="sm">
                                {svc.serviceType}
                              </Badge>
                            ) : '-'}
                          </td>
                          <td className="py-2.5 px-4 font-mono text-[11px] text-zinc-500 max-w-[180px] truncate" title={svc.rollout_strategy}>
                            {truncateJson(svc.rollout_strategy)}
                          </td>
                          <td className="py-2.5 px-4 font-mono text-[11px] text-zinc-500 max-w-[180px] truncate" title={svc.revert_strategy}>
                            {truncateJson(svc.revert_strategy || '')}
                          </td>
                          <td className="py-2.5 px-4" colSpan={4}></td>
                          <td className="py-2.5 px-4 text-center">
                            <div className="flex items-center justify-center gap-1">
                              <PermissionGate product="autopilot" permission="RELEASE_CREATE">
                                <button
                                  onClick={() => openEditService(svc)}
                                  className="p-1.5 rounded-lg text-zinc-400 hover:text-zinc-600 hover:bg-zinc-100 cursor-pointer transition-colors duration-150"
                                >
                                  <Pencil className="w-3.5 h-3.5" />
                                </button>
                                <button
                                  onClick={() => handleDeleteService(svc)}
                                  className="p-1.5 rounded-lg text-red-400 hover:text-red-600 hover:bg-red-50 cursor-pointer transition-colors duration-150"
                                >
                                  <Trash2 className="w-3.5 h-3.5" />
                                </button>
                              </PermissionGate>
                            </div>
                          </td>
                        </tr>
                      ))}

                      {/* Add Service button row */}
                      {isExpanded && (
                        <tr className="border-b border-zinc-100 bg-zinc-50/10">
                          <td className="py-2 px-4"></td>
                          <td className="py-2 px-4" colSpan={11}>
                            <div className="flex items-center">
                              <div className="border-l-2 border-zinc-200 h-5 mr-3"></div>
                              <PermissionGate product="autopilot" permission="RELEASE_CREATE">
                                <button
                                  onClick={() => openCreateService(group.appGroup)}
                                  className="flex items-center gap-1.5 text-xs text-zinc-400 hover:text-zinc-600 transition-colors duration-150 cursor-pointer"
                                >
                                  <Plus className="w-3.5 h-3.5" />
                                  Add Service
                                </button>
                              </PermissionGate>
                            </div>
                          </td>
                        </tr>
                      )}
                    </React.Fragment>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}

        {/* Mobile/tablet card list */}
        {!isLoading && groupedData.length > 0 && (
          <div className="lg:hidden divide-y divide-zinc-200">
            {groupedData.map(({ group, services }) => {
              const isExpanded = expandedGroups.has(group.appGroup);
              return (
                <div key={group.id || group.appGroup}>
                  <div
                    className="p-4 cursor-pointer hover:bg-zinc-50 active:bg-zinc-100 transition-colors"
                    onClick={() => toggleGroup(group.appGroup)}
                  >
                    <div className="flex items-start justify-between gap-2 mb-2">
                      <div className="flex items-center gap-2 min-w-0 flex-1">
                        {isExpanded
                          ? <ChevronDown className="w-4 h-4 text-zinc-400 shrink-0" />
                          : <ChevronRight className="w-4 h-4 text-zinc-400 shrink-0" />}
                        <span className="font-semibold text-zinc-900 truncate">{group.appGroup}</span>
                        <span className="text-xs text-zinc-400 shrink-0">
                          {services.length} svc
                        </span>
                      </div>
                      <div className="flex items-center gap-1 shrink-0" onClick={e => e.stopPropagation()}>
                        <PermissionGate product="autopilot" permission="RELEASE_CREATE">
                          <button
                            onClick={() => openEditGroup(group)}
                            className="w-9 h-9 flex items-center justify-center rounded-lg text-zinc-400 hover:text-zinc-700 hover:bg-zinc-100 cursor-pointer"
                            aria-label="Edit group"
                          >
                            <Pencil className="w-4 h-4" />
                          </button>
                          <button
                            onClick={() => handleDeleteGroup(group)}
                            className="w-9 h-9 flex items-center justify-center rounded-lg text-red-400 hover:text-red-600 hover:bg-red-50 cursor-pointer"
                            aria-label="Delete group"
                          >
                            <Trash2 className="w-4 h-4" />
                          </button>
                        </PermissionGate>
                      </div>
                    </div>
                    <div className="grid grid-cols-1 sm:grid-cols-2 gap-x-3 gap-y-1 text-xs text-zinc-500 ml-6">
                      <div><span className="text-zinc-400">Cluster:</span> <span className="font-mono">{group.cluster || '-'}</span></div>
                      <div><span className="text-zinc-400">Namespace:</span> <span className="font-mono">{group.namespace || '-'}</span></div>
                      <div><span className="text-zinc-400">VS:</span> <span className="font-mono">{group.vs_name || '-'}</span></div>
                      <div><span className="text-zinc-400">Sync:</span> <span>{group.sync_cluster || '-'}</span></div>
                      <div className="sm:col-span-2"><span className="text-zinc-400">Slack:</span> <span className="font-mono">{group.slack_channel || '-'}</span></div>
                    </div>
                    <div className="flex items-center gap-2 mt-2 ml-6 flex-wrap">
                      <Badge variant={typeBadgeVariant(group.product_type)} size="sm">{group.product_type || '-'}</Badge>
                      {group.need_infra_approval ? <Badge variant="warning" size="sm">Infra Approval</Badge> : null}
                      {group.vs_locked_by ? <Badge variant="danger" size="sm">Locked: {group.vs_locked_by}</Badge> : null}
                    </div>
                  </div>

                  {isExpanded && (
                    <div className="bg-zinc-50/60 border-t border-zinc-100">
                      {services.map(svc => (
                        <div key={svc.id || svc.service} className="p-4 pl-8 border-b border-zinc-100 last:border-b-0">
                          <div className="flex items-start justify-between gap-2 mb-1">
                            <div className="text-sm font-medium text-zinc-800 break-all min-w-0 flex-1">{svc.service}</div>
                            <div className="flex items-center gap-1 shrink-0">
                              <PermissionGate product="autopilot" permission="RELEASE_CREATE">
                                <button
                                  onClick={() => openEditService(svc)}
                                  className="w-9 h-9 flex items-center justify-center rounded-lg text-zinc-400 hover:text-zinc-700 hover:bg-zinc-100 cursor-pointer"
                                  aria-label="Edit service"
                                >
                                  <Pencil className="w-4 h-4" />
                                </button>
                                <button
                                  onClick={() => handleDeleteService(svc)}
                                  className="w-9 h-9 flex items-center justify-center rounded-lg text-red-400 hover:text-red-600 hover:bg-red-50 cursor-pointer"
                                  aria-label="Delete service"
                                >
                                  <Trash2 className="w-4 h-4" />
                                </button>
                              </PermissionGate>
                            </div>
                          </div>
                          <div className="text-[11px] text-zinc-500 font-mono break-all">{svc.host || '-'}</div>
                          <div className="flex items-center gap-2 mt-1.5 flex-wrap">
                            {svc.serviceType && <Badge variant={typeBadgeVariant(svc.serviceType)} size="sm">{svc.serviceType}</Badge>}
                          </div>
                        </div>
                      ))}
                      <div className="p-3 pl-8">
                        <PermissionGate product="autopilot" permission="RELEASE_CREATE">
                          <button
                            onClick={() => openCreateService(group.appGroup)}
                            className="flex items-center gap-1.5 text-xs text-zinc-500 hover:text-zinc-700 transition-colors cursor-pointer h-9"
                          >
                            <Plus className="w-4 h-4" />
                            Add Service
                          </button>
                        </PermissionGate>
                      </div>
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </div>

      {/* ── Group Modal ──────────────────────────────────────────── */}
      <Dialog open={groupModalOpen} onOpenChange={setGroupModalOpen}>
        <DialogContent size="lg">
          <DialogHeader>
            <DialogTitle>{editingGroup ? 'Edit Deployment Group' : 'Create Deployment Group'}</DialogTitle>
            <DialogDescription>
              {editingGroup ? 'Update the deployment group configuration.' : 'Add a new deployment group.'}
            </DialogDescription>
          </DialogHeader>
          <DialogBody>
            <div className="space-y-4">
              <div>
                <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Group Name *</label>
                <input
                  type="text"
                  value={groupForm.appGroup || ''}
                  onChange={e => setGroupForm(prev => ({ ...prev, appGroup: e.target.value }))}
                  className={inputClass}
                  placeholder="e.g. BECKN"
                  disabled={!!editingGroup}
                />
              </div>
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <div>
                  <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Cluster *</label>
                  <input
                    type="text"
                    value={groupForm.cluster || ''}
                    onChange={e => setGroupForm(prev => ({ ...prev, cluster: e.target.value }))}
                    className={inputClass}
                    placeholder="e.g. BECKN_UAT"
                  />
                </div>
                <div>
                  <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Namespace *</label>
                  <input
                    type="text"
                    value={groupForm.namespace || ''}
                    onChange={e => setGroupForm(prev => ({ ...prev, namespace: e.target.value }))}
                    className={inputClass}
                    placeholder="e.g. atlas"
                  />
                </div>
              </div>
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <div>
                  <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">VS Name *</label>
                  <input
                    type="text"
                    value={groupForm.vs_name || ''}
                    onChange={e => setGroupForm(prev => ({ ...prev, vs_name: e.target.value }))}
                    className={inputClass}
                    placeholder="e.g. atlas-vs"
                  />
                </div>
                <div>
                  <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Acronym *</label>
                  <input
                    type="text"
                    value={groupForm.product_acronym || ''}
                    onChange={e => setGroupForm(prev => ({ ...prev, product_acronym: e.target.value }))}
                    className={inputClass}
                    placeholder="e.g. BKN"
                  />
                </div>
              </div>
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <div>
                  <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Type</label>
                  <select
                    value={groupForm.product_type || 'SERVICE'}
                    onChange={e => setGroupForm(prev => ({ ...prev, product_type: e.target.value }))}
                    className={cn(inputClass, 'cursor-pointer')}
                  >
                    <option value="SERVICE">SERVICE</option>
                    <option value="SCHEDULER">SCHEDULER</option>
                  </select>
                </div>
                <div>
                  <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Sync Cluster</label>
                  <input
                    type="text"
                    value={groupForm.sync_cluster || ''}
                    onChange={e => setGroupForm(prev => ({ ...prev, sync_cluster: e.target.value }))}
                    className={inputClass}
                  />
                </div>
                <div>
                  <label className="text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5 block">Slack Channel</label>
                  <input
                    type="text"
                    value={groupForm.slack_channel || ''}
                    onChange={e => setGroupForm(prev => ({ ...prev, slack_channel: e.target.value }))}
                    placeholder="e.g. some-channel"
                    className={inputClass}
                  />
                </div>
              </div>
              <label className="flex items-center gap-2.5 cursor-pointer">
                <input
                  type="checkbox"
                  checked={!!groupForm.need_infra_approval}
                  onChange={e => setGroupForm(prev => ({ ...prev, need_infra_approval: e.target.checked ? 1 : 0 }))}
                  className="rounded border-zinc-300 accent-zinc-900"
                />
                <span className="text-sm text-zinc-700">Requires Infra Approval</span>
              </label>
            </div>
          </DialogBody>
          <DialogFooter>
            <Button variant="secondary" size="md" onClick={() => setGroupModalOpen(false)}>Cancel</Button>
            <Button size="md" onClick={handleGroupSubmit} loading={createGroupMut.isPending || updateGroupMut.isPending}>
              {editingGroup ? 'Update' : 'Create'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* ── Service Modal ────────────────────────────────────────── */}
      <Dialog open={serviceModalOpen} onOpenChange={setServiceModalOpen}>
        <DialogContent size="xl">
          <DialogHeader>
            <DialogTitle>{editingService ? 'Edit Service' : 'Add Service'}</DialogTitle>
            <DialogDescription>
              {editingService
                ? 'Update the service configuration.'
                : `Add a new service${serviceForm.appGroup ? ` to ${serviceForm.appGroup}` : ''}.`
              }
            </DialogDescription>
          </DialogHeader>
          <DialogBody>
            <div className="space-y-4">
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <div>
                  <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Group *</label>
                  <select
                    value={serviceForm.appGroup || ''}
                    onChange={e => setServiceForm(prev => ({ ...prev, appGroup: e.target.value }))}
                    className={cn(inputClass, 'cursor-pointer')}
                    disabled={!!editingService}
                  >
                    <option value="">Select Group</option>
                    {productOptions.map((p: string) => <option key={p} value={p}>{p}</option>)}
                  </select>
                </div>
                <div>
                  <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Service Name *</label>
                  <input
                    type="text"
                    value={serviceForm.service || ''}
                    onChange={e => setServiceForm(prev => ({ ...prev, service: e.target.value }))}
                    className={inputClass}
                    placeholder="e.g. BECKN_APP_BACKEND_MASTER"
                    disabled={!!editingService}
                  />
                </div>
              </div>
              <div>
                <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Service Host *</label>
                <input
                  type="text"
                  value={serviceForm.host || ''}
                  onChange={e => setServiceForm(prev => ({ ...prev, host: e.target.value }))}
                  className={inputClass}
                  placeholder="e.g. beckn-app-backend-master"
                />
              </div>
              <div>
                <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Type</label>
                <select
                  value={serviceForm.serviceType || 'SERVICE'}
                  onChange={e => setServiceForm(prev => ({ ...prev, serviceType: e.target.value }))}
                  className={cn(inputClass, 'cursor-pointer')}
                >
                  <option value="SERVICE">SERVICE</option>
                  <option value="SCHEDULER">SCHEDULER</option>
                  <option value="CUSTOM">CUSTOM</option>
                </select>
              </div>
              {/* Rollout Strategy Editor */}
              <div>
                <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Rollout Strategy</label>
                {(() => {
                  let stages: Array<{rolloutPercent: number; cooloffMinutes: number; podPercent: number}> = [];
                  try { stages = JSON.parse(serviceForm.rollout_strategy || '[]'); } catch { stages = []; }
                  if (!Array.isArray(stages)) stages = [];

                  const updateStages = (newStages: typeof stages) => {
                    setServiceForm(prev => ({ ...prev, rollout_strategy: JSON.stringify(newStages) }));
                  };

                  return (
                    <div className="border border-zinc-200 rounded-lg overflow-hidden">
                      <table className="w-full text-xs">
                        <thead>
                          <tr className="bg-zinc-50 text-zinc-500 uppercase tracking-wider">
                            <th className="px-2 py-1.5 text-left">Rollout %</th>
                            <th className="px-2 py-1.5 text-left">Cooloff (min)</th>
                            <th className="px-2 py-1.5 text-left">Pods %</th>
                            <th className="px-2 py-1.5 w-8"></th>
                          </tr>
                        </thead>
                        <tbody>
                          {stages.map((s, i) => (
                            <tr key={i} className="border-t border-zinc-100">
                              <td className="px-2 py-1">
                                <input type="number" min={1} max={100} value={s.rolloutPercent}
                                  onChange={e => updateStages(stages.map((st, idx) => idx === i ? { ...st, rolloutPercent: parseInt(e.target.value) || 0 } : st))}
                                  className="w-full h-7 border border-zinc-200 rounded px-2 text-xs focus:outline-none focus:ring-1 focus:ring-zinc-400" />
                              </td>
                              <td className="px-2 py-1">
                                <input type="number" min={0} max={90} value={s.cooloffMinutes}
                                  onChange={e => updateStages(stages.map((st, idx) => idx === i ? { ...st, cooloffMinutes: parseInt(e.target.value) || 0 } : st))}
                                  className="w-full h-7 border border-zinc-200 rounded px-2 text-xs focus:outline-none focus:ring-1 focus:ring-zinc-400" />
                              </td>
                              <td className="px-2 py-1">
                                <input type="number" min={1} max={500} value={s.podPercent}
                                  onChange={e => updateStages(stages.map((st, idx) => idx === i ? { ...st, podPercent: parseInt(e.target.value) || 0 } : st))}
                                  className="w-full h-7 border border-zinc-200 rounded px-2 text-xs focus:outline-none focus:ring-1 focus:ring-zinc-400" />
                              </td>
                              <td className="px-2 py-1">
                                <button type="button" onClick={() => updateStages(stages.filter((_, idx) => idx !== i))}
                                  className="text-red-400 hover:text-red-600 cursor-pointer text-sm">&times;</button>
                              </td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                      <button type="button"
                        onClick={() => updateStages([...stages, { rolloutPercent: 100, cooloffMinutes: 0, podPercent: 100 }])}
                        className="w-full py-1.5 text-xs text-zinc-400 hover:text-zinc-600 border-t border-zinc-100 cursor-pointer">
                        + Add Stage
                      </button>
                    </div>
                  );
                })()}
              </div>
              {/* Revert Strategy Editor */}
              <div>
                <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Revert Strategy</label>
                {(() => {
                  let stages: Array<{rolloutPercent: number; cooloffMinutes: number; podPercent: number}> = [];
                  try { stages = JSON.parse(serviceForm.revert_strategy || '[]'); } catch { stages = []; }
                  if (!Array.isArray(stages)) stages = [];

                  const updateStages = (newStages: typeof stages) => {
                    setServiceForm(prev => ({ ...prev, revert_strategy: JSON.stringify(newStages) }));
                  };

                  return (
                    <div className="border border-zinc-200 rounded-lg overflow-hidden">
                      <table className="w-full text-xs">
                        <thead>
                          <tr className="bg-zinc-50 text-zinc-500 uppercase tracking-wider">
                            <th className="px-2 py-1.5 text-left">Rollout %</th>
                            <th className="px-2 py-1.5 text-left">Cooloff (min)</th>
                            <th className="px-2 py-1.5 text-left">Pods %</th>
                            <th className="px-2 py-1.5 w-8"></th>
                          </tr>
                        </thead>
                        <tbody>
                          {stages.map((s, i) => (
                            <tr key={i} className="border-t border-zinc-100">
                              <td className="px-2 py-1">
                                <input type="number" min={1} max={100} value={s.rolloutPercent}
                                  onChange={e => updateStages(stages.map((st, idx) => idx === i ? { ...st, rolloutPercent: parseInt(e.target.value) || 0 } : st))}
                                  className="w-full h-7 border border-zinc-200 rounded px-2 text-xs focus:outline-none focus:ring-1 focus:ring-zinc-400" />
                              </td>
                              <td className="px-2 py-1">
                                <input type="number" min={0} max={90} value={s.cooloffMinutes}
                                  onChange={e => updateStages(stages.map((st, idx) => idx === i ? { ...st, cooloffMinutes: parseInt(e.target.value) || 0 } : st))}
                                  className="w-full h-7 border border-zinc-200 rounded px-2 text-xs focus:outline-none focus:ring-1 focus:ring-zinc-400" />
                              </td>
                              <td className="px-2 py-1">
                                <input type="number" min={1} max={500} value={s.podPercent}
                                  onChange={e => updateStages(stages.map((st, idx) => idx === i ? { ...st, podPercent: parseInt(e.target.value) || 0 } : st))}
                                  className="w-full h-7 border border-zinc-200 rounded px-2 text-xs focus:outline-none focus:ring-1 focus:ring-zinc-400" />
                              </td>
                              <td className="px-2 py-1">
                                <button type="button" onClick={() => updateStages(stages.filter((_, idx) => idx !== i))}
                                  className="text-red-400 hover:text-red-600 cursor-pointer text-sm">&times;</button>
                              </td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                      <button type="button"
                        onClick={() => updateStages([...stages, { rolloutPercent: 100, cooloffMinutes: 0, podPercent: 100 }])}
                        className="w-full py-1.5 text-xs text-zinc-400 hover:text-zinc-600 border-t border-zinc-100 cursor-pointer">
                        + Add Stage
                      </button>
                    </div>
                  );
                })()}
              </div>
              <div>
                <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">Decision Config (JSON)</label>
                <textarea
                  value={serviceForm.decision_config || ''}
                  onChange={e => setServiceForm(prev => ({ ...prev, decision_config: e.target.value }))}
                  rows={3}
                  className="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm font-mono resize-y focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150"
                  placeholder='Optional decision config JSON'
                />
              </div>
              {/* Slack Channel is configured at the App Group level, not per service. */}
            </div>
          </DialogBody>
          <DialogFooter>
            <Button variant="secondary" size="md" onClick={() => setServiceModalOpen(false)}>Cancel</Button>
            <Button size="md" onClick={handleServiceSubmit} loading={createServiceMut.isPending || updateServiceMut.isPending}>
              {editingService ? 'Update' : 'Create'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default DeploymentConfig;
