import { useEffect, useMemo, useState } from 'react';
import { useParams } from 'react-router-dom';
import { Pencil, Plus, Trash2, TriangleAlert } from 'lucide-react';
import {
  useOtaAccess,
  useOtaPropertiesList,
  useOtaPropertiesSchema,
  usePutOtaPropertiesSchema,
} from '../hooks';
import type { OtaPropertyNode } from '../types';
import { OtaAppHeader } from '../components/OtaAppHeader';
import { Button } from '../../../shared/ui/button';
import { Badge } from '../../../shared/ui/badge';
import { Input, SelectInput, Textarea } from '../../../shared/ui/input';
import {
  Dialog,
  DialogBody,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '../../../shared/ui/dialog';
import { TableSkeleton } from '../../../shared/ui/skeleton';
import { useOtaTheme } from '../theme';
import { cn, truncate } from '../../../lib/utils';

const primaryBtnDark = 'bg-airborne border-airborne text-white hover:bg-airborne-hover';
const secondaryBtnDark =
  'dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800';
const fieldDark = 'dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-100';
// Dialog portals out of the .dark subtree — re-enter dark scope on the content.
const dialogDark = 'dark bg-zinc-900 border-zinc-800 sm:border-zinc-800';

const cardCls = 'bg-white border-zinc-200 dark:bg-zinc-900 dark:border-zinc-800 rounded-xl border';
const cardHeaderCls =
  'px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100 dark:border-zinc-800 flex items-center justify-between gap-3';

type Tab = 'properties' | 'json' | 'snapshots';

const TABS: { id: Tab; label: string }[] = [
  { id: 'properties', label: 'Properties' },
  { id: 'json', label: 'JSON' },
  { id: 'snapshots', label: 'Snapshots' },
];

type PropType = 'string' | 'number' | 'boolean' | 'object' | 'array';

const TYPE_OPTIONS = (['string', 'number', 'boolean', 'object', 'array'] as PropType[]).map(
  (t) => ({ value: t, label: t }),
);

interface PropForm {
  name: string;
  type: PropType;
  description: string;
  defaultRaw: string;
}

const EMPTY_FORM: PropForm = { name: '', type: 'string', description: '', defaultRaw: '' };

const inferType = (node: OtaPropertyNode): PropType => {
  const t = node.schema?.type;
  if (t === 'string' || t === 'number' || t === 'boolean' || t === 'object' || t === 'array')
    return t;
  if (t === 'integer') return 'number';
  const dv = node.default_value;
  if (Array.isArray(dv)) return 'array';
  if (typeof dv === 'number') return 'number';
  if (typeof dv === 'boolean') return 'boolean';
  if (typeof dv === 'string') return 'string';
  return 'object';
};

const rawFor = (type: PropType, dv: unknown): string => {
  if (type === 'object' || type === 'array')
    return JSON.stringify(dv ?? (type === 'array' ? [] : {}), null, 2);
  if (type === 'boolean') return dv === false ? 'false' : 'true';
  return dv == null ? '' : String(dv);
};

const parseDefault = (type: PropType, raw: string): { value?: unknown; error?: string } => {
  switch (type) {
    case 'string':
      return { value: raw };
    case 'boolean':
      return { value: raw !== 'false' };
    case 'number': {
      if (raw.trim() === '') return { error: 'Default value is required' };
      const n = Number(raw);
      return Number.isNaN(n) ? { error: 'Not a valid number' } : { value: n };
    }
    case 'object':
    case 'array': {
      if (raw.trim() === '') return { error: 'Default value is required (JSON)' };
      try {
        const v = JSON.parse(raw);
        const bad =
          type === 'array' ? !Array.isArray(v) : typeof v !== 'object' || v === null || Array.isArray(v);
        if (bad) return { error: type === 'array' ? 'Must be a JSON array' : 'Must be a JSON object' };
        return { value: v };
      } catch {
        return { error: 'Invalid JSON' };
      }
    }
    default:
      return { error: 'Unsupported type' };
  }
};

const statusVariant = (s: string): 'default' | 'success' | 'info' | 'danger' | 'blue' => {
  const u = s.toUpperCase();
  if (u === 'DEFAULT') return 'default';
  if (u === 'CONCLUDED') return 'success';
  if (u === 'INPROGRESS') return 'info';
  if (u === 'DISCARDED') return 'danger';
  if (u === 'CREATED') return 'blue';
  return 'default';
};

const fmtVal = (v: unknown): string =>
  typeof v === 'object' && v !== null ? JSON.stringify(v) : String(v);

export default function RemoteConfigPage() {
  const { app } = useParams<{ app: string }>();
  const { isDark } = useOtaTheme();

  const { data: access } = useOtaAccess();
  const perms = access?.apps.find((a) => a.appRef === app)?.permissions ?? [];
  const canManage = perms.includes('OTA_CONFIG_MANAGE');

  const schemaQuery = useOtaPropertiesSchema(app);
  const listQuery = useOtaPropertiesList(app);
  const putMutation = usePutOtaPropertiesSchema(app);

  const [tab, setTab] = useState<Tab>('properties');
  const [draft, setDraft] = useState<Record<string, OtaPropertyNode>>({});
  const [dirty, setDirty] = useState(false);
  // True once the draft has been populated from a successful fetch at least
  // once — gates every mutating control. Without this, a slow/errored initial
  // fetch leaves draft={}, and one Add + Save would full-replace-delete every
  // existing property upstream.
  const [seeded, setSeeded] = useState(false);

  // Sync the local draft with server state whenever it is untouched (also
  // re-syncs after a successful save, when the refetched schema lands).
  useEffect(() => {
    if (schemaQuery.data && !dirty) {
      setDraft(schemaQuery.data.properties ?? {});
      setSeeded(true);
    }
  }, [schemaQuery.data, dirty]);

  const names = useMemo(() => Object.keys(draft).sort(), [draft]);

  // ── Add / Edit dialog ────────────────────────────────────────────
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editingName, setEditingName] = useState<string | null>(null);
  const [form, setForm] = useState<PropForm>(EMPTY_FORM);

  const openAdd = () => {
    setEditingName(null);
    setForm(EMPTY_FORM);
    setDialogOpen(true);
  };

  const openEdit = (name: string) => {
    const node = draft[name];
    if (!node) return;
    const t = inferType(node);
    setEditingName(name);
    setForm({
      name,
      type: t,
      description: node.description ?? '',
      defaultRaw: rawFor(t, node.default_value),
    });
    setDialogOpen(true);
  };

  const trimmedName = form.name.trim();
  const nameError =
    editingName != null || trimmedName === ''
      ? undefined
      : /\s/.test(trimmedName)
        ? 'No spaces — use dotted keys like payment.retry_count'
        : trimmedName.startsWith('config.properties.')
          ? 'Use the bare key — no config.properties. prefix'
          : trimmedName in draft
            ? 'Property already exists'
            : undefined;

  const parsed = parseDefault(form.type, form.defaultRaw);
  const defaultError = form.defaultRaw.trim() !== '' ? parsed.error : undefined;

  const targetName = editingName ?? trimmedName;
  const canSubmitDialog = targetName !== '' && !nameError && !parsed.error;

  const submitDialog = () => {
    if (!canSubmitDialog) return;
    const prevNode = editingName != null ? draft[editingName] : undefined;
    // Only carry over the previous schema's constraints (enum/pattern/min/max)
    // when the type is unchanged — otherwise e.g. a string enum survives onto
    // a number field, producing a schema no value can satisfy upstream.
    const prevSchema =
      prevNode && inferType(prevNode) === form.type ? prevNode.schema : undefined;
    const node: OtaPropertyNode = {
      description: form.description.trim() || `Configuration for ${targetName}`,
      default_value: parsed.value,
      schema: { ...(prevSchema ?? {}), type: form.type },
    };
    setDraft((d) => ({ ...d, [targetName]: node }));
    setDirty(true);
    setDialogOpen(false);
  };

  const removeProp = (name: string) => {
    setDraft((d) => {
      const next = { ...d };
      delete next[name];
      return next;
    });
    setDirty(true);
  };

  const discard = () => {
    setDraft(schemaQuery.data?.properties ?? {});
    setDirty(false);
  };

  const save = () => {
    putMutation.mutate({ ...draft }, { onSuccess: () => setDirty(false) });
  };

  // ── JSON tab ─────────────────────────────────────────────────────
  const [jsonText, setJsonText] = useState('');
  const [jsonError, setJsonError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    if (tab === 'json') {
      setJsonText(JSON.stringify(draft, null, 2));
      setJsonError(null);
    }
  }, [tab, draft]);

  const applyJson = () => {
    let parsedJson: unknown;
    try {
      parsedJson = JSON.parse(jsonText);
    } catch (e: any) {
      setJsonError(e?.message || 'Invalid JSON');
      return;
    }
    if (typeof parsedJson !== 'object' || parsedJson === null || Array.isArray(parsedJson)) {
      setJsonError('Top level must be an object mapping property names to nodes');
      return;
    }
    for (const [k, v] of Object.entries(parsedJson)) {
      // Wire names are bare — the server namespaces every key as
      // "config.properties.<name>"; a pasted pre-prefixed key double-prefixes.
      if (/\s/.test(k)) {
        setJsonError(`"${k}": property names cannot contain spaces`);
        return;
      }
      if (k.startsWith('config.properties.')) {
        setJsonError(`"${k}": use the bare key — no config.properties. prefix`);
        return;
      }
      if (typeof v !== 'object' || v === null || Array.isArray(v)) {
        setJsonError(`"${k}": node must be an object`);
        return;
      }
      const node = v as Record<string, unknown>;
      if (typeof node.description !== 'string') {
        setJsonError(`"${k}": "description" must be a string`);
        return;
      }
      if (typeof node.schema !== 'object' || node.schema === null || Array.isArray(node.schema)) {
        setJsonError(`"${k}": "schema" must be an object`);
        return;
      }
      if (!('default_value' in node)) {
        setJsonError(`"${k}": "default_value" is required`);
        return;
      }
    }
    setJsonError(null);
    setDraft(parsedJson as Record<string, OtaPropertyNode>);
    setDirty(true);
  };

  const copyJson = () => {
    navigator.clipboard
      .writeText(jsonText)
      .then(() => {
        setCopied(true);
        window.setTimeout(() => setCopied(false), 1500);
      })
      .catch(() => {});
  };

  // ── Context preview ──────────────────────────────────────────────
  const [ctxInput, setCtxInput] = useState('');
  const [previewCtx, setPreviewCtx] = useState('');
  const previewQuery = useOtaPropertiesSchema(app, previewCtx || undefined);
  const previewNames = useMemo(
    () => Object.keys(previewQuery.data?.properties ?? {}).sort(),
    [previewQuery.data],
  );

  // Reset all draft/dialog state on app switch — the page stays mounted
  // across sidebar app changes, and a dirty draft must never carry into
  // another app's full-replace PUT.
  useEffect(() => {
    setDraft({});
    setDirty(false);
    setSeeded(false);
    setDialogOpen(false);
    setEditingName(null);
    setTab('properties');
    setPreviewCtx('');
    setCtxInput('');
    // Reacts only to the app segment changing — the setters above are stable.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [app]);

  const snapshots = listQuery.data?.properties ?? [];

  return (
    <div className="flex flex-col flex-1 w-full pb-12 space-y-4">
      <OtaAppHeader app={app!} title="Remote Config" />

      {/* Tabs */}
      <div className="flex items-center gap-1 border-b border-zinc-200 dark:border-zinc-800">
        {TABS.map((t) => (
          <button
            key={t.id}
            type="button"
            onClick={() => setTab(t.id)}
            className={cn(
              'px-3 py-2 text-sm font-medium -mb-px cursor-pointer transition-colors duration-150',
              tab === t.id
                ? 'text-airborne border-b-2 border-airborne'
                : 'text-zinc-500 hover:text-zinc-800 dark:text-zinc-400 dark:hover:text-zinc-200 border-b-2 border-transparent',
            )}
          >
            {t.label}
          </button>
        ))}
      </div>

      {canManage && tab !== 'snapshots' && (
        <div className="rounded-xl border border-amber-200 bg-amber-50 dark:border-amber-900 dark:bg-amber-950/40 px-4 py-3 flex items-start gap-2.5">
          <TriangleAlert className="w-4 h-4 text-amber-600 dark:text-amber-400 mt-0.5 shrink-0" />
          <div className="text-sm text-amber-800 dark:text-amber-300">
            Saving replaces the entire schema — properties removed here are deleted upstream.
            Values shown are resolved for the current context; if a live release overrides a
            property, saving can persist its override as the new stored default.
          </div>
        </div>
      )}

      {/* Properties tab */}
      {tab === 'properties' && (
        <>
          <div className={cardCls}>
            <header className={cardHeaderCls}>
              <div className="flex items-center gap-2 shrink-0">
                <h2 className="text-sm font-semibold text-zinc-900 dark:text-zinc-100">Properties</h2>
                <span className="text-xs text-zinc-500 dark:text-zinc-400">{names.length}</span>
              </div>
              <div className="flex items-center gap-2 flex-wrap justify-end">
                <div className="w-52">
                  <Input
                    value={ctxInput}
                    onChange={(e) => setCtxInput(e.target.value)}
                    placeholder="preview context k=v;k2=v2"
                    className={cn('font-mono text-xs', fieldDark)}
                  />
                </div>
                <Button
                  variant="secondary"
                  size="sm"
                  className={secondaryBtnDark}
                  disabled={!previewCtx && ctxInput.trim() === ''}
                  onClick={() => setPreviewCtx(previewCtx ? '' : ctxInput.trim())}
                >
                  {previewCtx ? 'Hide preview' : 'Preview'}
                </Button>
                {dirty && (
                  <Button
                    variant="ghost"
                    size="sm"
                    className="dark:text-zinc-400 dark:hover:bg-zinc-800"
                    onClick={discard}
                  >
                    Discard
                  </Button>
                )}
                {canManage && (
                  <Button size="sm" className={primaryBtnDark} disabled={!seeded} onClick={openAdd}>
                    <Plus className="w-4 h-4" />
                    Add Property
                  </Button>
                )}
                {canManage && (
                  <Button
                    size="sm"
                    className={primaryBtnDark}
                    disabled={!dirty || !seeded}
                    loading={putMutation.isPending}
                    onClick={save}
                  >
                    Save Changes
                  </Button>
                )}
              </div>
            </header>

            {schemaQuery.error && !schemaQuery.data ? (
              <div className="px-4 py-6 text-sm text-red-600 dark:text-red-400">
                Failed to load the properties schema. Refresh to retry.
              </div>
            ) : schemaQuery.isLoading ? (
              <div className="dark:invert">
                <TableSkeleton rows={6} cols={4} />
              </div>
            ) : names.length === 0 ? (
              <div className="py-16 text-center text-zinc-400 dark:text-zinc-500 text-sm">
                No properties defined yet.
              </div>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-left">
                  <thead>
                    <tr className="bg-zinc-50 border-b border-zinc-200 dark:bg-zinc-800/50 dark:border-zinc-800 text-[11px] text-zinc-500 dark:text-zinc-500 font-medium uppercase tracking-wider">
                      <th className="py-3 px-4">Name</th>
                      <th className="py-3 px-4">Type</th>
                      <th className="py-3 px-4">Default</th>
                      <th className="py-3 px-4">Description</th>
                      {canManage && <th className="py-3 px-4 w-24 text-right">Actions</th>}
                    </tr>
                  </thead>
                  <tbody className="text-sm">
                    {names.map((name) => {
                      const node = draft[name];
                      const type = typeof node.schema?.type === 'string' ? node.schema.type : null;
                      const dvStr = JSON.stringify(node.default_value);
                      return (
                        <tr key={name} className="border-b border-zinc-100 dark:border-zinc-800">
                          <td className="py-3 px-4 font-mono text-xs text-zinc-700 dark:text-zinc-300">
                            {name}
                          </td>
                          <td className="py-3 px-4 text-zinc-700 dark:text-zinc-300">
                            {type ? <Badge variant="default">{type}</Badge> : '—'}
                          </td>
                          <td
                            className="py-3 px-4 font-mono text-xs text-zinc-700 dark:text-zinc-300"
                            title={dvStr}
                          >
                            {dvStr != null ? truncate(dvStr, 40) : '—'}
                          </td>
                          <td className="py-3 px-4 text-zinc-700 dark:text-zinc-300">
                            {node.description || '—'}
                          </td>
                          {canManage && (
                            <td className="py-3 px-4">
                              <div className="flex items-center justify-end gap-1">
                                <Button
                                  variant="ghost"
                                  size="icon-sm"
                                  className="dark:text-zinc-400 dark:hover:bg-zinc-800"
                                  onClick={() => openEdit(name)}
                                  aria-label={`Edit ${name}`}
                                >
                                  <Pencil className="w-3.5 h-3.5" />
                                </Button>
                                <Button
                                  variant="ghost"
                                  size="icon-sm"
                                  className="text-red-500 hover:bg-red-50 dark:text-red-400 dark:hover:bg-red-950/40"
                                  onClick={() => removeProp(name)}
                                  aria-label={`Remove ${name}`}
                                >
                                  <Trash2 className="w-3.5 h-3.5" />
                                </Button>
                              </div>
                            </td>
                          )}
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </div>

          {/* Resolved-values preview for a dimension context */}
          {previewCtx && (
            <div className={cardCls}>
              <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100 dark:border-zinc-800">
                <h3 className="text-sm font-semibold text-zinc-900 dark:text-zinc-100">
                  Resolved values for <span className="font-mono text-xs">{previewCtx}</span>
                </h3>
              </header>
              {previewQuery.error && !previewQuery.data ? (
                <div className="px-4 py-4 text-sm text-red-600 dark:text-red-400">
                  Failed to resolve values for this context.
                </div>
              ) : previewQuery.isLoading ? (
                <div className="px-4 py-4 text-sm text-zinc-500 dark:text-zinc-400">Resolving…</div>
              ) : previewNames.length === 0 ? (
                <div className="py-8 text-center text-zinc-400 dark:text-zinc-500 text-sm">
                  No properties resolved for this context.
                </div>
              ) : (
                <div className="divide-y divide-zinc-100 dark:divide-zinc-800">
                  {previewNames.map((name) => (
                    <div
                      key={name}
                      className="px-4 py-2 sm:px-6 flex items-center justify-between gap-3 text-xs"
                    >
                      <span className="font-mono text-zinc-700 dark:text-zinc-300 truncate">
                        {name}
                      </span>
                      <span
                        className="font-mono text-zinc-500 dark:text-zinc-400 truncate"
                        title={JSON.stringify(previewQuery.data?.properties?.[name]?.default_value)}
                      >
                        {JSON.stringify(previewQuery.data?.properties?.[name]?.default_value) ?? '—'}
                      </span>
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}
        </>
      )}

      {/* JSON tab */}
      {tab === 'json' && (
        <div className={cardCls}>
          <header className={cardHeaderCls}>
            <h2 className="text-sm font-semibold text-zinc-900 dark:text-zinc-100">
              Draft schema JSON
            </h2>
            <div className="flex items-center gap-2">
              <Button variant="secondary" size="sm" className={secondaryBtnDark} onClick={copyJson}>
                {copied ? 'Copied' : 'Copy'}
              </Button>
              {canManage && (
                <Button size="sm" className={primaryBtnDark} disabled={!seeded} onClick={applyJson}>
                  Apply JSON
                </Button>
              )}
            </div>
          </header>
          {schemaQuery.error && !schemaQuery.data ? (
            <div className="px-4 py-6 text-sm text-red-600 dark:text-red-400">
              Failed to load the properties schema. Refresh to retry.
            </div>
          ) : schemaQuery.isLoading ? (
            <div className="dark:invert">
              <TableSkeleton rows={6} cols={4} />
            </div>
          ) : (
            <div className="p-4 sm:p-6 space-y-2">
              {jsonError && <p className="text-xs text-red-600 dark:text-red-400">{jsonError}</p>}
              <textarea
                value={jsonText}
                onChange={(e) => {
                  setJsonText(e.target.value);
                  setJsonError(null);
                }}
                readOnly={!canManage}
                spellCheck={false}
                aria-label="Draft schema JSON"
                className={cn(
                  'w-full min-h-96 rounded-lg border border-zinc-300 bg-white px-3 py-2 font-mono text-xs text-zinc-900',
                  'focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent',
                  fieldDark,
                )}
              />
              {canManage && (
                <p className="text-xs text-zinc-500 dark:text-zinc-400">
                  Apply updates the local draft only — use Save Changes on the Properties tab to
                  persist.
                </p>
              )}
            </div>
          )}
        </div>
      )}

      {/* Snapshots tab */}
      {tab === 'snapshots' && (
        <div className={cardCls}>
          <header className={cardHeaderCls}>
            <div className="flex items-center gap-2">
              <h2 className="text-sm font-semibold text-zinc-900 dark:text-zinc-100">Snapshots</h2>
              <span className="text-xs text-zinc-500 dark:text-zinc-400">{snapshots.length}</span>
            </div>
          </header>
          {listQuery.error && !listQuery.data ? (
            <div className="px-4 py-6 text-sm text-red-600 dark:text-red-400">
              Failed to load property snapshots. Refresh to retry.
            </div>
          ) : listQuery.isLoading ? (
            <div className="dark:invert">
              <TableSkeleton rows={6} cols={4} />
            </div>
          ) : snapshots.length === 0 ? (
            <div className="py-16 text-center text-zinc-400 dark:text-zinc-500 text-sm">
              No property snapshots for this app.
            </div>
          ) : (
            <div className="divide-y divide-zinc-100 dark:divide-zinc-800">
              {snapshots.map((exp, i) => (
                <div key={exp.experiment_id ?? i} className="px-4 py-3 sm:px-6 space-y-2">
                  <div className="flex items-center gap-2 flex-wrap">
                    <span
                      className="font-mono text-xs text-zinc-700 dark:text-zinc-300"
                      title={exp.experiment_id}
                    >
                      {exp.experiment_id ? truncate(exp.experiment_id, 12) : '—'}
                    </span>
                    {exp.status && <Badge variant={statusVariant(exp.status)}>{exp.status}</Badge>}
                    {Object.entries(exp.dimensions ?? {}).map(([k, v]) => (
                      <Badge key={k} variant="muted" className="normal-case">
                        {k}={fmtVal(v)}
                      </Badge>
                    ))}
                  </div>
                  <details className="text-xs">
                    <summary className="cursor-pointer text-zinc-500 dark:text-zinc-400 select-none">
                      Properties
                    </summary>
                    <div className="overflow-x-auto">
                      <pre className="mt-2 font-mono text-xs text-zinc-700 dark:text-zinc-300 bg-zinc-50 dark:bg-zinc-800/50 rounded-lg p-3">
                        {JSON.stringify(exp.properties ?? {}, null, 2)}
                      </pre>
                    </div>
                  </details>
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      {/* Add / Edit property dialog */}
      <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
        <DialogContent size="md" className={cn(isDark && dialogDark)}>
          <DialogHeader>
            <DialogTitle className="dark:text-zinc-100">
              {editingName != null ? 'Edit property' : 'Add property'}
            </DialogTitle>
            <DialogDescription className="dark:text-zinc-400">
              Properties are bare dotted keys resolved by the SDK at runtime.
            </DialogDescription>
          </DialogHeader>
          <DialogBody className="space-y-4">
            <Input
              label="Name"
              value={form.name}
              onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))}
              disabled={editingName != null}
              error={nameError}
              hint={
                editingName != null
                  ? undefined
                  : 'Bare dotted key, e.g. payment.retry_count — no config.properties. prefix'
              }
              required
              className={cn('font-mono', fieldDark)}
            />
            <SelectInput
              label="Type"
              value={form.type}
              onChange={(e) => setForm((f) => ({ ...f, type: e.target.value as PropType }))}
              options={TYPE_OPTIONS}
              className={fieldDark}
            />
            <Input
              label="Description"
              value={form.description}
              onChange={(e) => setForm((f) => ({ ...f, description: e.target.value }))}
              hint={`Defaults to "Configuration for ${targetName || '<name>'}" when left empty`}
              className={fieldDark}
            />
            {form.type === 'boolean' ? (
              <SelectInput
                label="Default value"
                value={form.defaultRaw === 'false' ? 'false' : 'true'}
                onChange={(e) => setForm((f) => ({ ...f, defaultRaw: e.target.value }))}
                options={[
                  { value: 'true', label: 'true' },
                  { value: 'false', label: 'false' },
                ]}
                className={fieldDark}
              />
            ) : form.type === 'number' ? (
              <Input
                label="Default value"
                type="number"
                value={form.defaultRaw}
                onChange={(e) => setForm((f) => ({ ...f, defaultRaw: e.target.value }))}
                error={defaultError}
                required
                className={fieldDark}
              />
            ) : form.type === 'string' ? (
              <Input
                label="Default value"
                value={form.defaultRaw}
                onChange={(e) => setForm((f) => ({ ...f, defaultRaw: e.target.value }))}
                className={fieldDark}
              />
            ) : (
              <Textarea
                label="Default value (JSON)"
                value={form.defaultRaw}
                onChange={(e) => setForm((f) => ({ ...f, defaultRaw: e.target.value }))}
                rows={5}
                error={defaultError}
                hint={form.type === 'array' ? 'JSON array, e.g. [1, 2, 3]' : 'JSON object, e.g. {"key": "value"}'}
                spellCheck={false}
                required
                className={cn('font-mono text-xs', fieldDark)}
              />
            )}
          </DialogBody>
          <DialogFooter className="dark:bg-zinc-900 dark:border-zinc-800">
            <Button variant="secondary" className={secondaryBtnDark} onClick={() => setDialogOpen(false)}>
              Cancel
            </Button>
            <Button
              variant="primary"
              className={primaryBtnDark}
              disabled={!canSubmitDialog}
              onClick={submitDialog}
            >
              {editingName != null ? 'Save property' : 'Add property'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
