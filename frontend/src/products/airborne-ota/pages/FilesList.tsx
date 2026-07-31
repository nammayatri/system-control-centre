import { Fragment, useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { ChevronDown, ChevronLeft, ChevronRight, Filter, Pencil, Plus, Search } from 'lucide-react';
import {
  useCreateOtaFile,
  useOtaAccess,
  useOtaFileGroups,
  useOtaFileTags,
  useUpdateOtaFileTag,
} from '../hooks';
import type { OtaFileGroup, OtaFileGroupVersion } from '../types';
import { OtaAppHeader } from '../components/OtaAppHeader';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
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
import { useSearch } from '../../../shared/hooks';
import { useOtaTheme } from '../theme';
import { cn, formatDate } from '../../../lib/utils';
import { OtaErrorState } from '../components/OtaErrorState';

const PAGE_SIZE = 15;
// How many tag chips to show on a collapsed group row before "+N".
const TAG_CHIPS = 2;

const fieldDark = 'dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-100';
const primaryBtnDark = 'bg-airborne border-airborne text-white hover:bg-airborne-hover';
const secondaryBtnDark =
  'dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800';
// Dialog portals out of the .dark subtree — re-enter dark scope on the content.
const dialogDark = 'dark bg-zinc-900 border-zinc-800 sm:border-zinc-800';

interface RegisterForm {
  filePath: string;
  url: string;
  tag: string;
  size: string;
  checksum: string;
  metadata: string;
}

const EMPTY_REGISTER: RegisterForm = {
  filePath: '',
  url: '',
  tag: '',
  size: '',
  checksum: '',
  metadata: '',
};

const formatSize = (bytes: number | undefined): string => {
  if (bytes == null) return '—';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
};

// Latest = highest version number. Upstream orders newest-first, but deriving
// it is cheap and removes the dependency on that ordering.
const latestOf = (g: OtaFileGroup): OtaFileGroupVersion | null =>
  (g.versions ?? []).reduce<OtaFileGroupVersion | null>(
    (best, v) => (best == null || v.version > best.version ? v : best),
    null,
  );

function TagChip({ tag }: { tag: string }) {
  return (
    <Badge className="font-mono dark:bg-zinc-800 dark:border-zinc-700 dark:text-zinc-300">
      {tag}
    </Badge>
  );
}

export default function FilesList() {
  const { app } = useParams<{ app: string }>();
  const { isDark } = useOtaTheme();
  const [page, setPage] = useState(1);
  const { search, debouncedSearch, setSearch } = useSearch();
  const [tagFilter, setTagFilter] = useState('');
  const [expanded, setExpanded] = useState<string | null>(null);

  // New filter values restart pagination.
  useEffect(() => {
    setPage(1);
  }, [debouncedSearch, tagFilter]);

  const { data, isLoading, isFetching, error } = useOtaFileGroups(app, {
    page,
    count: PAGE_SIZE,
    search: debouncedSearch || undefined,
    tags: tagFilter || undefined,
  });
  const { data: tagsData } = useOtaFileTags(app);

  const { data: access } = useOtaAccess();
  const perms = access?.apps.find((a) => a.appRef === app)?.permissions ?? [];
  const canManage = perms.includes('OTA_FILE_MANAGE');

  const createMutation = useCreateOtaFile(app);
  const tagMutation = useUpdateOtaFileTag(app);

  const [registerOpen, setRegisterOpen] = useState(false);
  const [regForm, setRegForm] = useState<RegisterForm>(EMPTY_REGISTER);
  const [tagTarget, setTagTarget] = useState<{ fileKey: string; label: string } | null>(null);
  const [tagValue, setTagValue] = useState('');

  // Airborne requires size+checksum both-or-neither: size >= 1, checksum 64 hex.
  const hasSize = regForm.size.trim() !== '';
  const hasChecksum = regForm.checksum.trim() !== '';
  const sizeInvalid = hasSize && (!Number.isInteger(Number(regForm.size)) || Number(regForm.size) < 1);
  const checksumInvalid = hasChecksum && !/^[0-9a-fA-F]{64}$/.test(regForm.checksum.trim());
  const pairInvalid = hasSize !== hasChecksum;
  // Metadata is free-form JSON upstream (FileRequest.metadata), so it only has
  // to parse — but it must parse, or the file silently registers without it.
  const metadataInvalid = (() => {
    const raw = regForm.metadata.trim();
    if (!raw) return false;
    try {
      JSON.parse(raw);
      return false;
    } catch {
      return true;
    }
  })();
  const canRegister =
    regForm.filePath.trim() !== '' &&
    regForm.url.trim() !== '' &&
    !sizeInvalid &&
    !checksumInvalid &&
    !pairInvalid &&
    !metadataInvalid;

  const openRegister = () => {
    setRegForm(EMPTY_REGISTER);
    setRegisterOpen(true);
  };

  const submitRegister = () => {
    if (!canRegister) return;
    const meta = regForm.metadata.trim();
    createMutation.mutate(
      {
        file_path: regForm.filePath.trim(),
        url: regForm.url.trim(),
        ...(regForm.tag.trim() ? { tag: regForm.tag.trim() } : {}),
        ...(meta ? { metadata: JSON.parse(meta) } : {}),
        ...(hasSize ? { size: Number(regForm.size), checksum: regForm.checksum.trim() } : {}),
      },
      { onSuccess: () => setRegisterOpen(false) },
    );
  };

  const openTagEdit = (filePath: string, version: number, current: string) => {
    setTagTarget({ fileKey: `${filePath}@version:${version}`, label: `${filePath} · v${version}` });
    setTagValue(current);
  };

  const submitTagEdit = () => {
    if (!tagTarget || !tagValue.trim()) return;
    tagMutation.mutate(
      { fileKey: tagTarget.fileKey, tag: tagValue.trim() },
      { onSuccess: () => setTagTarget(null) },
    );
  };

  const groups = data?.groups ?? [];
  const totalItems = data?.total_items;
  const totalPages = data?.total_pages ?? 1;

  const tagOptions = [
    { value: '', label: 'All tags' },
    ...(tagsData?.data ?? []).map((t) => ({ value: t.tag, label: `${t.tag} (${t.count})` })),
  ];

  return (
    <div className="flex flex-col flex-1 w-full pb-12 space-y-4">
      <OtaAppHeader app={app!} title="Files" />

      {/* Page heading + primary action */}
      <div className="flex items-start justify-between gap-3 flex-wrap">
        <div>
          <h1 className="text-xl sm:text-2xl font-bold text-zinc-900 dark:text-zinc-100">Files</h1>
          <p className="text-sm text-zinc-500 dark:text-zinc-400 mt-1">
            Manage your application assets and resources
          </p>
        </div>
        {canManage && (
          <Button size="sm" className={primaryBtnDark} onClick={openRegister}>
            <Plus className="w-4 h-4" />
            Create File
          </Button>
        )}
      </div>

      {/* Filter bar */}
      <div className="rounded-xl border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900 p-3 sm:p-4 flex flex-col sm:flex-row gap-3">
        <div className="flex-1 min-w-0">
          <Input
            placeholder="Search files by path…"
            icon={<Search className="w-4 h-4" />}
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className={fieldDark}
          />
        </div>
        <div className="w-full sm:w-60 flex items-center gap-2">
          <Filter className="w-4 h-4 text-zinc-400 dark:text-zinc-500 shrink-0" />
          <div className="flex-1 min-w-0">
            <SelectInput
              aria-label="Filter by tag"
              options={tagOptions}
              value={tagFilter}
              onChange={(e) => setTagFilter(e.target.value)}
              className={fieldDark}
            />
          </div>
        </div>
      </div>

      {/* Groups table */}
      <div className="bg-white border-zinc-200 dark:bg-zinc-900 dark:border-zinc-800 rounded-xl border">
        <header className="px-4 py-3 sm:px-6 sm:py-4 border-b border-zinc-100 dark:border-zinc-800">
          <h2 className="text-sm font-semibold text-zinc-900 dark:text-zinc-100">
            Files{totalItems != null ? ` (${totalItems})` : ''}
          </h2>
          <p className="text-xs text-zinc-500 dark:text-zinc-400 mt-0.5">
            All files with version history and tags
          </p>
        </header>

        {error && !data ? (
          <div className="p-4">
            <OtaErrorState error={error} what="files for this app" />
          </div>
        ) : isLoading ? (
          <div className="dark:invert">
            <TableSkeleton rows={6} cols={4} />
          </div>
        ) : groups.length === 0 ? (
          <div className="py-16 text-center text-zinc-400 dark:text-zinc-500 text-sm">
            No files{debouncedSearch || tagFilter ? ' match the current filters' : ' for this app'}.
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left">
              <thead>
                <tr className="bg-zinc-50 border-b border-zinc-200 dark:bg-zinc-800/50 dark:border-zinc-800 text-[11px] text-zinc-500 dark:text-zinc-500 font-medium uppercase tracking-wider">
                  <th className="py-3 px-4 w-10" />
                  <th className="py-3 px-4">File Path</th>
                  <th className="py-3 px-4 w-32">Latest Version</th>
                  <th className="py-3 px-4 w-56">Tags</th>
                  <th className="py-3 px-4 w-24">Size</th>
                </tr>
              </thead>
              <tbody className="text-sm">
                {groups.map((g) => {
                  const isOpen = expanded === g.file_path;
                  const versions = [...(g.versions ?? [])].sort((a, b) => b.version - a.version);
                  const latest = latestOf(g);
                  const tags = g.tags ?? [];
                  // version -> tag, so the expanded rows can show each one's tag.
                  const tagFor = new Map(tags.map((t) => [t.version, t.tag]));
                  return (
                    <Fragment key={g.file_path}>
                      <tr
                        className="border-b border-zinc-100 dark:border-zinc-800 cursor-pointer hover:bg-zinc-50 dark:hover:bg-airborne-nav"
                        onClick={() => setExpanded(isOpen ? null : g.file_path)}
                      >
                        <td className="py-3 px-4">
                          <ChevronDown
                            className={cn(
                              'w-4 h-4 text-zinc-400 dark:text-zinc-500 transition-transform duration-150',
                              !isOpen && '-rotate-90',
                            )}
                          />
                        </td>
                        <td className="py-3 px-4">
                          <span
                            className="font-mono text-xs text-zinc-700 dark:text-zinc-300 truncate block max-w-[480px]"
                            title={g.file_path}
                          >
                            {g.file_path}
                          </span>
                        </td>
                        <td className="py-3 px-4 font-mono text-xs text-zinc-700 dark:text-zinc-300">
                          {latest?.version ?? g.total_versions ?? '—'}
                        </td>
                        <td className="py-3 px-4">
                          {tags.length === 0 ? (
                            <span className="text-xs text-zinc-400 dark:text-zinc-500">—</span>
                          ) : (
                            <div className="flex items-center gap-1.5 flex-wrap">
                              {tags.slice(0, TAG_CHIPS).map((t) => (
                                <TagChip key={`${t.tag}-${t.version}`} tag={t.tag} />
                              ))}
                              {tags.length > TAG_CHIPS && (
                                <span className="text-xs text-zinc-400 dark:text-zinc-500">
                                  +{tags.length - TAG_CHIPS}
                                </span>
                              )}
                            </div>
                          )}
                        </td>
                        <td className="py-3 px-4 text-zinc-500 dark:text-zinc-400 text-xs">
                          {formatSize(latest?.size)}
                        </td>
                      </tr>

                      {isOpen && (
                        <tr className="border-b border-zinc-100 dark:border-zinc-800">
                          <td colSpan={5} className="p-0 bg-zinc-50/60 dark:bg-zinc-800/30">
                            <div className="overflow-x-auto">
                              <table className="w-full text-left">
                                <thead>
                                  <tr className="text-[11px] text-zinc-500 dark:text-zinc-500 font-medium uppercase tracking-wider border-b border-zinc-200 dark:border-zinc-800">
                                    <th className="py-2.5 px-4 w-20">Version</th>
                                    <th className="py-2.5 px-4 w-28">Tag</th>
                                    <th className="py-2.5 px-4">URL</th>
                                    <th className="py-2.5 px-4 w-24">Size</th>
                                    <th className="py-2.5 px-4 w-32">Created</th>
                                    {canManage && <th className="py-2.5 px-4 w-28 text-right">Actions</th>}
                                  </tr>
                                </thead>
                                <tbody>
                                  {versions.map((v) => {
                                    const vTag = tagFor.get(v.version) ?? '';
                                    return (
                                      <tr
                                        key={v.version}
                                        className="border-b border-zinc-100 dark:border-zinc-800/70 last:border-b-0"
                                      >
                                        <td className="py-2.5 px-4 font-mono text-xs text-zinc-700 dark:text-zinc-300">
                                          {v.version}
                                        </td>
                                        <td className="py-2.5 px-4">
                                          {vTag ? (
                                            <TagChip tag={vTag} />
                                          ) : (
                                            <span className="text-xs text-zinc-400 dark:text-zinc-500">—</span>
                                          )}
                                        </td>
                                        <td className="py-2.5 px-4">
                                          <a
                                            href={v.url}
                                            target="_blank"
                                            rel="noreferrer"
                                            onClick={(e) => e.stopPropagation()}
                                            className="font-mono text-xs text-zinc-500 dark:text-zinc-400 hover:text-airborne dark:hover:text-airborne truncate block max-w-[420px]"
                                            title={v.url}
                                          >
                                            {v.url}
                                          </a>
                                        </td>
                                        <td className="py-2.5 px-4 text-zinc-500 dark:text-zinc-400 text-xs">
                                          {formatSize(v.size)}
                                        </td>
                                        <td className="py-2.5 px-4 text-zinc-500 dark:text-zinc-400 text-xs whitespace-nowrap">
                                          {formatDate(v.created_at)}
                                        </td>
                                        {canManage && (
                                          <td className="py-2.5 px-4">
                                            <div className="flex items-center justify-end">
                                              <Button
                                                variant="ghost"
                                                size="sm"
                                                className="dark:text-zinc-400 dark:hover:bg-zinc-800"
                                                onClick={(e) => {
                                                  e.stopPropagation();
                                                  openTagEdit(g.file_path, v.version, vTag);
                                                }}
                                              >
                                                <Pencil className="w-3.5 h-3.5" />
                                                Edit Tag
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
                          </td>
                        </tr>
                      )}
                    </Fragment>
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
              disabled={page >= totalPages}
              onClick={() => setPage((p) => p + 1)}
              aria-label="Next page"
            >
              <ChevronRight className="w-4 h-4" />
            </Button>
          </div>
        </footer>
      </div>

      {/* Register file dialog */}
      <Dialog open={registerOpen} onOpenChange={setRegisterOpen}>
        <DialogContent size="md" className={cn(isDark && dialogDark)}>
          <DialogHeader>
            <DialogTitle className="dark:text-zinc-100">Create file</DialogTitle>
            <DialogDescription className="dark:text-zinc-400">
              Provide a URL and metadata to register a file in your application
            </DialogDescription>
          </DialogHeader>
          <DialogBody className="space-y-4">
            <Input
              label="File Path *"
              value={regForm.filePath}
              onChange={(e) => setRegForm((f) => ({ ...f, filePath: e.target.value }))}
              placeholder="e.g., dist/app-bundle.js"
              required
              className={fieldDark}
            />
            <Input
              label="URL *"
              value={regForm.url}
              onChange={(e) => setRegForm((f) => ({ ...f, url: e.target.value }))}
              placeholder="https://cdn.example.com/dist/app-bundle.js"
              required
              className={fieldDark}
            />
            <Input
              label="Tag"
              value={regForm.tag}
              onChange={(e) => setRegForm((f) => ({ ...f, tag: e.target.value }))}
              placeholder="latest"
              className={fieldDark}
            />
            <Input
              label="Checksum (SHA256 hex, optional)"
              value={regForm.checksum}
              onChange={(e) => setRegForm((f) => ({ ...f, checksum: e.target.value }))}
              placeholder="e.g., a3f2b1c4d5e6f7890abcdef1234567890abcdef1234567890ab"
              error={checksumInvalid ? 'Must be exactly 64 hex characters (SHA-256)' : undefined}
              hint="Required only for authenticated/private files. Must be 64 hex characters. Must be provided with size."
              className={fieldDark}
            />
            <Input
              label="Size (bytes, optional)"
              type="number"
              min={1}
              value={regForm.size}
              onChange={(e) => setRegForm((f) => ({ ...f, size: e.target.value }))}
              placeholder="e.g., 1048576"
              error={sizeInvalid ? 'Must be an integer of at least 1' : undefined}
              hint="File size in bytes. Must be provided with checksum."
              className={fieldDark}
            />
            <Textarea
              label="Metadata (JSON, optional)"
              rows={3}
              value={regForm.metadata}
              onChange={(e) => setRegForm((f) => ({ ...f, metadata: e.target.value }))}
              placeholder='{"commit":"abc123"}'
              error={metadataInvalid ? 'Must be valid JSON' : undefined}
              className={cn(fieldDark, 'font-mono text-xs')}
            />
            {pairInvalid && (
              <p className="text-xs text-red-600 dark:text-red-400">
                Provide checksum and size together, or leave both blank (airborne computes them
                from the URL).
              </p>
            )}
          </DialogBody>
          <DialogFooter className="dark:bg-zinc-900 dark:border-zinc-800">
            <Button variant="secondary" className={secondaryBtnDark} onClick={() => setRegisterOpen(false)}>
              Cancel
            </Button>
            <Button
              variant="primary"
              className={primaryBtnDark}
              disabled={!canRegister}
              loading={createMutation.isPending}
              onClick={submitRegister}
            >
              Create
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Edit tag dialog */}
      <Dialog open={tagTarget != null} onOpenChange={(open) => !open && setTagTarget(null)}>
        <DialogContent size="sm" className={cn(isDark && dialogDark)}>
          <DialogHeader>
            <DialogTitle className="dark:text-zinc-100">Edit tag</DialogTitle>
            <DialogDescription className="dark:text-zinc-400 font-mono truncate">
              {tagTarget?.label}
            </DialogDescription>
          </DialogHeader>
          <DialogBody>
            <Input
              label="Tag"
              value={tagValue}
              onChange={(e) => setTagValue(e.target.value)}
              placeholder="e.g. stable"
              required
              className={fieldDark}
            />
          </DialogBody>
          <DialogFooter className="dark:bg-zinc-900 dark:border-zinc-800">
            <Button variant="secondary" className={secondaryBtnDark} onClick={() => setTagTarget(null)}>
              Cancel
            </Button>
            <Button
              variant="primary"
              className={primaryBtnDark}
              disabled={!tagValue.trim()}
              loading={tagMutation.isPending}
              onClick={submitTagEdit}
            >
              Save tag
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
