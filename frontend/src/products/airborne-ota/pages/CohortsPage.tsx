import { useState } from 'react';
import { Link, useParams, useSearchParams } from 'react-router-dom';
import { ArrowDown, ArrowUp, ChevronDown, ChevronRight, Plus, X } from 'lucide-react';
import {
  useCreateOtaCheckpoint,
  useCreateOtaGroup,
  useOtaAccess,
  useOtaCohort,
  useOtaCohortPriority,
  useOtaDimensions,
  useOtaReleasesForDimension,
  useUpdateOtaCohortPriority,
} from '../hooks';
import type { OtaCheckpointComparator } from '../types';
import { OtaAppHeader } from '../components/OtaAppHeader';
import { OtaStatusBadge } from '../components/OtaStatusBadge';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { Input, SelectInput } from '../../../shared/ui/input';
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
import { cn } from '../../../lib/utils';

const primaryBtnDark = 'bg-airborne border-airborne text-white hover:bg-airborne-hover';
const secondaryBtnDark = 'dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800';
const fieldDark = 'dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-100';
// Dialog portals out of the .dark subtree — re-enter dark scope on the content.
const dialogDark = 'dark bg-zinc-900 border-zinc-800 sm:border-zinc-800';

const cardCls = 'bg-white border-zinc-200 dark:bg-zinc-900 dark:border-zinc-800 rounded-xl border';
const cardHeaderCls =
  'px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100 dark:border-zinc-800 flex items-center justify-between gap-3';
const chipDark = 'normal-case dark:bg-zinc-800 dark:text-zinc-300 dark:border-zinc-700';

const OP_SYMBOL: Record<string, string> = {
  jp_ver_ge: '≥',
  jp_ver_gt: '>',
  jp_ver_le: '≤',
  jp_ver_lt: '<',
  str_ge: '≥',
  str_gt: '>',
  str_le: '≤',
  str_lt: '<',
};

// Leaf shape: { '<op>': [{ var: '<dim>' }, '<value>'] } → "≥ 1.2.3".
function leafSummary(obj: Record<string, unknown>): string | null {
  const keys = Object.keys(obj);
  if (keys.length !== 1) return null;
  const sym = OP_SYMBOL[keys[0]];
  const args = obj[keys[0]];
  if (!sym || !Array.isArray(args) || args.length < 2) return null;
  const value = args[1];
  return `${sym} ${typeof value === 'string' ? value : JSON.stringify(value)}`;
}

// 'and' wraps an array of single-key leaves; anything unrecognized falls back
// to a raw JSON snippet so unknown upstream shapes still render.
function conditionSummary(def: Record<string, unknown> | undefined): string {
  if (!def) return '—';
  const fallback = () => {
    const raw = JSON.stringify(def);
    return raw.length > 80 ? `${raw.slice(0, 77)}…` : raw;
  };
  const andArgs = def.and;
  if (Array.isArray(andArgs)) {
    const parts: string[] = [];
    for (const c of andArgs) {
      const leaf = c && typeof c === 'object' ? leafSummary(c as Record<string, unknown>) : null;
      if (leaf == null) return fallback();
      parts.push(leaf);
    }
    return parts.join(' and ');
  }
  return leafSummary(def) ?? fallback();
}

// Group shape: { in: [{ var: dim }, [members...]] }.
function groupMembersOf(def: Record<string, unknown> | undefined): string[] {
  const arr = def?.in;
  if (!Array.isArray(arr) || !Array.isArray(arr[1])) return [];
  return arr[1].filter((m): m is string => typeof m === 'string');
}

type Tab = 'checkpoints' | 'groups';

export default function CohortsPage() {
  const { app } = useParams<{ app: string }>();
  const [searchParams, setSearchParams] = useSearchParams();
  const { isDark } = useOtaTheme();

  const { data: access } = useOtaAccess();
  const perms = access?.apps.find((a) => a.appRef === app)?.permissions ?? [];
  const canManage = perms.includes('OTA_CONFIG_MANAGE');

  const dimsQuery = useOtaDimensions(app);
  const cohortDims = (dimsQuery.data?.data ?? []).filter((d) => d.dimension_type === 'cohort');
  const dimParam = searchParams.get('dimension');
  const selectedDim = cohortDims.some((d) => d.dimension === dimParam)
    ? dimParam!
    : cohortDims[0]?.dimension;

  const cohortQuery = useOtaCohort(app, selectedDim);
  const priorityQuery = useOtaCohortPriority(app, selectedDim);
  const priorityMap = priorityQuery.data?.priority_map ?? {};

  const [tab, setTab] = useState<Tab>('checkpoints');
  const [expandedCohort, setExpandedCohort] = useState<string | null>(null);

  // Single expansion state so the per-cohort releases preview is ONE hook call.
  const relQuery = useOtaReleasesForDimension(
    app,
    selectedDim && expandedCohort ? `${selectedDim}=${expandedCohort}` : undefined,
  );

  const enumNames = cohortQuery.data?.enum ?? [];
  const defs = cohortQuery.data?.definitions ?? {};
  const names = enumNames.filter((n) => n !== 'otherwise');
  const isGroup = (n: string) => {
    const d = defs[n];
    return !!d && typeof d === 'object' && 'in' in d;
  };
  const groups = names.filter(isGroup);
  const checkpoints = names.filter((n) => !isGroup(n));
  const hasOtherwise = enumNames.includes('otherwise');

  const checkpointMutation = useCreateOtaCheckpoint(app);
  const groupMutation = useCreateOtaGroup(app);
  const priorityMutation = useUpdateOtaCohortPriority(app);

  // Add Checkpoint dialog
  const [cpOpen, setCpOpen] = useState(false);
  const [cpName, setCpName] = useState('');
  const [cpValue, setCpValue] = useState('');
  const [cpType, setCpType] = useState<'semver' | 'str'>('semver');
  const [cpBoundary, setCpBoundary] = useState<'ge' | 'gt'>('ge');

  // Add Group dialog
  const [grpOpen, setGrpOpen] = useState(false);
  const [grpName, setGrpName] = useState('');
  const [grpMembers, setGrpMembers] = useState<string[]>([]);
  const [memberDraft, setMemberDraft] = useState('');

  const selectDimension = (dim: string) => {
    setSearchParams({ dimension: dim });
    setExpandedCohort(null);
  };

  const switchTab = (t: Tab) => {
    setTab(t);
    setExpandedCohort(null);
  };

  const toggleExpanded = (name: string) => {
    setExpandedCohort((c) => (c === name ? null : name));
  };

  const openCheckpointDialog = () => {
    setCpName('');
    setCpValue('');
    setCpType('semver');
    setCpBoundary('ge');
    setCpOpen(true);
  };

  // ';' can never round-trip through the x-dimension "k=v;k2=v2" transport
  // used by the releases-preview panel below.
  const cpNameError = cpName.includes(';') ? "Can't contain ';'" : undefined;
  const grpNameError = grpName.includes(';') ? "Can't contain ';'" : undefined;

  const submitCheckpoint = () => {
    if (!selectedDim || !cpName.trim() || !cpValue.trim() || cpNameError) return;
    const comparator = `${cpType}_${cpBoundary}` as OtaCheckpointComparator;
    checkpointMutation.mutate(
      { dimension: selectedDim, body: { name: cpName.trim(), value: cpValue.trim(), comparator } },
      { onSuccess: () => setCpOpen(false) },
    );
  };

  const openGroupDialog = () => {
    setGrpName('');
    setGrpMembers([]);
    setMemberDraft('');
    setGrpOpen(true);
  };

  const addMember = () => {
    const v = memberDraft.trim();
    if (!v) return;
    if (!grpMembers.includes(v)) setGrpMembers((m) => [...m, v]);
    setMemberDraft('');
  };

  const submitGroup = () => {
    if (!selectedDim || !grpName.trim() || grpMembers.length === 0 || grpNameError) return;
    groupMutation.mutate(
      { dimension: selectedDim, body: { name: grpName.trim(), members: grpMembers } },
      { onSuccess: () => setGrpOpen(false) },
    );
  };

  // ONE name per call — upstream applies multi-entry priority maps nondeterministically.
  const moveGroup = (name: string, dir: -1 | 1) => {
    if (!selectedDim) return;
    const gi = groups.indexOf(name);
    const target = Math.min(Math.max(gi + dir, 0), groups.length - 1);
    if (target === gi) return;
    priorityMutation.mutate({ dimension: selectedDim, priorityMap: { [name]: target } });
  };

  const renderReleases = () => {
    if (relQuery.isLoading) {
      return <div className="py-2 text-xs text-zinc-400 dark:text-zinc-500">Loading releases…</div>;
    }
    if (relQuery.error) {
      return <div className="py-2 text-xs text-red-600 dark:text-red-400">Failed to load releases.</div>;
    }
    const rels = relQuery.data?.data ?? [];
    if (rels.length === 0) {
      return <div className="py-2 text-xs text-zinc-400 dark:text-zinc-500">—</div>;
    }
    return (
      <div className="py-1 space-y-0.5">
        {rels.map((r, i) => {
          const rid = typeof r.id === 'string' ? r.id : undefined;
          const traffic = r.experiment?.traffic_percentage;
          const inner = (
            <>
              <span className="font-mono text-xs text-zinc-700 dark:text-zinc-300">
                {rid ? rid.slice(0, 8) : '—'}
              </span>
              <OtaStatusBadge status={r.experiment?.status} />
              <span className="text-xs text-zinc-500 dark:text-zinc-400">
                {traffic != null ? `${traffic}%` : '—'}
              </span>
            </>
          );
          return rid ? (
            <Link
              key={rid}
              to={`/airborne/${encodeURIComponent(app!)}/releases/${encodeURIComponent(rid)}`}
              className="flex items-center gap-3 px-2 py-1.5 rounded-lg hover:bg-zinc-100 dark:hover:bg-zinc-800/60"
            >
              {inner}
            </Link>
          ) : (
            <div key={i} className="flex items-center gap-3 px-2 py-1.5">
              {inner}
            </div>
          );
        })}
      </div>
    );
  };

  const renderExpandedPanel = () => (
    <div className="mt-2 rounded-lg border border-zinc-100 dark:border-zinc-800 bg-zinc-50/60 dark:bg-zinc-800/30 px-2">
      <p className="pt-2 px-2 text-[11px] text-zinc-500 dark:text-zinc-500 font-medium uppercase tracking-wider">
        Releases targeting this cohort
      </p>
      {renderReleases()}
    </div>
  );

  const tabBtnCls = (active: boolean) =>
    cn(
      'pb-1 -mb-px text-sm font-medium border-b-2 cursor-pointer transition-colors duration-150',
      active
        ? 'text-airborne border-airborne'
        : 'text-zinc-500 dark:text-zinc-400 border-transparent hover:text-zinc-700 dark:hover:text-zinc-200',
    );

  return (
    <div className="flex flex-col flex-1 w-full pb-12 space-y-4">
      <OtaAppHeader app={app!} title="Cohorts" />

      {dimsQuery.error && !dimsQuery.data ? (
        <div className={cardCls}>
          <div className="px-4 py-6 text-sm text-red-600 dark:text-red-400">
            Failed to load dimensions. Refresh to retry.
          </div>
        </div>
      ) : dimsQuery.isLoading ? (
        <div className={cardCls}>
          <div className="dark:invert">
            <TableSkeleton rows={6} cols={4} />
          </div>
        </div>
      ) : cohortDims.length === 0 ? (
        <div className={cardCls}>
          <div className="py-16 text-center text-zinc-400 dark:text-zinc-500 text-sm">
            No cohort dimensions. Create one from the{' '}
            <Link
              to={`/airborne/${encodeURIComponent(app!)}/dimensions`}
              className="text-airborne hover:underline"
            >
              Dimensions page
            </Link>
            .
          </div>
        </div>
      ) : (
        <>
          {/* Dimension selector */}
          <div className={cardCls}>
            <header className={cardHeaderCls}>
              <h2 className="text-sm font-semibold text-zinc-900 dark:text-zinc-100">Cohort dimension</h2>
            </header>
            <div className="px-4 py-4 sm:px-6">
              <SelectInput
                label="Dimension"
                className={fieldDark}
                value={selectedDim ?? ''}
                onChange={(e) => selectDimension(e.target.value)}
                options={cohortDims.map((d) => ({
                  value: d.dimension,
                  label: d.depends_on ? `${d.dimension} → ${d.depends_on}` : d.dimension,
                }))}
                hint="Cohorts partition users by the dimension this one depends on."
              />
            </div>
          </div>

          {/* Checkpoints / Groups */}
          {selectedDim && (
            <div className={cardCls}>
              <header className={cardHeaderCls}>
                <div className="flex items-center gap-4">
                  <button type="button" className={tabBtnCls(tab === 'checkpoints')} onClick={() => switchTab('checkpoints')}>
                    Checkpoints
                    <span className="ml-1.5 text-xs text-zinc-400 dark:text-zinc-500">{checkpoints.length}</span>
                  </button>
                  <button type="button" className={tabBtnCls(tab === 'groups')} onClick={() => switchTab('groups')}>
                    Groups
                    <span className="ml-1.5 text-xs text-zinc-400 dark:text-zinc-500">{groups.length}</span>
                  </button>
                </div>
                {canManage &&
                  (tab === 'checkpoints' ? (
                    <Button size="sm" className={primaryBtnDark} onClick={openCheckpointDialog}>
                      <Plus className="w-4 h-4" />
                      Add Checkpoint
                    </Button>
                  ) : (
                    <Button size="sm" className={primaryBtnDark} onClick={openGroupDialog}>
                      <Plus className="w-4 h-4" />
                      Add Group
                    </Button>
                  ))}
              </header>

              {cohortQuery.error && !cohortQuery.data ? (
                <div className="px-4 py-6 text-sm text-red-600 dark:text-red-400">
                  Failed to load cohorts. Refresh to retry.
                </div>
              ) : cohortQuery.isLoading ? (
                <div className="dark:invert">
                  <TableSkeleton rows={6} cols={4} />
                </div>
              ) : tab === 'checkpoints' ? (
                checkpoints.length === 0 ? (
                  <div className="py-16 text-center text-zinc-400 dark:text-zinc-500 text-sm">
                    No checkpoints for this dimension.
                  </div>
                ) : (
                  <ol className="px-4 py-4 sm:px-6">
                    {checkpoints.map((name, i) => {
                      const last = i === checkpoints.length - 1 && !hasOtherwise;
                      const expanded = expandedCohort === name;
                      return (
                        <li key={name} className="flex gap-3">
                          <div className="flex flex-col items-center">
                            <div className="w-6 h-6 rounded-full bg-airborne text-white text-[11px] font-semibold flex items-center justify-center shrink-0">
                              {i + 1}
                            </div>
                            {!last && <div className="w-px flex-1 bg-zinc-200 dark:bg-zinc-800" />}
                          </div>
                          <div className={cn('flex-1 min-w-0', !last && 'pb-4')}>
                            <div className="flex items-center gap-2 min-w-0">
                              <span className="text-sm font-medium text-zinc-900 dark:text-zinc-100 truncate">
                                {name}
                              </span>
                              <span className="font-mono text-xs text-zinc-500 dark:text-zinc-400 truncate">
                                {conditionSummary(defs[name])}
                              </span>
                              <div className="flex-1" />
                              <Button
                                variant="ghost"
                                size="icon-sm"
                                className="dark:text-zinc-400 dark:hover:bg-zinc-800"
                                onClick={() => toggleExpanded(name)}
                                aria-label={expanded ? `Collapse ${name}` : `Expand ${name}`}
                              >
                                {expanded ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
                              </Button>
                            </div>
                            {expanded && renderExpandedPanel()}
                          </div>
                        </li>
                      );
                    })}
                    {hasOtherwise && (
                      <li className="flex gap-3">
                        <div className="w-6 h-6 rounded-full border border-zinc-300 dark:border-zinc-700 flex items-center justify-center shrink-0">
                          <span className="w-1.5 h-1.5 rounded-full bg-zinc-300 dark:bg-zinc-700" />
                        </div>
                        <div className="flex items-center min-w-0 text-sm text-zinc-400 dark:text-zinc-500">
                          otherwise — everyone else
                        </div>
                      </li>
                    )}
                  </ol>
                )
              ) : groups.length === 0 ? (
                <div className="py-16 text-center text-zinc-400 dark:text-zinc-500 text-sm">
                  No groups for this dimension.
                </div>
              ) : (
                <div className="divide-y divide-zinc-100 dark:divide-zinc-800">
                  {groups.map((name, gi) => {
                    const expanded = expandedCohort === name;
                    const members = groupMembersOf(defs[name]);
                    return (
                      <div key={name}>
                        <div className="px-4 py-3 sm:px-6 flex items-center gap-3">
                          <span
                            className="w-6 shrink-0 font-mono text-xs text-zinc-500 dark:text-zinc-400"
                            title="Priority (0 = highest)"
                          >
                            {priorityMap[name] ?? gi}
                          </span>
                          <span className="text-sm font-medium text-zinc-900 dark:text-zinc-100 truncate shrink-0">
                            {name}
                          </span>
                          <div className="flex flex-wrap items-center gap-1 flex-1 min-w-0">
                            {members.length === 0 ? (
                              <span className="text-sm text-zinc-400 dark:text-zinc-500">—</span>
                            ) : (
                              members.map((m) => (
                                <Badge key={m} className={chipDark}>
                                  {m}
                                </Badge>
                              ))
                            )}
                          </div>
                          {canManage && (
                            <div className="flex items-center gap-1 shrink-0">
                              <Button
                                variant="ghost"
                                size="icon-sm"
                                className="dark:text-zinc-400 dark:hover:bg-zinc-800"
                                disabled={priorityMutation.isPending || gi === 0}
                                onClick={() => moveGroup(name, -1)}
                                aria-label={`Move ${name} up`}
                              >
                                <ArrowUp className="w-3.5 h-3.5" />
                              </Button>
                              <Button
                                variant="ghost"
                                size="icon-sm"
                                className="dark:text-zinc-400 dark:hover:bg-zinc-800"
                                disabled={priorityMutation.isPending || gi === groups.length - 1}
                                onClick={() => moveGroup(name, 1)}
                                aria-label={`Move ${name} down`}
                              >
                                <ArrowDown className="w-3.5 h-3.5" />
                              </Button>
                            </div>
                          )}
                          <Button
                            variant="ghost"
                            size="icon-sm"
                            className="dark:text-zinc-400 dark:hover:bg-zinc-800"
                            onClick={() => toggleExpanded(name)}
                            aria-label={expanded ? `Collapse ${name}` : `Expand ${name}`}
                          >
                            {expanded ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
                          </Button>
                        </div>
                        {expanded && <div className="px-4 pb-3 sm:px-6">{renderExpandedPanel()}</div>}
                      </div>
                    );
                  })}
                </div>
              )}
            </div>
          )}
        </>
      )}

      {/* Add Checkpoint dialog */}
      <Dialog open={cpOpen} onOpenChange={setCpOpen}>
        <DialogContent size="md" className={cn(isDark && dialogDark)}>
          <DialogHeader>
            <DialogTitle className="dark:text-zinc-100">Add Checkpoint</DialogTitle>
            <DialogDescription className="dark:text-zinc-400">
              Users at or beyond the boundary value fall into this cohort.
            </DialogDescription>
          </DialogHeader>
          <DialogBody className="space-y-4">
            <Input
              label="Name"
              value={cpName}
              onChange={(e) => setCpName(e.target.value)}
              placeholder="e.g. v2-rollout"
              required
              error={cpNameError}
              className={fieldDark}
            />
            <Input
              label="Value"
              value={cpValue}
              onChange={(e) => setCpValue(e.target.value)}
              placeholder={cpType === 'semver' ? 'e.g. 1.2.3' : 'e.g. 2024-06-01'}
              required
              className={fieldDark}
            />
            <SelectInput
              label="Value Type"
              value={cpType}
              onChange={(e) => setCpType(e.target.value as 'semver' | 'str')}
              options={[
                { value: 'semver', label: 'Semantic Version' },
                { value: 'str', label: 'String' },
              ]}
              className={fieldDark}
            />
            <SelectInput
              label="Boundary"
              value={cpBoundary}
              onChange={(e) => setCpBoundary(e.target.value as 'ge' | 'gt')}
              options={[
                { value: 'ge', label: 'Include this value (≥)' },
                { value: 'gt', label: 'Exclude this value (>)' },
              ]}
              className={fieldDark}
            />
            <p className="text-xs text-zinc-500 dark:text-zinc-400">
              Create checkpoints in ascending value order — the newest checkpoint always becomes the
              highest priority and re-bounds the previous one.
            </p>
          </DialogBody>
          <DialogFooter className="dark:bg-zinc-900 dark:border-zinc-800">
            <Button variant="secondary" className={secondaryBtnDark} onClick={() => setCpOpen(false)}>
              Cancel
            </Button>
            <Button
              variant="primary"
              className={primaryBtnDark}
              disabled={!cpName.trim() || !cpValue.trim() || !!cpNameError}
              loading={checkpointMutation.isPending}
              onClick={submitCheckpoint}
            >
              Add Checkpoint
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Add Group dialog */}
      <Dialog open={grpOpen} onOpenChange={setGrpOpen}>
        <DialogContent size="md" className={cn(isDark && dialogDark)}>
          <DialogHeader>
            <DialogTitle className="dark:text-zinc-100">Add Group</DialogTitle>
            <DialogDescription className="dark:text-zinc-400">
              A named set of exact values of the dimension this cohort depends on.
            </DialogDescription>
          </DialogHeader>
          <DialogBody className="space-y-4">
            <Input
              label="Name"
              value={grpName}
              onChange={(e) => setGrpName(e.target.value)}
              placeholder="e.g. beta-cities"
              required
              error={grpNameError}
              className={fieldDark}
            />
            <div className="space-y-1.5">
              <label htmlFor="group-member" className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider dark:text-zinc-400">
                Members<span className="text-red-500 ml-0.5">*</span>
              </label>
              <div className="flex items-center gap-2">
                <Input
                  id="group-member"
                  value={memberDraft}
                  onChange={(e) => setMemberDraft(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') {
                      e.preventDefault();
                      addMember();
                    }
                  }}
                  placeholder="Type a value and press Enter"
                  className={fieldDark}
                />
                <Button variant="secondary" className={secondaryBtnDark} onClick={addMember} disabled={!memberDraft.trim()}>
                  Add
                </Button>
              </div>
              {grpMembers.length > 0 && (
                <div className="flex flex-wrap gap-1.5 pt-1">
                  {grpMembers.map((m) => (
                    <Badge key={m} className={chipDark}>
                      {m}
                      <button
                        type="button"
                        className="cursor-pointer hover:text-red-500"
                        onClick={() => setGrpMembers((cur) => cur.filter((x) => x !== m))}
                        aria-label={`Remove ${m}`}
                      >
                        <X className="w-3 h-3" />
                      </button>
                    </Badge>
                  ))}
                </div>
              )}
            </div>
          </DialogBody>
          <DialogFooter className="dark:bg-zinc-900 dark:border-zinc-800">
            <Button variant="secondary" className={secondaryBtnDark} onClick={() => setGrpOpen(false)}>
              Cancel
            </Button>
            <Button
              variant="primary"
              className={primaryBtnDark}
              disabled={!grpName.trim() || grpMembers.length === 0 || !!grpNameError}
              loading={groupMutation.isPending}
              onClick={submitGroup}
            >
              Add Group
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
