import React, { useState, useEffect } from 'react';
import { useNavigate, Link, useParams, useLocation } from 'react-router-dom';
import Editor from '@monaco-editor/react';
import { useProductConfigs, useServices } from '../../hooks/useProducts';
import { useCreateRelease } from '../../hooks/useReleases';
import { fetchReleaseDetails, fetchEnvs, fetchSecondaryEnvs } from '../../services/releases';
import type { ProductConfig } from '../../api';
import { Button } from '../../components/ui/button';
import { toast } from 'sonner';

const CreateRelease: React.FC = () => {
  const navigate = useNavigate();
  const location = useLocation();
  const { id } = useParams<{ id?: string }>();
  const isClone = location.pathname.endsWith('/clone') && !!id;

  const { data: productConfigs = [] } = useProductConfigs();
  const products = [...new Set(productConfigs.map((c: ProductConfig) => c.product).filter(Boolean))];

  const [formData, setFormData] = useState({
    product: '', service: '', env: '', new_version: '', docker_image: '', change_log: '',
    status: 'CREATED', mode: 'AUTO', priority: '0', info: '', custom_pods_scale_down_days: '1',
    cronjob_suspend: false, is_art_recorder: false, description: '', schedule_time: '',
    cluster: 'EULER_UAT', scale_down_delay: '1',
  });
  const [isNewService, setIsNewService] = useState(false);
  const [error, setError] = useState('');
  const [isEnvSwitch, setIsEnvSwitch] = useState(false);
  const [envData, setEnvData] = useState('');
  const [clonedService, setClonedService] = useState('');
  const [stages, setStages] = useState([{ rollout: 100, cooloff: 1, pods: 2 }]);
  const [isReleaseSync, setIsReleaseSync] = useState(false);
  const [isSecondaryEnvSwitch, setIsSecondaryEnvSwitch] = useState(false);
  const [secondaryEnvData, setSecondaryEnvData] = useState('');
  const [secondaryEnvLoading, setSecondaryEnvLoading] = useState(false);
  const [secondaryStages, setSecondaryStages] = useState([{ rollout: 100, cooloff: 1, pods: 2 }]);
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
        if (data.rollout_strategy) {
          try {
            const parsed = typeof data.rollout_strategy === 'string' ? JSON.parse(data.rollout_strategy) : data.rollout_strategy;
            if (Array.isArray(parsed) && parsed.length > 0) setStages(parsed);
          } catch (e) { console.error('Failed to parse stages', e); }
        }
      }).catch(err => { setError('Failed to load clone details'); });
    }
  }, [isClone, id]);

  // Sync cluster
  useEffect(() => {
    if (formData.product) {
      const config = productConfigs.find((c: ProductConfig) => c.product === formData.product);
      setSyncCluster(config?.sync_cluster || '');
    } else setSyncCluster('');
  }, [formData.product, productConfigs]);

  useEffect(() => { if (!isEnvSwitch) setEnvData(''); }, [isEnvSwitch]);

  // Fetch envs
  useEffect(() => {
    if (isEnvSwitch && formData.product && formData.service && formData.env) {
      fetchEnvs(formData.product, formData.env, formData.service).then(res => setEnvData(JSON.stringify(res, null, 2))).catch(console.error);
    }
  }, [isEnvSwitch, formData.product, formData.service, formData.env]);

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

  const dateStr = new Date().toISOString().split('T')[0].replace(/-/g, '.');
  const prodAcronym = formData.product.substring(0, 3).toUpperCase() || 'PROD';
  const srvAcronym = formData.service.substring(0, 3).toUpperCase() || 'SRV';
  const generatedReleaseTag = `${prodAcronym}_${dateStr}_${formData.new_version || 'V'}_${srvAcronym}_${formData.mode}_${formData.env || 'ENV'}_${formData.priority}`;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    const selectedProductConfig = productConfigs.find((c: ProductConfig) => c.product === formData.product);
    const trackerType = selectedProductConfig?.product_type === 'SCHEDULER' ? 'Scheduler' : 'Service';

    const payload = {
      product: formData.product, service: [formData.service], env: formData.env,
      new_version: formData.new_version, docker_image: formData.docker_image,
      change_log: formData.change_log, status: formData.status, mode: formData.mode,
      priority: parseInt(formData.priority, 10) || 0, info: formData.info,
      pods_scale_down_delay: parseFloat(formData.scale_down_delay) || 1.0,
      cronjob_suspend: formData.cronjob_suspend,
      is_art_recorder: formData.is_art_recorder ? 1 : 0,
      description: formData.description, schedule_time: formData.schedule_time,
      cluster: formData.cluster, new_service: isNewService, rollout_strategy: stages,
      is_approved: formData.env === 'INTEG_CLUSTER' ? 1 : 0,
      udf2: isEnvSwitch ? envData : null, isReleaseSync,
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
    <label className="text-xs font-medium text-zinc-500 uppercase tracking-wider mb-1.5 block">
      {children} {required && <span className="text-red-500">*</span>}
    </label>
  );

  const inputClass = "w-full border border-zinc-200 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-800 focus:border-transparent";
  const disabledInputClass = "w-full border border-zinc-200 rounded-lg px-3 py-2 text-sm bg-zinc-50 text-zinc-400 cursor-not-allowed";

  return (
    <div className="flex flex-col flex-1 w-full pb-12 max-w-6xl">
      <form onSubmit={handleSubmit} className="space-y-6">
        {error && <div className="bg-red-50 border border-red-200 text-red-600 px-4 py-3 rounded-lg text-sm">{error}</div>}

        {/* Main Form Card */}
        <div className="bg-white rounded-lg border border-border">
          <div className="px-6 py-4 border-b border-border flex justify-between items-center">
            <h2 className="text-lg font-bold text-zinc-800">{isClone ? 'Clone Release' : 'Create Release'}</h2>
            <div className="flex items-center gap-3">
              <span className="text-sm text-zinc-600">New Service?</span>
              <button type="button" onClick={() => setIsNewService(!isNewService)}
                className={`relative inline-flex h-6 w-10 items-center rounded-full transition-colors ${isNewService ? 'bg-zinc-900' : 'bg-zinc-300'}`}>
                <span className={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${isNewService ? 'translate-x-5' : 'translate-x-1'}`} />
              </button>
            </div>
          </div>

          <div className="p-6 grid grid-cols-1 md:grid-cols-3 gap-x-8 gap-y-5">
            {/* Col 1 */}
            <div className="space-y-4">
              <div><FieldLabel>Release Tag</FieldLabel><input type="text" disabled value={generatedReleaseTag} className={disabledInputClass} /></div>
              <div><FieldLabel required>New Version</FieldLabel><input type="text" name="new_version" value={formData.new_version} onChange={handleInputChange} required placeholder="Jenkins tag" className={inputClass} /></div>
              <div><FieldLabel>Mode</FieldLabel><select name="mode" value={formData.mode} onChange={handleInputChange} className={inputClass}><option value="AUTO">AUTO</option><option value="MANUAL">MANUAL</option></select></div>
              <div><FieldLabel>Info</FieldLabel><input type="text" name="info" value={formData.info} onChange={handleInputChange} placeholder="Any Valid JSON" className={inputClass} /></div>
              <div><FieldLabel>Scale Down Days</FieldLabel><select name="custom_pods_scale_down_days" value={formData.custom_pods_scale_down_days} onChange={handleInputChange} className={inputClass}>{[1,2,3,4,5,6].map(d => <option key={d} value={d}>{d}</option>)}</select></div>
              <label className="flex items-center gap-2.5 cursor-pointer"><input type="checkbox" name="cronjob_suspend" checked={formData.cronjob_suspend} onChange={handleInputChange} className="rounded border-zinc-300" /><span className="text-sm text-zinc-700">Cronjob Suspend</span></label>
              <label className="flex items-center gap-2.5 cursor-pointer"><input type="checkbox" name="is_art_recorder" checked={formData.is_art_recorder} onChange={handleInputChange} className="rounded border-zinc-300" /><span className="text-sm text-zinc-700">ART Recorder</span></label>
            </div>

            {/* Col 2 */}
            <div className="space-y-4">
              <div><FieldLabel required>Product</FieldLabel><select name="product" value={formData.product} onChange={handleInputChange} required className={inputClass}><option value="">Select Product</option>{products.map(p => <option key={p} value={p}>{p}</option>)}</select></div>
              <div><FieldLabel required>Env</FieldLabel><select name="env" value={formData.env} onChange={handleInputChange} required className={inputClass}><option value="">Select Env</option><option value="UAT">UAT</option><option value="PROD">PROD</option><option value="INTEG_CLUSTER">INTEG_CLUSTER</option></select></div>
              <div><FieldLabel>Priority</FieldLabel><select name="priority" value={formData.priority} onChange={handleInputChange} className={inputClass}>{[0,1,2,3,4,5,6,7,8,9].map(d => <option key={d} value={d}>{d}</option>)}</select></div>
              <div><FieldLabel>Description</FieldLabel><input type="text" name="description" value={formData.description} onChange={handleInputChange} placeholder="Deploying webhook Hotfix" className={inputClass} /></div>
              <div><FieldLabel required>Docker Image</FieldLabel><input type="text" name="docker_image" value={formData.docker_image} onChange={handleInputChange} required placeholder="Enter Docker Image" className={inputClass} /></div>
            </div>

            {/* Col 3 */}
            <div className="space-y-4">
              <div><FieldLabel required>Service</FieldLabel><select name="service" value={formData.service} onChange={handleInputChange} required disabled={!formData.product || services.length === 0} className={cn(inputClass, (!formData.product || services.length === 0) && 'bg-zinc-50 cursor-not-allowed')}><option value="">Select Service</option>{services.map(s => <option key={s} value={s}>{s}</option>)}</select></div>
              <div><FieldLabel>Schedule Time</FieldLabel><input type="text" name="schedule_time" value={formData.schedule_time} onChange={handleInputChange} placeholder="2022-11-01T19:39:35" className={inputClass} /></div>
              <div><FieldLabel>Cluster</FieldLabel><input type="text" disabled value={formData.cluster} className={disabledInputClass} /></div>
              <div><FieldLabel required>Change Log</FieldLabel><input type="text" name="change_log" value={formData.change_log} onChange={handleInputChange} required placeholder="EUL-1.0.0" className={inputClass} /></div>
              <div><FieldLabel>Scale Down Delay (hrs)</FieldLabel><input type="text" name="scale_down_delay" value={formData.scale_down_delay} onChange={handleInputChange} placeholder="1" className={inputClass} /></div>
            </div>
          </div>
        </div>

        {/* Stages Card */}
        <div className="bg-white rounded-lg border border-border">
          <div className="px-6 py-4 border-b border-border"><h2 className="text-lg font-bold text-zinc-800">Stages</h2></div>
          <div className="p-6">
            {stages.map((stage, idx) => (
              <div key={idx} className="flex gap-4 mb-3 items-end">
                <div><FieldLabel>Rollout %</FieldLabel><input type="number" value={stage.rollout} onChange={(e) => { const s = [...stages]; s[idx].rollout = parseInt(e.target.value) || 0; setStages(s); }} className={cn(inputClass, 'w-28')} /></div>
                <div><FieldLabel>Cooloff (min)</FieldLabel><input type="number" value={stage.cooloff} onChange={(e) => { const s = [...stages]; s[idx].cooloff = parseInt(e.target.value) || 0; setStages(s); }} className={cn(inputClass, 'w-28')} /></div>
                <div><FieldLabel>Pods</FieldLabel><input type="number" value={stage.pods} onChange={(e) => { const s = [...stages]; s[idx].pods = parseInt(e.target.value) || 0; setStages(s); }} className={cn(inputClass, 'w-28')} /></div>
                {stages.length > 1 && <button type="button" onClick={() => setStages(stages.filter((_, i) => i !== idx))} className="text-red-500 hover:text-red-700 font-bold px-2 py-2 mb-0.5">x</button>}
              </div>
            ))}
            <button type="button" onClick={() => setStages([...stages, { rollout: 100, cooloff: 0, pods: 0 }])} className="text-zinc-600 border border-zinc-300 hover:bg-zinc-50 px-4 py-2 rounded-lg text-sm mt-2">+ Add Stage</button>
          </div>
        </div>

        {/* Env Switch */}
        {!isNewService && (
          <div className="bg-white rounded-lg border border-border">
            <div className="px-6 py-4 border-b border-border flex items-center gap-3">
              <h2 className="text-lg font-bold text-zinc-800">Env Switch</h2>
              <button type="button" onClick={() => formData.service && setIsEnvSwitch(!isEnvSwitch)} disabled={!formData.service}
                className={`relative inline-flex h-6 w-10 items-center rounded-full transition-colors ${!formData.service ? 'bg-zinc-200 cursor-not-allowed' : isEnvSwitch ? 'bg-zinc-900' : 'bg-zinc-300'}`}>
                <span className={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${isEnvSwitch ? 'translate-x-5' : 'translate-x-1'}`} />
              </button>
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

        {/* Sync Release */}
        {syncCluster && (
          <div className="bg-white rounded-lg border border-border">
            <div className="px-6 py-4 border-b border-border flex items-center gap-3">
              <h2 className="text-lg font-bold text-zinc-800">Sync Release to Other Cloud</h2>
              <button type="button" onClick={() => setIsReleaseSync(!isReleaseSync)}
                className={`relative inline-flex h-6 w-10 items-center rounded-full transition-colors ${isReleaseSync ? 'bg-zinc-900' : 'bg-zinc-300'}`}>
                <span className={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${isReleaseSync ? 'translate-x-5' : 'translate-x-1'}`} />
              </button>
              <span className="text-sm text-zinc-500">{isReleaseSync ? `Sync to ${syncCluster}` : 'Single cloud only'}</span>
            </div>
            {isReleaseSync && (
              <div className="p-6 space-y-6">
                <div>
                  <div className="flex items-center gap-3 mb-3">
                    <h3 className="text-base font-bold text-zinc-800">Env Switch (Secondary)</h3>
                    <button type="button" onClick={() => formData.service && setIsSecondaryEnvSwitch(!isSecondaryEnvSwitch)} disabled={!formData.service}
                      className={`relative inline-flex h-6 w-10 items-center rounded-full transition-colors ${!formData.service ? 'bg-zinc-200 cursor-not-allowed' : isSecondaryEnvSwitch ? 'bg-zinc-900' : 'bg-zinc-300'}`}>
                      <span className={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${isSecondaryEnvSwitch ? 'translate-x-5' : 'translate-x-1'}`} />
                    </button>
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
                  <h3 className="text-base font-bold text-zinc-800 mb-3">Secondary Cluster Stages</h3>
                  {secondaryStages.map((stage, idx) => (
                    <div key={idx} className="flex gap-4 mb-3 items-end">
                      <div><FieldLabel>Rollout %</FieldLabel><input type="number" value={stage.rollout} onChange={(e) => { const s = [...secondaryStages]; s[idx].rollout = parseInt(e.target.value) || 0; setSecondaryStages(s); }} className={cn(inputClass, 'w-28')} /></div>
                      <div><FieldLabel>Cooloff</FieldLabel><input type="number" value={stage.cooloff} onChange={(e) => { const s = [...secondaryStages]; s[idx].cooloff = parseInt(e.target.value) || 0; setSecondaryStages(s); }} className={cn(inputClass, 'w-28')} /></div>
                      <div><FieldLabel>Pods</FieldLabel><input type="number" value={stage.pods} onChange={(e) => { const s = [...secondaryStages]; s[idx].pods = parseInt(e.target.value) || 0; setSecondaryStages(s); }} className={cn(inputClass, 'w-28')} /></div>
                      {secondaryStages.length > 1 && <button type="button" onClick={() => setSecondaryStages(secondaryStages.filter((_, i) => i !== idx))} className="text-red-500 hover:text-red-700 font-bold px-2 py-2 mb-0.5">x</button>}
                    </div>
                  ))}
                  <button type="button" onClick={() => setSecondaryStages([...secondaryStages, { rollout: 100, cooloff: 0, pods: 0 }])} className="text-zinc-600 border border-zinc-300 hover:bg-zinc-50 px-4 py-2 rounded-lg text-sm mt-2">+ Add Stage</button>
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

import { cn } from '../../lib/utils';

export default CreateRelease;
