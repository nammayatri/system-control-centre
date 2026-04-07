import React, { useState, useEffect } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import Editor from '@monaco-editor/react';
import { useQuery, useMutation } from '@tanstack/react-query';
import { apiClient } from '../../../lib/api-client';
import { fetchConfigMapNames, fetchConfigMapData, fetchSecondaryConfigMap } from '../api';
import { fetchProducts, fetchProductConfigs } from '../../releases/api';
import { Button } from '../../../shared/ui/button';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { toast } from 'sonner';
import { cn } from '../../../lib/utils';
import ReactDiffViewer from 'react-diff-viewer-continued';
import { DEFAULT_ENV, AVAILABLE_ENVS } from '../../../lib/constants';
import type { ProductConfig } from '../../releases/api';

function jsonConfigToYaml(raw: string): string {
  try {
    const parsed = JSON.parse(raw);
    if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) {
      return Object.entries(parsed)
        .map(([key, value]) => {
          if (typeof value === 'string') {
            const indented = value.split('\n').map(line => '  ' + line).join('\n');
            return `${key}: |\n${indented}`;
          }
          return `${key}: ${JSON.stringify(value, null, 2)}`;
        })
        .join('\n\n');
    }
  } catch { /* not JSON */ }
  return raw;
}

function yamlConfigToJson(yaml: string): string {
  const entries: Record<string, string> = {};
  const blocks = yaml.split(/^(\S[^:\n]*): \|$/m);
  for (let i = 1; i < blocks.length; i += 2) {
    const key = blocks[i].trim();
    const content = (blocks[i + 1] || '').split('\n').map(line => line.startsWith('  ') ? line.slice(2) : line).join('\n').replace(/^\n/, '').replace(/\n$/, '');
    if (key) entries[key] = content;
  }
  if (Object.keys(entries).length > 0) return JSON.stringify(entries);
  return yaml;
}

interface CreateConfigMapProps {
  isUpdate?: boolean;
  id?: string;
}

const CreateConfigMap: React.FC<CreateConfigMapProps> = ({ isUpdate = false, id = '' }) => {
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const cloneId = searchParams.get('clone_id') || '';

  const { data: products = [] } = useQuery({ queryKey: ['products'], queryFn: fetchProducts, staleTime: 300000 });
  const { data: productConfigs = [] } = useQuery({ queryKey: ['product-configs'], queryFn: fetchProductConfigs, staleTime: 300000 });

  const [namesOptions, setNamesOptions] = useState<string[]>([]);
  const [fileContent, setFileContent] = useState('');
  const [secondaryContent, setSecondaryContent] = useState('');
  const [secondaryLoading, setSecondaryLoading] = useState(false);
  const [showDiff, setShowDiff] = useState(false);
  const [syncCluster, setSyncCluster] = useState('');
  const [error, setError] = useState('');

  const [form, setForm] = useState({
    appGroup: '', name: '', description: '', change_log: '', priority: '0', env: DEFAULT_ENV, schedule_time: '', cluster: 'BECKN_UAT', file: '', mode: 'AUTO',
  });

  const createMut = useMutation({
    mutationFn: async (payload: Record<string, unknown>) => {
      const url = `/tracker/configmap${isUpdate ? `/${id}` : ''}`;
      const { data } = isUpdate
        ? await apiClient.put(url, payload)
        : await apiClient.post(url, payload);
      return data;
    },
    onSuccess: () => {
      toast.success(isUpdate ? 'ConfigMap updated' : 'ConfigMap created');
      navigate('/configmap');
    },
    onError: (err: any) => {
      const msg = err?.response?.data?.message || err.message || `Failed to ${isUpdate ? 'update' : 'create'} ConfigMap`;
      setError(msg);
      toast.error(msg);
    },
  });

  // Derive sync_cluster from product config
  useEffect(() => {
    if (form.appGroup && productConfigs.length > 0) {
      const config = productConfigs.find((c: ProductConfig) => c.appGroup === form.appGroup);
      setSyncCluster(config?.sync_cluster || '');
    }
  }, [form.appGroup, productConfigs]);

  // Fetch secondary configmap when name is selected and sync_cluster exists
  useEffect(() => {
    if (form.appGroup && form.name && syncCluster) {
      setSecondaryLoading(true);
      fetchSecondaryConfigMap(form.appGroup, form.name)
        .then(cm => {
          const raw = typeof cm === 'string' ? cm : JSON.stringify(cm, null, 2);
          setSecondaryContent(jsonConfigToYaml(raw));
        })
        .catch((err: any) => {
          toast.error('Failed to load secondary cluster config — check sync_cluster setting');
          console.error('[CreateConfigMap] secondary fetch failed:', err);
          setSecondaryContent('');
        })
        .finally(() => setSecondaryLoading(false));
    }
  }, [form.appGroup, form.name, syncCluster]);

  // Load configmap names when product changes
  useEffect(() => {
    if (!form.appGroup) return;
    fetchConfigMapNames(form.appGroup)
      .then(names => setNamesOptions(Array.isArray(names) ? names : []))
      .catch((err: any) => {
        toast.error('Failed to load config map names');
        console.error('[CreateConfigMap] fetchConfigMapNames failed:', err);
        setNamesOptions([]);
      });
  }, [form.appGroup]);

  // Load file content when name is selected
  useEffect(() => {
    if (!form.appGroup || !form.name) return;
    fetchConfigMapData(form.appGroup, form.name)
      .then(raw => {
        const content = typeof raw === 'string' ? raw : '';
        setFileContent(jsonConfigToYaml(content));
      })
      .catch((err: any) => {
        toast.error('Failed to load file content');
        console.error('[CreateConfigMap] fetchConfigMapData failed:', err);
        setFileContent('');
      });
  }, [form.appGroup, form.name]);

  // For update/clone: pre-populate form
  useEffect(() => {
    const fetchId = id || cloneId;
    if (!fetchId) return;
    apiClient.get(`/tracker/configmap/${fetchId}`).then(r => {
      const d = r.data;
      setForm({
        appGroup: d.appGroup || '',
        name: d.name || '',
        description: d.description || '',
        change_log: d.change_log || '',
        priority: String(d.priority || '0'),
        env: d.env || 'UAT',
        schedule_time: isUpdate ? (d.schedule_time || '') : '',
        cluster: d.cluster || 'BECKN_UAT',
        file: d.file || '',
        mode: d.mode || 'AUTO',
      });
      setFileContent(jsonConfigToYaml(d.file || ''));
    }).catch((err: any) => {
      const msg = err?.response?.data?.message || err.message || 'Failed to load ConfigMap';
      toast.error(msg);
      navigate('/configmap');
    });
  }, [id, cloneId, isUpdate]);

  const handleChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>) => {
    setForm(f => ({ ...f, [e.target.name]: e.target.value }));
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    const payload = {
      ...form,
      priority: Number(form.priority),
      file: yamlConfigToJson(fileContent || form.file),
      secondary_file: syncCluster ? yamlConfigToJson(secondaryContent) : undefined,
      isSync: !!syncCluster,
    };
    createMut.mutate(payload);
  };

  const inputClass = "w-full h-10 sm:h-9 border border-zinc-300 rounded-lg px-3 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150";
  const FieldLabel = ({ children, required }: { children: React.ReactNode; required?: boolean }) => (
    <label className="text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5 block">{children} {required && <span className="text-red-500">*</span>}</label>
  );

  return (
    <div className="flex flex-col w-full pb-12">
      <form onSubmit={handleSubmit} className="space-y-4 sm:space-y-6">
        {error && <div className="bg-red-50 border border-red-200 text-red-700 px-4 py-3 rounded-xl text-sm">{error}</div>}

        <div className="bg-white rounded-xl border border-zinc-200">
          <div className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100">
            <h2 className="text-base sm:text-lg font-semibold text-zinc-900">{isUpdate ? 'Update ConfigMap' : cloneId ? 'Clone ConfigMap' : 'Create ConfigMap'}</h2>
          </div>
          <div className="p-4 sm:p-6 grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-x-6 lg:gap-x-8 gap-y-4 sm:gap-y-5">
            {/* LEFT column */}
            <div className="space-y-4">
              <div><FieldLabel required>App Group</FieldLabel><select name="appGroup" value={form.appGroup} onChange={handleChange} required className={cn(inputClass, 'cursor-pointer')}><option value="">Select App Group</option>{products.map(p => <option key={p} value={p}>{p}</option>)}</select></div>
              <div><FieldLabel>Description</FieldLabel><input name="description" value={form.description} onChange={handleChange} placeholder="Deploying Hotfix" className={inputClass} /></div>
              <div><FieldLabel>Priority</FieldLabel><select name="priority" value={form.priority} onChange={handleChange} className={cn(inputClass, 'cursor-pointer')}>{[0,1,2,3,4,5,6,7,8,9].map(n => <option key={n} value={n}>{n}</option>)}</select></div>
            </div>
            {/* CENTER column */}
            <div className="space-y-4">
              <div><FieldLabel required>Name</FieldLabel><select name="name" value={form.name} onChange={handleChange} required disabled={!form.appGroup || namesOptions.length === 0} className={cn(inputClass, (!form.appGroup || namesOptions.length === 0) ? 'bg-zinc-50 cursor-not-allowed' : 'cursor-pointer')}><option value="">Select Name</option>{namesOptions.map(n => <option key={n} value={n}>{n}</option>)}</select></div>
              <div><FieldLabel required>Change Log</FieldLabel><input name="change_log" value={form.change_log} onChange={handleChange} required placeholder="EUL-1.0.0" className={inputClass} /></div>
              <div><FieldLabel required>Env</FieldLabel><select name="env" value={form.env} onChange={handleChange} required className={cn(inputClass, 'cursor-pointer')}>{AVAILABLE_ENVS.map(e => <option key={e} value={e}>{e}</option>)}</select></div>
            </div>
            {/* RIGHT column */}
            <div className="space-y-4">
              <div><FieldLabel>Schedule Time</FieldLabel><input name="schedule_time" value={form.schedule_time} onChange={handleChange} placeholder="2022-11-01T19:39:35" className={inputClass} /></div>
              <div><FieldLabel required>Cluster</FieldLabel><input name="cluster" value={form.cluster} disabled className={cn(inputClass, 'bg-zinc-50 text-zinc-400 cursor-not-allowed')} /></div>
            </div>
          </div>

          {/* Editors */}
          {(!!fileContent || syncCluster) && (
            <div className="px-4 pb-4 sm:px-6 sm:pb-6">
              {syncCluster ? (
                <>
                  <div className="flex items-center gap-3 mb-3">
                    <label className="flex items-center gap-2 text-sm text-zinc-600 cursor-pointer">
                      <input type="checkbox" checked={showDiff} onChange={() => setShowDiff(!showDiff)} className="rounded border-zinc-300 accent-zinc-900 w-4 h-4" />
                      Compare with Secondary (Diff View)
                    </label>
                  </div>
                  {showDiff && fileContent && secondaryContent ? (
                    <div className="border border-zinc-200 rounded-lg overflow-hidden overflow-x-auto text-xs sm:text-sm">
                      <ReactDiffViewer
                        oldValue={fileContent}
                        newValue={secondaryContent}
                        splitView={true}
                        leftTitle="Primary"
                        rightTitle="Secondary"
                        useDarkTheme={false}
                      />
                    </div>
                  ) : (
                    <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
                      <div>
                        <div className="text-sm font-semibold text-zinc-700 mb-2">Primary ConfigMap</div>
                        <div className="border border-zinc-200 rounded-lg overflow-hidden">
                          <Editor height="55vh" defaultLanguage="yaml" theme="light" value={fileContent} onChange={(val) => setFileContent(val || '')}
                            options={{ minimap: { enabled: false }, fontSize: 13, lineNumbers: 'on', scrollBeyondLastLine: false, wordWrap: 'on', tabSize: 2, automaticLayout: true }} />
                        </div>
                      </div>
                      <div>
                        <div className="text-sm font-semibold text-zinc-700 mb-2">Secondary ConfigMap {secondaryLoading && <span className="text-zinc-400 font-normal ml-2">Loading...</span>}</div>
                        <div className="border border-zinc-200 rounded-lg overflow-hidden">
                          <Editor height="55vh" defaultLanguage="yaml" theme="light" value={secondaryContent} onChange={(val) => setSecondaryContent(val || '')}
                            options={{ minimap: { enabled: false }, fontSize: 13, lineNumbers: 'on', scrollBeyondLastLine: false, wordWrap: 'on', tabSize: 2, automaticLayout: true }} />
                        </div>
                      </div>
                    </div>
                  )}
                </>
              ) : (
                <>
                  <div className="text-sm font-semibold text-zinc-700 mb-2">Config File Content</div>
                  <div className="border border-zinc-200 rounded-lg overflow-hidden">
                    <Editor height="55vh" defaultLanguage="yaml" theme="light" value={fileContent} onChange={(val) => setFileContent(val || '')}
                      options={{ minimap: { enabled: false }, fontSize: 13, lineNumbers: 'on', scrollBeyondLastLine: false, wordWrap: 'on', tabSize: 2, automaticLayout: true }} />
                  </div>
                </>
              )}
            </div>
          )}
        </div>

        <div className="flex flex-col-reverse sm:flex-row sm:justify-end gap-2 sm:gap-3 pt-2">
          <Button type="button" variant="secondary" onClick={() => navigate('/configmap')}>Cancel</Button>
          <PermissionGate product="autopilot" permission="CONFIG_CREATE">
            <Button type="submit" loading={createMut.isPending}>{createMut.isPending ? 'Saving...' : isUpdate ? 'Update' : 'Create ConfigMap'}</Button>
          </PermissionGate>
        </div>
      </form>
    </div>
  );
};

export default CreateConfigMap;
