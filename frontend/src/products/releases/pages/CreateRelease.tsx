import React, { useState, useEffect } from 'react';
import { useNavigate, useParams, useLocation } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import Editor from '@monaco-editor/react';
import { useProductConfigs, useServices } from '../useProducts';
import { useCreateRelease, useUpdateTracker } from '../hooks';
import { fetchReleaseDetails, fetchEnvs, fetchSecondaryEnvs, fetchReleaseConfigs, fetchResources } from '../api';
import type { ProductConfig } from '../api';
import { Button } from '../../../shared/ui/button';
import { cn } from '../../../lib/utils';
import { DEFAULT_ENV, AVAILABLE_ENVS } from '../../../lib/constants';
import { Trash2, Lock, ChevronDown } from 'lucide-react';
import { toast } from 'sonner';

// Valid status transitions for update mode (UPPERCASE canonical)
const VALID_STATUS_TRANSITIONS: Record<string, string[]> = {
  'CREATED': ['CREATED', 'INPROGRESS', 'DISCARDED'],
  'INPROGRESS': ['INPROGRESS', 'PAUSED', 'ABORTING', 'COMPLETED'],
  'PAUSED': ['PAUSED', 'INPROGRESS', 'ABORTING'],
  'ABORTING': ['ABORTING'],
  'ABORTED': ['ABORTED'],
  'USER_ABORTED': ['USER_ABORTED'],
  'GCLT_ABORTED': ['GCLT_ABORTED'],
  'COMPLETED': ['COMPLETED'],
  'REVERTED': ['REVERTED'],
  'DISCARDED': ['DISCARDED'],
};

const CreateRelease: React.FC = () => {
  const navigate = useNavigate();
  const location = useLocation();
  const { id } = useParams<{ id?: string }>();
  const isClone = location.pathname.endsWith('/clone') && !!id;
  const isUpdate = !!id && location.pathname.endsWith('/edit');

  const { data: productConfigs = [] } = useProductConfigs();
  const products = [...new Set(productConfigs.map((c: ProductConfig) => c.appGroup).filter(Boolean))];

  const [formData, setFormData] = useState({
    appGroup: '', service: '', env: DEFAULT_ENV, old_version: '', new_version: '', docker_image: '', change_log: '',
    status: 'CREATED', mode: 'AUTO', priority: '0', info: '', custom_pods_scale_down_days: '1',
    cluster: 'MOVING_TECH', scale_down_delay: '1',
    cronjob_suspend: false, description: '', schedule_time: '',
    // deploy_file_path, vs_file_path, dr_file_path removed (backend still accepts via API)
  });
  const isNewService = false; // new_service toggle removed from UI; still accepted by backend API
  const [error, setError] = useState('');
  const [isEnvSwitch, setIsEnvSwitch] = useState(false);
  const [envData, setEnvData] = useState('');
  const [isResourcesSwitch, setIsResourcesSwitch] = useState(false);
  const [resourcesData, setResourcesData] = useState('');
  const [selectedServices, setSelectedServices] = useState<string[]>([]);
  const [showServiceDropdown, setShowServiceDropdown] = useState(false);
  const [clonedService, setClonedService] = useState('');
  const [stages, setStages] = useState([
    { rollout: 5, cooloff: 10, pods: 2 },
    { rollout: 25, cooloff: 10, pods: 2 },
    { rollout: 50, cooloff: 10, pods: 2 },
    { rollout: 75, cooloff: 10, pods: 2 },
    { rollout: 100, cooloff: 10, pods: 2 },
  ]);
  const [isReleaseSync, setIsReleaseSync] = useState(false);
  const [isSecondaryEnvSwitch, setIsSecondaryEnvSwitch] = useState(false);
  const [secondaryEnvData, setSecondaryEnvData] = useState('');
  const [secondaryEnvLoading, setSecondaryEnvLoading] = useState(false);
  const [secondaryStages, setSecondaryStages] = useState([
    { rollout: 5, cooloff: 10, pods: 2 },
    { rollout: 25, cooloff: 10, pods: 2 },
    { rollout: 50, cooloff: 10, pods: 2 },
    { rollout: 75, cooloff: 10, pods: 2 },
    { rollout: 100, cooloff: 10, pods: 2 },
  ]);
  const [syncCluster, setSyncCluster] = useState('');
  const [rolloutHistoryLength, setRolloutHistoryLength] = useState(0);

  const { data: services = [] } = useServices(formData.appGroup, isNewService);
  const createMutation = useCreateRelease();
  const updateMutation = useUpdateTracker();

  // Sync first selected service into formData.service for dependent effects (envs, resources, rollout)
  useEffect(() => {
    setFormData(prev => ({ ...prev, service: selectedServices[0] || '' }));
    // Disable env/resources switches when multiple services selected (can't fetch for multiple)
    if (selectedServices.length !== 1) {
      setIsEnvSwitch(false);
      setIsResourcesSwitch(false);
    }
  }, [selectedServices]);

  // Close service dropdown on outside click
  useEffect(() => {
    const handleClickOutside = (e: MouseEvent) => {
      if (showServiceDropdown && !(e.target as HTMLElement).closest('.service-dropdown')) {
        setShowServiceDropdown(false);
      }
    };
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [showServiceDropdown]);

  // Fetch existing release for update mode
  const { data: existingRelease } = useQuery({
    queryKey: ['release', id],
    queryFn: () => fetchReleaseDetails(id!),
    enabled: isUpdate && !!id,
  });

  // Pre-fill form when editing
  useEffect(() => {
    if (existingRelease && isUpdate) {
      setFormData({
        appGroup: existingRelease.appGroup || '',
        service: existingRelease.service || '',
        env: existingRelease.env || DEFAULT_ENV,
        old_version: existingRelease.old_version || '',
        new_version: existingRelease.new_version || '',
        docker_image: existingRelease.docker_image || existingRelease.release_context?.docker_image || '',
        change_log: existingRelease.change_log || '',
        status: existingRelease.status || 'CREATED',
        mode: existingRelease.mode || 'AUTO',
        priority: String(existingRelease.priority ?? 0),
        info: existingRelease.info || '',
        custom_pods_scale_down_days: String(existingRelease.custom_pod_scaledown_days ?? 1),
        cluster: existingRelease.release_context?.cluster || 'MOVING_TECH',
        scale_down_delay: String(existingRelease.release_context?.pods_scale_down_delay ?? 1),
        cronjob_suspend: existingRelease.cronjob_suspend || false,
        description: existingRelease.description || '',
        schedule_time: existingRelease.schedule_time || '',
        // deploy/vs/dr file paths removed from UI
      });
      setSelectedServices([existingRelease.service || ''].filter(Boolean));
      setRolloutHistoryLength(existingRelease.rollout_history?.length || 0);
      if (existingRelease.env_override_data) { setIsEnvSwitch(true); setEnvData(existingRelease.env_override_data); }
      if (existingRelease.rollout_strategy) {
        try {
          const parsed = typeof existingRelease.rollout_strategy === 'string'
            ? JSON.parse(existingRelease.rollout_strategy) : existingRelease.rollout_strategy;
          if (Array.isArray(parsed) && parsed.length > 0) setStages(parsed);
        } catch (e) { console.error('Failed to parse stages', e); }
      }
    }
  }, [existingRelease, isUpdate]);

  // Clone fetch
  useEffect(() => {
    if (isClone && id) {
      fetchReleaseDetails(id).then(data => {
        setClonedService(data.service);
        setSelectedServices([data.service].filter(Boolean));
        setFormData(prev => ({
          ...prev, appGroup: data.appGroup, service: data.service,
          cluster: data.release_context?.cluster || 'MOVING_TECH', env: data.env,
          priority: String(data.priority || '0'),
          docker_image: data.release_context?.docker_image || data.docker_image || '',
          mode: data.mode, new_version: data.new_version || '', change_log: data.change_log || ''
        }));
        if (data.env_override_data) { setIsEnvSwitch(true); setEnvData(data.env_override_data); }
        if (data.rollout_strategy) {
          try {
            const parsed = typeof data.rollout_strategy === 'string' ? JSON.parse(data.rollout_strategy) : data.rollout_strategy;
            if (Array.isArray(parsed) && parsed.length > 0) setStages(parsed);
          } catch (e) { console.error('Failed to parse stages', e); }
        }
      }).catch(() => { setError('Failed to load clone details'); });
    }
  }, [isClone, id]);

  // Sync cluster
  useEffect(() => {
    if (formData.appGroup) {
      const config = productConfigs.find((c: ProductConfig) => c.appGroup === formData.appGroup);
      setSyncCluster(config?.sync_cluster || '');
    } else setSyncCluster('');
  }, [formData.appGroup, productConfigs]);

  // Load rollout stages from service config when service is selected (skip if cloning or updating)
  useEffect(() => {
    if (!isClone && !isUpdate && formData.appGroup && formData.service) {
      fetchReleaseConfigs(formData.appGroup).then(configs => {
        const svcConfig = configs.find(c => c.service === formData.service);
        if (svcConfig?.rollout_strategy) {
          try {
            // DB stores double-escaped JSON — parse until we get an array
            let parsed: any = svcConfig.rollout_strategy;
            for (let i = 0; i < 3 && typeof parsed === 'string'; i++) {
              parsed = JSON.parse(parsed);
            }
            // Handle [{cluster, rollouts: [...]}] format
            if (Array.isArray(parsed) && parsed.length > 0) {
              const rollouts = parsed[0]?.rollouts || parsed;
              if (Array.isArray(rollouts) && rollouts.length > 0) {
                setStages(rollouts.map((r: any) => ({
                  rollout: r.rollout ?? r.rolloutPercent ?? 0,
                  cooloff: r.cooloff ?? r.cooloffMinutes ?? 10,
                  pods: r.pods ?? r.podPercent ?? 1,
                })));
              }
            }
          } catch {}
        }
      }).catch(() => {});
    }
  }, [formData.appGroup, formData.service, isClone, isUpdate]);

  useEffect(() => { if (!isEnvSwitch) setEnvData(''); }, [isEnvSwitch]);
  useEffect(() => { if (!isResourcesSwitch) setResourcesData(''); }, [isResourcesSwitch]);

  // Fetch envs
  useEffect(() => {
    if (isEnvSwitch && formData.appGroup && formData.service && formData.env) {
      fetchEnvs(formData.appGroup, formData.env, formData.service).then(res => setEnvData(JSON.stringify(res, null, 2))).catch(console.error);
    }
  }, [isEnvSwitch, formData.appGroup, formData.service, formData.env]);

  // Fetch resources
  useEffect(() => {
    if (isResourcesSwitch && formData.appGroup && formData.service) {
      fetchResources(formData.appGroup, formData.service)
        .then(res => setResourcesData(JSON.stringify(res, null, 2)))
        .catch(() => setResourcesData(''));
    }
  }, [isResourcesSwitch, formData.appGroup, formData.service]);


  // Secondary envs
  useEffect(() => {
    if (isReleaseSync && isSecondaryEnvSwitch && formData.appGroup && formData.service && formData.env) {
      setSecondaryEnvLoading(true);
      fetchSecondaryEnvs(formData.appGroup, formData.env, formData.service)
        .then(res => setSecondaryEnvData(JSON.stringify(res, null, 2)))
        .catch(() => setSecondaryEnvData(''))
        .finally(() => setSecondaryEnvLoading(false));
    }
  }, [isReleaseSync, isSecondaryEnvSwitch, formData.appGroup, formData.service, formData.env]);

  useEffect(() => {
    if (!isReleaseSync) { setIsSecondaryEnvSwitch(false); setSecondaryEnvData(''); }
  }, [isReleaseSync]);

  // Auto-fill cluster & clear services on product change
  useEffect(() => {
    if (formData.appGroup && !isUpdate) {
      const config = productConfigs.find((c: ProductConfig) => c.appGroup === formData.appGroup);
      if (config) setFormData(prev => ({ ...prev, cluster: config.cluster }));
    }
    if (!isUpdate && !isClone) setSelectedServices([]);
  }, [formData.appGroup, productConfigs, isUpdate, isClone]);

  useEffect(() => {
    if (clonedService && services.includes(clonedService)) {
      setSelectedServices([clonedService]);
      setClonedService('');
    }
  }, [services, clonedService]);

  const handleInputChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>) => {
    const { name, value, type } = e.target;
    const finalValue = type === 'checkbox' ? (e.target as HTMLInputElement).checked : value;
    setFormData(prev => ({ ...prev, [name]: finalValue }));
  };

  const generateReleaseTag = (serviceOverride?: string) => {
    const svc = serviceOverride || selectedServices[0] || '';
    const acronym = productConfigs.find((p: ProductConfig) => p.appGroup === formData.appGroup)?.product_acronym || formData.appGroup?.slice(0, 4)?.toUpperCase() || '';
    const dateStr = new Date().toISOString().split('T')[0].replace(/-/g, '.');
    const versionTag = formData.new_version ? formData.new_version.slice(0, 8) : '';
    const svcTag = svc ? svc.slice(0, 6).toUpperCase() : '';
    const mode = formData.mode || 'AUTO';
    const env = formData.env || 'UAT';
    const pri = formData.priority || '0';
    // Only include non-empty parts to avoid double underscores
    const parts = [acronym, dateStr, versionTag, svcTag, mode, env, pri].filter(Boolean);
    return parts.join('_');
  };
  const generatedReleaseTag = generateReleaseTag();

  // Valid status options for update mode
  const statusOptions = isUpdate && formData.status
    ? (VALID_STATUS_TRANSITIONS[formData.status] || [formData.status])
    : ['CREATED'];

  const [versionError, setVersionError] = useState('');

  const validateNewVersion = (value: string): string => {
    if (!value) return '';
    if (/[A-Z]/.test(value)) return 'Version cannot contain uppercase letters';
    if (/[`!@#$%^&*()+\-=\[\]{};':"\\|,.<>\/?~]/.test(value)) return 'Version cannot contain special characters';
    return '';
  };

  const handleVersionChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    handleInputChange(e);
    setVersionError(validateNewVersion(e.target.value));
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');

    // Validate new_version (Fix #13)
    if (!isUpdate && formData.new_version) {
      if (/[A-Z]/.test(formData.new_version)) {
        toast.error('New version cannot contain uppercase letters');
        return;
      }
      if (/[`!@#$%^&*()+\-=\[\]{};':"\\|,.<>\/?~]/.test(formData.new_version)) {
        toast.error('New version cannot contain special characters');
        return;
      }
    }

    // Validate rollout strategy (Fix #12)
    if (stages.length === 0) {
      toast.error('Rollout strategy must have at least one stage');
      return;
    }
    const lastStage = stages[stages.length - 1];
    if (lastStage.rollout !== 100) {
      toast.error('Last rollout stage must be 100%');
      return;
    }
    for (let i = 1; i < stages.length; i++) {
      if (stages[i].rollout <= stages[i - 1].rollout) {
        toast.error('Rollout stages must be in increasing order');
        return;
      }
    }
    for (const stage of stages) {
      if (stage.rollout < 1 || stage.rollout > 100) {
        toast.error('Each rollout percent must be between 1 and 100');
        return;
      }
      if (stage.cooloff < 0) {
        toast.error('Cooloff must be >= 0');
        return;
      }
    }

    if (isUpdate && id) {
      // Update mode: only send editable fields + future stages
      const futureStages = stages.slice(rolloutHistoryLength);
      try {
        await updateMutation.mutateAsync({
          releaseId: id,
          updates: {
            status: formData.status,
            mode: formData.mode,
            description: formData.description,
            changeLog: formData.change_log,
            priority: parseInt(formData.priority, 10) || 0,
            scheduleTime: formData.schedule_time || null,
            dockerImage: formData.docker_image,
            podsScaleDownDelay: parseFloat(formData.scale_down_delay) || 1.0,
            info: formData.info,
            rolloutStrategy: stages.map(s => ({
              rolloutPercent: s.rollout,
              cooloffMinutes: s.cooloff,
              podPercent: s.pods,
            })),
          },
        });
        navigate(`/releases/${id}`);
      } catch (err: any) {
        setError(err.message || 'Failed to update release');
      }
      return;
    }

    // Create mode
    if (selectedServices.length === 0) {
      toast.error('Select at least one service');
      return;
    }

    const selectedProductConfig = productConfigs.find((c: ProductConfig) => c.appGroup === formData.appGroup);
    const trackerType = selectedProductConfig?.product_type === 'SCHEDULER' ? 'BackendScheduler' : 'BackendService';

    const buildPayload = (svc: string) => ({
      appGroup: formData.appGroup, service: [svc], env: formData.env,
      old_version: formData.old_version || 'unknown',
      new_version: formData.new_version, docker_image: formData.docker_image,
      change_log: formData.change_log, status: formData.status, mode: formData.mode,
      priority: parseInt(formData.priority, 10) || 0, info: formData.info,
      pods_scale_down_delay: parseFloat(formData.scale_down_delay) || 1.0,
      cronjob_suspend: formData.cronjob_suspend,
      description: formData.description, schedule_time: formData.schedule_time,
      cluster: formData.cluster, new_service: false, rollout_strategy: stages,
      is_approved: formData.env === 'INTEG_CLUSTER' ? 1 : 0,
      env_override_data: isEnvSwitch ? envData : null,
      slack_thread_ts: null,
      isReleaseSync,
      syncClusterEnvOverrideData: isReleaseSync && isSecondaryEnvSwitch ? secondaryEnvData : null,
      syncClusterRolloutStrategy: isReleaseSync ? secondaryStages.map(s => ({ rolloutPercent: s.rollout, cooloffMinutes: s.cooloff, podPercent: s.pods })) : null,
      release_manager: "local_admin", release_tag: generateReleaseTag(svc), trackerType,
    });

    try {
      if (selectedServices.length === 1) {
        await createMutation.mutateAsync({ isNewService, payload: buildPayload(selectedServices[0]) });
        toast.success('Release created');
      } else {
        let created = 0;
        for (const svc of selectedServices) {
          await createMutation.mutateAsync({ isNewService, payload: buildPayload(svc) });
          created++;
        }
        toast.success(`Created ${created} releases`);
      }
      navigate('/releases');
    } catch (err: any) {
      setError(err.message || 'Failed to create release');
    }
  };

  const FieldLabel = ({ children, required }: { children: React.ReactNode; required?: boolean }) => (
    <label className="text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5 block">
      {children} {required && <span className="text-red-500">*</span>}
    </label>
  );

  const inputClass = "w-full h-9 border border-zinc-300 rounded-lg px-3 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150";
  const disabledInputClass = "w-full h-9 border border-zinc-200 rounded-lg px-3 text-sm bg-zinc-100 text-zinc-500 cursor-not-allowed";

  const Toggle = ({ checked, onChange, disabled }: { checked: boolean; onChange: () => void; disabled?: boolean }) => (
    <button type="button" onClick={onChange} disabled={disabled}
      className={cn(
        'relative inline-flex h-6 w-10 items-center rounded-full transition-colors duration-150 cursor-pointer',
        disabled ? 'bg-zinc-200 cursor-not-allowed' : checked ? 'bg-zinc-900' : 'bg-zinc-300'
      )}>
      <span className={cn('inline-block h-4 w-4 transform rounded-full bg-white transition-transform duration-150', checked ? 'translate-x-5' : 'translate-x-1')} />
    </button>
  );

  const canToggleEnvSwitch = selectedServices.length === 1;
  const canToggleResourcesSwitch = selectedServices.length === 1;
  const isSubmitting = isUpdate ? updateMutation.isPending : createMutation.isPending;
  const pageTitle = isUpdate ? 'Update Release' : isClone ? 'Clone Release' : 'Create Release';
  const submitLabel = isUpdate
    ? (updateMutation.isPending ? 'Updating...' : 'Update Release')
    : (createMutation.isPending ? 'Creating...' : selectedServices.length > 1 ? `Create ${selectedServices.length} Releases` : 'Create Release');

  return (
    <div className="flex flex-col flex-1 w-full pb-12">
      <form onSubmit={handleSubmit} className="space-y-6">
        {error && <div className="bg-red-50 border border-red-200 text-red-600 px-4 py-3 rounded-xl text-sm">{error}</div>}

        {/* Main Form Card */}
        <div className="bg-white rounded-xl border border-zinc-200">
          <div className="px-6 py-4 border-b border-zinc-100 flex justify-between items-center">
            <h2 className="text-lg font-semibold text-zinc-900">{pageTitle}</h2>
          </div>

          <div className="p-6 grid grid-cols-1 md:grid-cols-3 gap-x-8 gap-y-5">
            {/* Col 1 */}
            <div className="space-y-4">
              <div>
                <FieldLabel>Release Tag</FieldLabel>
                <input type="text" value={isUpdate ? (existingRelease?.release_tag || '') : generatedReleaseTag} disabled className={disabledInputClass} />
              </div>
              <div>
                <FieldLabel required={!isUpdate}>New Version</FieldLabel>
                <input type="text" name="new_version" value={formData.new_version}
                  onChange={isUpdate ? handleInputChange : handleVersionChange}
                  required={!isUpdate} placeholder="Jenkins tag"
                  disabled={isUpdate}
                  className={cn(
                    isUpdate ? disabledInputClass : inputClass,
                    versionError && 'border-red-400 focus:ring-red-400'
                  )} />
                {versionError && <p className="text-[10px] text-red-500 mt-0.5">{versionError}</p>}
              </div>
              <div>
                <FieldLabel>Old Version</FieldLabel>
                <input type="text" name="old_version" value={formData.old_version} onChange={handleInputChange}
                  placeholder="Auto-resolved from K8s if empty"
                  disabled={isUpdate} className={isUpdate ? disabledInputClass : inputClass} />
              </div>
              <div>
                <FieldLabel>Mode</FieldLabel>
                <select name="mode" value={formData.mode} onChange={handleInputChange} className={cn(inputClass, 'cursor-pointer')}>
                  <option value="AUTO">AUTO</option>
                  <option value="MANUAL">MANUAL</option>
                </select>
              </div>
              <div><FieldLabel>Info</FieldLabel><input type="text" name="info" value={formData.info} onChange={handleInputChange} placeholder="Any Valid JSON" className={inputClass} /></div>
              <div><FieldLabel>Scale Down Days</FieldLabel><select name="custom_pods_scale_down_days" value={formData.custom_pods_scale_down_days} onChange={handleInputChange} className={cn(inputClass, 'cursor-pointer')}>{[1,2,3,4,5,6].map(d => <option key={d} value={d}>{d}</option>)}</select></div>
            </div>

            {/* Col 2 */}
            <div className="space-y-4">
              <div>
                <FieldLabel required={!isUpdate}>App Group</FieldLabel>
                {isUpdate ? (
                  <input type="text" value={formData.appGroup} disabled className={disabledInputClass} />
                ) : (
                  <select name="appGroup" value={formData.appGroup} onChange={handleInputChange} required className={cn(inputClass, 'cursor-pointer')}>
                    <option value="">Select Product</option>
                    {products.map(p => <option key={p} value={p}>{p}</option>)}
                  </select>
                )}
              </div>
              <div>
                <FieldLabel required={!isUpdate}>Env</FieldLabel>
                {isUpdate ? (
                  <input type="text" value={formData.env} disabled className={disabledInputClass} />
                ) : (
                  <select name="env" value={formData.env} onChange={handleInputChange} required className={cn(inputClass, 'cursor-pointer')}>
                    <option value="">Select Env</option>
                    {AVAILABLE_ENVS.map(e => <option key={e} value={e}>{e}</option>)}
                  </select>
                )}
              </div>
              <div><FieldLabel>Priority</FieldLabel><select name="priority" value={formData.priority} onChange={handleInputChange} className={cn(inputClass, 'cursor-pointer')}>{[0,1,2,3,4,5,6,7,8,9].map(d => <option key={d} value={d}>{d}</option>)}</select></div>
              <div><FieldLabel>Description</FieldLabel><input type="text" name="description" value={formData.description} onChange={handleInputChange} placeholder="Deploying webhook Hotfix" className={inputClass} /></div>
              <div>
                <FieldLabel required={!isUpdate}>Docker Image</FieldLabel>
                <input type="text" name="docker_image" value={formData.docker_image} onChange={handleInputChange}
                  required={!isUpdate} placeholder="Enter Docker Image" className={inputClass} />
              </div>
              {isUpdate && (
                <div>
                  <FieldLabel>Status</FieldLabel>
                  <select name="status" value={formData.status} onChange={handleInputChange} className={cn(inputClass, 'cursor-pointer')}>
                    {statusOptions.map(st => <option key={st} value={st}>{st}</option>)}
                  </select>
                </div>
              )}
            </div>

            {/* Col 3 */}
            <div className="space-y-4">
              <div>
                <FieldLabel required={!isUpdate}>Service</FieldLabel>
                {isUpdate ? (
                  <input type="text" value={selectedServices.join(', ')} disabled className={disabledInputClass} />
                ) : (
                  <div className="service-dropdown relative">
                    <div
                      onClick={() => formData.appGroup && services.length > 0 && setShowServiceDropdown(!showServiceDropdown)}
                      className={cn(inputClass, 'cursor-pointer flex items-center justify-between', (!formData.appGroup || services.length === 0) && 'bg-zinc-50 cursor-not-allowed')}
                    >
                      <span className={selectedServices.length > 0 ? 'text-zinc-900' : 'text-zinc-400'}>
                        {selectedServices.length > 0 ? `${selectedServices.length} selected` : 'Select services'}
                      </span>
                      <ChevronDown className="w-4 h-4 text-zinc-400" />
                    </div>
                    {showServiceDropdown && (
                      <div className="absolute z-20 mt-1 w-full max-h-60 overflow-y-auto bg-white border border-zinc-200 rounded-lg shadow-lg">
                        {services.length === 0 ? (
                          <div className="px-3 py-2 text-sm text-zinc-400">No services found</div>
                        ) : (
                          <>
                            <button type="button" onClick={() => setSelectedServices(selectedServices.length === services.length ? [] : [...services])}
                              className="w-full px-3 py-2 text-left text-xs text-zinc-500 hover:bg-zinc-50 border-b border-zinc-100">
                              {selectedServices.length === services.length ? 'Deselect All' : 'Select All'}
                            </button>
                            {services.map((svc: string) => (
                              <label key={svc} className="flex items-center gap-2 px-3 py-2 text-sm hover:bg-zinc-50 cursor-pointer">
                                <input type="checkbox" checked={selectedServices.includes(svc)}
                                  onChange={() => setSelectedServices(prev => prev.includes(svc) ? prev.filter(s => s !== svc) : [...prev, svc])}
                                  className="rounded border-zinc-300 accent-zinc-900" />
                                {svc}
                              </label>
                            ))}
                          </>
                        )}
                      </div>
                    )}
                  </div>
                )}
                {selectedServices.length > 0 && !isUpdate && (
                  <div className="flex flex-wrap gap-1 mt-1.5">
                    {selectedServices.map(svc => (
                      <span key={svc} className="inline-flex items-center gap-1 px-2 py-0.5 rounded-md bg-zinc-100 text-zinc-700 text-xs">
                        {svc}
                        <button type="button" onClick={() => setSelectedServices(prev => prev.filter(s => s !== svc))} className="text-zinc-400 hover:text-zinc-600">&times;</button>
                      </span>
                    ))}
                  </div>
                )}
              </div>
              <div><FieldLabel>Schedule Time</FieldLabel><input type="text" name="schedule_time" value={formData.schedule_time} onChange={handleInputChange} placeholder="2022-11-01T19:39:35" className={inputClass} /></div>
              <div><FieldLabel>Cluster</FieldLabel><input type="text" disabled value={formData.cluster} className={disabledInputClass} /></div>
              <div>
                <FieldLabel required={!isUpdate}>Change Log</FieldLabel>
                <input type="text" name="change_log" value={formData.change_log} onChange={handleInputChange}
                  required={!isUpdate} placeholder="v1.0.0" className={inputClass} />
              </div>
              <div><FieldLabel>Scale Down Delay (hrs)</FieldLabel><input type="text" name="scale_down_delay" value={formData.scale_down_delay} onChange={handleInputChange} placeholder="1" className={inputClass} /></div>
            </div>
          </div>

          {/* New Service YAML Paths removed from UI — backend still accepts via API */}
        </div>

        {/* Stages Card */}
        <div className="bg-white rounded-xl border border-zinc-200">
          <div className="px-6 py-4 border-b border-zinc-100">
            <h2 className="text-lg font-semibold text-zinc-900">Stages</h2>
            {isUpdate && rolloutHistoryLength > 0 && (
              <p className="text-xs text-zinc-500 mt-1">
                Stages 1-{rolloutHistoryLength} are locked (already executed). Only future stages can be edited.
              </p>
            )}
          </div>
          <div className="p-6">
            <div className="overflow-x-auto">
              <table className="w-full text-sm text-left">
                <thead>
                  <tr className="bg-zinc-50 border-b border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                    <th className="py-2 px-3 w-12">#</th>
                    <th className="py-2 px-3">Rollout %</th>
                    <th className="py-2 px-3">Cooloff (min)</th>
                    <th className="py-2 px-3">Pods</th>
                    <th className="py-2 px-3 w-16"></th>
                  </tr>
                </thead>
                <tbody>
                  {stages.map((stage, idx) => {
                    const isLocked = isUpdate && idx < rolloutHistoryLength;
                    return (
                      <tr key={idx} className={cn(
                        'border-b border-zinc-100',
                        idx % 2 === 1 ? 'bg-zinc-50' : 'bg-white',
                        isLocked && 'opacity-50'
                      )}>
                        <td className="py-2 px-3 text-zinc-400 font-mono text-xs flex items-center gap-1.5">
                          {isLocked && <Lock className="w-3 h-3 text-zinc-400" />}
                          {idx + 1}
                        </td>
                        <td className="py-2 px-3">
                          <input type="number" value={stage.rollout}
                            disabled={isLocked}
                            onChange={(e) => setStages(prev => prev.map((s, i) => i === idx ? { ...s, rollout: parseInt(e.target.value) || 0 } : s))}
                            className={cn(isLocked ? disabledInputClass : inputClass, 'w-24')} />
                        </td>
                        <td className="py-2 px-3">
                          <input type="number" value={stage.cooloff}
                            disabled={isLocked}
                            onChange={(e) => setStages(prev => prev.map((s, i) => i === idx ? { ...s, cooloff: parseInt(e.target.value) || 0 } : s))}
                            className={cn(isLocked ? disabledInputClass : inputClass, 'w-24')} />
                        </td>
                        <td className="py-2 px-3">
                          <input type="number" value={stage.pods}
                            disabled={isLocked}
                            onChange={(e) => setStages(prev => prev.map((s, i) => i === idx ? { ...s, pods: parseInt(e.target.value) || 0 } : s))}
                            className={cn(isLocked ? disabledInputClass : inputClass, 'w-24')} />
                        </td>
                        <td className="py-2 px-3">
                          {!isLocked && stages.filter((_, i) => !isUpdate || i >= rolloutHistoryLength).length > 1 && (
                            <button type="button" onClick={() => setStages(stages.filter((_, i) => i !== idx))} className="p-1.5 rounded-lg text-red-500 hover:bg-red-50 cursor-pointer transition-colors duration-150">
                              <Trash2 className="w-3.5 h-3.5" />
                            </button>
                          )}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
            <Button type="button" variant="secondary" size="sm" onClick={() => setStages([...stages, { rollout: 100, cooloff: 0, pods: 0 }])} className="mt-3">+ Add Stage</Button>
          </div>
        </div>

        {/* Env Switch */}
        {!isNewService && (
          <div className="bg-white rounded-xl border border-zinc-200">
            <div className="px-6 py-4 border-b border-zinc-100 flex items-center gap-3">
              <h2 className="text-lg font-semibold text-zinc-900">Env Switch</h2>
              <Toggle checked={isEnvSwitch} onChange={() => canToggleEnvSwitch && formData.service && setIsEnvSwitch(!isEnvSwitch)} disabled={!canToggleEnvSwitch || !formData.service} />
              {!canToggleEnvSwitch && selectedServices.length > 1 && <span className="text-xs text-zinc-400 ml-2">Single service only</span>}
            </div>
            {isEnvSwitch && (
              <div className="p-6">
                <FieldLabel>Environment Variables JSON</FieldLabel>
                <div className="border border-zinc-200 rounded-lg overflow-hidden mt-1">
                  <Editor height="320px" defaultLanguage="json" theme="light" value={envData} onChange={(val) => setEnvData(val || '')}
                    options={{ minimap: { enabled: false }, fontSize: 13, lineNumbers: 'on', scrollBeyondLastLine: false, wordWrap: 'on', tabSize: 2, automaticLayout: true }} />
                </div>
              </div>
            )}
          </div>
        )}

        {/* Get Resources */}
        {!isNewService && (
          <div className="bg-white rounded-xl border border-zinc-200">
            <div className="px-6 py-4 border-b border-zinc-100 flex items-center gap-3">
              <h2 className="text-lg font-semibold text-zinc-900">Get Resources</h2>
              <Toggle checked={isResourcesSwitch} onChange={() => canToggleResourcesSwitch && formData.service && setIsResourcesSwitch(!isResourcesSwitch)} disabled={!canToggleResourcesSwitch || !formData.service} />
              {!canToggleResourcesSwitch && selectedServices.length > 1 && <span className="text-xs text-zinc-400 ml-2">Single service only</span>}
            </div>
            {isResourcesSwitch && (
              <div className="p-6">
                <FieldLabel>Resource Limits (CPU / Memory)</FieldLabel>
                <div className="border border-zinc-200 rounded-lg overflow-hidden mt-1">
                  <Editor height="280px" defaultLanguage="json" theme="light" value={resourcesData}
                    options={{ readOnly: true, minimap: { enabled: false }, fontSize: 13, lineNumbers: 'on', scrollBeyondLastLine: false, wordWrap: 'on', tabSize: 2, automaticLayout: true }} />
                </div>
              </div>
            )}
          </div>
        )}

        {/* Sync Release */}
        {syncCluster && !isUpdate && (
          <div className="bg-white rounded-xl border border-zinc-200">
            <div className="px-6 py-4 border-b border-zinc-100 flex items-center gap-3">
              <h2 className="text-lg font-semibold text-zinc-900">Sync Release to Other Cloud</h2>
              <Toggle checked={isReleaseSync} onChange={() => setIsReleaseSync(!isReleaseSync)} />
              <span className="text-sm text-zinc-500">{isReleaseSync ? `Sync to ${syncCluster}` : 'Single cloud only'}</span>
            </div>
            {isReleaseSync && (
              <div className="p-6 space-y-6">
                <div>
                  <div className="flex items-center gap-3 mb-3">
                    <h3 className="text-base font-semibold text-zinc-900">Env Switch (Secondary)</h3>
                    <Toggle checked={isSecondaryEnvSwitch} onChange={() => canToggleEnvSwitch && formData.service && setIsSecondaryEnvSwitch(!isSecondaryEnvSwitch)} disabled={!canToggleEnvSwitch || !formData.service} />
                  </div>
                  {isSecondaryEnvSwitch && (
                    secondaryEnvLoading ? <p className="text-xs text-zinc-400 py-4">Loading secondary env vars...</p> : (
                      <div className="border border-zinc-200 rounded-lg overflow-hidden">
                        <Editor height="280px" defaultLanguage="json" theme="light" value={secondaryEnvData} onChange={(val) => setSecondaryEnvData(val || '')}
                          options={{ minimap: { enabled: false }, fontSize: 13, lineNumbers: 'on', scrollBeyondLastLine: false, wordWrap: 'on', tabSize: 2, automaticLayout: true }} />
                      </div>
                    )
                  )}
                </div>
                <div>
                  <h3 className="text-base font-semibold text-zinc-900 mb-3">Secondary Cluster Stages</h3>
                  <div className="overflow-x-auto">
                    <table className="w-full text-sm text-left">
                      <thead>
                        <tr className="bg-zinc-50 border-b border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                          <th className="py-2 px-3 w-12">#</th>
                          <th className="py-2 px-3">Rollout %</th>
                          <th className="py-2 px-3">Cooloff</th>
                          <th className="py-2 px-3">Pods</th>
                          <th className="py-2 px-3 w-16"></th>
                        </tr>
                      </thead>
                      <tbody>
                        {secondaryStages.map((stage, idx) => (
                          <tr key={idx} className={cn('border-b border-zinc-100', idx % 2 === 1 ? 'bg-zinc-50' : 'bg-white')}>
                            <td className="py-2 px-3 text-zinc-400 font-mono text-xs">{idx + 1}</td>
                            <td className="py-2 px-3"><input type="number" value={stage.rollout} onChange={(e) => { const s = [...secondaryStages]; s[idx].rollout = parseInt(e.target.value) || 0; setSecondaryStages(s); }} className={cn(inputClass, 'w-24')} /></td>
                            <td className="py-2 px-3"><input type="number" value={stage.cooloff} onChange={(e) => { const s = [...secondaryStages]; s[idx].cooloff = parseInt(e.target.value) || 0; setSecondaryStages(s); }} className={cn(inputClass, 'w-24')} /></td>
                            <td className="py-2 px-3"><input type="number" value={stage.pods} onChange={(e) => { const s = [...secondaryStages]; s[idx].pods = parseInt(e.target.value) || 0; setSecondaryStages(s); }} className={cn(inputClass, 'w-24')} /></td>
                            <td className="py-2 px-3">
                              {secondaryStages.length > 1 && (
                                <button type="button" onClick={() => setSecondaryStages(secondaryStages.filter((_, i) => i !== idx))} className="p-1.5 rounded-lg text-red-500 hover:bg-red-50 cursor-pointer transition-colors duration-150">
                                  <Trash2 className="w-3.5 h-3.5" />
                                </button>
                              )}
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                  <Button type="button" variant="secondary" size="sm" onClick={() => setSecondaryStages([...secondaryStages, { rollout: 100, cooloff: 0, pods: 0 }])} className="mt-3">+ Add Stage</Button>
                </div>
              </div>
            )}
          </div>
        )}

        {/* Action Buttons */}
        <div className="flex justify-end gap-3 pt-2">
          <Button type="button" variant="secondary" onClick={() => isUpdate ? navigate(`/releases/${id}`) : navigate('/releases')}>Cancel</Button>
          <Button type="submit" loading={isSubmitting}>{submitLabel}</Button>
        </div>
      </form>
    </div>
  );
};

export default CreateRelease;
