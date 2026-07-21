import { useEffect, useMemo, useState } from 'react';
import * as Popover from '@radix-ui/react-popover';
import {
  Check,
  ChevronDown,
  ChevronRight,
  File as FileIcon,
  Search,
  Tag as TagIcon,
} from 'lucide-react';
import { useOtaFileGroups, useOtaFileTags } from '../hooks';
import type { OtaFileGroup, OtaSelectedFile } from '../types';
import { useOtaTheme } from '../theme';
import { Badge } from '../../../shared/ui/badge';
import { Input } from '../../../shared/ui/input';
import { useSearch } from '../../../shared/hooks';
import { cn, formatDate } from '../../../lib/utils';

const PAGE_SIZE = 25;
const TAG_CHIPS = 2;
const fieldDark = 'dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-100';

const formatSize = (bytes: number | undefined): string => {
  if (bytes == null) return '—';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
};

const tagOf = (g: OtaFileGroup, version: number): string | undefined =>
  (g.tags ?? []).find((t) => t.version === version)?.tag;

const baseName = (path: string): string => path.split('/').pop() || path;

// Latest = highest version number (upstream orders newest-first; derive anyway).
const latestOf = (g: OtaFileGroup) =>
  [...(g.versions ?? [])].sort((a, b) => b.version - a.version)[0];

function CheckBox({
  checked,
  onClick,
  label,
}: {
  checked: boolean;
  onClick: (e: React.MouseEvent) => void;
  label: string;
}) {
  return (
    <button
      type="button"
      role="checkbox"
      aria-checked={checked}
      aria-label={label}
      onClick={onClick}
      className={cn(
        'w-4 h-4 rounded border shrink-0 flex items-center justify-center cursor-pointer transition-colors',
        checked
          ? 'bg-airborne border-airborne text-white'
          : 'border-zinc-300 dark:border-zinc-600 hover:border-airborne',
      )}
    >
      {checked && <Check className="w-3 h-3" />}
    </button>
  );
}

interface OtaFileChooserProps {
  app: string;
  /** single = one file total (index); multi = at most one VERSION per file. */
  mode: 'single' | 'multi';
  value: OtaSelectedFile[];
  onChange: (next: OtaSelectedFile[]) => void;
  /** File paths hidden from the list (e.g. the index chosen in step 1). */
  excludePaths?: string[];
}

// Mirrors the airborne dashboard file-chooser: search + tag filter, groups
// with a checkbox that picks the LATEST version, expandable per-version rows,
// select-all-loaded, and a "(N in package)" counter for excluded paths.
export function OtaFileChooser({ app, mode, value, onChange, excludePaths }: OtaFileChooserProps) {
  const { isDark } = useOtaTheme();
  const { search, debouncedSearch, setSearch } = useSearch();
  const [tagFilters, setTagFilters] = useState<string[]>([]);
  const [tagQuery, setTagQuery] = useState('');
  const [page, setPage] = useState(1);
  const [acc, setAcc] = useState<OtaFileGroup[]>([]);
  const [expanded, setExpanded] = useState<string | null>(null);

  const tagsKey = tagFilters.join(',');

  // Filter changes restart the accumulated list.
  useEffect(() => {
    setPage(1);
    setAcc([]);
  }, [debouncedSearch, tagsKey]);

  const { data, isLoading, isFetching } = useOtaFileGroups(app, {
    page,
    count: PAGE_SIZE,
    search: debouncedSearch || undefined,
    tags: tagsKey || undefined,
  });
  const { data: tagsData } = useOtaFileTags(app);

  // Accumulate pages so "Load more" appends rather than replaces.
  useEffect(() => {
    const incoming = data?.groups;
    if (!incoming) return;
    setAcc((prev) => {
      if (page === 1) return incoming;
      const seen = new Set(prev.map((g) => g.file_path));
      return [...prev, ...incoming.filter((g) => !seen.has(g.file_path))];
    });
  }, [data, page]);

  const excluded = useMemo(() => new Set(excludePaths ?? []), [excludePaths]);
  const groups = acc.filter((g) => !excluded.has(g.file_path));
  const totalPages = data?.total_pages ?? 1;
  const hasMore = page < totalPages;

  const selectedPaths = useMemo(() => new Set(value.map((s) => s.file_path)), [value]);
  const selectedFor = (path: string) => value.find((s) => s.file_path === path);

  const entryFor = (g: OtaFileGroup, version: number, url?: string): OtaSelectedFile => ({
    file_path: g.file_path,
    version,
    url,
    tag: tagOf(g, version),
  });

  // Row checkbox: toggle the file, picking its latest version (airborne
  // file-chooser.tsx — checkbox selects versions[0] without expanding).
  const toggleGroup = (g: OtaFileGroup) => {
    if (selectedPaths.has(g.file_path)) {
      onChange(value.filter((s) => s.file_path !== g.file_path));
      return;
    }
    const v = latestOf(g);
    if (v) onChange([...value, entryFor(g, v.version, v.url)]);
  };

  const pickVersion = (g: OtaFileGroup, version: number, url?: string) => {
    if (mode === 'single') {
      onChange([entryFor(g, version, url)]);
      return;
    }
    const current = selectedFor(g.file_path);
    if (current?.version === version) {
      // Clicking the selected version clears it.
      onChange(value.filter((s) => s.file_path !== g.file_path));
      return;
    }
    // At most one version per file: replace any existing pick for this path.
    onChange([...value.filter((s) => s.file_path !== g.file_path), entryFor(g, version, url)]);
  };

  const allLoadedSelected = groups.length > 0 && groups.every((g) => selectedPaths.has(g.file_path));
  const toggleSelectAll = () => {
    if (allLoadedSelected) {
      const loaded = new Set(groups.map((g) => g.file_path));
      onChange(value.filter((s) => !loaded.has(s.file_path)));
      return;
    }
    const additions: OtaSelectedFile[] = [];
    for (const g of groups) {
      if (selectedPaths.has(g.file_path)) continue;
      const v = latestOf(g);
      if (v) additions.push(entryFor(g, v.version, v.url));
    }
    onChange([...value, ...additions]);
  };

  const tagOptions = (tagsData?.data ?? []).filter((t) =>
    tagQuery.trim() ? t.tag.toLowerCase().includes(tagQuery.trim().toLowerCase()) : true,
  );

  return (
    <div className="space-y-3">
      {/* Search */}
      <Input
        placeholder="Search files…"
        icon={<Search className="w-4 h-4" />}
        value={search}
        onChange={(e) => setSearch(e.target.value)}
        className={fieldDark}
      />

      {/* Tag filter */}
      <div className="flex items-center justify-between gap-3 flex-wrap">
        <Popover.Root>
          <Popover.Trigger asChild>
            <button
              type="button"
              className={cn(
                'inline-flex items-center gap-2 rounded-lg border px-3 h-9 text-sm font-medium cursor-pointer transition-colors',
                'border-zinc-300 bg-white text-zinc-700 hover:bg-zinc-50',
                'dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-200 dark:hover:bg-zinc-800',
              )}
            >
              <TagIcon className="w-4 h-4 text-zinc-400 dark:text-zinc-500" />
              Tags
              {tagFilters.length > 0 && (
                <span className="text-xs text-airborne">({tagFilters.length})</span>
              )}
              <ChevronDown className="w-4 h-4 text-zinc-400 dark:text-zinc-500" />
            </button>
          </Popover.Trigger>
          <Popover.Portal>
            <Popover.Content
              align="start"
              sideOffset={6}
              className={cn(
                'z-50 w-64 rounded-xl border p-2 shadow-lg',
                'border-zinc-200 bg-white',
                isDark && 'dark border-zinc-800 bg-zinc-900',
              )}
            >
              <Input
                placeholder="Search tags…"
                value={tagQuery}
                onChange={(e) => setTagQuery(e.target.value)}
                className={fieldDark}
              />
              <div className="mt-2 max-h-64 overflow-y-auto">
                {tagOptions.length === 0 ? (
                  <p className="px-2 py-4 text-center text-xs text-zinc-400 dark:text-zinc-500">
                    No tags
                  </p>
                ) : (
                  tagOptions.map((t) => {
                    const on = tagFilters.includes(t.tag);
                    return (
                      <button
                        key={t.tag}
                        type="button"
                        onClick={() =>
                          setTagFilters((prev) =>
                            on ? prev.filter((x) => x !== t.tag) : [...prev, t.tag],
                          )
                        }
                        className={cn(
                          'w-full flex items-center justify-between gap-2 px-2 py-1.5 rounded-md text-sm cursor-pointer',
                          on
                            ? 'bg-airborne/10 text-airborne'
                            : 'text-zinc-700 hover:bg-zinc-100 dark:text-zinc-300 dark:hover:bg-zinc-800',
                        )}
                      >
                        <span className="font-mono truncate">{t.tag}</span>
                        <span className="text-xs text-zinc-400 dark:text-zinc-500 tabular-nums">
                          {t.count}
                        </span>
                      </button>
                    );
                  })
                )}
              </div>
            </Popover.Content>
          </Popover.Portal>
        </Popover.Root>
      </div>

      {/* Select-all bar (multi) + counter */}
      {mode === 'multi' && (
        <div className="flex items-center justify-between gap-3">
          <div className="flex items-center gap-2">
            <CheckBox
              checked={allLoadedSelected}
              onClick={toggleSelectAll}
              label="Select all loaded files"
            />
            <button
              type="button"
              onClick={toggleSelectAll}
              className="text-xs text-zinc-500 dark:text-zinc-400 cursor-pointer"
            >
              Select all loaded files
            </button>
          </div>
          <span className="text-xs text-zinc-500 dark:text-zinc-400">
            {groups.length} file{groups.length !== 1 ? 's' : ''}
            {(excludePaths?.length ?? 0) > 0 && ` (${excludePaths!.length} in package)`}
          </span>
        </div>
      )}

      {/* File groups */}
      <div className="rounded-lg border border-zinc-200 dark:border-zinc-800 overflow-hidden">
        {isLoading && acc.length === 0 ? (
          <div className="py-12 text-center text-sm text-zinc-400 dark:text-zinc-500">Loading…</div>
        ) : groups.length === 0 ? (
          <div className="py-12 flex flex-col items-center gap-2 text-sm text-zinc-400 dark:text-zinc-500">
            <FileIcon className="w-8 h-8 opacity-30" />
            {debouncedSearch || tagFilters.length > 0 ? 'No files match your filters' : 'No files found'}
          </div>
        ) : (
          <div className="divide-y divide-zinc-100 dark:divide-zinc-800">
            {groups.map((g) => {
              const isOpen = expanded === g.file_path;
              const picked = selectedFor(g.file_path);
              const versions = [...(g.versions ?? [])].sort((a, b) => b.version - a.version);
              const tags = g.tags ?? [];
              return (
                <div key={g.file_path}>
                  <div
                    className={cn(
                      'flex items-center gap-2 px-3 py-2 cursor-pointer transition-colors hover:bg-zinc-50 dark:hover:bg-zinc-800/50',
                      isOpen && 'bg-zinc-50 dark:bg-zinc-800/40',
                    )}
                    onClick={() => setExpanded(isOpen ? null : g.file_path)}
                  >
                    {mode === 'multi' && (
                      <CheckBox
                        checked={!!picked}
                        onClick={(e) => {
                          e.stopPropagation();
                          toggleGroup(g);
                        }}
                        label={`Select ${g.file_path}`}
                      />
                    )}
                    <button
                      type="button"
                      className="p-0.5 rounded hover:bg-zinc-100 dark:hover:bg-zinc-800 shrink-0"
                      onClick={(e) => {
                        e.stopPropagation();
                        setExpanded(isOpen ? null : g.file_path);
                      }}
                      aria-label={isOpen ? 'Collapse versions' : 'Expand versions'}
                    >
                      {isOpen ? (
                        <ChevronDown className="w-4 h-4 text-zinc-400 dark:text-zinc-500" />
                      ) : (
                        <ChevronRight className="w-4 h-4 text-zinc-400 dark:text-zinc-500" />
                      )}
                    </button>

                    <FileIcon className="w-4 h-4 text-zinc-400/70 dark:text-zinc-500/70 shrink-0" />

                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2">
                        <span
                          className="font-mono text-sm text-zinc-800 dark:text-zinc-200 truncate"
                          title={g.file_path}
                        >
                          {baseName(g.file_path)}
                        </span>
                        <span className="text-xs text-zinc-400 dark:text-zinc-500 shrink-0">
                          {g.total_versions ?? versions.length}v
                        </span>
                      </div>
                      <div className="text-xs text-zinc-400 dark:text-zinc-500 truncate">
                        {g.file_path}
                      </div>
                    </div>

                    <div className="hidden sm:flex items-center gap-1.5 shrink-0">
                      {tags.slice(0, TAG_CHIPS).map((t) => (
                        <Badge
                          key={`${t.tag}-${t.version}`}
                          className="font-mono dark:bg-zinc-800 dark:border-zinc-700 dark:text-zinc-300"
                        >
                          {t.tag}
                        </Badge>
                      ))}
                      {tags.length > TAG_CHIPS && (
                        <span className="text-[11px] text-zinc-400 dark:text-zinc-500">
                          +{tags.length - TAG_CHIPS}
                        </span>
                      )}
                    </div>

                    {picked && (
                      <Badge
                        variant="success"
                        className="shrink-0 font-mono dark:bg-transparent dark:border-emerald-700 dark:text-emerald-300"
                      >
                        v{picked.version}
                      </Badge>
                    )}
                  </div>

                  {isOpen && (
                    <div className="bg-zinc-50/60 dark:bg-zinc-800/30 border-t border-zinc-100 dark:border-zinc-800">
                      {versions.map((v) => {
                        const on = picked?.version === v.version;
                        const vTag = tagOf(g, v.version);
                        return (
                          <div
                            key={v.version}
                            onClick={() => pickVersion(g, v.version, v.url)}
                            className={cn(
                              'flex items-center gap-3 px-3 py-2 pl-10 cursor-pointer transition-colors border-b border-zinc-100 dark:border-zinc-800/70 last:border-0',
                              on
                                ? 'bg-emerald-500/5'
                                : 'hover:bg-zinc-100 dark:hover:bg-zinc-800/60',
                            )}
                          >
                            <CheckBox
                              checked={on}
                              onClick={(e) => {
                                e.stopPropagation();
                                pickVersion(g, v.version, v.url);
                              }}
                              label={`Select version ${v.version}`}
                            />
                            <div className="flex-1 min-w-0">
                              <div className="flex items-center gap-2">
                                <span
                                  className={cn(
                                    'text-sm font-medium',
                                    on
                                      ? 'text-emerald-600 dark:text-emerald-300'
                                      : 'text-zinc-800 dark:text-zinc-200',
                                  )}
                                >
                                  v{v.version}
                                </span>
                                {vTag && (
                                  <Badge className="font-mono dark:bg-zinc-800 dark:border-zinc-700 dark:text-zinc-300">
                                    {vTag}
                                  </Badge>
                                )}
                              </div>
                              <div className="flex items-center gap-3 text-xs text-zinc-500 dark:text-zinc-400">
                                <span>{formatSize(v.size)}</span>
                                <span>{formatDate(v.created_at)}</span>
                              </div>
                            </div>
                          </div>
                        );
                      })}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}

        {/* Load-more footer */}
        {(groups.length > 0 || hasMore) && (
          <div className="border-t border-zinc-100 dark:border-zinc-800 py-2 flex items-center justify-center">
            {hasMore ? (
              <button
                type="button"
                disabled={isFetching}
                onClick={() => setPage((p) => p + 1)}
                className="text-xs text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-200 cursor-pointer disabled:cursor-not-allowed px-3 py-1 rounded-md border border-zinc-200 dark:border-zinc-700"
              >
                {isFetching ? 'Loading more files…' : 'Load more'}
              </button>
            ) : (
              <span className="text-xs text-zinc-400 dark:text-zinc-500">
                You&apos;ve reached the end
              </span>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
