import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ChevronDown, ChevronLeft, ChevronRight, Pencil, Plus, Trash2 } from 'lucide-react';
import {
  useCreateOtaView,
  useDeleteOtaView,
  useOtaAccess,
  useOtaDimensions,
  useOtaReleasesForDimension,
  useOtaViews,
  useUpdateOtaView,
} from '../hooks';
import type { OtaRelease, OtaReleaseView } from '../types';
import { OtaAppHeader } from '../components/OtaAppHeader';
import { OtaStatusBadge } from '../components/OtaStatusBadge';
import { useOtaTheme } from '../theme';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { Input } from '../../../shared/ui/input';
import {
  Dialog,
  DialogBody,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '../../../shared/ui/dialog';
import { useConfirm } from '../../../shared/ui/confirm-dialog';
import { TableSkeleton } from '../../../shared/ui/skeleton';
import { cn } from '../../../lib/utils';

const PAGE_SIZE = 20;

const primaryBtnDark = 'bg-airborne border-airborne text-white hover:bg-airborne-hover';
const secondaryBtnDark =
  'dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800';
const fieldDark = 'dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-100';
// Dialog portals out of the .dark subtree — re-enter dark scope on the content.
const dialogDark = 'dark bg-zinc-900 border-zinc-800 sm:border-zinc-800';

const selectCls =
  'h-10 sm:h-9 w-44 shrink-0 rounded-lg border border-zinc-300 bg-white px-3 text-sm text-zinc-900 ' +
  'focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent cursor-pointer';

interface DimRow {
  key: string;
  value: string;
  // Raw upstream value (may be non-string) — preserved until the user edits
  // `value`'s text, so an untouched non-string value round-trips through
  // the full-replace PUT instead of being stringified.
  original?: unknown;
}

const EMPTY_ROW: DimRow = { key: '', value: '' };

const dimStr = (v: unknown): string => (typeof v === 'string' ? v : String(v));

export default function ViewsPage() {
  const { app } = useParams<{ app: string }>();
  const [page, setPage] = useState(1);
  const [expandedId, setExpandedId] = useState<string | null>(null);

  const { data, isLoading, isFetching, error } = useOtaViews(app, { page, count: PAGE_SIZE });
  const dimensionsQuery = useOtaDimensions(app);
  const createMutation = useCreateOtaView(app);
  const updateMutation = useUpdateOtaView(app);
  const deleteMutation = useDeleteOtaView(app);
  const confirm = useConfirm();
  const { isDark } = useOtaTheme();

  const { data: access } = useOtaAccess();
  const perms = access?.apps.find((a) => a.appRef === app)?.permissions ?? [];
  const canManage = perms.includes('OTA_CONFIG_MANAGE');

  const rows = data?.data ?? [];
  const totalPages = data?.total_pages ?? 1;
  const totalItems = data?.total_items;
  const dimensionKeys = (dimensionsQuery.data?.data ?? []).map((d) => d.dimension);

  // Deleting the last row on a trailing page shrinks total_pages below the
  // current page — clamp back instead of showing a misleading empty state.
  useEffect(() => {
    const tp = data?.total_pages;
    if (tp != null && page > Math.max(1, tp)) setPage(Math.max(1, tp));
  }, [data?.total_pages, page]);

  // ONE preview query — the "k=v;k2=v2" context of the expanded view.
  const expandedView = rows.find((v) => v.id === expandedId);
  const expandedDim = expandedView?.dimensions?.length
    ? expandedView.dimensions.map((d) => `${d.key}=${dimStr(d.value)}`).join(';')
    : undefined;
  const releasesQuery = useOtaReleasesForDimension(app, expandedDim);
  const previewRows = releasesQuery.data?.data ?? [];

  // Dialog state (create when editingId is null, edit otherwise).
  const [open, setOpen] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [name, setName] = useState('');
  const [dimRows, setDimRows] = useState<DimRow[]>([EMPTY_ROW]);
  const [formError, setFormError] = useState<string | null>(null);

  const openCreate = () => {
    setEditingId(null);
    setName('');
    setDimRows([EMPTY_ROW]);
    setFormError(null);
    setOpen(true);
  };

  const openEdit = (view: OtaReleaseView) => {
    setEditingId(view.id);
    setName(view.name);
    setDimRows(
      view.dimensions?.length
        ? view.dimensions.map((d) => ({ key: d.key, value: dimStr(d.value), original: d.value }))
        : [EMPTY_ROW],
    );
    setFormError(null);
    setOpen(true);
  };

  const setRow = (i: number, patch: Partial<DimRow>) =>
    setDimRows((rs) =>
      rs.map((r, j) => {
        if (j !== i) return r;
        const next = { ...r, ...patch };
        // Editing the value's text invalidates the preserved raw original.
        if ('value' in patch && patch.value !== r.value) next.original = undefined;
        return next;
      }),
    );

  const saving = createMutation.isPending || updateMutation.isPending;

  const submit = () => {
    const surviving = dimRows.filter((r) => r.key !== '' && r.value.trim() !== '');
    if (!name.trim()) {
      setFormError('View name is required.');
      return;
    }
    if (surviving.length === 0) {
      setFormError('Add at least one dimension with both a key and a value.');
      return;
    }
    // ';' can never round-trip through the x-dimension "k=v;k2=v2" transport
    // used by the release-preview panel.
    if (surviving.some((r) => r.value.includes(';'))) {
      setFormError("Dimension values can't contain ';'.");
      return;
    }
    setFormError(null);
    const body = {
      name: name.trim(),
      // Untouched rows resubmit their original (possibly non-string) value —
      // edited rows send the new text.
      dimensions: surviving.map((r) => ({
        key: r.key,
        value: r.original !== undefined ? r.original : r.value,
      })),
    };
    if (editingId) {
      updateMutation.mutate({ viewId: editingId, body }, { onSuccess: () => setOpen(false) });
    } else {
      createMutation.mutate(body, { onSuccess: () => setOpen(false) });
    }
  };

  const onDelete = async (view: OtaReleaseView) => {
    const ok = await confirm({
      title: 'Delete view?',
      description: `"${view.name}" will be permanently deleted. Releases are not affected.`,
      confirmLabel: 'Delete',
      variant: 'danger',
    });
    if (!ok) return;
    deleteMutation.mutate(view.id);
  };

  return (
    <div className="flex flex-col flex-1 w-full pb-12 space-y-4">
      <OtaAppHeader app={app!} title="Views" />

      <div className="bg-white border-zinc-200 dark:bg-zinc-900 dark:border-zinc-800 rounded-xl border">
        <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100 dark:border-zinc-800 flex items-center justify-between gap-3">
          <div className="flex items-center gap-2">
            <h2 className="text-sm font-semibold text-zinc-900 dark:text-zinc-100">Saved Views</h2>
            {totalItems != null && (
              <span className="text-xs text-zinc-500 dark:text-zinc-400">{totalItems}</span>
            )}
          </div>
          {canManage && (
            <Button size="sm" className={primaryBtnDark} onClick={openCreate}>
              <Plus className="w-4 h-4" />
              Create View
            </Button>
          )}
        </header>

        {error && !data ? (
          <div className="px-4 py-6 text-sm text-red-600 dark:text-red-400">
            Failed to load views. Refresh to retry.
          </div>
        ) : isLoading ? (
          <div className="dark:invert">
            <TableSkeleton rows={6} cols={4} />
          </div>
        ) : rows.length === 0 ? (
          <div className="py-16 text-center text-zinc-400 dark:text-zinc-500 text-sm">
            No saved views. Views are reusable dimension filters for browsing releases.
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left">
              <thead>
                <tr className="bg-zinc-50 border-b border-zinc-200 dark:bg-zinc-800/50 dark:border-zinc-800 text-[11px] text-zinc-500 dark:text-zinc-500 font-medium uppercase tracking-wider">
                  <th className="py-3 px-4">Name</th>
                  <th className="py-3 px-4">Dimensions</th>
                  <th className="py-3 px-4">Created</th>
                  <th className="py-3 px-4 w-32 text-right">Actions</th>
                </tr>
              </thead>
              <tbody className="text-sm">
                {rows.map((v) => {
                  const isExpanded = expandedId === v.id;
                  return (
                    <ViewRow
                      key={v.id}
                      app={app!}
                      view={v}
                      canManage={canManage}
                      isExpanded={isExpanded}
                      onToggle={() => setExpandedId((id) => (id === v.id ? null : v.id))}
                      onEdit={() => openEdit(v)}
                      onDelete={() => onDelete(v)}
                      deleting={deleteMutation.isPending}
                      previewLoading={releasesQuery.isLoading}
                      previewError={!!releasesQuery.error}
                      previewRows={previewRows}
                    />
                  );
                })}
              </tbody>
            </table>
          </div>
        )}

        <footer className="px-4 py-3 sm:px-6 border-t border-zinc-100 dark:border-zinc-800 flex items-center justify-between gap-3">
          <span className="text-xs text-zinc-500 dark:text-zinc-400">
            Page {page} of {Math.max(totalPages, 1)}
            {isFetching && <span className="ml-2 text-zinc-400 dark:text-zinc-500">refreshing…</span>}
          </span>
          <div className="flex items-center gap-2">
            <Button
              variant="secondary"
              size="icon-sm"
              className={secondaryBtnDark}
              disabled={page <= 1}
              onClick={() => setPage((p) => Math.max(1, p - 1))}
              aria-label="Previous page"
            >
              <ChevronLeft className="w-4 h-4" />
            </Button>
            <Button
              variant="secondary"
              size="icon-sm"
              className={secondaryBtnDark}
              disabled={data?.total_pages != null ? page >= totalPages : rows.length < PAGE_SIZE}
              onClick={() => setPage((p) => p + 1)}
              aria-label="Next page"
            >
              <ChevronRight className="w-4 h-4" />
            </Button>
          </div>
        </footer>
      </div>

      {/* Create / edit dialog */}
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent size="md" className={cn(isDark && dialogDark)}>
          <DialogHeader>
            <DialogTitle className="dark:text-zinc-100">
              {editingId ? 'Edit View' : 'Create View'}
            </DialogTitle>
            <DialogDescription className="dark:text-zinc-400">
              A reusable set of dimension filters for browsing releases.
            </DialogDescription>
          </DialogHeader>
          <DialogBody className="space-y-4">
            <Input
              label="View name"
              value={name}
              onChange={(e) => setName(e.target.value.toLowerCase().replace(/\s+/g, '_'))}
              placeholder="e.g. android_beta"
              required
              className={fieldDark}
            />
            <div className="space-y-2">
              <span className="block text-[11px] font-medium text-zinc-600 dark:text-zinc-400 uppercase tracking-wider">
                Dimensions
              </span>
              {dimRows.map((row, i) => (
                <div key={i} className="flex items-center gap-2">
                  <select
                    value={row.key}
                    onChange={(e) => setRow(i, { key: e.target.value })}
                    className={cn(selectCls, fieldDark)}
                    aria-label="Dimension key"
                  >
                    <option value="">Select key…</option>
                    {row.key && !dimensionKeys.includes(row.key) && (
                      <option value={row.key}>{row.key}</option>
                    )}
                    {dimensionKeys.map((k) => (
                      <option key={k} value={k}>
                        {k}
                      </option>
                    ))}
                  </select>
                  <div className="flex-1 min-w-0">
                    <Input
                      value={row.value}
                      onChange={(e) => setRow(i, { value: e.target.value })}
                      placeholder="value"
                      aria-label="Dimension value"
                      error={row.value.includes(';') ? "Can't contain ';'" : undefined}
                      className={fieldDark}
                    />
                  </div>
                  {dimRows.length > 1 && (
                    <Button
                      variant="ghost"
                      size="icon-sm"
                      className="text-red-500 hover:bg-red-50 dark:text-red-400 dark:hover:bg-red-950/40 shrink-0"
                      onClick={() => setDimRows((rs) => rs.filter((_, j) => j !== i))}
                      aria-label="Remove dimension row"
                    >
                      <Trash2 className="w-3.5 h-3.5" />
                    </Button>
                  )}
                </div>
              ))}
              <Button
                variant="ghost"
                size="sm"
                className="dark:text-zinc-400 dark:hover:bg-zinc-800"
                onClick={() => setDimRows((rs) => [...rs, EMPTY_ROW])}
              >
                + Add dimension
              </Button>
            </div>
            {formError && <p className="text-sm text-red-600 dark:text-red-400">{formError}</p>}
          </DialogBody>
          <DialogFooter className="dark:bg-zinc-900 dark:border-zinc-800">
            <Button variant="secondary" className={secondaryBtnDark} onClick={() => setOpen(false)}>
              Cancel
            </Button>
            <Button
              variant="primary"
              className={primaryBtnDark}
              loading={saving}
              onClick={submit}
            >
              {editingId ? 'Save changes' : 'Create view'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}

interface ViewRowProps {
  app: string;
  view: OtaReleaseView;
  canManage: boolean;
  isExpanded: boolean;
  onToggle: () => void;
  onEdit: () => void;
  onDelete: () => void;
  deleting: boolean;
  previewLoading: boolean;
  previewError: boolean;
  previewRows: OtaRelease[];
}

function ViewRow({
  app,
  view,
  canManage,
  isExpanded,
  onToggle,
  onEdit,
  onDelete,
  deleting,
  previewLoading,
  previewError,
  previewRows,
}: ViewRowProps) {
  const dims = view.dimensions ?? [];
  return (
    <>
      <tr className="border-b border-zinc-100 dark:border-zinc-800">
        <td className="py-3 px-4 text-zinc-700 dark:text-zinc-300 font-medium">{view.name}</td>
        <td className="py-3 px-4 text-zinc-700 dark:text-zinc-300">
          {dims.length === 0 ? (
            '—'
          ) : (
            <div className="flex flex-wrap gap-1.5">
              {dims.map((d, i) => (
                <Badge
                  key={i}
                  variant="default"
                  className="normal-case dark:bg-zinc-800 dark:border-zinc-700 dark:text-zinc-300"
                >
                  {d.key}: {dimStr(d.value)}
                </Badge>
              ))}
            </div>
          )}
        </td>
        <td className="py-3 px-4 text-zinc-700 dark:text-zinc-300">
          {view.created_at ? new Date(view.created_at).toLocaleString() : '—'}
        </td>
        <td className="py-3 px-4">
          <div className="flex items-center justify-end gap-1">
            <Button
              variant="ghost"
              size="icon-sm"
              className="dark:text-zinc-400 dark:hover:bg-zinc-800"
              onClick={onToggle}
              aria-label={isExpanded ? `Collapse ${view.name}` : `Expand ${view.name}`}
              aria-expanded={isExpanded}
            >
              <ChevronDown
                className={cn('w-4 h-4 transition-transform duration-150', isExpanded && 'rotate-180')}
              />
            </Button>
            {canManage && (
              <>
                <Button
                  variant="ghost"
                  size="icon-sm"
                  className="dark:text-zinc-400 dark:hover:bg-zinc-800"
                  onClick={onEdit}
                  aria-label={`Edit view ${view.name}`}
                >
                  <Pencil className="w-3.5 h-3.5" />
                </Button>
                <Button
                  variant="ghost"
                  size="icon-sm"
                  className="text-red-500 hover:bg-red-50 dark:text-red-400 dark:hover:bg-red-950/40"
                  onClick={onDelete}
                  disabled={deleting}
                  aria-label={`Delete view ${view.name}`}
                >
                  <Trash2 className="w-3.5 h-3.5" />
                </Button>
              </>
            )}
          </div>
        </td>
      </tr>
      {isExpanded && (
        <tr className="border-b border-zinc-100 dark:border-zinc-800">
          <td colSpan={4} className="px-4 py-3 sm:px-6 bg-zinc-50/60 dark:bg-zinc-800/30">
            {previewLoading ? (
              <p className="text-xs text-zinc-500 dark:text-zinc-400">Loading matching releases…</p>
            ) : previewError ? (
              <p className="text-xs text-red-600 dark:text-red-400">
                Failed to load matching releases.
              </p>
            ) : previewRows.length === 0 ? (
              <p className="text-xs text-zinc-500 dark:text-zinc-400">No releases match this view.</p>
            ) : (
              <div className="space-y-1">
                {previewRows.map((r, i) => {
                  const rid = typeof r.id === 'string' ? r.id : undefined;
                  const inner = (
                    <>
                      <span className="font-mono text-xs text-zinc-700 dark:text-zinc-300">
                        {rid ? rid.slice(0, 8) : '—'}
                      </span>
                      <OtaStatusBadge status={r.experiment?.status} />
                      <span className="text-xs text-zinc-500 dark:text-zinc-400">
                        {r.experiment?.traffic_percentage != null
                          ? `${r.experiment.traffic_percentage}%`
                          : '—'}
                      </span>
                      <span className="text-xs text-zinc-500 dark:text-zinc-400 ml-auto">
                        {r.created_at ? new Date(r.created_at).toLocaleString() : '—'}
                      </span>
                    </>
                  );
                  const rowCls = 'flex items-center gap-3 px-3 py-2 rounded-lg';
                  return rid ? (
                    <Link
                      key={rid}
                      to={`/airborne/${encodeURIComponent(app)}/releases/${encodeURIComponent(rid)}`}
                      className={cn(rowCls, 'hover:bg-zinc-100 dark:hover:bg-zinc-800')}
                    >
                      {inner}
                    </Link>
                  ) : (
                    <div key={i} className={rowCls}>
                      {inner}
                    </div>
                  );
                })}
              </div>
            )}
          </td>
        </tr>
      )}
    </>
  );
}
