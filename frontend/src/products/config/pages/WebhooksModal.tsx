import React, { useEffect, useMemo, useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import {
  fetchWebhooks, fetchWebhookPlaceholders,
  createWebhook, updateWebhook, deleteWebhook, testWebhook,
} from '../../releases/api';
import type {
  ReleaseWebhook, ReleaseConfig, WebhookKV, WebhookMethod, WebhookTestResult, WebhookPlaceholder,
} from '../../releases/api';
import { Button } from '../../../shared/ui/button';
import { Badge } from '../../../shared/ui/badge';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { useConfirm } from '../../../shared/ui/confirm-dialog';
import {
  Dialog, DialogContent, DialogHeader, DialogTitle,
  DialogDescription, DialogBody, DialogFooter,
} from '../../../shared/ui/dialog';
import {
  Plus, Pencil, Trash2, Send, ArrowLeft, Copy, HelpCircle, ChevronDown,
  CheckCircle2, XCircle, Webhook as WebhookIcon,
} from 'lucide-react';
import { cn, copyToClipboard } from '../../../lib/utils';
import { toast } from 'sonner';

const METHODS: WebhookMethod[] = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'];

const inputClass =
  'w-full h-10 sm:h-9 border border-zinc-300 rounded-lg px-3 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150';
const labelClass = 'block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5';
const monoClass = 'font-mono [font-variant-ligatures:none]';

const EMPTY_FORM: Partial<ReleaseWebhook> = {
  name: '',
  services: [],
  enabled: true,
  onSuccess: true,
  onFailure: true,
  method: 'POST',
  url: '',
  headers: [],
  queryParams: [],
  body: '',
  timeoutSeconds: null,
  retries: null,
};

function methodBadgeVariant(m: string): 'success' | 'blue' | 'warning' | 'purple' | 'danger' {
  switch (m) {
    case 'GET': return 'success';
    case 'POST': return 'blue';
    case 'PUT': return 'warning';
    case 'PATCH': return 'purple';
    default: return 'danger';
  }
}

interface Props {
  /** App group the dialog is scoped to. `null` keeps it closed. */
  appGroup: string | null;
  /** Services in that group, offered as the optional narrower scope. */
  services: ReleaseConfig[];
  onClose: () => void;
}

/**
 * Configure the outbound webhooks fired when a release in this app group
 * settles. Two views share the dialog: the list of configured hooks, and the
 * request editor for one of them — the back arrow returns to the list.
 */
const WebhooksModal: React.FC<Props> = ({ appGroup, services, onClose }) => {
  const queryClient = useQueryClient();
  const confirmAction = useConfirm();

  const [editing, setEditing] = useState<ReleaseWebhook | null>(null);
  const [form, setForm] = useState<Partial<ReleaseWebhook> | null>(null);
  const [testResult, setTestResult] = useState<Record<number, WebhookTestResult>>({});
  const [helpOpen, setHelpOpen] = useState(false);

  const open = !!appGroup;

  const { data: webhooks = [], isLoading } = useQuery({
    queryKey: ['release-webhooks', appGroup],
    queryFn: () => fetchWebhooks(appGroup!),
    enabled: open,
    staleTime: 60000,
  });

  // Served by the backend so the docs can't drift from what actually resolves.
  const { data: placeholders = [] } = useQuery({
    queryKey: ['webhook-placeholders'],
    queryFn: fetchWebhookPlaceholders,
    enabled: open,
    staleTime: Infinity,
  });

  const invalidate = () => queryClient.invalidateQueries({ queryKey: ['release-webhooks', appGroup] });

  const createMut = useMutation({
    mutationFn: (payload: Partial<ReleaseWebhook>) => createWebhook(payload),
    onSuccess: () => { toast.success('Webhook created'); invalidate(); closeEditor(); },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to create webhook'),
  });

  // A stored test result describes the request as it was when it ran, so any
  // edit to that webhook retires it rather than leaving a green banner over a
  // URL that was never tested.
  const clearResult = (id: number) =>
    setTestResult(prev => {
      const { [id]: _dropped, ...rest } = prev;
      return rest;
    });

  const updateMut = useMutation({
    mutationFn: ({ id, payload }: { id: number; payload: Partial<ReleaseWebhook> }) => updateWebhook(id, payload),
    onSuccess: (_res, vars) => {
      toast.success('Webhook updated');
      clearResult(vars.id);
      invalidate();
      closeEditor();
    },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to update webhook'),
  });

  const deleteMut = useMutation({
    mutationFn: (id: number) => deleteWebhook(id),
    onSuccess: (_res, id) => { toast.success('Webhook deleted'); clearResult(id); invalidate(); },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to delete webhook'),
  });

  // Separate from updateMut so flipping the switch doesn't close an open editor.
  const toggleMut = useMutation({
    mutationFn: ({ id, payload }: { id: number; payload: Partial<ReleaseWebhook> }) => updateWebhook(id, payload),
    onSuccess: (_res, vars) => {
      toast.success(vars.payload.enabled ? 'Webhook enabled' : 'Webhook disabled');
      invalidate();
    },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Failed to update webhook'),
  });

  const testMut = useMutation({
    mutationFn: (id: number) => testWebhook(id),
    onSuccess: (res, id) => {
      setTestResult(prev => ({ ...prev, [id]: res }));
      if (res.ok) toast.success(`Test delivered — HTTP ${res.responseStatus}`);
      else toast.error(res.error || 'Test failed');
    },
    onError: (err: any) => toast.error(err?.response?.data?.message || 'Test failed'),
  });

  const serviceOptions = useMemo(
    () => [...new Set(services.map(s => s.service).filter(Boolean))].sort(),
    [services]
  );

  const openCreate = () => { setEditing(null); setForm({ ...EMPTY_FORM, appGroup: appGroup || '' }); };
  const openEdit = (wh: ReleaseWebhook) => { setEditing(wh); setForm({ ...wh }); };
  const closeEditor = () => { setEditing(null); setForm(null); };

  const handleClose = () => { closeEditor(); setTestResult({}); onClose(); };

  const handleDelete = async (wh: ReleaseWebhook) => {
    const ok = await confirmAction({
      title: 'Delete Webhook',
      description: `Delete "${wh.name}"? Releases in ${wh.appGroup} will stop calling ${wh.url}.`,
      confirmLabel: 'Delete',
      variant: 'danger',
    });
    if (ok) deleteMut.mutate(wh.id);
  };

  const handleSubmit = () => {
    if (!form) return;
    if (!form.name?.trim()) { toast.error('Name is required'); return; }
    if (!form.url?.trim()) { toast.error('URL is required'); return; }
    if (editing) updateMut.mutate({ id: editing.id, payload: { ...form, appGroup: editing.appGroup } });
    else createMut.mutate({ ...form, appGroup: appGroup || '' });
  };

  const isEditorOpen = form !== null;

  return (
    <Dialog open={open} onOpenChange={o => { if (!o) handleClose(); }}>
      <DialogContent size="xl">
        <DialogHeader>
          <div className="flex items-center gap-2">
            {isEditorOpen && (
              <button
                onClick={closeEditor}
                className="p-1 -ml-1 rounded-lg text-zinc-400 hover:text-zinc-700 hover:bg-zinc-100 cursor-pointer transition-colors duration-150"
                aria-label="Back to list"
              >
                <ArrowLeft className="w-4 h-4" />
              </button>
            )}
            <DialogTitle>
              {isEditorOpen ? (editing ? 'Edit Webhook' : 'New Webhook') : 'Release Webhooks'}
            </DialogTitle>
          </div>
          {/* Positioned like DialogContent's own close button (same top, one
              slot to its left) so the two read as one row of controls. */}
          {isEditorOpen && (
            <button
              type="button"
              onClick={() => setHelpOpen(true)}
              title="Available placeholders"
              className="absolute right-11 top-3 sm:right-12 sm:top-4 inline-flex items-center gap-1.5 rounded-lg px-2 py-1.5 text-[11px] text-zinc-500 hover:text-zinc-800 hover:bg-zinc-100 cursor-pointer transition-colors duration-150"
            >
              <HelpCircle className="w-3.5 h-3.5" />
              <span className="hidden sm:inline">Placeholders</span>
            </button>
          )}
          {!isEditorOpen && (
            <DialogDescription>
              Called when a release in <span className="font-medium text-zinc-700">{appGroup}</span> completes or fails.
            </DialogDescription>
          )}
        </DialogHeader>

        <DialogBody>
          {form !== null ? (
            <WebhookEditor
              form={form}
              setForm={setForm}
              serviceOptions={serviceOptions}
            />
          ) : isLoading ? (
            <div className="py-10 text-center text-sm text-zinc-400">Loading webhooks…</div>
          ) : webhooks.length === 0 ? (
            <div className="py-12 flex flex-col items-center text-center">
              <WebhookIcon className="w-8 h-8 text-zinc-300 mb-3" />
              <p className="text-sm text-zinc-500">No webhooks configured for this group.</p>
              <p className="text-[11px] text-zinc-400 mt-1 max-w-xs">
                Add one to notify an external system every time a release here succeeds or fails.
              </p>
            </div>
          ) : (
            <div className="space-y-2.5">
              {webhooks.map(wh => (
                <WebhookCard
                  key={wh.id}
                  webhook={wh}
                  result={testResult[wh.id]}
                  testing={testMut.isPending && testMut.variables === wh.id}
                  toggling={toggleMut.isPending && toggleMut.variables?.id === wh.id}
                  onEdit={() => openEdit(wh)}
                  onDelete={() => handleDelete(wh)}
                  onTest={() => testMut.mutate(wh.id)}
                  onToggle={() => toggleMut.mutate({ id: wh.id, payload: { ...wh, enabled: !wh.enabled } })}
                />
              ))}
            </div>
          )}
        </DialogBody>

        <DialogFooter>
          {isEditorOpen ? (
            <>
              <Button variant="secondary" size="md" onClick={closeEditor}>Cancel</Button>
              <Button size="md" onClick={handleSubmit} loading={createMut.isPending || updateMut.isPending}>
                {editing ? 'Update' : 'Create'}
              </Button>
            </>
          ) : (
            <>
              <Button variant="secondary" size="md" onClick={handleClose}>Close</Button>
              <PermissionGate product="autopilot" permission="PRODUCT_CONFIG_EDIT" appGroup={appGroup || undefined}>
                <Button size="md" onClick={openCreate}>
                  <Plus className="w-4 h-4" /> Add Webhook
                </Button>
              </PermissionGate>
            </>
          )}
        </DialogFooter>

        <PlaceholderHelpDialog open={helpOpen} onOpenChange={setHelpOpen} placeholders={placeholders} />
      </DialogContent>
    </Dialog>
  );
};

// ── List card ─────────────────────────────────────────────────────

/** Local toggle, matching the one in MobileAppsAdmin — small enough not to
 *  deserve its own shared component yet. */
function Toggle({
  checked, onChange, disabled, title,
}: { checked: boolean; onChange: () => void; disabled?: boolean; title?: string }) {
  return (
    <button
      type="button"
      onClick={onChange}
      disabled={disabled}
      title={title}
      aria-label={title}
      role="switch"
      aria-checked={checked}
      className={cn(
        'relative inline-flex h-5 w-9 items-center rounded-full transition-colors duration-150 cursor-pointer shrink-0',
        disabled ? 'bg-zinc-200 cursor-not-allowed opacity-60'
          : checked ? 'bg-zinc-900' : 'bg-zinc-300',
      )}
    >
      <span
        className={cn(
          'inline-block h-3.5 w-3.5 transform rounded-full bg-white transition-transform duration-150',
          checked ? 'translate-x-[1.125rem]' : 'translate-x-0.5',
        )}
      />
    </button>
  );
}

const WebhookCard: React.FC<{
  webhook: ReleaseWebhook;
  result?: WebhookTestResult;
  testing: boolean;
  toggling: boolean;
  onEdit: () => void;
  onDelete: () => void;
  onTest: () => void;
  onToggle: () => void;
}> = ({ webhook: wh, result, testing, toggling, onEdit, onDelete, onTest, onToggle }) => (
  <div className={cn('border border-zinc-200 rounded-xl overflow-hidden', !wh.enabled && 'bg-zinc-50/60')}>
    <div className="px-4 py-3">
      <div className="flex items-start justify-between gap-2">
        <div className={cn('min-w-0 flex-1', !wh.enabled && 'opacity-50')}>
          <span className="text-sm font-semibold text-zinc-900 truncate block">{wh.name}</span>
          <div className="flex items-center gap-2 mt-1.5 min-w-0">
            <Badge variant={methodBadgeVariant(wh.method)} size="sm">{wh.method}</Badge>
            <span className={cn(monoClass, 'text-[11px] text-zinc-500 truncate')} title={wh.url}>{wh.url}</span>
          </div>
        </div>

        <PermissionGate product="autopilot" permission="PRODUCT_CONFIG_EDIT" appGroup={wh.appGroup}>
          <div className="flex items-center gap-1 shrink-0">
            {/* Testing a hook that can't fire would report a meaningless pass. */}
            {wh.enabled && (
              <button
                onClick={onTest}
                disabled={testing}
                title="Send a test request — placeholders resolve to TEST_* values, not a real version"
                className="p-1.5 rounded-lg text-zinc-400 hover:text-zinc-600 hover:bg-zinc-100 cursor-pointer transition-colors duration-150 disabled:opacity-50"
              >
                <Send className={cn('w-3.5 h-3.5', testing && 'animate-pulse')} />
              </button>
            )}
            <button
              onClick={onEdit}
              title="Edit"
              className="p-1.5 rounded-lg text-zinc-400 hover:text-zinc-600 hover:bg-zinc-100 cursor-pointer transition-colors duration-150"
            >
              <Pencil className="w-3.5 h-3.5" />
            </button>
            <button
              onClick={onDelete}
              title="Delete"
              className="p-1.5 rounded-lg text-red-400 hover:text-red-600 hover:bg-red-50 cursor-pointer transition-colors duration-150"
            >
              <Trash2 className="w-3.5 h-3.5" />
            </button>
          </div>
        </PermissionGate>
      </div>

      <div className="flex items-center justify-between gap-2 mt-2.5">
        <div className={cn('flex items-center gap-1.5 flex-wrap min-w-0', !wh.enabled && 'opacity-50')}>
          <Badge variant="default" size="sm">
            {wh.services.length === 0
              ? 'All services'
              : wh.services.length === 1
                ? wh.services[0]
                : `${wh.services.length} services`}
          </Badge>
          {wh.onSuccess && <Badge variant="success" size="sm">On success</Badge>}
          {wh.onFailure && <Badge variant="danger" size="sm">On failure</Badge>}
          {wh.headers.length > 0 && (
            <span className="text-[10px] text-zinc-400">
              {wh.headers.length} header{wh.headers.length !== 1 ? 's' : ''}
            </span>
          )}
          {wh.queryParams.length > 0 && (
            <span className="text-[10px] text-zinc-400">
              {wh.queryParams.length} query param{wh.queryParams.length !== 1 ? 's' : ''}
            </span>
          )}
        </div>
        <PermissionGate product="autopilot" permission="PRODUCT_CONFIG_EDIT" appGroup={wh.appGroup}>
          <Toggle
            checked={wh.enabled}
            onChange={onToggle}
            disabled={toggling}
            title={wh.enabled ? 'Disable webhook' : 'Enable webhook'}
          />
        </PermissionGate>
      </div>
    </div>

    {result && (
      <div
        className={cn(
          'px-4 py-2 border-t text-[11px] flex items-start gap-1.5',
          result.ok ? 'bg-emerald-50 border-emerald-100 text-emerald-800' : 'bg-red-50 border-red-100 text-red-800'
        )}
      >
        {result.ok
          ? <CheckCircle2 className="w-3.5 h-3.5 shrink-0 mt-px" />
          : <XCircle className="w-3.5 h-3.5 shrink-0 mt-px" />}
        <div className="min-w-0">
          <div className="font-medium">
            {result.ok ? `Delivered — HTTP ${result.responseStatus}` : (result.error || 'Failed')}
          </div>
          {/* The resolved URL is the point of the test — it shows what the
              placeholders became. */}
          <div className={cn(monoClass, 'text-[10px] opacity-80 break-all mt-0.5')}>
            {result.requestMethod} {result.requestUrl}
          </div>
        </div>
      </div>
    )}
  </div>
);

// ── Editor ────────────────────────────────────────────────────────

const WebhookEditor: React.FC<{
  form: Partial<ReleaseWebhook>;
  setForm: React.Dispatch<React.SetStateAction<Partial<ReleaseWebhook> | null>>;
  serviceOptions: string[];
}> = ({ form, setForm, serviceOptions }) => {
  const set = <K extends keyof ReleaseWebhook>(k: K, v: ReleaseWebhook[K]) =>
    setForm(prev => ({ ...(prev || {}), [k]: v }));

  /** '' clears back to the default; NaN from junk input is ignored, and 0 is
   *  kept (a valid retries value). */
  const setNumber = (k: 'timeoutSeconds' | 'retries', raw: string) => {
    if (raw === '') return set(k, null);
    const n = parseInt(raw, 10);
    if (!Number.isNaN(n)) set(k, n);
  };

  const selectedServices = form.services || [];

  return (
    <div className="space-y-4">
      <div>
        <label className={labelClass}>Name *</label>
        <input
          type="text"
          value={form.name || ''}
          onChange={e => set('name', e.target.value)}
          className={inputClass}
          placeholder="e.g. Notify Ops Dashboard"
        />
      </div>

      <ServicePicker
        options={serviceOptions}
        selected={selectedServices}
        onChange={v => set('services', v)}
      />

      <div className="grid grid-cols-[7rem_1fr] gap-3">
        <div>
          <label className={labelClass}>Method</label>
          <select
            value={form.method || 'POST'}
            onChange={e => set('method', e.target.value as WebhookMethod)}
            className={cn(inputClass, 'cursor-pointer')}
          >
            {METHODS.map(m => <option key={m} value={m}>{m}</option>)}
          </select>
        </div>
        <div className="min-w-0">
          <label className={labelClass}>URL *</label>
          <input
            type="text"
            value={form.url || ''}
            onChange={e => set('url', e.target.value)}
            className={cn(inputClass, monoClass, 'text-[13px]')}
            placeholder="https://hooks.example.com/release/{{NEW_VERSION}}"
          />
          <p className="text-[10px] text-zinc-400 mt-1">
            Must start with http:// or https://
          </p>
        </div>
      </div>

      <div>
        <label className={labelClass}>Fire on</label>
        <div className="flex items-center gap-5">
          <label className="flex items-center gap-2.5 cursor-pointer">
            <input
              type="checkbox"
              checked={form.onSuccess !== false}
              onChange={e => set('onSuccess', e.target.checked)}
              className="rounded border-zinc-300 accent-zinc-900"
            />
            <span className="text-sm text-zinc-700">Release completed</span>
          </label>
          <label className="flex items-center gap-2.5 cursor-pointer">
            <input
              type="checkbox"
              checked={form.onFailure !== false}
              onChange={e => set('onFailure', e.target.checked)}
              className="rounded border-zinc-300 accent-zinc-900"
            />
            <span className="text-sm text-zinc-700">Release failed / aborted</span>
          </label>
        </div>
      </div>

      <KVEditor
        label="Query Params"
        rows={form.queryParams || []}
        onChange={rows => set('queryParams', rows)}
        keyPlaceholder="version"
        valuePlaceholder="{{NEW_VERSION}}"
        hint="Appended to the URL and percent-encoded."
      />

      <KVEditor
        label="Headers"
        rows={form.headers || []}
        onChange={rows => set('headers', rows)}
        keyPlaceholder="Authorization"
        valuePlaceholder="Bearer …"
        hint="Content-Type defaults to application/json when a body is set."
      />

      <div>
        <label className={labelClass}>Body</label>
        <textarea
          value={form.body || ''}
          onChange={e => set('body', e.target.value)}
          rows={6}
          spellCheck={false}
          className={cn(monoClass, 'w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm resize-y focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150')}
          placeholder={'{\n  "released": "{{NEW_VERSION}}",\n  "previous": "{{OLD_VERSION}}"\n}'}
        />
        <p className="text-[10px] text-zinc-400 mt-1">Sent as-is. Leave blank to send no body.</p>
      </div>

      <div className="grid grid-cols-2 gap-4">
        <div>
          <label className={labelClass}>Timeout (seconds)</label>
          <input
            type="number"
            min={1}
            max={120}
            value={form.timeoutSeconds ?? ''}
            onChange={e => setNumber('timeoutSeconds', e.target.value)}
            className={inputClass}
            placeholder="Default: 10"
          />
        </div>
        <div>
          <label className={labelClass}>Retries</label>
          <input
            type="number"
            min={0}
            max={5}
            value={form.retries ?? ''}
            onChange={e => setNumber('retries', e.target.value)}
            className={inputClass}
            placeholder="Default: 1"
          />
          <p className="text-[10px] text-zinc-400 mt-1">Retried on network errors and 5xx only.</p>
        </div>
      </div>
    </div>
  );
};

// ── Service scope ─────────────────────────────────────────────────

/**
 * Which services the hook covers. Nothing checked = all of them, and the only
 * way to cover services added later.
 */
const ServicePicker: React.FC<{
  options: string[];
  selected: string[];
  onChange: (values: string[]) => void;
}> = ({ options, selected, onChange }) => {
  const [open, setOpen] = useState(false);

  // Marker class on the wrapper is load-bearing, same trick as Create Release.
  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (!(e.target as HTMLElement).closest('.webhook-service-dropdown')) setOpen(false);
    };
    document.addEventListener('mousedown', onDown);
    return () => document.removeEventListener('mousedown', onDown);
  }, [open]);

  const allSelected = options.length > 0 && selected.length === options.length;

  return (
    <div>
      <label className={labelClass}>Services</label>
      <div className="webhook-service-dropdown relative">
        <div
          onClick={() => options.length > 0 && setOpen(!open)}
          className={cn(
            inputClass,
            'cursor-pointer flex items-center justify-between',
            options.length === 0 && 'bg-zinc-50 cursor-not-allowed'
          )}
        >
          <span className={selected.length > 0 ? 'text-zinc-900' : 'text-zinc-400'}>
            {selected.length > 0 ? `${selected.length} selected` : 'All services'}
          </span>
          <ChevronDown className="w-4 h-4 text-zinc-400" />
        </div>
        {open && (
          <div className="absolute z-20 mt-1 w-full max-h-60 overflow-y-auto bg-white border border-zinc-200 rounded-lg shadow-lg">
            {options.length === 0 ? (
              <div className="px-3 py-2 text-sm text-zinc-400">No services found</div>
            ) : (
              <>
                <button
                  type="button"
                  onClick={() => { onChange(allSelected ? [] : [...options]); setOpen(false); }}
                  className="w-full px-3 py-2 text-left text-xs text-zinc-500 hover:bg-zinc-50 border-b border-zinc-100"
                >
                  {allSelected ? 'Deselect All' : 'Select All'}
                </button>
                {options.map(svc => (
                  <label key={svc} className="flex items-center gap-2 px-3 py-2 text-sm hover:bg-zinc-50 cursor-pointer">
                    <input
                      type="checkbox"
                      checked={selected.includes(svc)}
                      onChange={() =>
                        onChange(selected.includes(svc) ? selected.filter(s => s !== svc) : [...selected, svc])
                      }
                      className="rounded border-zinc-300 accent-zinc-900"
                    />
                    {svc}
                  </label>
                ))}
              </>
            )}
          </div>
        )}
      </div>

      {selected.length > 0 && (
        <div className="flex flex-wrap gap-1 mt-1.5">
          {selected.map(svc => (
            <span key={svc} className="inline-flex items-center gap-1 px-2 py-0.5 rounded-md bg-zinc-100 text-zinc-700 text-xs">
              {svc}
              <button
                type="button"
                onClick={() => onChange(selected.filter(s => s !== svc))}
                className="text-zinc-400 hover:text-zinc-600"
              >
                &times;
              </button>
            </span>
          ))}
        </div>
      )}

      <p className="text-[10px] text-zinc-400 mt-1">
        {selected.length === 0
          ? 'Nothing selected — fires for every service in this group, including ones added later.'
          : `Fires only for ${selected.length === 1 ? 'this service' : `these ${selected.length} services`}.`}
      </p>
    </div>
  );
};

// ── Key/value rows (headers, query params) ────────────────────────

const KVEditor: React.FC<{
  label: string;
  rows: WebhookKV[];
  onChange: (rows: WebhookKV[]) => void;
  keyPlaceholder: string;
  valuePlaceholder: string;
  hint?: string;
}> = ({ label, rows, onChange, keyPlaceholder, valuePlaceholder, hint }) => (
  <div>
    <label className={labelClass}>{label}</label>
    <div className="border border-zinc-200 rounded-lg overflow-hidden">
      {rows.length > 0 && (
        <table className="w-full text-xs table-fixed">
          <thead>
            <tr className="bg-zinc-50 text-zinc-500 uppercase tracking-wider">
              <th className="px-2 py-1.5 text-left w-[38%]">Name</th>
              <th className="px-2 py-1.5 text-left">Value</th>
              <th className="px-2 py-1.5 w-8"></th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row, i) => (
              <tr key={i} className="border-t border-zinc-100">
                <td className="px-2 py-1">
                  <input
                    type="text"
                    value={row.key}
                    onChange={e => onChange(rows.map((r, idx) => idx === i ? { ...r, key: e.target.value } : r))}
                    placeholder={keyPlaceholder}
                    className={cn(monoClass, 'w-full h-7 border border-zinc-200 rounded px-2 text-xs focus:outline-none focus:ring-1 focus:ring-zinc-400')}
                  />
                </td>
                <td className="px-2 py-1">
                  <input
                    type="text"
                    value={row.value}
                    onChange={e => onChange(rows.map((r, idx) => idx === i ? { ...r, value: e.target.value } : r))}
                    placeholder={valuePlaceholder}
                    className={cn(monoClass, 'w-full h-7 border border-zinc-200 rounded px-2 text-xs focus:outline-none focus:ring-1 focus:ring-zinc-400')}
                  />
                </td>
                <td className="px-2 py-1">
                  <button
                    type="button"
                    onClick={() => onChange(rows.filter((_, idx) => idx !== i))}
                    className="text-red-400 hover:text-red-600 cursor-pointer text-sm"
                  >
                    &times;
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <button
        type="button"
        onClick={() => onChange([...rows, { key: '', value: '' }])}
        className={cn(
          'w-full py-1.5 text-xs text-zinc-400 hover:text-zinc-600 cursor-pointer',
          rows.length > 0 && 'border-t border-zinc-100'
        )}
      >
        + Add {label.replace(/s$/, '')}
      </button>
    </div>
    {hint && <p className="text-[10px] text-zinc-400 mt-1">{hint}</p>}
  </div>
);

// ── Placeholder reference ─────────────────────────────────────────

/**
 * The placeholder cheatsheet, as its own dialog opened from the editor's
 * "Available placeholders" button. Nested inside the webhook dialog — Radix
 * stacks them and Escape closes the top one first.
 */
const PlaceholderHelpDialog: React.FC<{
  open: boolean;
  onOpenChange: (open: boolean) => void;
  placeholders: WebhookPlaceholder[];
}> = ({ open, onOpenChange, placeholders }) => (
  <Dialog open={open} onOpenChange={onOpenChange}>
    <DialogContent size="md">
      <DialogHeader>
        <DialogTitle>Available Placeholders</DialogTitle>
        <DialogDescription>
          Usable anywhere in a webhook — the URL path, query params, headers and body.
          Each is replaced with the release's real value when the hook fires.
        </DialogDescription>
      </DialogHeader>
      <DialogBody>
        {placeholders.length === 0 ? (
          <p className="py-6 text-center text-sm text-zinc-400">No placeholders available.</p>
        ) : (
          <div className="space-y-3">
            {placeholders.map(p => (
              <div key={p.name} className="flex items-start gap-3">
                <button
                  type="button"
                  onClick={() => { copyToClipboard(p.token); toast.success(`Copied ${p.token}`); }}
                  title="Copy"
                  className={cn(monoClass, 'shrink-0 inline-flex items-center gap-1.5 text-[11px] bg-zinc-50 border border-zinc-200 rounded-md px-2 py-1 text-zinc-700 hover:border-zinc-400 hover:text-zinc-900 cursor-pointer transition-colors duration-150')}
                >
                  {p.token}
                  <Copy className="w-3 h-3 opacity-50" />
                </button>
                <div className="min-w-0 text-xs leading-relaxed pt-0.5">
                  <div className="text-zinc-600">{p.description}</div>
                  <div className="text-zinc-400 mt-0.5">
                    e.g. <span className={monoClass}>{p.sample}</span>
                  </div>
                </div>
              </div>
            ))}
          </div>
        )}
        <p className="text-[11px] text-zinc-400 mt-4 pt-3 border-t border-zinc-100 leading-relaxed">
          The name is case-insensitive. An unrecognised token is left as-is in the
          request rather than blanked, so a typo is visible.
        </p>
      </DialogBody>
      <DialogFooter>
        <Button variant="secondary" size="md" onClick={() => onOpenChange(false)}>Close</Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>
);

export default WebhooksModal;
