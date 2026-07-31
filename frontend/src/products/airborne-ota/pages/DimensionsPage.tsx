import { useMemo, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { ArrowDown, ArrowUp, Plus, Search } from 'lucide-react';
import { useCreateOtaDimension, useOtaAccess, useOtaDimensions, useUpdateOtaDimension } from '../hooks';
import type { OtaDimension } from '../types';
import { OtaAppHeader } from '../components/OtaAppHeader';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { Input, Textarea } from '../../../shared/ui/input';
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
import { OtaErrorState } from '../components/OtaErrorState';

const primaryBtnDark = 'bg-airborne border-airborne text-white hover:bg-airborne-hover';
const secondaryBtnDark = 'dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800';
const fieldDark = 'dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-100';
// Dialog portals out of the .dark subtree — re-enter dark scope on the content.
const dialogDark = 'dark bg-zinc-900 border-zinc-800 sm:border-zinc-800';

const labelCls = 'block text-[11px] font-medium text-zinc-600 dark:text-zinc-400 uppercase tracking-wider';
const selectCls =
  'w-full h-10 sm:h-9 rounded-lg border border-zinc-300 bg-white px-3 text-sm text-zinc-900 ' +
  'focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent cursor-pointer';

type DimType = 'standard' | 'cohort';

const dimType = (d: OtaDimension): DimType => (d.dimension_type === 'cohort' ? 'cohort' : 'standard');

interface DimForm {
  key: string;
  type: DimType;
  dependsOn: string;
  description: string;
}

const EMPTY_FORM: DimForm = { key: '', type: 'standard', dependsOn: '', description: '' };

export default function DimensionsPage() {
  const { app } = useParams<{ app: string }>();
  const navigate = useNavigate();

  const { data, isLoading, error } = useOtaDimensions(app);
  const createMutation = useCreateOtaDimension(app);
  const updateMutation = useUpdateOtaDimension(app);

  const { data: access } = useOtaAccess();
  const perms = access?.apps.find((a) => a.appRef === app)?.permissions ?? [];
  const canManage = perms.includes('OTA_CONFIG_MANAGE');

  const [search, setSearch] = useState('');
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState<DimForm>(EMPTY_FORM);
  const { isDark } = useOtaTheme();

  const sorted = useMemo(
    () => [...(data?.data ?? [])].sort((a, b) => a.position - b.position),
    [data],
  );

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return sorted;
    return sorted.filter(
      (d) => d.dimension.toLowerCase().includes(q) || (d.description ?? '').toLowerCase().includes(q),
    );
  }, [sorted, search]);

  const standardDims = sorted.filter((d) => dimType(d) === 'standard');
  const hasStandard = standardDims.length > 0;

  const openCreate = () => {
    setForm(EMPTY_FORM);
    setOpen(true);
  };

  // "release-view" collides with upstream's dimension/release-view sub-router.
  const keyReserved = form.key.trim() === 'release-view';

  const canSubmit =
    form.key.trim() !== '' &&
    !keyReserved &&
    form.description.trim() !== '' &&
    (form.type !== 'cohort' || form.dependsOn !== '');

  const submit = () => {
    if (!canSubmit) return;
    createMutation.mutate(
      {
        dimension: form.key.trim(),
        description: form.description.trim(),
        dimension_type: form.type,
        ...(form.type === 'cohort' ? { depends_on: form.dependsOn } : {}),
      },
      { onSuccess: () => setOpen(false) },
    );
  };

  const move = (d: OtaDimension, delta: number) => {
    updateMutation.mutate({ dimension: d.dimension, body: { position: d.position + delta } });
  };

  const cohortsPath = (dim: string) =>
    `/airborne/${encodeURIComponent(app!)}/cohorts?dimension=${encodeURIComponent(dim)}`;

  return (
    <div className="flex flex-col flex-1 w-full pb-12 space-y-4">
      <OtaAppHeader app={app!} title="Dimensions" />

      <div className="bg-white border-zinc-200 dark:bg-zinc-900 dark:border-zinc-800 rounded-xl border">
        <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100 dark:border-zinc-800 flex items-center justify-between gap-3">
          <div className="flex items-center gap-2">
            <h2 className="text-sm font-semibold text-zinc-900 dark:text-zinc-100">Dimensions</h2>
            <span className="text-xs text-zinc-500 dark:text-zinc-400">{sorted.length}</span>
          </div>
          <div className="flex items-center gap-2">
            <Input
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Search dimensions…"
              icon={<Search className="w-3.5 h-3.5" />}
              className={cn(fieldDark, 'h-9 w-40 sm:w-64')}
              aria-label="Search dimensions"
            />
            {canManage && (
              <Button size="sm" className={primaryBtnDark} onClick={openCreate}>
                <Plus className="w-4 h-4" />
                Create Dimension
              </Button>
            )}
          </div>
        </header>

        {error && !data ? (
          <div className="p-4">
            <OtaErrorState error={error} what="dimensions for this app" />
          </div>
        ) : isLoading ? (
          <div className="dark:invert">
            <TableSkeleton rows={6} cols={4} />
          </div>
        ) : sorted.length === 0 ? (
          <div className="py-16 text-center text-zinc-400 dark:text-zinc-500 text-sm">
            No dimensions yet. Dimensions are the targeting vocabulary for releases.
          </div>
        ) : filtered.length === 0 ? (
          <div className="py-16 text-center text-zinc-400 dark:text-zinc-500 text-sm">
            No dimensions match your search.
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left">
              <thead>
                <tr className="bg-zinc-50 border-b border-zinc-200 dark:bg-zinc-800/50 dark:border-zinc-800 text-[11px] text-zinc-500 dark:text-zinc-500 font-medium uppercase tracking-wider">
                  <th className="py-3 px-4 w-32">Priority</th>
                  <th className="py-3 px-4">Name</th>
                  <th className="py-3 px-4">Type</th>
                  <th className="py-3 px-4">Description</th>
                  <th className="py-3 px-4 w-24 text-right">Actions</th>
                </tr>
              </thead>
              <tbody className="text-sm">
                {filtered.map((d) => {
                  const type = dimType(d);
                  const idx = sorted.findIndex((s) => s.dimension === d.dimension);
                  const isFirst = idx === 0;
                  // The bottom slot is reserved (parity with airborne's dashboard,
                  // which also pins the second-to-last row's down arrow) — nothing
                  // can be pushed past the last two rows.
                  const isLast = idx >= sorted.length - 2;
                  return (
                    <tr key={d.dimension} className="border-b border-zinc-100 dark:border-zinc-800">
                      <td className="py-3 px-4 text-zinc-700 dark:text-zinc-300">
                        <div className="flex items-center gap-1">
                          <span className="font-mono text-xs w-6">{d.position}</span>
                          {canManage && (
                            <>
                              <Button
                                variant="ghost"
                                size="icon-sm"
                                className="dark:text-zinc-400 dark:hover:bg-zinc-800"
                                disabled={isFirst || updateMutation.isPending}
                                onClick={() => move(d, -1)}
                                aria-label={`Move ${d.dimension} up`}
                              >
                                <ArrowUp className="w-3.5 h-3.5" />
                              </Button>
                              <Button
                                variant="ghost"
                                size="icon-sm"
                                className="dark:text-zinc-400 dark:hover:bg-zinc-800"
                                disabled={isLast || updateMutation.isPending}
                                onClick={() => move(d, 1)}
                                aria-label={`Move ${d.dimension} down`}
                              >
                                <ArrowDown className="w-3.5 h-3.5" />
                              </Button>
                            </>
                          )}
                        </div>
                      </td>
                      <td className="py-3 px-4 font-mono text-xs text-zinc-700 dark:text-zinc-300">
                        {d.dimension}
                      </td>
                      <td className="py-3 px-4 text-zinc-700 dark:text-zinc-300">
                        <Badge
                          className={cn(
                            type === 'cohort'
                              ? 'bg-airborne/10 text-airborne border-airborne/30'
                              : 'dark:bg-zinc-800 dark:text-zinc-300 dark:border-zinc-700',
                          )}
                        >
                          {type}
                        </Badge>
                        {type === 'cohort' && d.depends_on && (
                          <span className="ml-2 font-mono text-xs text-zinc-500 dark:text-zinc-500">
                            → {d.depends_on}
                          </span>
                        )}
                      </td>
                      <td className="py-3 px-4 text-zinc-700 dark:text-zinc-300">
                        {d.description || '—'}
                      </td>
                      <td className="py-3 px-4">
                        <div className="flex items-center justify-end">
                          {type === 'cohort' ? (
                            <Button
                              variant="secondary"
                              size="sm"
                              className={secondaryBtnDark}
                              onClick={() => navigate(cohortsPath(d.dimension))}
                            >
                              Manage
                            </Button>
                          ) : (
                            <span className="text-zinc-400 dark:text-zinc-600">—</span>
                          )}
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {/* Create dialog — no delete/edit of key/type/description, by parity with airborne. */}
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent size="md" className={cn(isDark && dialogDark)}>
          <DialogHeader>
            <DialogTitle className="dark:text-zinc-100">Create Dimension</DialogTitle>
            <DialogDescription className="dark:text-zinc-400">
              Add a targeting dimension. Cohort dimensions segment on a standard dimension's value.
            </DialogDescription>
          </DialogHeader>
          <DialogBody className="space-y-4">
            <Input
              label="Key"
              value={form.key}
              onChange={(e) =>
                setForm((f) => ({ ...f, key: e.target.value.toLowerCase().replace(/\s+/g, '_') }))
              }
              placeholder="e.g. city"
              hint={keyReserved ? undefined : 'Lowercase; spaces become underscores'}
              error={keyReserved ? '"release-view" is a reserved name' : undefined}
              required
              className={fieldDark}
            />
            <div className="space-y-1.5">
              <label htmlFor="dim-type" className={labelCls}>
                Type<span className="text-red-500 ml-0.5">*</span>
              </label>
              <select
                id="dim-type"
                value={form.type}
                onChange={(e) => setForm((f) => ({ ...f, type: e.target.value as DimType }))}
                className={cn(selectCls, fieldDark)}
              >
                <option value="standard">standard</option>
                <option value="cohort" disabled={!hasStandard}>
                  cohort{hasStandard ? '' : ' (requires standard dimensions)'}
                </option>
              </select>
            </div>
            {form.type === 'cohort' && (
              <div className="space-y-1.5">
                <label htmlFor="dim-depends-on" className={labelCls}>
                  Depends On<span className="text-red-500 ml-0.5">*</span>
                </label>
                <select
                  id="dim-depends-on"
                  value={form.dependsOn}
                  onChange={(e) => setForm((f) => ({ ...f, dependsOn: e.target.value }))}
                  required
                  className={cn(selectCls, fieldDark)}
                >
                  <option value="">Select a standard dimension…</option>
                  {standardDims.map((d) => (
                    <option key={d.dimension} value={d.dimension}>
                      {d.dimension}
                    </option>
                  ))}
                </select>
              </div>
            )}
            <Textarea
              label="Description"
              value={form.description}
              onChange={(e) => setForm((f) => ({ ...f, description: e.target.value }))}
              rows={3}
              required
              className={fieldDark}
            />
          </DialogBody>
          <DialogFooter className="dark:bg-zinc-900 dark:border-zinc-800">
            <Button variant="secondary" className={secondaryBtnDark} onClick={() => setOpen(false)}>
              Cancel
            </Button>
            <Button
              variant="primary"
              className={primaryBtnDark}
              disabled={!canSubmit}
              loading={createMutation.isPending}
              onClick={submit}
            >
              Create dimension
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
