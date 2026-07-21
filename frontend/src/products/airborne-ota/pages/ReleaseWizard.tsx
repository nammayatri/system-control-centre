import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { ArrowLeft, ChevronDown, ChevronLeft, ChevronRight, Info, Lock, Plus, Search, Trash2 } from 'lucide-react';
import { toast } from 'sonner';
import {
  useCreateOtaRelease,
  useOtaAllFiles,
  useOtaAllPackages,
  useOtaCohort,
  useOtaDimensions,
  useOtaPackageDetail,
  useOtaPropertiesSchema,
  useOtaRelease,
  useOtaReleases,
  useUpdateOtaRelease,
} from '../hooks';
import { otaFileKey, otaPackageId, otaResourceKey } from '../keys';
import type { OtaCreateReleaseReq, OtaDimension, OtaFile, OtaRelease } from '../types';
import { OtaPickList } from '../components/OtaPickList';
import type { OtaPickOption } from '../components/OtaPickList';
import { Button } from '../../../shared/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '../../../shared/ui/card';
import { Input, SelectInput, Textarea } from '../../../shared/ui/input';
import { MultiSelect } from '../../../shared/ui/multi-select';
import type { MultiSelectOption } from '../../../shared/ui/multi-select';
import { Skeleton } from '../../../shared/ui/skeleton';
import {
  Dialog,
  DialogBody,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '../../../shared/ui/dialog';
import { useOtaTheme } from '../theme';
import { cn } from '../../../lib/utils';

type WizardMode = 'create' | 'edit' | 'clone';

const fieldDark = 'dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-100';
const primaryBtnDark = 'bg-airborne border-airborne text-white hover:bg-airborne-hover';
const secondaryBtnDark = 'dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800';
const cardDark = 'dark:bg-zinc-900 dark:border-zinc-800';
// Dialog portals out of the .dark subtree — re-enter dark scope on the content.
const dialogDark = 'dark bg-zinc-900 border-zinc-800 sm:border-zinc-800';

const TITLES: Record<WizardMode, string> = {
  create: 'New OTA Release',
  edit: 'Edit OTA Release',
  clone: 'Clone OTA Release',
};

// Created-release id, tolerant to upstream shape drift.
function createdReleaseId(r: OtaRelease): string | null {
  const candidates = [r.id, (r as Record<string, unknown>).release_id, r.experiment?.experiment_id];
  for (const c of candidates) if (typeof c === 'string' && c) return c;
  return null;
}

// Resolve a split entry (key string or Resource/ServeFile object) to a file
// key; bare paths are matched against the package's keyed file list.
function resolveSplitKey(entry: unknown, pkgFiles: string[]): string | null {
  const direct = otaResourceKey(entry);
  if (direct && direct.includes('@')) return direct;
  const path =
    typeof entry === 'string'
      ? entry
      : entry && typeof entry === 'object'
        ? (entry as OtaFile).file_path
        : undefined;
  if (path) return pkgFiles.find((k) => k.split('@')[0] === path) ?? null;
  return null;
}

// One toast per session even if resources and split both drop keys.
function warnDroppedKeys() {
  toast.warning('Some resources/files could not be resolved and were dropped — re-select them.', {
    id: 'ota-prefill-dropped',
  });
}

interface TargetRule {
  dim: string;
  value: string;
}

// A release's dimensions object ({dim: scalar | array}) flattened to editor rows.
function dimensionsToRules(dims: Record<string, unknown>): TargetRule[] {
  const rules: TargetRule[] = [];
  for (const [dim, v] of Object.entries(dims)) {
    if (Array.isArray(v)) for (const el of v) rules.push({ dim, value: String(el) });
    else rules.push({ dim, value: String(v) });
  }
  return rules;
}

function rulesToDimensions(rules: TargetRule[]): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const r of rules) {
    const value = r.value.trim();
    if (!r.dim || !value) continue;
    const existing = out[r.dim];
    if (existing === undefined) out[r.dim] = value;
    else if (Array.isArray(existing)) (existing as unknown[]).push(value);
    else out[r.dim] = [existing, value];
  }
  return out;
}

// One row of the targeting editor. Cohort dimensions swap the free-text value
// for the cohort enum (fetched lazily per row — this is a component so the
// hook count stays stable per rule).
function TargetRuleRow({
  app,
  rule,
  dims,
  onChange,
  onRemove,
}: {
  app: string;
  rule: TargetRule;
  dims: OtaDimension[];
  onChange: (r: TargetRule) => void;
  onRemove: () => void;
}) {
  const meta = dims.find((d) => d.dimension === rule.dim);
  const isCohort = meta?.dimension_type === 'cohort';
  const cohortQuery = useOtaCohort(isCohort ? app : undefined, isCohort ? rule.dim : undefined);
  const cohortValues = cohortQuery.data?.enum ?? [];

  return (
    <div className="flex items-center gap-2">
      <div className="w-48 shrink-0">
        <SelectInput
          className={fieldDark}
          value={rule.dim}
          onChange={(e) => onChange({ dim: e.target.value, value: '' })}
          aria-label="Dimension"
          placeholder="Select dimension…"
          options={dims.map((d) => ({
            value: d.dimension,
            label: d.dimension + (d.dimension_type === 'cohort' ? ' (cohort)' : ''),
          }))}
        />
      </div>
      <span className="text-xs text-zinc-400 dark:text-zinc-500 shrink-0">equals</span>
      <div className="flex-1 min-w-0">
        {isCohort ? (
          <SelectInput
            className={fieldDark}
            value={rule.value}
            onChange={(e) => onChange({ ...rule, value: e.target.value })}
            aria-label="Cohort value"
            placeholder={cohortQuery.isLoading ? 'Loading cohorts…' : 'Select cohort…'}
            options={cohortValues.map((c) => ({ value: c, label: c }))}
          />
        ) : (
          <Input
            className={fieldDark}
            value={rule.value}
            onChange={(e) => onChange({ ...rule, value: e.target.value })}
            placeholder="Value"
            aria-label="Value"
            error={rule.value.includes(';') ? "Can't contain ';'" : undefined}
          />
        )}
      </div>
      <Button
        variant="secondary"
        size="icon-sm"
        className={secondaryBtnDark}
        onClick={onRemove}
        aria-label="Remove rule"
      >
        <Trash2 className="w-4 h-4" />
      </Button>
    </div>
  );
}

const SPLIT_PER_PAGE = 10;

const keyPath = (k: string) => k.split('@')[0] || k;
const keyVersion = (k: string): string => {
  const m = /@version:(\d+)$/.exec(k);
  if (m) return m[1];
  const t = /@tag:(.+)$/.exec(k);
  return t ? `tag:${t[1]}` : '—';
};

// 1 … cur-1 cur cur+1 … total, airborne-style numbered pagination.
function pageItems(cur: number, total: number): (number | '…')[] {
  if (total <= 7) return Array.from({ length: total }, (_, i) => i + 1);
  const keep = [...new Set([1, total, cur - 1, cur, cur + 1])]
    .filter((n) => n >= 1 && n <= total)
    .sort((a, b) => a - b);
  const out: (number | '…')[] = [];
  let prev = 0;
  for (const n of keep) {
    if (n - prev > 1) out.push('…');
    out.push(n);
    prev = n;
  }
  return out;
}

function SummaryRow({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex items-start justify-between gap-4 px-3 py-2">
      <span className="text-xs text-zinc-500 dark:text-zinc-400 shrink-0">{label}</span>
      <span className="text-xs text-zinc-800 dark:text-zinc-200 text-right break-all min-w-0">
        {value}
      </span>
    </div>
  );
}

// Card whose body collapses. Config/Resources start closed so the form leads
// with the two decisions that actually matter (package + targeting).
function CollapsibleCard({
  title,
  subtitle,
  open,
  onToggle,
  summary,
  children,
}: {
  title: string;
  subtitle?: string;
  open: boolean;
  onToggle: () => void;
  summary?: string;
  children: React.ReactNode;
}) {
  return (
    <Card className={cardDark}>
      <button
        type="button"
        onClick={onToggle}
        aria-expanded={open}
        className="w-full flex items-center gap-3 px-4 py-3 sm:px-6 sm:py-4 text-left cursor-pointer"
      >
        <ChevronDown
          className={cn(
            'w-4 h-4 text-zinc-400 dark:text-zinc-500 shrink-0 transition-transform duration-150',
            !open && '-rotate-90',
          )}
        />
        <span className="flex-1 min-w-0">
          <span className="block text-sm font-semibold text-zinc-900 dark:text-zinc-100">{title}</span>
          {subtitle && (
            <span className="block text-xs text-zinc-500 dark:text-zinc-400 mt-0.5">{subtitle}</span>
          )}
        </span>
        {!open && summary && (
          <span className="text-xs text-zinc-500 dark:text-zinc-400 shrink-0">{summary}</span>
        )}
      </button>
      {open && <CardContent className="space-y-4">{children}</CardContent>}
    </Card>
  );
}

function ReleaseWizard({ mode }: { mode: WizardMode }) {
  const { app, releaseId } = useParams<{ app: string; releaseId: string }>();
  const navigate = useNavigate();

  const packagesQuery = useOtaAllPackages(app);
  const filesQuery = useOtaAllFiles(app);
  // Prefill source for edit/clone; disabled in create (no releaseId in the route).
  const releaseQuery = useOtaRelease(app, mode === 'create' ? undefined : releaseId);

  const createMutation = useCreateOtaRelease(app);
  const updateMutation = useUpdateOtaRelease(app);

  const [packageId, setPackageId] = useState('');
  // 0 = no boot timeout, matching the release-config-timeout default below.
  const [bootTimeout, setBootTimeout] = useState('0');
  // Airborne treats 0 as "no release-config timeout" — the safe default here.
  const [releaseConfigTimeout, setReleaseConfigTimeout] = useState('0');
  const [propertiesText, setPropertiesText] = useState('');
  const [resources, setResources] = useState<string[]>([]);
  const [important, setImportant] = useState<string[]>([]);
  const [lazy, setLazy] = useState<string[]>([]);
  // Package the split is initialised for — gates submit, resets on change.
  const [splitPkg, setSplitPkg] = useState<string | null>(null);
  // Raw split from the loaded release, resolved once its package files arrive.
  const [pendingSplit, setPendingSplit] = useState<{
    pkg: string;
    important: unknown[];
    lazy: unknown[];
  } | null>(null);
  // Raw dimensions from the loaded release — edit mode resubmits these
  // verbatim (targeting is immutable after create; clone is the retarget path).
  const [dimensions, setDimensions] = useState<Record<string, unknown> | null>(null);
  // Editable targeting rules (create/clone).
  const [rules, setRules] = useState<TargetRule[]>([]);
  const [prefilled, setPrefilled] = useState(false);
  // Snapshot of the targeting context to seed properties from the schema.
  const [seedCtx, setSeedCtx] = useState<string | null>(null);
  const [configOpen, setConfigOpen] = useState(false);
  const [resourcesOpen, setResourcesOpen] = useState(false);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const { isDark } = useOtaTheme();

  const pkgDetailQuery = useOtaPackageDetail(app, packageId || undefined);
  const dimsQuery = useOtaDimensions(app);
  // First-release rule: an untargeted first release is mandatory upstream.
  const existingQuery = useOtaReleases(mode === 'create' ? app : undefined, { page: 1, count: 1 });
  const seedQuery = useOtaPropertiesSchema(seedCtx != null ? app : undefined, seedCtx || undefined);

  const release = releaseQuery.data;

  // One-shot prefill once the release arrives (edit/clone only).
  useEffect(() => {
    if (mode === 'create' || prefilled || !release) return;
    const cfg = release.config;
    if (typeof cfg?.boot_timeout === 'number') setBootTimeout(String(cfg.boot_timeout));
    if (typeof cfg?.release_config_timeout === 'number')
      setReleaseConfigTimeout(String(cfg.release_config_timeout));
    if (cfg?.properties && typeof cfg.properties === 'object' && !Array.isArray(cfg.properties)) {
      setPropertiesText(JSON.stringify(cfg.properties, null, 2));
    }
    const pkgVersion = release.package?.version ?? release.experiment?.package_version;
    let pkgId = '';
    if (pkgVersion != null) pkgId = `version:${pkgVersion}`;
    else if (release.package?.tag) pkgId = `tag:${release.package.tag}`;
    if (pkgId) setPackageId(pkgId);
    // Explicit important/lazy split, resolved later against the package files.
    const relPkg = release.package;
    const imp = relPkg && Array.isArray(relPkg.important) ? (relPkg.important as unknown[]) : null;
    const laz = relPkg && Array.isArray(relPkg.lazy) ? (relPkg.lazy as unknown[]) : null;
    if (pkgId && (imp || laz)) setPendingSplit({ pkg: pkgId, important: imp ?? [], lazy: laz ?? [] });
    const res = Array.isArray(release.resources) ? release.resources : [];
    const resKeys = res.map(otaResourceKey).filter((k): k is string => !!k && k.includes('@'));
    if (resKeys.length < res.length) warnDroppedKeys();
    setResources(resKeys);
    const dims = release.dimensions;
    if (dims && typeof dims === 'object' && !Array.isArray(dims)) {
      setDimensions(dims as Record<string, unknown>);
      setRules(dimensionsToRules(dims as Record<string, unknown>));
    }
    setPrefilled(true);
  }, [mode, prefilled, release]);

  // Apply schema defaults (resolved for the snapshotted targeting context)
  // into the properties JSON once the seed fetch lands.
  useEffect(() => {
    if (seedCtx == null) return;
    if (seedQuery.error) {
      toast.error('Failed to load the remote-config schema');
      setSeedCtx(null);
      return;
    }
    if (!seedQuery.data) return;
    const props = seedQuery.data.properties ?? {};
    if (Object.keys(props).length === 0) {
      toast.info('No properties defined in the remote-config schema for this app');
    } else {
      const values = Object.fromEntries(
        Object.entries(props).map(([k, node]) => [k, node.default_value]),
      );
      setPropertiesText(JSON.stringify(values, null, 2));
      toast.success('Properties filled from the remote-config schema');
    }
    setSeedCtx(null);
  }, [seedCtx, seedQuery.data, seedQuery.error]);

  // Seed or reset the important/lazy split once the package's file list is known.
  useEffect(() => {
    if (!packageId || !pkgDetailQuery.data || splitPkg === packageId) return;
    const pkgFiles = (pkgDetailQuery.data.files ?? []).filter((k) => typeof k === 'string' && !!k);
    if (pendingSplit && pendingSplit.pkg === packageId) {
      const resolve = (arr: unknown[]) =>
        arr.map((e) => resolveSplitKey(e, pkgFiles)).filter((k): k is string => !!k);
      const imp = resolve(pendingSplit.important);
      const laz = resolve(pendingSplit.lazy);
      if (imp.length + laz.length < pendingSplit.important.length + pendingSplit.lazy.length) {
        warnDroppedKeys();
      }
      setImportant(imp);
      setLazy(laz);
      setPendingSplit(null);
    } else {
      // Airborne's no-split default: everything important, nothing lazy.
      setImportant(pkgFiles);
      setLazy([]);
    }
    setSplitPkg(packageId);
  }, [packageId, pkgDetailQuery.data, splitPkg, pendingSplit]);

  // The two split lists are exclusive: picking on one side leaves the other.
  // Priority per file key: everything is Important unless explicitly Lazy
  // (airborne's default). Flipping keeps the two arrays disjoint.
  const priorityOf = (k: string): 'important' | 'lazy' => (lazy.includes(k) ? 'lazy' : 'important');
  const setPriority = (k: string, p: 'important' | 'lazy') => {
    if (p === 'lazy') {
      setImportant((prev) => prev.filter((v) => v !== k));
      setLazy((prev) => (prev.includes(k) ? prev : [...prev, k]));
    } else {
      setLazy((prev) => prev.filter((v) => v !== k));
      setImportant((prev) => (prev.includes(k) ? prev : [...prev, k]));
    }
  };
  const [splitSearch, setSplitSearch] = useState('');
  const [splitPage, setSplitPage] = useState(1);
  // Fresh package = fresh table view.
  useEffect(() => {
    setSplitSearch('');
    setSplitPage(1);
  }, [packageId]);

  const packageOptions = useMemo<OtaPickOption[]>(() => {
    const pkgs = packagesQuery.data?.data ?? [];
    const opts: OtaPickOption[] = [];
    for (const p of pkgs) {
      const id = otaPackageId(p);
      if (!id) continue;
      const label = p.version != null ? `v${p.version}${p.tag ? ` · ${p.tag}` : ''}` : `tag: ${p.tag}`;
      opts.push({ value: id, label, hint: p.index });
    }
    return opts;
  }, [packagesQuery.data]);

  const resourceOptions = useMemo<MultiSelectOption[]>(() => {
    const files = filesQuery.data?.files ?? [];
    const opts: MultiSelectOption[] = [];
    const known = new Set<string>();
    for (const f of files) {
      const key = otaFileKey(f);
      if (!key || known.has(key)) continue;
      known.add(key);
      opts.push({ value: key, label: f.file_path || key, hint: key });
    }
    // Prefilled keys missing from the current files page still get chips.
    for (const v of resources) {
      if (!known.has(v)) opts.push({ value: v, label: v });
    }
    return opts;
  }, [filesQuery.data, resources]);

  // Package file list for the priorities table; tolerant union with any
  // prefilled split keys the pkg detail no longer lists (edit/clone).
  const splitKeys = useMemo<string[]>(() => {
    const out: string[] = [];
    const known = new Set<string>();
    const push = (v: unknown) => {
      if (typeof v === 'string' && v && !known.has(v)) {
        known.add(v);
        out.push(v);
      }
    };
    for (const f of pkgDetailQuery.data?.files ?? []) push(f);
    for (const v of important) push(v);
    for (const v of lazy) push(v);
    return out;
  }, [pkgDetailQuery.data, important, lazy]);

  const splitFiltered = splitKeys.filter((k) =>
    keyPath(k).toLowerCase().includes(splitSearch.trim().toLowerCase()),
  );
  const splitTotalPages = Math.max(1, Math.ceil(splitFiltered.length / SPLIT_PER_PAGE));
  const splitSafePage = Math.min(splitPage, splitTotalPages);
  const splitPageKeys = splitFiltered.slice(
    (splitSafePage - 1) * SPLIT_PER_PAGE,
    splitSafePage * SPLIT_PER_PAGE,
  );

  // Airborne clamps the files list at 200/page — warn when the picker is short.
  const filesTotal = filesQuery.data?.total;
  const filesLoaded = filesQuery.data?.files?.length ?? 0;
  const filesClamped = filesTotal != null && filesTotal > filesLoaded;

  const dimList = dimsQuery.data?.data ?? [];
  // Gate on a successful fetch, not just "not loading" — a failed fetch also
  // has isLoading=false/data=undefined, which would otherwise misread as "no
  // releases exist" and silently submit an untargeted release.
  const firstReleaseUnknown = mode === 'create' && existingQuery.isError;
  const firstRelease =
    mode === 'create' &&
    existingQuery.data != null &&
    (existingQuery.data.total_items ?? existingQuery.data.data?.length ?? 0) === 0;
  // x-dimension context ("k=v;k2=v2") from the complete rules.
  const targetCtx = useMemo(
    () =>
      rules
        .filter((r) => r.dim && r.value.trim())
        .map((r) => `${r.dim}=${r.value.trim()}`)
        .join(';'),
    [rules],
  );

  const propertiesError = useMemo(() => {
    if (!propertiesText.trim()) return undefined;
    try {
      const parsed = JSON.parse(propertiesText);
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
        return 'Properties must be a JSON object';
      }
      return undefined;
    } catch {
      return 'Invalid JSON';
    }
  }, [propertiesText]);

  const timeoutError = (v: string) => {
    const n = Number(v);
    return v.trim() === '' || !Number.isInteger(n) || n < 0
      ? 'Must be a non-negative integer (ms)'
      : undefined;
  };
  const bootError = timeoutError(bootTimeout);
  const rctError = timeoutError(releaseConfigTimeout);

  const backPath =
    mode === 'create'
      ? `/airborne/${encodeURIComponent(app!)}/releases`
      : `/airborne/${encodeURIComponent(app!)}/releases/${encodeURIComponent(releaseId!)}`;

  const isPending = createMutation.isPending || updateMutation.isPending;
  // Split must be initialised for the selected package before submitting —
  // sending package_id without the split block 400s upstream.
  const splitReady = !!packageId && splitPkg === packageId;
  // ';' can never round-trip through the x-dimension "k=v;k2=v2" transport.
  const rulesInvalid = mode !== 'edit' && rules.some((r) => r.value.includes(';'));
  // A rule only counts once it has both halves.
  const completeRules = rules.filter((r) => r.dim && r.value.trim());
  // Targeting is REQUIRED, with two exceptions: the very first release for an
  // app cannot be targeted at all (upstream rule), and edit mode resubmits the
  // original dimensions untouched.
  const targetingRequired = mode !== 'edit' && !firstRelease;
  const targetingMissing = targetingRequired && completeRules.length === 0;
  const canSubmit =
    splitReady &&
    !propertiesError &&
    !bootError &&
    !rctError &&
    !isPending &&
    !firstReleaseUnknown &&
    !rulesInvalid &&
    !targetingMissing;

  // Validate, then ask for confirmation — the actual write happens in submit().
  const requestSubmit = () => {
    if (!packageId) {
      toast.error('Select a package for this release');
      return;
    }
    if (!splitReady) {
      toast.error('Package files are still loading — try again in a moment');
      return;
    }
    if (targetingMissing) {
      toast.error('Add at least one targeting rule for this release');
      return;
    }
    if (bootError || rctError || propertiesError) {
      toast.error('Fix the highlighted config fields first');
      return;
    }
    setConfirmOpen(true);
  };

  const submit = () => {
    setConfirmOpen(false);
    if (!packageId || !splitReady) return;
    const properties = propertiesText.trim()
      ? (JSON.parse(propertiesText) as Record<string, unknown>)
      : undefined;
    // Only well-formed "<path>@version:<n>"/"@tag:<t>" keys go upstream.
    const keyed = (ks: string[]) => ks.filter((k) => k.includes('@'));
    const cleanResources = keyed(resources);
    // Edit resubmits the original dimensions untouched (targeting is locked);
    // create/clone send the editor rules; a first release is never targeted.
    const dimObj =
      mode === 'edit' ? (dimensions ?? {}) : firstRelease ? {} : rulesToDimensions(rules);
    const body: OtaCreateReleaseReq = {
      config: {
        boot_timeout: Number(bootTimeout),
        release_config_timeout: Number(releaseConfigTimeout),
        ...(properties ? { properties } : {}),
      },
      package_id: packageId,
      package: { important: keyed(important), lazy: keyed(lazy) },
      ...(cleanResources.length > 0 ? { resources: cleanResources } : {}),
      ...(Object.keys(dimObj).length > 0 ? { dimensions: dimObj } : {}),
    };
    if (mode === 'edit') {
      updateMutation.mutate(
        { releaseId: releaseId!, body },
        { onSuccess: () => navigate(backPath) },
      );
    } else {
      createMutation.mutate(body, {
        onSuccess: (res) => {
          const id = createdReleaseId(res);
          navigate(
            id
              ? `/airborne/${encodeURIComponent(app!)}/releases/${encodeURIComponent(id)}`
              : `/airborne/${encodeURIComponent(app!)}/releases`,
          );
        },
      });
    }
  };

  // Prefill source still loading (edit/clone) — hold the form back.
  if (mode !== 'create' && releaseQuery.isLoading) {
    return (
      <div className="space-y-4 dark:invert pb-12">
        <Skeleton className="h-10 w-64" />
        <Skeleton className="h-64 w-full" />
        <Skeleton className="h-40 w-full" />
      </div>
    );
  }

  if (mode !== 'create' && releaseQuery.error && !release) {
    return (
      <div className="py-16 text-center text-sm text-red-600 dark:text-red-400">
        Failed to load the release to {mode}. It may not exist for this app.
      </div>
    );
  }

  return (
    <div className="flex flex-col flex-1 w-full pb-12 space-y-4">
      {/* Header */}
      <div className="flex items-center gap-3 min-w-0">
        <Link
          to={backPath}
          className="w-9 h-9 rounded-lg border border-zinc-200 bg-white text-zinc-500 hover:text-zinc-800 hover:bg-zinc-50 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100 dark:hover:bg-zinc-800 flex items-center justify-center shrink-0"
          aria-label="Back"
        >
          <ArrowLeft className="w-4 h-4" />
        </Link>
        <div className="min-w-0">
          <h1 className="text-base sm:text-lg font-semibold text-zinc-900 dark:text-zinc-100">
            {TITLES[mode]}
          </h1>
          {mode !== 'create' && (
            <p className="text-xs text-zinc-500 dark:text-zinc-400 font-mono truncate">{releaseId}</p>
          )}
        </div>
      </div>

      {/* Package */}
      <Card className={cardDark}>
        <CardHeader className="dark:border-zinc-800">
          <CardTitle className="dark:text-zinc-100">Package <span className="text-red-500">*</span></CardTitle>
        </CardHeader>
        <CardContent className="space-y-2">
          <OtaPickList
            label="Select the package this release serves"
            options={packageOptions}
            value={packageId}
            onChange={setPackageId}
            loading={packagesQuery.isLoading}
            error={packagesQuery.error ? 'Failed to load packages' : null}
            emptyText="No packages for this app — create one first."
            placeholder="Search by version, tag or index…"
          />
          {packageId && (
            <p className="text-xs text-zinc-500 dark:text-zinc-400">
              Selected: <span className="font-mono">{packageId}</span>
            </p>
          )}
        </CardContent>
      </Card>

      {/* Targeting */}
      <Card className={cardDark}>
        <CardHeader className="dark:border-zinc-800">
          <CardTitle className="dark:text-zinc-100">Targeting{targetingRequired && <span className="text-red-500 ml-1">*</span>}</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          {mode === 'edit' ? (
            <>
              <div className="flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50 dark:border-amber-500/30 dark:bg-amber-500/10 px-3 py-2.5 text-xs text-amber-800 dark:text-amber-300">
                <Lock className="w-3.5 h-3.5 mt-0.5 shrink-0" />
                <span>
                  Targeting cannot be changed when editing a release — it is resubmitted
                  unchanged. Clone the release to retarget.
                </span>
              </div>
              {rules.length > 0 ? (
                <div className="flex flex-wrap gap-1.5">
                  {rules.map((r, i) => (
                    <span
                      key={i}
                      className="inline-flex items-center rounded-md bg-zinc-100 dark:bg-zinc-800 px-2 py-1 text-xs font-mono text-zinc-700 dark:text-zinc-300"
                    >
                      {r.dim} = {r.value}
                    </span>
                  ))}
                </div>
              ) : (
                <p className="text-xs text-zinc-500 dark:text-zinc-400">
                  This release is untargeted — it applies to all users.
                </p>
              )}
            </>
          ) : firstReleaseUnknown ? (
            <div className="flex items-start gap-2 rounded-lg border border-red-200 bg-red-50 dark:border-red-500/30 dark:bg-red-500/10 px-3 py-2.5 text-xs text-red-800 dark:text-red-300">
              <span className="flex-1">
                Couldn't confirm whether this app already has releases — targeting can't be
                verified. Submit is disabled until this loads.
              </span>
              <Button
                variant="secondary"
                size="sm"
                className={secondaryBtnDark}
                onClick={() => existingQuery.refetch()}
              >
                Retry
              </Button>
            </div>
          ) : firstRelease ? (
            <p className="text-xs text-zinc-500 dark:text-zinc-400">
              Your first release can't be targeted — it goes to all users. Targeting becomes
              available once a release exists.
            </p>
          ) : (
            <>
              <p className="text-xs text-zinc-500 dark:text-zinc-400">
                Only users matching every rule get this release. At least one rule is required.
              </p>
              {targetingMissing && (
                <p className="text-xs text-red-600 dark:text-red-400">
                  Add at least one targeting rule before creating this release.
                </p>
              )}
              {rules.map((r, i) => (
                <TargetRuleRow
                  key={i}
                  app={app!}
                  rule={r}
                  dims={dimList}
                  onChange={(next) => setRules((prev) => prev.map((p, j) => (j === i ? next : p)))}
                  onRemove={() => setRules((prev) => prev.filter((_, j) => j !== i))}
                />
              ))}
              <Button
                variant="secondary"
                size="sm"
                className={secondaryBtnDark}
                onClick={() => setRules((prev) => [...prev, { dim: '', value: '' }])}
                disabled={dimsQuery.isLoading || dimList.length === 0}
              >
                <Plus className="w-4 h-4" />
                Add rule
              </Button>
              {!dimsQuery.isLoading && dimList.length === 0 && (
                <p className="text-xs text-zinc-500 dark:text-zinc-400">
                  No dimensions defined for this app — create them on the Dimensions page.
                </p>
              )}
            </>
          )}
        </CardContent>
      </Card>

      {/* Configure File Priorities — mirrors the airborne dashboard step */}
      {packageId && (
        <Card className={cardDark}>
          <CardHeader className="dark:border-zinc-800">
            <CardTitle className="dark:text-zinc-100">Configure File Priorities</CardTitle>
            <p className="text-sm text-zinc-500 dark:text-zinc-400 mt-0.5">
              Choose which files load immediately (important) vs on-demand (lazy)
            </p>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="flex items-center gap-2 rounded-lg border border-blue-200 bg-blue-50 dark:border-blue-500/30 dark:bg-blue-500/10 px-3 py-2.5 text-sm text-blue-800 dark:text-blue-300">
              <Info className="w-4 h-4 shrink-0" />
              All files default to Important. Switch to Lazy to defer loading.
            </div>

            {pkgDetailQuery.isLoading ? (
              <p className="py-8 text-center text-sm text-zinc-400 dark:text-zinc-500">
                Loading package files…
              </p>
            ) : pkgDetailQuery.error ? (
              <p className="text-sm text-red-600 dark:text-red-400">Failed to load package files.</p>
            ) : splitKeys.length === 0 ? (
              <p className="py-8 text-center text-sm text-zinc-400 dark:text-zinc-500">
                This package has no files.
              </p>
            ) : (
              <>
                <Input
                  placeholder="Search files…"
                  icon={<Search className="w-4 h-4" />}
                  value={splitSearch}
                  onChange={(e) => {
                    setSplitSearch(e.target.value);
                    setSplitPage(1);
                  }}
                  className={fieldDark}
                />
                <p className="text-xs text-zinc-500 dark:text-zinc-400">
                  Showing {splitPageKeys.length} of {splitFiltered.length} files
                  {splitSearch.trim() ? ` matching "${splitSearch.trim()}"` : ''}
                </p>

                {splitFiltered.length === 0 ? (
                  <p className="py-8 text-center text-sm text-zinc-400 dark:text-zinc-500">
                    No files found matching your search.
                  </p>
                ) : (
                  <div className="overflow-x-auto rounded-lg border border-zinc-100 dark:border-zinc-800">
                    <table className="w-full text-left">
                      <thead>
                        <tr className="bg-zinc-50 border-b border-zinc-200 dark:bg-zinc-800/50 dark:border-zinc-800 text-[11px] text-zinc-500 dark:text-zinc-500 font-medium uppercase tracking-wider">
                          <th className="py-3 px-4">File Path</th>
                          <th className="py-3 px-4 w-24">Version</th>
                          <th className="py-3 px-4 w-40">Priority</th>
                        </tr>
                      </thead>
                      <tbody className="text-sm">
                        {splitPageKeys.map((k) => (
                          <tr key={k} className="border-b border-zinc-100 dark:border-zinc-800 last:border-0">
                            <td className="py-2.5 px-4">
                              <span
                                className="font-mono text-xs text-zinc-700 dark:text-zinc-300 truncate block max-w-[520px]"
                                title={k}
                              >
                                {keyPath(k)}
                              </span>
                            </td>
                            <td className="py-2.5 px-4 font-mono text-xs text-zinc-500 dark:text-zinc-400">
                              {keyVersion(k)}
                            </td>
                            <td className="py-2.5 px-4">
                              <div className="w-32">
                                <SelectInput
                                  aria-label={`Priority for ${keyPath(k)}`}
                                  options={[
                                    { value: 'important', label: 'Important' },
                                    { value: 'lazy', label: 'Lazy' },
                                  ]}
                                  value={priorityOf(k)}
                                  onChange={(e) => setPriority(k, e.target.value as 'important' | 'lazy')}
                                  className={fieldDark}
                                />
                              </div>
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                )}

                {splitTotalPages > 1 && (
                  <div className="flex items-center justify-center gap-1.5 pt-1">
                    <button
                      type="button"
                      disabled={splitSafePage <= 1}
                      onClick={() => setSplitPage((v) => Math.max(1, v - 1))}
                      className="inline-flex items-center gap-1 px-2 h-8 rounded-md text-sm text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-200 disabled:opacity-40 disabled:cursor-not-allowed cursor-pointer"
                    >
                      <ChevronLeft className="w-4 h-4" />
                      Previous
                    </button>
                    {pageItems(splitSafePage, splitTotalPages).map((it, idx) =>
                      it === '…' ? (
                        <span key={`e${idx}`} className="px-1 text-zinc-400 dark:text-zinc-500">
                          …
                        </span>
                      ) : (
                        <button
                          key={it}
                          type="button"
                          onClick={() => setSplitPage(it)}
                          className={cn(
                            'w-8 h-8 rounded-md text-sm cursor-pointer transition-colors',
                            it === splitSafePage
                              ? 'bg-airborne text-white'
                              : 'text-zinc-600 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800',
                          )}
                        >
                          {it}
                        </button>
                      ),
                    )}
                    <button
                      type="button"
                      disabled={splitSafePage >= splitTotalPages}
                      onClick={() => setSplitPage((v) => Math.min(splitTotalPages, v + 1))}
                      className="inline-flex items-center gap-1 px-2 h-8 rounded-md text-sm text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-200 disabled:opacity-40 disabled:cursor-not-allowed cursor-pointer"
                    >
                      Next
                      <ChevronRight className="w-4 h-4" />
                    </button>
                  </div>
                )}
              </>
            )}
          </CardContent>
        </Card>
      )}

      {/* Config — collapsed by default */}
      <CollapsibleCard
        title="Config"
        subtitle="Timeouts and remote-config properties"
        open={configOpen}
        onToggle={() => setConfigOpen((o) => !o)}
        summary={`boot ${bootTimeout || '—'}ms · release ${releaseConfigTimeout || '—'}ms${
          propertiesText.trim() ? ' · properties set' : ''
        }`}
      >
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <Input
              label="Boot timeout (ms)"
              type="number"
              min={0}
              value={bootTimeout}
              onChange={(e) => setBootTimeout(e.target.value)}
              error={bootError}
              required
              className={fieldDark}
            />
            <Input
              label="Release config timeout (ms)"
              type="number"
              min={0}
              value={releaseConfigTimeout}
              onChange={(e) => setReleaseConfigTimeout(e.target.value)}
              error={rctError}
              required
              className={fieldDark}
            />
          </div>
          <Textarea
            label="Properties (optional JSON object)"
            rows={6}
            value={propertiesText}
            onChange={(e) => setPropertiesText(e.target.value)}
            placeholder={'{\n  "key": "value"\n}'}
            error={propertiesError}
            className={`font-mono text-xs ${fieldDark}`}
          />
          <div className="flex items-center gap-3">
            <Button
              variant="secondary"
              size="sm"
              className={secondaryBtnDark}
              onClick={() => setSeedCtx(targetCtx)}
              disabled={seedCtx != null}
              loading={seedCtx != null && seedQuery.isLoading}
            >
              Fill from remote-config schema
            </Button>
            <p className="text-xs text-zinc-500 dark:text-zinc-400">
              Replaces Properties with the schema defaults
              {targetCtx ? ' resolved for the current targeting' : ''}.
            </p>
          </div>
      </CollapsibleCard>

      {/* Resources — collapsed by default */}
      <CollapsibleCard
        title="Resources (optional)"
        subtitle="Extra files served alongside the package"
        open={resourcesOpen}
        onToggle={() => setResourcesOpen((o) => !o)}
        summary={resources.length > 0 ? `${resources.length} selected` : 'none'}
      >
          <MultiSelect
            label="Extra files served alongside the package"
            options={resourceOptions}
            value={resources}
            onChange={setResources}
            loading={filesQuery.isLoading}
            error={filesQuery.error ? 'Failed to load files' : null}
            emptyText="No files for this app."
            placeholder="Search file keys…"
          />
          {filesClamped && (
            <p className="text-xs text-zinc-500 dark:text-zinc-400">
              Showing newest {filesLoaded} of {filesTotal} files — use the Files page to
              register/search more.
            </p>
          )}
      </CollapsibleCard>

      {/* Actions */}
      <div className="flex items-center justify-end gap-2">
        <Button variant="secondary" className={secondaryBtnDark} onClick={() => navigate(backPath)}>
          Cancel
        </Button>
        <Button
          variant="primary"
          className={primaryBtnDark}
          disabled={!canSubmit}
          loading={isPending}
          onClick={requestSubmit}
        >
          {mode === 'edit' ? 'Save changes' : 'Create release'}
        </Button>
      </div>

      {/* Confirmation — echo back the selected values before the write */}
      <Dialog open={confirmOpen} onOpenChange={setConfirmOpen}>
        <DialogContent size="md" className={cn(isDark && dialogDark)}>
          <DialogHeader>
            <DialogTitle className="dark:text-zinc-100">
              {mode === 'edit' ? 'Save these changes?' : 'Create this release?'}
            </DialogTitle>
            <DialogDescription className="dark:text-zinc-400">
              Review the values below — this is what will be submitted.
            </DialogDescription>
          </DialogHeader>
          <DialogBody>
            <div className="rounded-lg border border-zinc-200 dark:border-zinc-800 divide-y divide-zinc-100 dark:divide-zinc-800">
              <SummaryRow label="Package" value={<span className="font-mono">{packageId || '—'}</span>} />
              <SummaryRow
                label="Targeting"
                value={
                  mode === 'edit'
                    ? 'unchanged (locked)'
                    : firstRelease
                      ? 'Everyone (first release)'
                      : completeRules.map((r) => `${r.dim} = ${r.value.trim()}`).join('; ')
                }
              />
              <SummaryRow
                label="File split"
                value={`${important.length} important · ${lazy.length} lazy`}
              />
              <SummaryRow label="Boot timeout" value={`${bootTimeout} ms`} />
              <SummaryRow label="Release config timeout" value={`${releaseConfigTimeout} ms`} />
              <SummaryRow
                label="Properties"
                value={propertiesText.trim() ? 'custom JSON object' : '—'}
              />
              <SummaryRow
                label="Resources"
                value={resources.length > 0 ? `${resources.length} file${resources.length === 1 ? '' : 's'}` : '—'}
              />
            </div>
          </DialogBody>
          <DialogFooter className="dark:bg-zinc-900 dark:border-zinc-800">
            <Button variant="secondary" className={secondaryBtnDark} onClick={() => setConfirmOpen(false)}>
              Back
            </Button>
            <Button
              variant="primary"
              className={primaryBtnDark}
              loading={isPending}
              onClick={submit}
            >
              {mode === 'edit' ? 'Save changes' : 'Create release'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}

export default function OtaReleaseWizardCreate() {
  return <ReleaseWizard mode="create" />;
}

export function OtaReleaseWizardEdit() {
  return <ReleaseWizard mode="edit" />;
}

export function OtaReleaseWizardClone() {
  return <ReleaseWizard mode="clone" />;
}
