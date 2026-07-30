import React, { useState, useMemo, useEffect, useRef, useCallback } from 'react';
import { motion, useReducedMotion } from 'framer-motion';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import {
  fetchDeploymentAccessRoster,
  fetchProductAccessRoster,
  fetchUsers,
  fetchAdminProducts,
  fetchProductRoles,
  assignDeploymentRole,
  revokeDeploymentAccess,
  assignRole,
  revokeProductAccess,
  type DeploymentRosterEntry,
  type ProductRosterEntry,
} from '../api';
import { fetchProducts as fetchAppGroups } from '../../../products/releases/api';
import { useAuth } from '../../auth/AuthContext';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { CardSkeleton } from '../../../shared/ui/skeleton';
import { cn } from '../../../lib/utils';
import { toast } from 'sonner';
import { ChevronDown, Search, UserPlus, X, GripVertical, Lock, AlertTriangle } from 'lucide-react';

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

// `data.error` is the API's error envelope; falls back to the transport message.
const errMessage = (err: unknown, fallback = 'Request failed'): string =>
  (err as any)?.response?.data?.error || (err as any)?.message || fallback;

// The board thinks in lane names; the assign APIs take role ids.
const roleIdsByName = (rs: any[]): Record<string, string> =>
  Object.fromEntries(rs.map((r) => [r.name, String(r.id)]));

// Two scopes: product-wide grants (sc_person_product_access, Autopilot tab) and
// per-app-group grants (sc_person_deployment_access, Deployment tab). Both live
// in one Board, product scope keyed under a sentinel no real app group can use,
// so lanes, drag/drop, keyboard moves and the pending diff need no branching —
// only the persist step distinguishes the two.
const PRODUCT_SCOPE = '__product__';
const AUTOPILOT_SLUG = 'autopilot';
type Tab = 'autopilot' | 'deployment';
const TABS: { key: Tab; label: string }[] = [
  { key: 'autopilot', label: 'Autopilot' },
  { key: 'deployment', label: 'Deployment' },
];

type PendingChange =
  | { type: 'assign'; personId: string; roleName: string }
  | { type: 'revoke'; personId: string };

// Removing a product grant from someone who also holds deployment grants is
// undone by ensureDefaultProductAccess on their next deployment write.
const HINT_RESEEDED =
  'This user also has deployment grants, which keep working. Their product access comes back the next time any of those grants is saved — revoke them on the Deployment tab to remove access for good.';
const HINT_SELF =
  "This is your own access — changing it here would lock you out of the admin console. Ask another admin, or edit it from this user's detail page.";

// Physical slide between lanes. Kept module-level so the reference is stable.
const CARD_SPRING = { type: 'spring', stiffness: 500, damping: 40 } as const;

// A single draggable / keyboard-movable user card.
//
// Module-level (not inline) on purpose: an inline component is a fresh type on
// every parent render, so React would unmount/remount every card each render —
// which would break framer-motion's layout animation (constant exit/enter) and
// thrash keyboard focus. Here unchanged cards persist and only the moved card
// relocates, letting `layoutId` slide it between lanes.
interface UserCardProps {
  personKey: string; // `${ag}:${personId}` — also the shared layout id
  info: { name: string; email: string };
  role: string; // current lane/role name, for the aria-label
  isDragging: boolean;
  roleBadge?: string; // shown for custom-role ("Other") cards
  removeHint?: string; // hover note on ✕ — advisory, never blocks removal
  // Makes the card read-only (no drag / ← → / ✕) and explains why on hover.
  // Set for the signed-in admin's own product grant: editing it would revoke
  // their own admin-console access, since isAdmin derives from that row.
  lockedReason?: string;
  reducedMotion: boolean;
  pendingFocusRef: React.MutableRefObject<string | null>;
  onDragStart: (e: React.DragEvent) => void;
  onDragEnd: () => void;
  onRemove: () => void;
  onKeyDown: (e: React.KeyboardEvent) => void;
}

const UserCard: React.FC<UserCardProps> = ({
  personKey,
  info,
  role,
  isDragging,
  roleBadge,
  removeHint,
  lockedReason,
  reducedMotion,
  pendingFocusRef,
  onDragStart,
  onDragEnd,
  onRemove,
  onKeyDown,
}) => {
  const locked = !!lockedReason;

  // Restore focus to exactly the card that just moved (it remounts in the new
  // lane, losing focus). Only fires right after a keyboard move — never steals
  // focus on unrelated re-renders (e.g. typing in a lane's search).
  const setFocusRef = useCallback(
    (node: HTMLDivElement | null) => {
      if (node && pendingFocusRef.current === personKey) {
        node.focus();
        pendingFocusRef.current = null;
      }
    },
    [personKey, pendingFocusRef]
  );

  // Outer wrapper owns native HTML5 drag; framer-motion overrides
  // onDragStart/onDragEnd typings on `motion.div`, so we keep native DnD off it.
  return (
    <div
      draggable={!locked}
      onDragStart={locked ? undefined : onDragStart}
      onDragEnd={locked ? undefined : onDragEnd}
      className={locked ? 'cursor-default' : 'cursor-grab active:cursor-grabbing'}
    >
      <motion.div
        layout
        layoutId={personKey}
        transition={reducedMotion ? { duration: 0 } : CARD_SPRING}
        ref={setFocusRef}
        tabIndex={0}
        role="button"
        title={lockedReason}
        aria-label={`${info.name} — ${role}. ${
          lockedReason || 'Use left and right arrow keys to change lane.'
        }`}
        onKeyDown={locked ? undefined : onKeyDown}
        className={cn(
          'group flex items-center gap-2 rounded-lg border border-zinc-200 px-2.5 py-2 transition-shadow focus:outline-none focus:ring-2 focus:ring-emerald-400 focus:ring-offset-1',
          locked ? 'border-dashed bg-zinc-50' : 'bg-white hover:shadow-sm',
          isDragging && 'opacity-40'
        )}
      >
        {locked ? (
          <Lock className="w-3.5 h-3.5 text-zinc-300 shrink-0" />
        ) : (
          <GripVertical className="w-3.5 h-3.5 text-zinc-300 shrink-0" />
        )}
        <div className="min-w-0 flex-1">
          <div className="text-sm font-medium text-zinc-800 truncate">{info.name}</div>
          <div className="text-[11px] text-zinc-400 font-mono truncate">{info.email}</div>
          {roleBadge && (
            <Badge variant="warning" size="sm" className="mt-1">
              {roleBadge}
            </Badge>
          )}
        </div>
        {locked ? (
          <Badge variant="muted" size="sm" className="shrink-0">
            You
          </Badge>
        ) : (
          <button
            type="button"
            onClick={onRemove}
            title={removeHint}
            aria-label={removeHint ? `Remove — ${removeHint}` : 'Remove from deployment'}
            className="shrink-0 w-6 h-6 flex items-center justify-center rounded text-zinc-300 hover:text-red-600 hover:bg-red-50 transition-colors opacity-0 group-hover:opacity-100 cursor-pointer"
          >
            <X className="w-3.5 h-3.5" />
          </button>
        )}
      </motion.div>
    </div>
  );
};

const AccessControl: React.FC = () => {
  const queryClient = useQueryClient();
  const { user: currentUser } = useAuth();

  // Held as query objects, not just data, so the render can branch on isError.
  const rosterQ = useQuery({ queryKey: ['deployment-access-roster'], queryFn: fetchDeploymentAccessRoster });
  const productRosterQ = useQuery({ queryKey: ['product-access-roster'], queryFn: fetchProductAccessRoster });
  const appGroupsQ = useQuery({ queryKey: ['app-groups'], queryFn: fetchAppGroups });
  const usersQ = useQuery({ queryKey: ['admin-users'], queryFn: fetchUsers });
  const adminProductsQ = useQuery({ queryKey: ['admin-products'], queryFn: fetchAdminProducts });
  const roster = rosterQ.data ?? [];
  const productRoster = productRosterQ.data ?? [];
  const appGroups = appGroupsQ.data ?? [];
  const users = usersQ.data ?? [];
  const adminProducts = adminProductsQ.data ?? [];

  // Deployment access is scoped to a product; today there is exactly one
  // (autopilot), so a single roles list maps every lane name → roleId.
  const defaultProductSlug: string = adminProducts[0]?.slug || 'autopilot';
  const rolesQ = useQuery({
    queryKey: ['admin-product-roles', defaultProductSlug],
    queryFn: () => fetchProductRoles(defaultProductSlug),
    enabled: !!defaultProductSlug,
  });
  // The product board must map lane → roleId through Autopilot's roles, not
  // whichever product sorts first: assignRoleH accepts any roleId for any
  // productSlug without checking they match. Shares the key above while autopilot
  // is the only product, so this costs no extra request.
  const autopilotRolesQ = useQuery({
    queryKey: ['admin-product-roles', AUTOPILOT_SLUG],
    queryFn: () => fetchProductRoles(AUTOPILOT_SLUG),
  });
  const roles = rolesQ.data ?? [];
  const autopilotRoles = autopilotRolesQ.data ?? [];

  // ── Derived lookups ────────────────────────────────────────────────
  // sc_person_product_access has no FK to the product registry, so it can hold
  // slugs the app no longer serves — keep only autopilot's.
  const original: Board = useMemo(() => {
    const m: Board = { [PRODUCT_SCOPE]: {} };
    for (const e of roster) (m[e.appGroup] ||= {})[e.personId] = e.roleName;
    for (const e of productRoster) {
      if (e.productSlug === AUTOPILOT_SLUG) m[PRODUCT_SCOPE][e.personId] = e.roleName;
    }
    return m;
  }, [roster, productRoster]);

  const hasDeploymentGrant = useMemo(() => new Set(roster.map((e) => e.personId)), [roster]);

  const personInfoById = useMemo(() => {
    const m: Record<string, { name: string; email: string }> = {};
    for (const u of users as any[]) {
      const name = u.name || `${u.firstName || ''} ${u.lastName || ''}`.trim() || u.email;
      m[u.id] = { name, email: u.email };
    }
    // Rosters may reference users the list didn't include — fall back to them.
    for (const e of [...roster, ...productRoster] as (DeploymentRosterEntry | ProductRosterEntry)[]) {
      if (!m[e.personId]) {
        const name = `${e.firstName || ''} ${e.lastName || ''}`.trim() || e.email;
        m[e.personId] = { name, email: e.email };
      }
    }
    return m;
  }, [users, roster, productRoster]);

  const roleIdByName = useMemo(() => roleIdsByName(roles), [roles]);
  const autopilotRoleIdByName = useMemo(() => roleIdsByName(autopilotRoles), [autopilotRoles]);

  const productSlugByAg = useMemo(() => {
    const m: Record<string, string> = {};
    for (const e of roster) m[e.appGroup] = e.productSlug;
    return m;
  }, [roster]);
  const productSlugFor = (ag: string) => productSlugByAg[ag] || defaultProductSlug;

  // Every deployment worth listing: configured app groups ∪ any that already
  // carry a grant, sorted alphabetically. PRODUCT_SCOPE isn't a deployment.
  const allAgs = useMemo(() => {
    const s = new Set<string>([
      ...(appGroups as string[]),
      ...Object.keys(original).filter((k) => k !== PRODUCT_SCOPE),
    ]);
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
  const reducedMotion = useReducedMotion() ?? false;
  const [tab, setTab] = useState<Tab>('autopilot');
  const [search, setSearch] = useState('');
  const [openAgs, setOpenAgs] = useState<Record<string, boolean>>({});
  // Which lane (deployment + role) has its "add user" search open. At most one.
  const [addOpen, setAddOpen] = useState<{ ag: string; role: LaneRole } | null>(null);
  const [addSearch, setAddSearch] = useState('');
  const [draggingKey, setDraggingKey] = useState<string | null>(null);
  const [dragOver, setDragOver] = useState<{ ag: string; role: string } | null>(null);
  const dragRef = useRef<{ ag: string; personId: string } | null>(null);
  // Key (`${ag}:${personId}`) of a card that should grab focus once it remounts
  // in its new lane after a keyboard move. Consumed by UserCard's ref callback.
  const pendingFocusRef = useRef<string | null>(null);

  const toggleAg = (ag: string) => setOpenAgs((s) => ({ ...s, [ag]: !s[ag] }));

  // Close an open lane search on outside click (Escape is handled on the input).
  useEffect(() => {
    if (!addOpen) return;
    const onDocMouseDown = (e: MouseEvent) => {
      if (!(e.target as HTMLElement).closest('[data-add-panel]')) setAddOpen(null);
    };
    document.addEventListener('mousedown', onDocMouseDown);
    return () => document.removeEventListener('mousedown', onDocMouseDown);
  }, [addOpen]);

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
      const isProduct = ag === PRODUCT_SCOPE;
      const productSlug = isProduct ? AUTOPILOT_SLUG : productSlugFor(ag);
      const roleIds = isProduct ? autopilotRoleIdByName : roleIdByName;
      for (const c of changes) {
        if (c.type === 'assign') {
          const roleId = roleIds[c.roleName];
          if (!roleId) throw new Error(`No role id for "${c.roleName}"`);
          if (isProduct) await assignRole(c.personId, { productSlug, roleId });
          else await assignDeploymentRole(c.personId, { productSlug, appGroup: ag, roleId });
        } else {
          if (isProduct) await revokeProductAccess(c.personId, productSlug);
          else await revokeDeploymentAccess(c.personId, productSlug, ag);
        }
      }
    },
    onSuccess: (_d, vars) => {
      const scope = vars.ag === PRODUCT_SCOPE ? 'Autopilot' : vars.ag;
      toast.success(
        `Saved ${vars.changes.length} change${vars.changes.length > 1 ? 's' : ''} for ${scope}`
      );
    },
    onError: (err) => toast.error(errMessage(err, 'Failed to save changes')),
    // Changes apply one at a time, so a failure partway through leaves the earlier
    // ones persisted — refetch on both outcomes or the board keeps showing saved
    // changes as pending. Both rosters: either scope's write can seed a row in the
    // other via ensureDefaultProductAccess.
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ['deployment-access-roster'] });
      queryClient.invalidateQueries({ queryKey: ['product-access-roster'] });
    },
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

  // ── Keyboard lane-shift (← / →) ─────────────────────────────────────
  // Shift a focused card to the adjacent system lane. Clamps at the ends.
  // A custom-role ("Other") card isn't in SYSTEM_LANES — mirror the drag-out
  // capability: ArrowRight brings it into Viewer, ArrowLeft is a no-op.
  const shiftRole = (ag: string, personId: string, dir: 1 | -1) => {
    const current = draft[ag]?.[personId];
    if (!current) return;
    const idx = SYSTEM_LANES.indexOf(current as LaneRole);
    let next: LaneRole;
    if (idx === -1) {
      if (dir === -1) return;
      next = SYSTEM_LANES[0];
    } else {
      const ni = Math.min(Math.max(idx + dir, 0), SYSTEM_LANES.length - 1);
      if (ni === idx) return; // already at the end — nothing to do
      next = SYSTEM_LANES[ni];
    }
    pendingFocusRef.current = `${ag}:${personId}`;
    setRole(ag, personId, next);
  };
  const onCardKeyDown = (ag: string, personId: string) => (e: React.KeyboardEvent) => {
    if (e.key === 'ArrowRight') {
      e.preventDefault();
      shiftRole(ag, personId, 1);
    } else if (e.key === 'ArrowLeft') {
      e.preventDefault();
      shiftRole(ag, personId, -1);
    }
  };

  // ── Render helpers ──────────────────────────────────────────────────
  const sortByName = (a: string, b: string) =>
    (personInfoById[a]?.name || '').localeCompare(personInfoById[b]?.name || '');

  // Bridge the module-level UserCard to this deployment's handlers/lookups.
  const renderCard = (ag: string, personId: string, role: string, roleBadge?: string) => {
    const key = `${ag}:${personId}`;
    const isProduct = ag === PRODUCT_SCOPE;
    return (
      <UserCard
        key={personId}
        personKey={key}
        info={personInfoById[personId] || { name: personId, email: '' }}
        role={role}
        isDragging={draggingKey === key}
        roleBadge={roleBadge}
        removeHint={isProduct && hasDeploymentGrant.has(personId) ? HINT_RESEEDED : undefined}
        lockedReason={isProduct && personId === currentUser?.id ? HINT_SELF : undefined}
        reducedMotion={reducedMotion}
        pendingFocusRef={pendingFocusRef}
        onDragStart={onDragStart(ag, personId)}
        onDragEnd={onDragEnd}
        onRemove={() => removeUser(ag, personId)}
        onKeyDown={onCardKeyDown(ag, personId)}
      />
    );
  };

  // The board can't be drawn without these three, so treat a failure as fatal:
  // falling through would render an empty board reading as "nobody has access".
  const boardQueries = [rosterQ, productRosterQ, appGroupsQ];
  if (boardQueries.some((q) => q.isLoading)) {
    return (
      <div className="flex flex-col w-full space-y-4">
        <CardSkeleton />
        <CardSkeleton />
        <CardSkeleton />
      </div>
    );
  }

  const fatal = boardQueries.find((q) => q.isError);
  if (fatal) {
    return (
      <div className="flex flex-col w-full">
        <h1 className="text-lg sm:text-xl font-semibold text-zinc-900 mb-4">Access Control</h1>
        <div className="bg-white rounded-xl border border-zinc-200 py-16 px-6 text-center">
          <AlertTriangle className="w-8 h-8 text-amber-500 mx-auto mb-3" />
          <p className="text-sm font-medium text-zinc-800 mb-1">Couldn't load access data</p>
          <p className="text-xs text-zinc-500 mb-5">{errMessage(fatal.error)}</p>
          <Button size="sm" variant="secondary" onClick={() => boardQueries.forEach((q) => q.isError && q.refetch())}>
            Retry
          </Button>
        </div>
      </div>
    );
  }

  // Non-fatal, but each breaks one action — name it, so Confirm doesn't fail
  // later with an opaque "No role id for …".
  const degradedQueries = [usersQ, rolesQ, autopilotRolesQ];
  const degraded = [
    usersQ.isError && "The user list didn't load, so the ＋ lane picker will be empty.",
    (rolesQ.isError || autopilotRolesQ.isError) && "Role data didn't load, so saving changes will fail.",
  ].filter(Boolean) as string[];

  const visibleAgs = allAgs.filter((ag) => !search || ag.toLowerCase().includes(search.toLowerCase()));

  // The search box filters deployment names on the Deployment tab; on Autopilot
  // there are none, so it filters users within the lanes instead.
  const isProductTab = tab === 'autopilot';
  const shownAgs = isProductTab ? [PRODUCT_SCOPE] : visibleAgs;
  const matchesUserSearch = (pid: string) => {
    if (!search) return true;
    const q = search.toLowerCase();
    const info = personInfoById[pid];
    return (
      (info?.name || '').toLowerCase().includes(q) || (info?.email || '').toLowerCase().includes(q)
    );
  };

  return (
    <div className="flex flex-col w-full pb-12">
      {/* Page header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 mb-1">
        <h1 className="text-lg sm:text-xl font-semibold text-zinc-900">Access Control</h1>
        <div className="relative flex-1 sm:flex-none">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-zinc-400" />
          <input
            type="text"
            placeholder={isProductTab ? 'Search users' : 'Search deployments'}
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="pl-9 pr-4 h-10 sm:h-9 w-full sm:w-64 border border-zinc-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150"
          />
        </div>
      </div>
      <p className="text-sm text-zinc-500 mb-4">
        Drag a user — or select a card and press ← / → — to move them between Viewer, Manager and
        Admin and restage their role, then Confirm to save. Add a user to a lane with the ＋ icon in
        its header.{' '}
        {isProductTab
          ? 'These grants cover all of Autopilot, independent of any app group.'
          : 'Only explicit deployment-level grants are shown.'}
      </p>

      {/* Scope tabs */}
      <div
        className="flex items-center gap-1.5 mb-4 sm:mb-5 flex-wrap"
        role="tablist"
        aria-label="Access control scope"
      >
        {TABS.map((t) => (
          <button
            key={t.key}
            type="button"
            role="tab"
            aria-selected={tab === t.key}
            // Clear the query: it means different things per tab, so carrying it
            // across would silently hide cards.
            onClick={() => {
              setTab(t.key);
              setSearch('');
            }}
            className={cn(
              'inline-flex items-center h-8 px-3 rounded-full text-xs font-medium border cursor-pointer transition-colors duration-150',
              tab === t.key
                ? 'bg-zinc-900 text-white border-zinc-900'
                : 'bg-white text-zinc-600 border-zinc-300 hover:bg-zinc-50'
            )}
          >
            {t.label}
          </button>
        ))}
      </div>

      {degraded.length > 0 && (
        <div className="flex items-start gap-2 mb-4 px-3 py-2.5 rounded-lg border border-amber-200 bg-amber-50">
          <AlertTriangle className="w-4 h-4 text-amber-500 shrink-0 mt-0.5" />
          <div className="flex-1 min-w-0 text-xs text-amber-800 space-y-0.5">
            {degraded.map((line) => (
              <div key={line}>{line}</div>
            ))}
          </div>
          <button
            type="button"
            onClick={() => degradedQueries.forEach((q) => q.isError && q.refetch())}
            className="shrink-0 text-xs font-medium text-amber-900 underline hover:no-underline cursor-pointer"
          >
            Retry
          </button>
        </div>
      )}

      {shownAgs.length === 0 ? (
        <div className="bg-white rounded-xl border border-zinc-200 py-16 text-center text-zinc-400 text-sm">
          No deployments found.
        </div>
      ) : (
        <div className="space-y-3">
          {shownAgs.map((ag) => {
            const isProductScope = ag === PRODUCT_SCOPE;
            const cur = draft[ag] || {};
            const memberIds = Object.keys(cur);
            const changes = changesFor(ag);
            const isOpen = isProductScope || !!openAgs[ag]; // product board is the whole tab
            const otherIds = memberIds
              .filter((pid) => !SYSTEM_LANES.includes(cur[pid] as LaneRole))
              .filter((pid) => (isProductScope ? matchesUserSearch(pid) : true))
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
            // Count what's on screen: the product board's lanes are search-filtered.
            const headerCount = isProductScope ? memberIds.filter(matchesUserSearch).length : memberIds.length;
            const header = (
              <>
                <span className="text-sm font-semibold text-zinc-800">
                  {isProductScope ? 'Autopilot — product access' : ag}
                </span>
                <Badge variant="muted" size="sm">
                  {headerCount} {headerCount === 1 ? 'user' : 'users'}
                </Badge>
                {changes.length > 0 && (
                  <Badge variant="warning" size="sm" dot>
                    {changes.length} pending
                  </Badge>
                )}
              </>
            );

            return (
              <div key={ag} className="rounded-xl border border-zinc-200 bg-white overflow-hidden">
                {/* Collapse toggle per deployment; plain label for the product board. */}
                {isProductScope ? (
                  <div className="w-full flex items-center gap-2.5 px-4 py-3">{header}</div>
                ) : (
                  <button
                    type="button"
                    onClick={() => toggleAg(ag)}
                    className="w-full flex items-center gap-2.5 px-4 py-3 hover:bg-zinc-50 transition-colors"
                  >
                    <ChevronDown
                      className={cn('w-4 h-4 text-zinc-400 transition-transform', !isOpen && '-rotate-90')}
                    />
                    {header}
                  </button>
                )}

                {isOpen && (
                  <div className="border-t border-zinc-100 p-3 sm:p-4 bg-zinc-50/50">
                    {/* Toolbar: confirm/discard (adding users is now per-lane) */}
                    {changes.length > 0 && (
                      <div className="flex flex-wrap items-center justify-end gap-2 mb-3">
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

                    {/* Board: swim lanes */}
                    <div className="flex gap-3 overflow-x-auto pb-1">
                      {SYSTEM_LANES.map((role) => {
                        const laneIds = memberIds
                          .filter((pid) => cur[pid] === role)
                          .filter((pid) => (isProductScope ? matchesUserSearch(pid) : true))
                          .sort(sortByName);
                        const isDragTarget = dragOver?.ag === ag && dragOver.role === role;
                        const isAddHere = addOpen?.ag === ag && addOpen.role === role;
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
                              <div className="flex items-center gap-1.5">
                                <span className="text-xs text-zinc-400">{laneIds.length}</span>
                                <button
                                  type="button"
                                  data-add-panel
                                  onClick={() => {
                                    setAddSearch('');
                                    setAddOpen(isAddHere ? null : { ag, role });
                                  }}
                                  className={cn(
                                    'w-5 h-5 flex items-center justify-center rounded transition-colors cursor-pointer',
                                    isAddHere
                                      ? 'text-emerald-600 bg-emerald-50'
                                      : 'text-zinc-400 hover:text-emerald-600 hover:bg-emerald-50'
                                  )}
                                  aria-label={`Add user to ${role}`}
                                >
                                  <UserPlus className="w-3.5 h-3.5" />
                                </button>
                              </div>
                            </div>
                            {isAddHere && (
                              <div
                                data-add-panel
                                className="mb-2 rounded-md border border-zinc-200 bg-white shadow-sm"
                              >
                                <div className="p-1.5 border-b border-zinc-100">
                                  <input
                                    autoFocus
                                    type="text"
                                    placeholder={`Add to ${role}…`}
                                    value={addSearch}
                                    onChange={(e) => setAddSearch(e.target.value)}
                                    onKeyDown={(e) => e.key === 'Escape' && setAddOpen(null)}
                                    className="w-full h-7 px-2 border border-zinc-200 rounded text-xs focus:outline-none focus:ring-2 focus:ring-zinc-300"
                                  />
                                </div>
                                <div className="max-h-40 overflow-y-auto py-1">
                                  {availableUsers.length === 0 ? (
                                    <div className="px-2 py-2 text-[11px] text-zinc-400 text-center">
                                      No users available
                                    </div>
                                  ) : (
                                    availableUsers.map((u) => (
                                      <button
                                        key={u.id}
                                        type="button"
                                        onClick={() => {
                                          setRole(ag, u.id, role);
                                          setAddOpen(null);
                                        }}
                                        className="w-full flex flex-col items-start px-2 py-1 text-left hover:bg-zinc-50 transition-colors cursor-pointer"
                                      >
                                        <span className="text-xs text-zinc-800 truncate w-full">
                                          {u.name || `${u.firstName || ''} ${u.lastName || ''}`.trim() || u.email}
                                        </span>
                                        <span className="text-[10px] text-zinc-400 font-mono truncate w-full">
                                          {u.email}
                                        </span>
                                      </button>
                                    ))
                                  )}
                                </div>
                              </div>
                            )}
                            <div className="space-y-2 min-h-[60px]">
                              {laneIds.length === 0 ? (
                                <div className="text-[11px] text-zinc-300 text-center py-4 select-none">
                                  Drop here
                                </div>
                              ) : (
                                laneIds.map((pid) => renderCard(ag, pid, role))
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
                            {otherIds.map((pid) => renderCard(ag, pid, cur[pid], cur[pid]))}
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
