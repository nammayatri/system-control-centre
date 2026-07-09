import React, { useState, useMemo, useEffect, useRef } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import {
  fetchDeploymentAccessRoster,
  fetchUsers,
  fetchAdminProducts,
  fetchProductRoles,
  assignDeploymentRole,
  revokeDeploymentAccess,
  type DeploymentRosterEntry,
} from '../api';
import { fetchProducts as fetchAppGroups } from '../../../products/releases/api';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { CardSkeleton } from '../../../shared/ui/skeleton';
import { cn } from '../../../lib/utils';
import { toast } from 'sonner';
import { ChevronDown, Search, Plus, X, GripVertical } from 'lucide-react';

// Fixed left→right swim lanes. Custom (non-system) roles land in an extra
// read-only "Other" lane rendered only when such grants exist.
const SYSTEM_LANES = ['Viewer', 'Manager', 'Admin'] as const;
type LaneRole = (typeof SYSTEM_LANES)[number];

// Subtle per-role accent so lanes are visually distinct.
const LANE_BADGE: Record<string, 'default' | 'info' | 'purple' | 'muted'> = {
  Viewer: 'default',
  Manager: 'info',
  Admin: 'purple',
};

// appGroup → personId → roleName. The board's working state.
type Board = Record<string, Record<string, string>>;

type PendingChange =
  | { type: 'assign'; personId: string; roleName: string }
  | { type: 'revoke'; personId: string };

const AccessControl: React.FC = () => {
  const queryClient = useQueryClient();

  const { data: roster = [], isLoading: rosterLoading } = useQuery({
    queryKey: ['deployment-access-roster'],
    queryFn: fetchDeploymentAccessRoster,
  });
  const { data: appGroups = [], isLoading: appGroupsLoading } = useQuery({
    queryKey: ['app-groups'],
    queryFn: fetchAppGroups,
  });
  const { data: users = [] } = useQuery({
    queryKey: ['admin-users'],
    queryFn: fetchUsers,
  });
  const { data: adminProducts = [] } = useQuery({
    queryKey: ['admin-products'],
    queryFn: fetchAdminProducts,
  });

  // Deployment access is scoped to a product; today there is exactly one
  // (autopilot), so a single roles list maps every lane name → roleId.
  const defaultProductSlug: string = adminProducts[0]?.slug || 'autopilot';
  const { data: roles = [] } = useQuery({
    queryKey: ['admin-product-roles', defaultProductSlug],
    queryFn: () => fetchProductRoles(defaultProductSlug),
    enabled: !!defaultProductSlug,
  });

  // ── Derived lookups ────────────────────────────────────────────────
  const original: Board = useMemo(() => {
    const m: Board = {};
    for (const e of roster as DeploymentRosterEntry[]) {
      (m[e.appGroup] ||= {})[e.personId] = e.roleName;
    }
    return m;
  }, [roster]);

  const personInfoById = useMemo(() => {
    const m: Record<string, { name: string; email: string }> = {};
    for (const u of users as any[]) {
      const name = u.name || `${u.firstName || ''} ${u.lastName || ''}`.trim() || u.email;
      m[u.id] = { name, email: u.email };
    }
    // Roster may reference users the list didn't include — fall back to it.
    for (const e of roster as DeploymentRosterEntry[]) {
      if (!m[e.personId]) {
        const name = `${e.firstName || ''} ${e.lastName || ''}`.trim() || e.email;
        m[e.personId] = { name, email: e.email };
      }
    }
    return m;
  }, [users, roster]);

  const roleIdByName = useMemo(() => {
    const m: Record<string, string> = {};
    for (const r of roles as any[]) m[r.name] = String(r.id);
    return m;
  }, [roles]);

  const productSlugByAg = useMemo(() => {
    const m: Record<string, string> = {};
    for (const e of roster as DeploymentRosterEntry[]) m[e.appGroup] = e.productSlug;
    return m;
  }, [roster]);
  const productSlugFor = (ag: string) => productSlugByAg[ag] || defaultProductSlug;

  // Every deployment worth listing: configured app groups ∪ any that already
  // carry a grant, sorted alphabetically.
  const allAgs = useMemo(() => {
    const s = new Set<string>([...(appGroups as string[]), ...Object.keys(original)]);
    return [...s].sort((a, b) => a.localeCompare(b));
  }, [appGroups, original]);

  // ── Working (draft) state — reset from the roster on load / after save ──
  const [draft, setDraft] = useState<Board>({});
  useEffect(() => {
    const clone: Board = {};
    for (const ag in original) clone[ag] = { ...original[ag] };
    setDraft(clone);
  }, [original]);

  // ── UI state ────────────────────────────────────────────────────────
  const [search, setSearch] = useState('');
  const [openAgs, setOpenAgs] = useState<Record<string, boolean>>({});
  const [addOpenAg, setAddOpenAg] = useState<string | null>(null);
  const [addSearch, setAddSearch] = useState('');
  const [draggingKey, setDraggingKey] = useState<string | null>(null);
  const [dragOver, setDragOver] = useState<{ ag: string; role: string } | null>(null);
  const dragRef = useRef<{ ag: string; personId: string } | null>(null);

  const toggleAg = (ag: string) => setOpenAgs((s) => ({ ...s, [ag]: !s[ag] }));

  // ── Draft mutators ──────────────────────────────────────────────────
  const setRole = (ag: string, personId: string, role: string) =>
    setDraft((prev) => ({ ...prev, [ag]: { ...(prev[ag] || {}), [personId]: role } }));

  const removeUser = (ag: string, personId: string) =>
    setDraft((prev) => {
      const next = { ...(prev[ag] || {}) };
      delete next[personId];
      return { ...prev, [ag]: next };
    });

  const discard = (ag: string) =>
    setDraft((prev) => ({ ...prev, [ag]: { ...(original[ag] || {}) } }));

  // ── Pending-change diff (draft vs original) ─────────────────────────
  const changesFor = (ag: string): PendingChange[] => {
    const orig = original[ag] || {};
    const cur = draft[ag] || {};
    const changes: PendingChange[] = [];
    for (const pid in cur) {
      if (orig[pid] !== cur[pid]) changes.push({ type: 'assign', personId: pid, roleName: cur[pid] });
    }
    for (const pid in orig) {
      if (!(pid in cur)) changes.push({ type: 'revoke', personId: pid });
    }
    return changes;
  };

  // ── Persist ─────────────────────────────────────────────────────────
  const confirmMut = useMutation({
    mutationFn: async ({ ag, changes }: { ag: string; changes: PendingChange[] }) => {
      const productSlug = productSlugFor(ag);
      for (const c of changes) {
        if (c.type === 'assign') {
          const roleId = roleIdByName[c.roleName];
          if (!roleId) throw new Error(`No role id for "${c.roleName}"`);
          await assignDeploymentRole(c.personId, { productSlug, appGroup: ag, roleId });
        } else {
          await revokeDeploymentAccess(c.personId, productSlug, ag);
        }
      }
    },
    onSuccess: (_d, vars) => {
      toast.success(
        `Saved ${vars.changes.length} change${vars.changes.length > 1 ? 's' : ''} for ${vars.ag}`
      );
      queryClient.invalidateQueries({ queryKey: ['deployment-access-roster'] });
    },
    onError: (err: any) =>
      toast.error(err?.response?.data?.error || err.message || 'Failed to save changes'),
  });

  // ── Drag & drop (native HTML5) ──────────────────────────────────────
  const onDragStart = (ag: string, personId: string) => (e: React.DragEvent) => {
    dragRef.current = { ag, personId };
    setDraggingKey(`${ag}:${personId}`);
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/plain', personId);
  };
  const onDragEnd = () => {
    dragRef.current = null;
    setDraggingKey(null);
    setDragOver(null);
  };
  const onLaneDragOver = (ag: string, role: string) => (e: React.DragEvent) => {
    const d = dragRef.current;
    if (d && d.ag === ag) {
      e.preventDefault();
      e.dataTransfer.dropEffect = 'move';
      setDragOver({ ag, role });
    }
  };
  const onLaneDrop = (ag: string, role: string) => (e: React.DragEvent) => {
    e.preventDefault();
    const d = dragRef.current;
    onDragEnd();
    if (!d || d.ag !== ag) return;
    setRole(ag, d.personId, role);
  };

  // ── Render helpers ──────────────────────────────────────────────────
  const sortByName = (a: string, b: string) =>
    (personInfoById[a]?.name || '').localeCompare(personInfoById[b]?.name || '');

  const UserCard = ({ ag, personId, roleBadge }: { ag: string; personId: string; roleBadge?: string }) => {
    const info = personInfoById[personId] || { name: personId, email: '' };
    const key = `${ag}:${personId}`;
    return (
      <div
        draggable
        onDragStart={onDragStart(ag, personId)}
        onDragEnd={onDragEnd}
        className={cn(
          'group flex items-center gap-2 rounded-lg border border-zinc-200 bg-white px-2.5 py-2 cursor-grab active:cursor-grabbing transition-shadow hover:shadow-sm',
          draggingKey === key && 'opacity-40'
        )}
      >
        <GripVertical className="w-3.5 h-3.5 text-zinc-300 shrink-0" />
        <div className="min-w-0 flex-1">
          <div className="text-sm font-medium text-zinc-800 truncate">{info.name}</div>
          <div className="text-[11px] text-zinc-400 font-mono truncate">{info.email}</div>
          {roleBadge && (
            <Badge variant="warning" size="sm" className="mt-1">
              {roleBadge}
            </Badge>
          )}
        </div>
        <button
          type="button"
          onClick={() => removeUser(ag, personId)}
          className="shrink-0 w-6 h-6 flex items-center justify-center rounded text-zinc-300 hover:text-red-600 hover:bg-red-50 transition-colors opacity-0 group-hover:opacity-100 cursor-pointer"
          aria-label="Remove from deployment"
        >
          <X className="w-3.5 h-3.5" />
        </button>
      </div>
    );
  };

  if (rosterLoading || appGroupsLoading) {
    return (
      <div className="flex flex-col w-full space-y-4">
        <CardSkeleton />
        <CardSkeleton />
        <CardSkeleton />
      </div>
    );
  }

  const visibleAgs = allAgs.filter((ag) => !search || ag.toLowerCase().includes(search.toLowerCase()));

  return (
    <div className="flex flex-col w-full pb-12">
      {/* Page header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 mb-1">
        <h1 className="text-lg sm:text-xl font-semibold text-zinc-900">Access Control</h1>
        <div className="relative flex-1 sm:flex-none">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-zinc-400" />
          <input
            type="text"
            placeholder="Search deployments"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="pl-9 pr-4 h-10 sm:h-9 w-full sm:w-64 border border-zinc-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150"
          />
        </div>
      </div>
      <p className="text-sm text-zinc-500 mb-4 sm:mb-5">
        Drag a user between Viewer, Manager and Admin to restage their role for a deployment, then
        Confirm to save. Only explicit deployment-level grants are shown.
      </p>

      {visibleAgs.length === 0 ? (
        <div className="bg-white rounded-xl border border-zinc-200 py-16 text-center text-zinc-400 text-sm">
          No deployments found.
        </div>
      ) : (
        <div className="space-y-3">
          {visibleAgs.map((ag) => {
            const cur = draft[ag] || {};
            const memberIds = Object.keys(cur);
            const changes = changesFor(ag);
            const isOpen = !!openAgs[ag];
            const otherIds = memberIds
              .filter((pid) => !SYSTEM_LANES.includes(cur[pid] as LaneRole))
              .sort(sortByName);
            const availableUsers = (users as any[])
              .filter((u) => !(u.id in cur))
              .filter((u) => {
                if (!addSearch) return true;
                const q = addSearch.toLowerCase();
                const name = (u.name || `${u.firstName || ''} ${u.lastName || ''}`).toLowerCase();
                return name.includes(q) || (u.email || '').toLowerCase().includes(q);
              });
            const savingThis = confirmMut.isPending && confirmMut.variables?.ag === ag;

            return (
              <div key={ag} className="rounded-xl border border-zinc-200 bg-white overflow-hidden">
                {/* Accordion header */}
                <button
                  type="button"
                  onClick={() => toggleAg(ag)}
                  className="w-full flex items-center gap-2.5 px-4 py-3 hover:bg-zinc-50 transition-colors"
                >
                  <ChevronDown
                    className={cn('w-4 h-4 text-zinc-400 transition-transform', !isOpen && '-rotate-90')}
                  />
                  <span className="text-sm font-semibold text-zinc-800">{ag}</span>
                  <Badge variant="muted" size="sm">
                    {memberIds.length} {memberIds.length === 1 ? 'user' : 'users'}
                  </Badge>
                  {changes.length > 0 && (
                    <Badge variant="warning" size="sm" dot>
                      {changes.length} pending
                    </Badge>
                  )}
                </button>

                {isOpen && (
                  <div className="border-t border-zinc-100 p-3 sm:p-4 bg-zinc-50/50">
                    {/* Toolbar: add user + confirm/discard */}
                    <div className="flex flex-wrap items-center justify-between gap-2 mb-3">
                      <div className="relative">
                        <Button
                          size="sm"
                          variant="secondary"
                          onClick={() => {
                            setAddSearch('');
                            setAddOpenAg(addOpenAg === ag ? null : ag);
                          }}
                        >
                          <Plus className="w-3.5 h-3.5" />
                          Add user
                        </Button>
                        {addOpenAg === ag && (
                          <div className="absolute z-20 mt-1 w-72 max-w-[80vw] bg-white border border-zinc-200 rounded-lg shadow-lg">
                            <div className="p-2 border-b border-zinc-100">
                              <input
                                autoFocus
                                type="text"
                                placeholder="Search users"
                                value={addSearch}
                                onChange={(e) => setAddSearch(e.target.value)}
                                className="w-full h-8 px-2 border border-zinc-200 rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-zinc-300"
                              />
                            </div>
                            <div className="max-h-56 overflow-y-auto py-1">
                              {availableUsers.length === 0 ? (
                                <div className="px-3 py-3 text-xs text-zinc-400 text-center">
                                  No users available
                                </div>
                              ) : (
                                availableUsers.map((u) => (
                                  <button
                                    key={u.id}
                                    type="button"
                                    onClick={() => {
                                      setRole(ag, u.id, 'Viewer');
                                      setAddOpenAg(null);
                                    }}
                                    className="w-full flex flex-col items-start px-3 py-1.5 text-left hover:bg-zinc-50 transition-colors cursor-pointer"
                                  >
                                    <span className="text-sm text-zinc-800 truncate w-full">
                                      {u.name || `${u.firstName || ''} ${u.lastName || ''}`.trim() || u.email}
                                    </span>
                                    <span className="text-[11px] text-zinc-400 font-mono truncate w-full">
                                      {u.email}
                                    </span>
                                  </button>
                                ))
                              )}
                            </div>
                            <div className="p-1.5 border-t border-zinc-100 text-center">
                              <span className="text-[11px] text-zinc-400">Added users start as Viewer</span>
                            </div>
                          </div>
                        )}
                      </div>

                      {changes.length > 0 && (
                        <div className="flex items-center gap-2">
                          <span className="text-xs text-amber-600 font-medium">
                            {changes.length} unsaved change{changes.length > 1 ? 's' : ''}
                          </span>
                          <Button
                            size="sm"
                            variant="ghost"
                            onClick={() => discard(ag)}
                            disabled={savingThis}
                          >
                            Discard
                          </Button>
                          <Button
                            size="sm"
                            variant="success"
                            loading={savingThis}
                            onClick={() => confirmMut.mutate({ ag, changes })}
                          >
                            Confirm
                          </Button>
                        </div>
                      )}
                    </div>

                    {/* Board: swim lanes */}
                    <div className="flex gap-3 overflow-x-auto pb-1">
                      {SYSTEM_LANES.map((role) => {
                        const laneIds = memberIds.filter((pid) => cur[pid] === role).sort(sortByName);
                        const isDragTarget = dragOver?.ag === ag && dragOver.role === role;
                        return (
                          <div
                            key={role}
                            onDragOver={onLaneDragOver(ag, role)}
                            onDragLeave={() => setDragOver(null)}
                            onDrop={onLaneDrop(ag, role)}
                            className={cn(
                              'flex-1 min-w-[200px] rounded-lg border p-2 transition-colors',
                              isDragTarget
                                ? 'border-emerald-400 bg-emerald-50/60'
                                : 'border-zinc-200 bg-zinc-50'
                            )}
                          >
                            <div className="flex items-center justify-between px-1 pb-2 mb-1 border-b border-zinc-200">
                              <Badge variant={LANE_BADGE[role]} size="sm">
                                {role}
                              </Badge>
                              <span className="text-xs text-zinc-400">{laneIds.length}</span>
                            </div>
                            <div className="space-y-2 min-h-[60px]">
                              {laneIds.length === 0 ? (
                                <div className="text-[11px] text-zinc-300 text-center py-4 select-none">
                                  Drop here
                                </div>
                              ) : (
                                laneIds.map((pid) => (
                                  <UserCard key={pid} ag={ag} personId={pid} />
                                ))
                              )}
                            </div>
                          </div>
                        );
                      })}

                      {/* Custom-role grants — read-only, drag out only */}
                      {otherIds.length > 0 && (
                        <div className="flex-1 min-w-[200px] rounded-lg border border-dashed border-zinc-300 bg-white p-2">
                          <div className="flex items-center justify-between px-1 pb-2 mb-1 border-b border-zinc-200">
                            <Badge variant="muted" size="sm">
                              Other
                            </Badge>
                            <span className="text-xs text-zinc-400">{otherIds.length}</span>
                          </div>
                          <div className="space-y-2 min-h-[60px]">
                            {otherIds.map((pid) => (
                              <UserCard key={pid} ag={ag} personId={pid} roleBadge={cur[pid]} />
                            ))}
                          </div>
                        </div>
                      )}
                    </div>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
};

export default AccessControl;
