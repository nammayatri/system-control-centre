import React, { useState, useEffect } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import Editor from '@monaco-editor/react';
import { useQuery } from '@tanstack/react-query';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { apiClient } from '../../services/api';
import { fetchProducts, fetchProductConfigs } from '../../services/releases';
import { Button } from '../../components/ui/button';
import { toast } from 'sonner';
import type { ProductConfig } from '../../api';

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
  } catch {}
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

const CreateConfigMap: React.FC = () => {
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const cloneId = searchParams.get('clone_id') || '';

  const { data: products = [] } = useQuery({ queryKey: ['products'], queryFn: fetchProducts, staleTime: 300000 });
  const { data: productConfigs = [] } = useQuery({ queryKey: ['product-configs'], queryFn: fetchProductConfigs, staleTime: 300000 });

  const [namesOptions, setNamesOptions] = useState<string[]>([]);
  const [fileContent, setFileContent] = useState('');
  const [secondaryContent, setSecondaryContent] = useState('');
  const [secondaryLoading, setSecondaryLoading] = useState(false);
  const [syncCluster, setSyncCluster] = useState('');
  const [error, setError] = useState('');

  const [form, setForm] = useState({
    product: '', name: '', description: '', change_log: '', priority: '0', env: 'UAT', schedule_time: '', cluster: 'BECKN_UAT', file: '', mode: 'AUTO',
  });

  const createMut = useMutation({
    mutationFn: async (payload: any) => {
      const { data } = await apiClient.post('/tracker/configmap', payload);
      return data;
    },
    onSuccess: () => { toast.success('ConfigMap created'); navigate('/configmap'); },
    onError: (err: any) => { setError(err.message || 'Failed to create ConfigMap'); },
  });

  useEffect(() => {
    if (form.product && productConfigs.length > 0) {
      const config = productConfigs.find((c: ProductConfig) => c.product === form.product);
      setSyncCluster(config?.sync_cluster || '');
    }
  }, [form.product, productConfigs]);

  useEffect(() => {
    if (form.product && form.name && syncCluster) {
      setSecondaryLoading(true);
      apiClient.get('/configmap/secondary', { params: { PRODUCT: form.product, NAME: form.name } })
        .then(res => { const cm = res.data?.configMap || ''; setSecondaryContent(jsonConfigToYaml(typeof cm === 'string' ? cm : JSON.stringify(cm, null, 2))); })
        .catch(() => setSecondaryContent('')).finally(() => setSecondaryLoading(false));
    }
  }, [form.product, form.name, syncCluster]);

  useEffect(() => {
    if (!form.product) return;
    apiClient.get('/configmap', { params: { PRODUCT: form.product } })
      .then(r => setNamesOptions(Array.isArray(r.data.configMap) ? r.data.configMap : []))
      .catch(() => setNamesOptions([]));
  }, [form.product]);

  useEffect(() => {
    if (!form.product || !form.name) return;
    apiClient.get('/configmap', { params: { PRODUCT: form.product, NAME: form.name } })
      .then(r => { const raw = typeof r.data.configMap === 'string' ? r.data.configMap : ''; setFileContent(jsonConfigToYaml(raw)); })
      .catch(() => setFileContent(''));
  }, [form.product, form.name]);

  useEffect(() => {
    if (!cloneId) return;
    apiClient.get(`/tracker/configmap/${cloneId}`).then(r => {
      const d = r.data;
      setForm({ product: d.product || '', name: d.name || '', description: d.description || '', change_log: d.change_log || '', priority: String(d.priority || '0'), env: d.env || 'UAT', schedule_time: '', cluster: d.cluster || 'BECKN_UAT', file: d.file || '', mode: d.mode || 'AUTO' });
      setFileContent(jsonConfigToYaml(d.file || ''));
    }).catch(console.error);
  }, [cloneId]);

  const handleChange = (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>) => {
    setForm(f => ({ ...f, [e.target.name]: e.target.value }));
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    const payload = {
      ...form, priority: Number(form.priority),
      file: yamlConfigToJson(fileContent || form.file),
      secondary_file: syncCluster ? yamlConfigToJson(secondaryContent) : undefined,
      isSync: !!syncCluster,
    };
    createMut.mutate(payload);
  };

  const inputClass = "w-full border border-zinc-200 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-800 focus:border-transparent";
  const FieldLabel = ({ children, required }: { children: React.ReactNode; required?: boolean }) => (
    <label className="text-xs font-medium text-zinc-500 uppercase tracking-wider mb-1.5 block">{children} {required && <span className="text-red-500">*</span>}</label>
  );

  return (
    <div className="flex flex-col w-full pb-12 max-w-6xl">
      <form onSubmit={handleSubmit} className="space-y-6">
        {error && <div className="bg-red-50 border border-red-200 text-red-600 px-4 py-3 rounded-lg text-sm">{error}</div>}

        <div className="bg-white rounded-lg border border-border">
          <div className="px-6 py-4 border-b border-border"><h2 className="text-lg font-bold text-zinc-800">Create ConfigMap</h2></div>
          <div className="p-6 grid grid-cols-1 md:grid-cols-3 gap-x-8 gap-y-5">
            <div className="space-y-4">
              <div><FieldLabel required>Product</FieldLabel><select name="product" value={form.product} onChange={handleChange} required className={inputClass}><option value="">Select Product</option>{products.map(p => <option key={p} value={p}>{p}</option>)}</select></div>
              <div><FieldLabel>Description</FieldLabel><input name="description" value={form.description} onChange={handleChange} placeholder="Deploying Hotfix" className={inputClass} /></div>
              <div><FieldLabel>Priority</FieldLabel><select name="priority" value={form.priority} onChange={handleChange} className={inputClass}>{[0,1,2,3,4,5,6,7,8,9].map(n => <option key={n} value={n}>{n}</option>)}</select></div>
            </div>
            <div className="space-y-4">
              <div><FieldLabel required>Name</FieldLabel><select name="name" value={form.name} onChange={handleChange} required disabled={!form.product || namesOptions.length === 0} className={`${inputClass} disabled:bg-zinc-50 disabled:cursor-not-allowed`}><option value="">Select Name</option>{namesOptions.map(n => <option key={n} value={n}>{n}</option>)}</select></div>
              <div><FieldLabel required>Change Log</FieldLabel><input name="change_log" value={form.change_log} onChange={handleChange} required placeholder="EUL-1.0.0" className={inputClass} /></div>
              <div><FieldLabel required>Env</FieldLabel><select name="env" value={form.env} onChange={handleChange} required className={inputClass}><option value="UAT">UAT</option><option value="PROD">PROD</option><option value="INTEG_CLUSTER">INTEG_CLUSTER</option></select></div>
            </div>
            <div className="space-y-4">
              <div><FieldLabel>Schedule Time</FieldLabel><input name="schedule_time" value={form.schedule_time} onChange={handleChange} placeholder="2022-11-01T19:39:35" className={inputClass} /></div>
              <div><FieldLabel required>Cluster</FieldLabel><input name="cluster" value={form.cluster} disabled className={`${inputClass} bg-zinc-50 text-zinc-400 cursor-not-allowed`} /></div>
            </div>
          </div>

          {/* Editors */}
          {(!!fileContent || syncCluster) && (
            <div className="px-6 pb-6">
              {syncCluster ? (
                <div className="grid grid-cols-2 gap-4">
                  <div>
                    <div className="text-sm font-semibold text-zinc-700 mb-2">Primary ConfigMap</div>
                    <div className="border border-zinc-200 rounded-lg overflow-hidden">
                      <Editor height="55vh" defaultLanguage="yaml" theme="light" value={fileContent} onChange={(val) => setFileContent(val || '')}
                        options={{ minimap: { enabled: true }, fontSize: 13, lineNumbers: 'on', scrollBeyondLastLine: false, wordWrap: 'on', tabSize: 2, automaticLayout: true }} />
                    </div>
                  </div>
                  <div>
                    <div className="text-sm font-semibold text-zinc-700 mb-2">Secondary ConfigMap {secondaryLoading && <span className="text-zinc-400 font-normal ml-2">Loading...</span>}</div>
                    <div className="border border-zinc-200 rounded-lg overflow-hidden">
                      <Editor height="55vh" defaultLanguage="yaml" theme="light" value={secondaryContent} onChange={(val) => setSecondaryContent(val || '')}
                        options={{ minimap: { enabled: true }, fontSize: 13, lineNumbers: 'on', scrollBeyondLastLine: false, wordWrap: 'on', tabSize: 2, automaticLayout: true }} />
                    </div>
                  </div>
                </div>
              ) : (
                <>
                  <div className="text-sm font-semibold text-zinc-700 mb-2">Config File Content</div>
                  <div className="border border-zinc-200 rounded-lg overflow-hidden">
                    <Editor height="55vh" defaultLanguage="yaml" theme="light" value={fileContent} onChange={(val) => setFileContent(val || '')}
                      options={{ minimap: { enabled: true }, fontSize: 13, lineNumbers: 'on', scrollBeyondLastLine: false, wordWrap: 'on', tabSize: 2, automaticLayout: true }} />
                  </div>
                </>
              )}
            </div>
          )}
        </div>

        <div className="flex gap-3 pt-2">
          <Button type="submit" loading={createMut.isPending}>{createMut.isPending ? 'Saving...' : 'Create ConfigMap'}</Button>
          <Button type="button" variant="secondary" onClick={() => navigate('/configmap')}>Cancel</Button>
        </div>
      </form>
    </div>
  );
};

export default CreateConfigMap;
