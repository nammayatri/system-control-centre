import React, { useState, useEffect } from 'react';
import { useNavigate, useParams, useLocation } from 'react-router-dom';
import Editor from '@monaco-editor/react';
import { useProductConfigs, useServices } from '../useProducts';
import { useCreateRelease } from '../hooks';
import { fetchReleaseDetails, fetchEnvs, fetchSecondaryEnvs } from '../api';
import { fetchReleaseConfigs, fetchConfigMapData } from '../../../api';
import type { ProductConfig } from '../../../api';
import { Button } from '../../../shared/ui/button';
import { cn } from '../../../lib/utils';
import { DEFAULT_ENV, AVAILABLE_ENVS } from '../../../lib/constants';
import { Trash2 } from 'lucide-react';

const CreateRelease: React.FC = () => {
  const navigate = useNavigate();
  const location = useLocation();
  const { id } = useParams<{ id?: string }>();
  const isClone = location.pathname.endsWith('/clone') && !!id;

  const { data: productConfigs = [] } = useProductConfigs();
  const products = [...new Set(productConfigs.map((c: ProductConfig) => c.product).filter(Boolean))];

  const [formData, setFormData] = useState({
    product: '', service: '', env: DEFAULT_ENV, new_version: '', docker_image: '', change_log: '',
    status: 'CREATED', mode: 'AUTO', priority: '0', info: '', custom_pods_scale_down_days: '1',
    cluster: 'EULER_UAT', scale_down_delay: '1',
    cronjob_suspend: false, description: '', schedule_time: '',
    deploy_file_path: '', vs_file_path: '', dr_file_path: '',
  });
  const [isNewService, setIsNewService] = useState(false);
  const [error, setError] = useState('');
  const [isEnvSwitch, setIsEnvSwitch] = useState(false);
  const [envData, setEnvData] = useState('');
  const [isConfigMapSwitch, setIsConfigMapSwitch] = useState(false);
  const [configMapData, setConfigMapData] = useState('');
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

  const { data: services = [] } = useServices(formData.product, isNewService);
  const createMutation = useCreateRelease();

  // Clone fetch
  useEffect(() => {
    if (isClone && id) {
      fetchReleaseDetails(id).then(data => {
        setIsNewService(data.new_service === 'Yes');
        setClonedService(data.service);
        setFormData(prev => ({
          ...prev, product: data.product, service: data.service,
          cluster: data.release_context?.cluster || 'EULER_UAT', env: data.env,
          priority: String(data.priority || '0'),
          docker_image: data.release_context?.docker_image || data.docker_image || '',
          mode: data.mode, new_version: data.new_version || '', change_log: data.change_log || ''
        }));
        if (data.udf2) { setIsEnvSwitch(true); setEnvData(data.udf2); }
        if (data.udf3) { setIsConfigMapSwitch(true); setConfigMapData(data.udf3); }
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
    if (formData.product) {
      const config = productConfigs.find((c: ProductConfig) => c.product === formData.product);
      setSyncCluster(config?.sync_cluster || '');
    } else setSyncCluster('');
  }, [formData.product, productConfigs]);

  // Load rollout stages from service config when service is selected (skip if cloning)
  useEffect(() => {
    if (!isClone && formData.product && formData.service) {
      fetchReleaseConfigs(formData.product).then(configs => {
        const svcConfig = configs.find(c => c.service === formData.service);
        if (svcConfig?.rollout_strategy) {
          try {
            const parsed = typeof svcConfig.rollout_strategy === 'string'
              ? JSON.parse(svcConfig.rollout_strategy) : svcConfig.rollout_strategy;
            // Handle [{cluster, rollouts: [...]}] format
            if (Array.isArray(parsed) && parsed.length > 0) {
              const rollouts = parsed[0]?.rollouts || parsed;
              if (Array.isArray(rollouts) && rollouts.length > 0) {
                setStages(rollouts.map((r: any) => ({
                  rollout: r.rollout ?? r.rolloutPercent ?? 0,
                  cooloff: r.cooloff ?? r.cooloffSeconds ?? 10,
                  pods: r.pods ?? r.podPercent ?? 1,
                })));
              }
            }
          } catch {}
        }
      }).catch(() => {});
    }
  }, [formData.product, formData.service, isClone]);

  useEffect(() => { if (!isEnvSwitch) setEnvData(''); }, [isEnvSwitch]);
  useEffect(() => { if (!isConfigMapSwitch) setConfigMapData(''); }, [isConfigMapSwitch]);

  // Fetch envs
  useEffect(() => {
    if (isEnvSwitch && formData.product && formData.service && formData.env) {
      fetchEnvs(formData.product, formData.env, formData.service).then(res => setEnvData(JSON.stringify(res, null, 2))).catch(console.error);
    }
  }, [isEnvSwitch, formData.product, formData.service, formData.env]);

  // Fetch configmap
  useEffect(() => {
    if (isConfigMapSwitch && formData.product && formData.service) {
      fetchConfigMapData(formData.product, formData.service)
        .then(res => {
          try {
            const parsed = typeof res === 'string' ? JSON.parse(res) : res;
            setConfigMapData(JSON.stringify(parsed, null, 2));
          } catch {
            setConfigMapData(typeof res === 'string' ? res : JSON.stringify(res, null, 2));
          }
        })
        .catch(() => setConfigMapData(''));
    }
  }, [isConfigMapSwitch, formData.product, formData.service]);

  // Secondary envs
  useEffect(() => {
    if (isReleaseSync && isSecondaryEnvSwitch && formData.product && formData.service && formData.env) {
      setSecondaryEnvLoading(true);
      fetchSecondaryEnvs(formData.product, formData.env, formData.service)
        .then(res => setSecondaryEnvData(JSON.stringify(res, null, 2)))
        .catch(() => setSecondaryEnvData(''))
        .finally(() => setSecondaryEnvLoading(false));
    }
  }, [isReleaseSync, isSecondaryEnvSwitch, formData.product, formData.service, formData.env]);

  useEffect(() => {
    if (!isReleaseSync) { setIsSecondaryEnvSwitch(false); setSecondaryEnvData(''); }
  }, [isReleaseSync]);

  // Auto-fill cluster & set cloned service
  useEffect(() => {
    if (formData.product) {
      const config = productConfigs.find((c: ProductConfig) => c.product === formData.product);
      if (config) setFormData(prev => ({ ...prev, cluster: config.cluster }));
    }
  }, [formData.product, productConfigs]);

  useEffect(() => {
    if (clonedService && services.includes(clonedService)) {
      setFormData(prev => ({ ...prev, service: clonedService }));
      setClonedService('');
    }
  }, [services, clonedService]);

  const handleInputChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>) => {
    const { name, value, type } = e.target;
    const finalValue = type === 'checkbox' ? (e.target as HTMLInputElement).checked : value;
    setFormData(prev => ({ ...prev, [name]: finalValue }));
  };

  const [manualReleaseTag, setManualReleaseTag] = useState('');
  const dateStr = new Date().toISOString().split('T')[0].replace(/-/g, '');
  const productTag = formData.product || 'PRODUCT';
  const serviceTag = formData.service || 'SERVICE';
  const versionTag = formData.new_version || 'VERSION';
  const autoGeneratedReleaseTag = `${productTag}_${dateStr}_${versionTag}_${serviceTag}_${formData.mode}_${formData.env || 'ENV'}_${formData.priority}`;
  const generatedReleaseTag = manualReleaseTag || autoGeneratedReleaseTag;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    const selectedProductConfig = productConfigs.find((c: ProductConfig) => c.product === formData.product);
    const trackerType = selectedProductConfig?.product_type === 'SCHEDULER' ? 'BackendScheduler' : 'BackendService';

    const payload = {
      product: formData.product, service: [formData.service], env: formData.env,
      new_version: formData.new_version, docker_image: formData.docker_image,
      change_log: formData.change_log, status: formData.status, mode: formData.mode,
      priority: parseInt(formData.priority, 10) || 0, info: formData.info,
      pods_scale_down_delay: parseFloat(formData.scale_down_delay) || 1.0,
      cronjob_suspend: formData.cronjob_suspend,
      description: formData.description, schedule_time: formData.schedule_time,
      cluster: formData.cluster, new_service: isNewService, rollout_strategy: stages,
      deploy_file_path: isNewService && formData.deploy_file_path ? formData.deploy_file_path : null,
      vs_file_path: isNewService && formData.vs_file_path ? formData.vs_file_path : null,
      dr_file_path: isNewService && formData.dr_file_path ? formData.dr_file_path : null,
      is_approved: formData.env === 'INTEG_CLUSTER' ? 1 : 0,
      udf2: isEnvSwitch ? envData : null,
      udf3: isConfigMapSwitch ? configMapData : null,
      isReleaseSync,
      syncClusterUdf2: isReleaseSync && isSecondaryEnvSwitch ? secondaryEnvData : null,
      syncClusterRolloutStrategy: isReleaseSync ? secondaryStages.map(s => ({ rolloutPercent: s.rollout, cooloffSeconds: s.cooloff, podPercent: s.pods })) : null,
      release_manager: "local_admin", release_tag: generatedReleaseTag, trackerType,
    };

    try {
      await createMutation.mutateAsync({ isNewService, payload });
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
  const disabledInputClass = "w-full h-9 border border-zinc-200 rounded-lg px-3 text-sm bg-zinc-50 text-zinc-400 cursor-not-allowed";

  const Toggle = ({ checked, onChange, disabled }: { checked: boolean; onChange: () => void; disabled?: boolean }) => (
    <button type="button" onClick={onChange} disabled={disabled}
      className={cn(
        'relative inline-flex h-6 w-10 items-center rounded-full transition-colors duration-150 cursor-pointer',
        disabled ? 'bg-zinc-200 cursor-not-allowed' : checked ? 'bg-zinc-900' : 'bg-zinc-300'
      )}>
      <span className={cn('inline-block h-4 w-4 transform rounded-full bg-white transition-transform duration-150', checked ? 'translate-x-5' : 'translate-x-1')} />
    </button>
  );

  return (
    <div className="flex flex-col flex-1 w-full pb-12 max-w-6xl">
      <form onSubmit={handleSubmit} className="space-y-6">
        {error && <div className="bg-red-50 border border-red-200 text-red-600 px-4 py-3 rounded-xl text-sm">{error}</div>}

        {/* Main Form Card */}
        <div className="bg-white rounded-xl border border-zinc-200">
          <div className="px-6 py-4 border-b border-zinc-100 flex justify-between items-center">
            <h2 className="text-lg font-semibold text-zinc-900">{isClone ? 'Clone Release' : 'Create Release'}</h2>
            <div className="flex items-center gap-3">
              <span className="text-sm text-zinc-600">New Service?</span>
              <Toggle checked={isNewService} onChange={() => setIsNewService(!isNewService)} />
            </div>
          </div>

          <div className="p-6 grid grid-cols-1 md:grid-cols-3 gap-x-8 gap-y-5">
            {/* Col 1 */}
            <div className="space-y-4">
              <div>
                <FieldLabel>Release Tag</FieldLabel>
                <input
                  type="text"
                  value={manualReleaseTag || autoGeneratedReleaseTag}
                  onChange={(e) => setManualReleaseTag(e.target.value)}
                  placeholder="Auto-generated from fields"
                  className={cn(inputClass, !manualReleaseTag && 'text-zinc-400')}
                />
                {manualReleaseTag && (
                  <button type="button" onClick={() => setManualReleaseTag('')} className="text-[10px] text-zinc-400 hover:text-zinc-600 mt-0.5 cursor-pointer">Reset to auto-generated</button>
                )}
              </div>
              <div><FieldLabel required>New Version</FieldLabel><input type="text" name="new_version" value={formData.new_version} onChange={handleInputChange} required placeholder="Jenkins tag" className={inputClass} /></div>
              <div><FieldLabel>Mode</FieldLabel><select name="mode" value={formData.mode} onChange={handleInputChange} className={cn(inputClass, 'cursor-pointer')}><option value="AUTO">AUTO</option><option value="MANUAL">MANUAL</option></select></div>
              <div><FieldLabel>Info</FieldLabel><input type="text" name="info" value={formData.info} onChange={handleInputChange} placeholder="Any Valid JSON" className={inputClass} /></div>
              <div><FieldLabel>Scale Down Days</FieldLabel><select name="custom_pods_scale_down_days" value={formData.custom_pods_scale_down_days} onChange={handleInputChange} className={cn(inputClass, 'cursor-pointer')}>{[1,2,3,4,5,6].map(d => <option key={d} value={d}>{d}</option>)}</select></div>
              <label className="flex items-center gap-2.5 cursor-pointer"><input type="checkbox" name="cronjob_suspend" checked={formData.cronjob_suspend} onChange={handleInputChange} className="rounded border-zinc-300 accent-zinc-900" /><span className="text-sm text-zinc-700">Cronjob Suspend</span></label>
            </div>

            {/* Col 2 */}
            <div className="space-y-4">
              <div><FieldLabel required>Product</FieldLabel><select name="product" value={formData.product} onChange={handleInputChange} required className={cn(inputClass, 'cursor-pointer')}><option value="">Select Product</option>{products.map(p => <option key={p} value={p}>{p}</option>)}</select></div>
              <div><FieldLabel required>Env</FieldLabel><select name="env" value={formData.env} onChange={handleInputChange} required className={cn(inputClass, 'cursor-pointer')}><option value="">Select Env</option>{AVAILABLE_ENVS.map(e => <option key={e} value={e}>{e}</option>)}</select></div>
              <div><FieldLabel>Priority</FieldLabel><select name="priority" value={formData.priority} onChange={handleInputChange} className={cn(inputClass, 'cursor-pointer')}>{[0,1,2,3,4,5,6,7,8,9].map(d => <option key={d} value={d}>{d}</option>)}</select></div>
              <div><FieldLabel>Description</FieldLabel><input type="text" name="description" value={formData.description} onChange={handleInputChange} placeholder="Deploying webhook Hotfix" className={inputClass} /></div>
              <div><FieldLabel required>Docker Image</FieldLabel><input type="text" name="docker_image" value={formData.docker_image} onChange={handleInputChange} required placeholder="Enter Docker Image" className={inputClass} /></div>
            </div>

            {/* Col 3 */}
            <div className="space-y-4">
              <div><FieldLabel required>Service</FieldLabel><select name="service" value={formData.service} onChange={handleInputChange} required disabled={!formData.product || services.length === 0} className={cn(inputClass, (!formData.product || services.length === 0) ? 'bg-zinc-50 cursor-not-allowed' : 'cursor-pointer')}><option value="">Select Service</option>{services.map(s => <option key={s} value={s}>{s}</option>)}</select></div>
              <div><FieldLabel>Schedule Time</FieldLabel><input type="text" name="schedule_time" value={formData.schedule_time} onChange={handleInputChange} placeholder="2022-11-01T19:39:35" className={inputClass} /></div>
              <div><FieldLabel>Cluster</FieldLabel><input type="text" disabled value={formData.cluster} className={disabledInputClass} /></div>
              <div><FieldLabel required>Change Log</FieldLabel><input type="text" name="change_log" value={formData.change_log} onChange={handleInputChange} required placeholder="EUL-1.0.0" className={inputClass} /></div>
              <div><FieldLabel>Scale Down Delay (hrs)</FieldLabel><input type="text" name="scale_down_delay" value={formData.scale_down_delay} onChange={handleInputChange} placeholder="1" className={inputClass} /></div>
            </div>
          </div>

          {/* New Service File Paths */}
          {isNewService && (
            <div className="px-6 pb-6 pt-2 border-t border-zinc-100">
              <h3 className="text-sm font-semibold text-zinc-700 mb-3">New Service YAML Paths</h3>
              <div className="grid grid-cols-1 md:grid-cols-3 gap-x-8 gap-y-4">
                <div><FieldLabel>Deploy File Path</FieldLabel><input type="text" name="deploy_file_path" value={formData.deploy_file_path} onChange={handleInputChange} placeholder="/path/to/deployment.yaml" className={inputClass} /></div>
                <div><FieldLabel>VirtualService File Path</FieldLabel><input type="text" name="vs_file_path" value={formData.vs_file_path} onChange={handleInputChange} placeholder="/path/to/virtualservice.yaml" className={inputClass} /></div>
                <div><FieldLabel>DestinationRule File Path</FieldLabel><input type="text" name="dr_file_path" value={formData.dr_file_path} onChange={handleInputChange} placeholder="/path/to/destinationrule.yaml" className={inputClass} /></div>
              </div>
            </div>
          )}
        </div>

        {/* Stages Card */}
        <div className="bg-white rounded-xl border border-zinc-200">
          <div className="px-6 py-4 border-b border-zinc-100"><h2 className="text-lg font-semibold text-zinc-900">Stages</h2></div>
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
                  {stages.map((stage, idx) => (
                    <tr key={idx} className={cn('border-b border-zinc-100', idx % 2 === 1 ? 'bg-zinc-50' : 'bg-white')}>
                      <td className="py-2 px-3 text-zinc-400 font-mono text-xs">{idx + 1}</td>
                      <td className="py-2 px-3"><input type="number" value={stage.rollout} onChange={(e) => { const s = [...stages]; s[idx].rollout = parseInt(e.target.value) || 0; setStages(s); }} className={cn(inputClass, 'w-24')} /></td>
                      <td className="py-2 px-3"><input type="number" value={stage.cooloff} onChange={(e) => { const s = [...stages]; s[idx].cooloff = parseInt(e.target.value) || 0; setStages(s); }} className={cn(inputClass, 'w-24')} /></td>
                      <td className="py-2 px-3"><input type="number" value={stage.pods} onChange={(e) => { const s = [...stages]; s[idx].pods = parseInt(e.target.value) || 0; setStages(s); }} className={cn(inputClass, 'w-24')} /></td>
                      <td className="py-2 px-3">
                        {stages.length > 1 && (
                          <button type="button" onClick={() => setStages(stages.filter((_, i) => i !== idx))} className="p-1.5 rounded-lg text-red-500 hover:bg-red-50 cursor-pointer transition-colors duration-150">
                            <Trash2 className="w-3.5 h-3.5" />
                          </button>
                        )}
                      </td>
                    </tr>
                  ))}
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
              <Toggle checked={isEnvSwitch} onChange={() => formData.service && setIsEnvSwitch(!isEnvSwitch)} disabled={!formData.service} />
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

        {/* ConfigMap Switch */}
        {!isNewService && (
          <div className="bg-white rounded-xl border border-zinc-200">
            <div className="px-6 py-4 border-b border-zinc-100 flex items-center gap-3">
              <h2 className="text-lg font-semibold text-zinc-900">Get ConfigMap</h2>
              <Toggle checked={isConfigMapSwitch} onChange={() => formData.service && setIsConfigMapSwitch(!isConfigMapSwitch)} disabled={!formData.service} />
            </div>
            {isConfigMapSwitch && (
              <div className="p-6">
                <FieldLabel>ConfigMap Data</FieldLabel>
                <div className="border border-zinc-200 rounded-lg overflow-hidden mt-1">
                  <Editor height="320px" defaultLanguage="json" theme="light" value={configMapData} onChange={(val) => setConfigMapData(val || '')}
                    options={{ minimap: { enabled: false }, fontSize: 13, lineNumbers: 'on', scrollBeyondLastLine: false, wordWrap: 'on', tabSize: 2, automaticLayout: true }} />
                </div>
              </div>
            )}
          </div>
        )}

        {/* Sync Release */}
        {syncCluster && (
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
                    <Toggle checked={isSecondaryEnvSwitch} onChange={() => formData.service && setIsSecondaryEnvSwitch(!isSecondaryEnvSwitch)} disabled={!formData.service} />
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
          <Button type="button" variant="secondary" onClick={() => navigate('/releases')}>Cancel</Button>
          <Button type="submit" loading={createMutation.isPending}>{createMutation.isPending ? 'Creating...' : 'Create Release'}</Button>
        </div>
      </form>
    </div>
  );
};

export default CreateRelease;
