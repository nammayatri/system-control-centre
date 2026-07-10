import React, { useState, useEffect, useMemo, useRef } from 'react';
import { useNavigate, useParams, useLocation } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import Editor from '@monaco-editor/react';
import { useProductConfigs, useServices } from '../useProducts';
import { useCreateRelease, useUpdateTracker } from '../hooks';
import { fetchReleaseDetails, fetchEnvs, fetchSecondaryEnvs, fetchReleaseConfigs, fetchResources, resolveOldVersion } from '../api';
import type { ProductConfig } from '../api';
import { Button } from '../../../shared/ui/button';
import { cn } from '../../../lib/utils';
import { normalizeProductType } from '../../../lib/constants';
import { useAuth } from '../../../core/auth/AuthContext';
import { Trash2, Lock, ChevronDown, Check, Info } from 'lucide-react';
import { toast } from 'sonner';

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

// Normalise whatever an admin typed into the product config's repo field into a
// bare "owner/repo" slug. Tolerates a full GitHub URL and a trailing ".git" so
// the compare link below is always well-formed.
const normalizeRepo = (raw?: string): string =>
  (raw || '')
    .trim()
    .replace(/^https?:\/\/github\.com\//i, '')
    .replace(/\.git$/i, '')
    .replace(/^\/+|\/+$/g, '');

// Release versions look like "a1b2c3-v2": a 6-char commit SHA prefix, sometimes
// followed by a suffix (-v1/-v2) that is NOT part of any git ref. GitHub's compare
// view needs the bare commit, so take the first 6 chars and confirm they're a
// short SHA (hex) before using them; otherwise treat the ref as unavailable.
const COMMIT_ID_RE = /^[0-9a-f]{6}$/i;
const toCommitId = (version: string): string => {
  const id = (version || '').trim().slice(0, 6);
  return COMMIT_ID_RE.test(id) ? id : '';
};

// Build a GitHub link that shows what shipped in this release. Prefer a
// compare view (old...new) so reviewers see the exact diff; fall back to the
// new ref's commit history when there's no old version to diff against.
// Each version is reduced to its commit-ID prefix (see toCommitId) so suffixes
// like "-v1" don't produce a broken ref. Returns '' when we lack a repo or a
// valid new commit — caller then leaves the changelog untouched.
const buildDiffLink = (repo: string, oldV: string, newV: string): string => {
  const r = normalizeRepo(repo);
  const o = toCommitId(oldV);
  const n = toCommitId(newV);
  if (!r || !n) return '';
  return o
    ? `https://github.com/${r}/compare/${o}...${n}`
    : `https://github.com/${r}/commits/${n}`;
};

const CreateRelease: React.FC = () => {
  const navigate = useNavigate();
  const location = useLocation();
  const { id } = useParams<{ id?: string }>();
  const isClone = location.pathname.endsWith('/clone') && !!id;
  const { env: deploymentEnv, user, products: productAccess, deploymentAccess } = useAuth();
  const isUpdate = !!id && location.pathname.endsWith('/edit');

  const { data: productConfigs = [] } = useProductConfigs();
  // Access is granted per app group; only autopilot Admins and superadmins see every group.
  const canSeeAllAppGroups =
    !!user?.isSuperadmin ||
    productAccess.some(p => p.slug === 'autopilot' && ['admin', 'superadmin'].includes(p.role?.toLowerCase()));
  const accessibleAppGroups = new Set(
    deploymentAccess.filter(d => d.productSlug === 'autopilot').map(d => d.appGroup)
  );
  const products = [...new Set(productConfigs.map((c: ProductConfig) => c.appGroup).filter(Boolean))]
    .filter(g => canSeeAllAppGroups || accessibleAppGroups.has(g))
    .sort((a, b) => a.localeCompare(b));

  const [formData, setFormData] = useState({
    appGroup: '', service: '', env: deploymentEnv, old_version: '', new_version: '', docker_image: '', change_log: '',
    status: 'CREATED', mode: 'AUTO', priority: '0', info: '',
    cluster: 'MOVING_TECH',
    cronjob_suspend: false, description: '', schedule_time: '',
  });
  const isNewService = false;

  // GitHub repo ("owner/repo") configured for the selected app group, if any.
  // Prefer a config row that actually carries a repo (service-level rows don't).
  const selectedRepo = useMemo(
    () => productConfigs.find((c: ProductConfig) => c.appGroup === formData.appGroup && c.repo_name)?.repo_name || '',
    [productConfigs, formData.appGroup],
  );
  // Tracks the last changelog value we auto-filled, so we only overwrite the
  // field while it still holds our generated link — never a changelog the user
  // has typed themselves.
  const autoChangelogRef = useRef('');
  // Tracks the last old_version we auto-filled from k8s, so switching services
  // updates the field but a value the user typed themselves is never clobbered.
  const autoOldVersionRef = useRef('');

  // Prefill the changelog with a GitHub diff link whenever the app group's repo
  // and the versions are known, so reviewers get a click-through to the diff and
  // nobody has to hand-write a throwaway changelog. Only on create (never touch
  // an existing release's changelog), and only while the field is empty or still
  // holds our previously generated link.
  useEffect(() => {
    if (isUpdate) return;
    const link = buildDiffLink(selectedRepo, formData.old_version, formData.new_version);
    if (!link) return;
    setFormData(prev => {
      if (prev.change_log === '' || prev.change_log === autoChangelogRef.current) {
        autoChangelogRef.current = link;
        return { ...prev, change_log: link };
      }
      return prev;
    });
  }, [isUpdate, selectedRepo, formData.old_version, formData.new_version]);

  // Once the old version has resolved and the app group has a repo, the changelog
  // becomes a read-only GitHub compare link (see changelogLocked below). Unlike the
  // prefill above, this forces the field to the link even over a value the user
  // typed earlier — because the field is then non-editable, so what's shown must
  // equal what's submitted.
  useEffect(() => {
    if (isUpdate) return;
    const link = buildDiffLink(selectedRepo, formData.old_version, formData.new_version);
    const locked = !!selectedRepo && !!formData.old_version.trim() && !!link;
    if (!locked) return;
    setFormData(prev => {
      if (prev.change_log === link) return prev;
      autoChangelogRef.current = link;
      return { ...prev, change_log: link };
    });
  }, [isUpdate, selectedRepo, formData.old_version, formData.new_version]);
  const [error, setError] = useState('');
  const [isEnvSwitch, setIsEnvSwitch] = useState(false);
  const [envData, setEnvData] = useState('');
  const [isResourcesSwitch, setIsResourcesSwitch] = useState(false);
  const [resourcesData, setResourcesData] = useState('');
  const [selectedServices, setSelectedServices] = useState<string[]>([]);
  const [showServiceDropdown, setShowServiceDropdown] = useState(false);
  const [showAppGroupDropdown, setShowAppGroupDropdown] = useState(false);
  const [showPriorityDropdown, setShowPriorityDropdown] = useState(false);
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

  // Sync first selected service into formData.service for dependent effects (envs, resources, rollout).
  // Env/resources switches only work with a single service.
  useEffect(() => {
    setFormData(prev => ({ ...prev, service: selectedServices[0] || '' }));
    if (selectedServices.length !== 1) {
      setIsEnvSwitch(false);
      setIsResourcesSwitch(false);
    }
  }, [selectedServices]);

  // Pre-fill Old Version with the currently-deployed version resolved from k8s
  // when exactly one service is selected on a create — so the changelog diff
  // link (buildDiffLink) becomes a proper compare/<old>...<new>. Only fills while
  // the field is empty or still holds our last auto value (never a manual entry).
  // With multiple services selected, a single old_version can't represent them
  // all, so we clear our auto value and let the backend resolve per-service on submit.
  useEffect(() => {
    if (isUpdate) return;
    if (selectedServices.length !== 1) {
      setFormData(prev => (prev.old_version === autoOldVersionRef.current ? { ...prev, old_version: '' } : prev));
      return;
    }
    const svc = selectedServices[0];
    if (!formData.appGroup || !svc) return;
    resolveOldVersion(formData.appGroup, svc).then(ver => {
      if (!ver) return;
      setFormData(prev => {
        if (prev.old_version === '' || prev.old_version === autoOldVersionRef.current) {
          autoOldVersionRef.current = ver;
          return { ...prev, old_version: ver };
        }
        return prev;
      });
    }).catch(() => {});
  }, [isUpdate, formData.appGroup, selectedServices]);

  useEffect(() => {
    const handleClickOutside = (e: MouseEvent) => {
      if (showServiceDropdown && !(e.target as HTMLElement).closest('.service-dropdown')) {
        setShowServiceDropdown(false);
      }
      if (showAppGroupDropdown && !(e.target as HTMLElement).closest('.app-group-dropdown')) {
        setShowAppGroupDropdown(false);
      }
      if (showPriorityDropdown && !(e.target as HTMLElement).closest('.priority-dropdown')) {
        setShowPriorityDropdown(false);
      }
    };
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [showServiceDropdown, showAppGroupDropdown, showPriorityDropdown]);

  // Disable polling on edit: useRelease's 10s poll would overwrite typed form fields otherwise.
  const { data: existingRelease } = useQuery({
    queryKey: ['release', id],
    queryFn: () => fetchReleaseDetails(id!),
    enabled: isUpdate && !!id,
    refetchInterval: false,
    refetchOnWindowFocus: false,
    staleTime: Infinity,
  });
  // Pre-fill once per release id — re-running on refetch would clobber keystrokes.
  const [prefilledOnce, setPrefilledOnce] = useState(false);

  useEffect(() => {
    if (existingRelease && isUpdate && !prefilledOnce) {
      setPrefilledOnce(true);
      setFormData({
        appGroup: existingRelease.appGroup || '',
        service: existingRelease.service || '',
        env: existingRelease.env || deploymentEnv,
        old_version: existingRelease.old_version || '',
        new_version: existingRelease.new_version || '',
        docker_image: existingRelease.docker_image || existingRelease.release_context?.docker_image || '',
        change_log: existingRelease.change_log || '',
        status: existingRelease.status || 'CREATED',
        mode: existingRelease.mode || 'AUTO',
        priority: String(existingRelease.priority ?? 0),
        info: existingRelease.info || '',
        cluster: existingRelease.release_context?.cluster || 'MOVING_TECH',
        cronjob_suspend: existingRelease.cronjob_suspend || false,
        description: existingRelease.description || '',
        schedule_time: existingRelease.schedule_time || '',
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
      }).catch((err: any) => {
        const msg = err?.response?.data?.message || err.message || 'Failed to load clone details';
        setError(msg);
        toast.error(msg);
      });
    }
  }, [isClone, id]);

  useEffect(() => {
    if (formData.appGroup) {
      const config = productConfigs.find((c: ProductConfig) => c.appGroup === formData.appGroup);
      setSyncCluster(config?.sync_cluster || '');
    } else setSyncCluster('');
  }, [formData.appGroup, productConfigs]);

  // Load rollout stages from service config on service select (skip clone/update — those use existing stages).
  useEffect(() => {
    if (!isClone && !isUpdate && formData.appGroup && formData.service) {
      fetchReleaseConfigs(formData.appGroup).then(configs => {
        const svcConfig = configs.find(c => c.service === formData.service);
        if (svcConfig?.rollout_strategy) {
          try {
            // DB stores double-escaped JSON — parse until we get an array.
            let parsed: any = svcConfig.rollout_strategy;
            for (let i = 0; i < 3 && typeof parsed === 'string'; i++) {
              parsed = JSON.parse(parsed);
            }
            // Accept both [{cluster, rollouts: [...]}] and plain array shapes.
            if (Array.isArray(parsed) && parsed.length > 0) {
              const rollouts = parsed[0]?.rollouts || parsed;
              if (Array.isArray(rollouts) && rollouts.length > 0) {
                setStages(rollouts.map((r: any) => ({
                  rollout: r.rollout ?? r.rolloutPercent ?? 0,
                  cooloff: r.cooloff ?? r.cooloffMinutes ?? 10,
                  pods: r.pods ?? r.podCount ?? r.podPercent ?? 1,
                })));
              }
            }
          } catch (e) {
            // Surface parse errors — silent fallback to defaults hides misconfigured service configs.
            console.error('[CreateRelease] failed to parse service rollout_strategy:', e);
            toast.error('Could not load saved rollout stages for this service — using defaults');
          }
        }
      }).catch((e: any) => {
        console.error('[CreateRelease] fetchReleaseConfigs failed:', e);
        toast.error('Could not load rollout config for this service — using defaults');
      });
    }
  }, [formData.appGroup, formData.service, isClone, isUpdate]);

  useEffect(() => { if (!isEnvSwitch) setEnvData(''); }, [isEnvSwitch]);
  useEffect(() => { if (!isResourcesSwitch) setResourcesData(''); }, [isResourcesSwitch]);

  useEffect(() => {
    if (isEnvSwitch && formData.appGroup && formData.service && formData.env) {
      fetchEnvs(formData.appGroup, formData.env, formData.service)
        .then(res => setEnvData(JSON.stringify(res, null, 2)))
        .catch((e: any) => {
          console.error(e);
          toast.error('Failed to load env data');
          setIsEnvSwitch(false);
        });
    }
  }, [isEnvSwitch, formData.appGroup, formData.service, formData.env]);

  useEffect(() => {
    if (isResourcesSwitch && formData.appGroup && formData.service) {
      fetchResources(formData.appGroup, formData.service)
        .then(res => setResourcesData(JSON.stringify(res, null, 2)))
        .catch(() => setResourcesData(''));
    }
  }, [isResourcesSwitch, formData.appGroup, formData.service]);


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
    const parts = [acronym, dateStr, versionTag, svcTag, mode, env, pri].filter(Boolean);
    return parts.join('_');
  };
  const generatedReleaseTag = generateReleaseTag();

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

    if (/^[0-9a-fA-F]{6,40}$/.test(formData.change_log.trim())) {
      toast.error('Change log cannot be a git commit ID. Please provide a descriptive changelog.');
      return;
    }
    if (formData.change_log.trim() && formData.new_version.trim() && formData.change_log.trim() === formData.new_version.trim()) {
      toast.error('Change log cannot be the same as the version. Please provide a descriptive changelog.');
      return;
    }

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
      // Backend allows only these fields mid-flight: status, mode,
      // rolloutStrategy (future stages must match history byte-for-byte),
      // and changeLog. Anything else returns 4xx. Before mid-flight
      // (CREATED) the backend accepts a wider set, but we still only
      // surface the editable subset in this form.
      const updates: Record<string, unknown> = {
        mode: formData.mode,
        rolloutStrategy: stages.map(s => ({
          rolloutPercent: s.rollout,
          cooloffMinutes: s.cooloff,
          podCount: s.pods,
        })),
      };
      if (!isMidFlight) {
        updates.description = formData.description;
        updates.changeLog = formData.change_log;
        updates.priority = parseInt(formData.priority, 10) || 0;
        updates.scheduleTime = formData.schedule_time || null;
        updates.dockerImage = formData.docker_image;
        updates.info = formData.info;
        updates.envOverrideData = isEnvSwitch ? envData : null;
      }
      try {
        await updateMutation.mutateAsync({ releaseId: id, updates });
        navigate(`/releases/${id}`);
      } catch (err: any) {
        setError(err?.response?.data?.message || err.message || 'Failed to update release');
      }
      return;
    }

    if (!formData.appGroup) {
      toast.error('Select an app group');
      return;
    }

    if (selectedServices.length === 0) {
      toast.error('Select at least one service');
      return;
    }

    const selectedProductConfig = productConfigs.find((c: ProductConfig) => c.appGroup === formData.appGroup);
    const trackerType = normalizeProductType(selectedProductConfig?.product_type);

    const buildPayload = (svc: string) => ({
      appGroup: formData.appGroup, service: [svc], env: formData.env,
      old_version: formData.old_version || 'unknown',
      new_version: formData.new_version, docker_image: formData.docker_image,
      change_log: formData.change_log, status: formData.status, mode: formData.mode,
      priority: parseInt(formData.priority, 10) || 0, info: formData.info,
      cronjob_suspend: formData.cronjob_suspend,
      description: formData.description, schedule_time: formData.schedule_time,
      cluster: formData.cluster, new_service: false, rollout_strategy: stages,
      is_approved: formData.env === 'INTEG_CLUSTER' ? 1 : 0,
      env_override_data: isEnvSwitch ? envData : null,
      slack_thread_ts: null,
      isReleaseSync,
      syncClusterEnvOverrideData: isReleaseSync && isSecondaryEnvSwitch ? secondaryEnvData : null,
      syncClusterRolloutStrategy: isReleaseSync ? secondaryStages.map(s => ({ rolloutPercent: s.rollout, cooloffMinutes: s.cooloff, podCount: s.pods })) : null,
      release_manager: user?.email || 'local_admin', release_tag: generateReleaseTag(svc), trackerType,
    });

    try {
      if (selectedServices.length === 1) {
        await createMutation.mutateAsync({ isNewService, payload: buildPayload(selectedServices[0]) });
      } else {
        const failed: string[] = [];
        for (const svc of selectedServices) {
          try {
            await createMutation.mutateAsync({ isNewService, payload: buildPayload(svc) });
          } catch (err: any) {
            failed.push(`${svc}: ${err?.response?.data?.message || err.message || 'failed'}`);
          }
        }
        if (failed.length > 0) {
          setError(`${selectedServices.length - failed.length} of ${selectedServices.length} releases created. Failed:\n${failed.join('\n')}`);
          return;
        }
      }
      navigate('/backend/releases');
    } catch (err: any) {
      setError(err?.response?.data?.message || err.message || 'Failed to create release');
    }
  };

  const FieldLabel = ({ children, required }: { children: React.ReactNode; required?: boolean }) => (
    <label className="text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5 block">
      {children} {required && <span className="text-red-500">*</span>}
    </label>
  );

  const inputClass = "w-full h-10 sm:h-9 border border-zinc-300 rounded-lg px-3 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150";
  const disabledInputClass = "w-full h-10 sm:h-9 border border-zinc-200 rounded-lg px-3 text-sm bg-zinc-100 text-zinc-500 cursor-not-allowed";

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
  // Mid-flight: backend rejects edits to most fields. Only status, rolloutStrategy,
  // changeLog, mode, and envOverrideData can change once a release is live.
  const isMidFlight = isUpdate && ['INPROGRESS', 'PAUSED', 'RESTARTING', 'REVERTING'].includes(formData.status);
  const pageTitle = isUpdate ? 'Update Release' : isClone ? 'Clone Release' : 'Create Release';
  const submitLabel = isUpdate
    ? (updateMutation.isPending ? 'Updating...' : 'Update Release')
    : (createMutation.isPending ? 'Creating...' : selectedServices.length > 1 ? `Create ${selectedServices.length} Releases` : 'Create Release');

  // On create, once the old version resolves and the app group has a GitHub repo,
  // the changelog IS a compare link — lock the field to a read-only link so it
  // can't be accidentally overwritten. With no repo (no link to show) it stays
  // editable so a manual description is still possible.
  const changelogDiffLink = buildDiffLink(selectedRepo, formData.old_version, formData.new_version);
  const changelogLocked = !isUpdate && !isMidFlight && !!selectedRepo && !!formData.old_version.trim() && !!changelogDiffLink;

  return (
    <div className="flex flex-col flex-1 w-full pb-12">
      <form onSubmit={handleSubmit} className="space-y-4 sm:space-y-6">
        {error && (() => {
          // Extract in-flight release UUID from backend error message to render a deep link.
          const uuidMatch = error.match(/in-flight release ([0-9a-f-]{36})/i);
          const inFlightId = uuidMatch?.[1];
          return (
            <div className="bg-red-50 border border-red-200 text-red-700 px-4 py-3 rounded-xl text-sm flex items-start justify-between gap-3">
              <span>{error}</span>
              {inFlightId && (
                <a
                  href={`/releases/${inFlightId}`}
                  className="shrink-0 underline font-medium whitespace-nowrap hover:text-red-900"
                >
                  View release →
                </a>
              )}
            </div>
          );
        })()}

        {isMidFlight && (
          <div className="bg-amber-50 border border-amber-200 text-amber-800 px-4 py-3 rounded-xl text-sm">
            This release is <strong>{formData.status}</strong>. Only <strong>mode</strong> and <strong>rollout stages</strong> are editable. For safety, pause the release before editing. Use the action buttons on the release page to pause/resume/abort. Abort and create a new release to change other fields.
          </div>
        )}

        <div className="bg-white rounded-xl border border-zinc-200">
          <div className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100 flex justify-between items-center">
            <h2 className="text-base sm:text-lg font-semibold text-zinc-900">{pageTitle}</h2>
          </div>

          <div className="p-4 sm:p-6 grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-x-6 lg:gap-x-8 gap-y-4 sm:gap-y-5">

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
              <div><FieldLabel>Info</FieldLabel><input type="text" name="info" value={formData.info} onChange={handleInputChange} placeholder="Any Valid JSON" disabled={isMidFlight} className={isMidFlight ? disabledInputClass : inputClass} /></div>
            </div>

            <div className="space-y-4">
              <div>
                <FieldLabel required={!isUpdate}>App Group</FieldLabel>
                {isUpdate ? (
                  <input type="text" value={formData.appGroup} disabled className={disabledInputClass} />
                ) : (
                  <div className="app-group-dropdown relative">
                    <div
                      onClick={() => setShowAppGroupDropdown(!showAppGroupDropdown)}
                      className={cn(inputClass, 'cursor-pointer flex items-center justify-between')}
                    >
                      <span className={formData.appGroup ? 'text-zinc-900' : 'text-zinc-400'}>
                        {formData.appGroup || 'Select App Group'}
                      </span>
                      <ChevronDown className="w-4 h-4 text-zinc-400" />
                    </div>
                    {showAppGroupDropdown && (
                      <div className="absolute z-20 mt-1 w-full max-h-60 overflow-y-auto bg-white border border-zinc-200 rounded-lg shadow-lg">
                        {products.length === 0 ? (
                          <div className="px-3 py-2 text-sm text-zinc-400">No app groups accessible</div>
                        ) : (
                          products.map(p => (
                            <button key={p} type="button"
                              onClick={() => { setFormData(prev => ({ ...prev, appGroup: p })); setShowAppGroupDropdown(false); }}
                              className="w-full px-3 py-2 text-left text-sm hover:bg-zinc-50 flex items-center justify-between">
                              {p}
                              {formData.appGroup === p && <Check className="w-4 h-4 text-zinc-900" />}
                            </button>
                          ))
                        )}
                      </div>
                    )}
                  </div>
                )}
              </div>
              <div>
                <FieldLabel>Env</FieldLabel>
                <input type="text" value={formData.env} disabled className={disabledInputClass} />
              </div>
              <div>
                <FieldLabel>Priority</FieldLabel>
                <div className="priority-dropdown relative">
                  <div
                    onClick={() => !isMidFlight && setShowPriorityDropdown(!showPriorityDropdown)}
                    className={cn(isMidFlight ? disabledInputClass : inputClass, 'flex items-center justify-between', !isMidFlight && 'cursor-pointer')}
                  >
                    <span className={isMidFlight ? '' : 'text-zinc-900'}>{formData.priority}</span>
                    <ChevronDown className="w-4 h-4 text-zinc-400" />
                  </div>
                  {showPriorityDropdown && !isMidFlight && (
                    <div className="absolute z-20 mt-1 w-full max-h-60 overflow-y-auto bg-white border border-zinc-200 rounded-lg shadow-lg">
                      {[0,1,2,3,4,5,6,7,8,9].map(d => (
                        <button key={d} type="button"
                          onClick={() => { setFormData(prev => ({ ...prev, priority: String(d) })); setShowPriorityDropdown(false); }}
                          className="w-full px-3 py-2 text-left text-sm hover:bg-zinc-50 flex items-center justify-between">
                          {d}
                          {formData.priority === String(d) && <Check className="w-4 h-4 text-zinc-900" />}
                        </button>
                      ))}
                    </div>
                  )}
                </div>
              </div>
              <div><FieldLabel>Description</FieldLabel><input type="text" name="description" value={formData.description} onChange={handleInputChange} placeholder="Deploying webhook Hotfix" disabled={isMidFlight} className={isMidFlight ? disabledInputClass : inputClass} /></div>
              <div>
                <FieldLabel required={!isUpdate}>Docker Image</FieldLabel>
                <input type="text" name="docker_image" value={formData.docker_image} onChange={handleInputChange}
                  required={!isUpdate} placeholder="Enter Docker Image" disabled={isMidFlight} className={isMidFlight ? disabledInputClass : inputClass} />
              </div>
            </div>

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
              <div><FieldLabel>Schedule Time</FieldLabel><input type="text" name="schedule_time" value={formData.schedule_time} onChange={handleInputChange} placeholder="2022-11-01T19:39:35" disabled={isMidFlight} className={isMidFlight ? disabledInputClass : inputClass} /></div>
              <div><FieldLabel>Cluster</FieldLabel><input type="text" disabled value={formData.cluster} className={disabledInputClass} /></div>
              <div>
                <FieldLabel required={!isUpdate}>Change Log</FieldLabel>
                {changelogLocked ? (
                  <>
                    <div className={cn(disabledInputClass, 'flex items-center cursor-default')}>
                      <a
                        href={changelogDiffLink}
                        target="_blank"
                        rel="noopener noreferrer"
                        title={changelogDiffLink}
                        className="text-sky-600 hover:text-sky-800 underline truncate"
                      >
                        View GitHub diff ↗
                      </a>
                    </div>
                    <p className="text-[10px] text-zinc-400 mt-0.5">Change log is a GitHub diff link (read-only).</p>
                  </>
                ) : (
                  <>
                    <input type="text" name="change_log" value={formData.change_log} onChange={handleInputChange}
                      required={!isUpdate} placeholder="Diff link or a short description of what changed"
                      disabled={isMidFlight} className={isMidFlight ? disabledInputClass : inputClass} />
                    {!isUpdate && (
                      selectedRepo ? (
                        <p className="text-[10px] text-zinc-400 mt-0.5">Auto-filled with a GitHub diff link — edit if you want a description instead.</p>
                      ) : formData.appGroup ? (
                        <p className="text-[10px] text-zinc-400 mt-0.5">Set a GitHub repo for this app group in Config to auto-fill a diff link.</p>
                      ) : null
                    )}
                  </>
                )}
              </div>
            </div>
          </div>

        </div>

        <div className="bg-white rounded-xl border border-zinc-200">
          <div className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100">
            <h2 className="text-base sm:text-lg font-semibold text-zinc-900">Stages</h2>
            {isUpdate && rolloutHistoryLength > 0 && (
              <p className="text-xs text-zinc-500 mt-1">
                Stages 1-{rolloutHistoryLength} are locked (already executed). Only future stages can be edited.
              </p>
            )}
          </div>
          <div className="p-4 sm:p-6">
            <div className="overflow-x-auto -mx-4 sm:mx-0">
              <table className="w-full text-sm text-left">
                <thead>
                  <tr className="bg-zinc-50 border-b border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                    <th className="py-2 px-3 w-12">#</th>
                    <th className="py-2 px-3">Rollout %</th>
                    <th className="py-2 px-3">Cooloff (min)</th>
                    <th className="py-2 px-3">
                      <span className="flex items-center gap-1">
                        Min Pods
                        <span title="Minimum number of new pods at this stage. Actual count = max(this floor, factor-based target, old-pod prediction). Default 2 = at least 2 pods." className="cursor-help text-zinc-400 hover:text-zinc-600"><Info className="w-3 h-3" /></span>
                      </span>
                    </th>
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

        {!isNewService && (
          <div className="bg-white rounded-xl border border-zinc-200">
            <div className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100 flex items-center gap-3 flex-wrap">
              <h2 className="text-base sm:text-lg font-semibold text-zinc-900">Env Switch</h2>
              <Toggle checked={isEnvSwitch} onChange={() => canToggleEnvSwitch && formData.service && !isMidFlight && setIsEnvSwitch(!isEnvSwitch)} disabled={!canToggleEnvSwitch || !formData.service || isMidFlight} />
              {!canToggleEnvSwitch && selectedServices.length > 1 && <span className="text-xs text-zinc-400 ml-2">Single service only</span>}
              {isMidFlight && <span className="text-xs text-zinc-400 ml-2">Locked mid-flight</span>}
            </div>
            {isEnvSwitch && (
              <div className="p-4 sm:p-6">
                <FieldLabel>Environment Variables JSON</FieldLabel>
                <div className="border border-zinc-200 rounded-lg overflow-hidden mt-1">
                  <Editor height="320px" defaultLanguage="json" theme="light" value={envData} onChange={(val) => !isMidFlight && setEnvData(val || '')}
                    options={{ readOnly: isMidFlight, minimap: { enabled: false }, fontSize: 13, lineNumbers: 'on', scrollBeyondLastLine: false, wordWrap: 'on', tabSize: 2, automaticLayout: true }} />
                </div>
              </div>
            )}
          </div>
        )}

        {!isNewService && (
          <div className="bg-white rounded-xl border border-zinc-200">
            <div className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100 flex items-center gap-3 flex-wrap">
              <h2 className="text-base sm:text-lg font-semibold text-zinc-900">Get Resources</h2>
              <Toggle checked={isResourcesSwitch} onChange={() => canToggleResourcesSwitch && formData.service && setIsResourcesSwitch(!isResourcesSwitch)} disabled={!canToggleResourcesSwitch || !formData.service} />
              {!canToggleResourcesSwitch && selectedServices.length > 1 && <span className="text-xs text-zinc-400 ml-2">Single service only</span>}
            </div>
            {isResourcesSwitch && (
              <div className="p-4 sm:p-6">
                <FieldLabel>Resource Limits (CPU / Memory)</FieldLabel>
                <div className="border border-zinc-200 rounded-lg overflow-hidden mt-1">
                  <Editor height="280px" defaultLanguage="json" theme="light" value={resourcesData}
                    options={{ readOnly: true, minimap: { enabled: false }, fontSize: 13, lineNumbers: 'on', scrollBeyondLastLine: false, wordWrap: 'on', tabSize: 2, automaticLayout: true }} />
                </div>
              </div>
            )}
          </div>
        )}

        {syncCluster && !isUpdate && (
          <div className="bg-white rounded-xl border border-zinc-200">
            <div className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100 flex items-center gap-3 flex-wrap">
              <h2 className="text-base sm:text-lg font-semibold text-zinc-900">Sync Release to Other Cloud</h2>
              <Toggle checked={isReleaseSync} onChange={() => setIsReleaseSync(!isReleaseSync)} />
              <span className="text-sm text-zinc-500">{isReleaseSync ? `Sync to ${syncCluster}` : 'Single cloud only'}</span>
            </div>
            {isReleaseSync && (
              <div className="p-4 sm:p-6 space-y-6">
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
                          <th className="py-2 px-3">
                            <span className="flex items-center gap-1">
                              Min Pods
                              <span title="Minimum number of new pods at this stage. Default 2 = at least 2 pods." className="cursor-help text-zinc-400 hover:text-zinc-600"><Info className="w-3 h-3" /></span>
                            </span>
                          </th>
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

        <div className="flex flex-col-reverse sm:flex-row sm:justify-end gap-2 sm:gap-3 pt-2">
          <Button type="button" variant="secondary" onClick={() => isUpdate ? navigate(`/backend/releases/${id}`) : navigate('/backend/releases')}>Cancel</Button>
          <Button type="submit" loading={isSubmitting}>{submitLabel}</Button>
        </div>
      </form>
    </div>
  );
};

export default CreateRelease;
