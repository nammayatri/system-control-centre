import React, { useState } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import {
  fetchUser,
  updateUser,
  deactivateUser,
  assignRole,
  revokeProductAccess,
  assignDeploymentRole,
  revokeDeploymentAccess,
  addPermissionOverride,
  removePermissionOverride,
  fetchAdminProducts,
  fetchProductPermissions,
  fetchProductRoles,
} from '../api';
import { fetchProducts as fetchAppGroups, mobileApi } from '../../../products/releases/api';
import type { AppCatalogEntry } from '../../../products/releases/types';
import type { MultiSelectOption } from '../../../shared/ui/multi-select';

// Grantable app namespaces ("surfaces"). Backend + Mobile share the autopilot
// product slug but draw apps from different sources; Airborne is its own
// product. Mobile grants ("<name>/<platform>") are enforced by the backend.
type AccessSurfaceId = 'backend' | 'mobile';
const ACCESS_SURFACES: {
  id: AccessSurfaceId;
  label: string;
  productSlug: string;
  enforced: boolean;
}[] = [
  { id: 'backend', label: 'Autopilot', productSlug: 'autopilot', enforced: true },
  // Mobile grants are per (app, platform): app_group = "<name>/<platform>".
  // One grant covers that app row's builds AND its airborne OTA — there is no
  // separate OTA surface (existing legacy per-ref airborne grants still work).
  { id: 'mobile', label: 'Mobile Releases (incl. OTA)', productSlug: 'autopilot', enforced: true },
];
import { Button } from '../../../shared/ui/button';
import { Badge } from '../../../shared/ui/badge';
import { Input, SelectInput } from '../../../shared/ui/input';
import { MultiSelect } from '../../../shared/ui/multi-select';
import { CardSkeleton } from '../../../shared/ui/skeleton';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogBody,
  DialogFooter,
} from '../../../shared/ui/dialog';
import { cn } from '../../../lib/utils';
import { toast } from 'sonner';
import { ArrowLeft, Plus, Trash2 } from 'lucide-react';

const UserDetail: React.FC = () => {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  // Dialog states
  const [editOpen, setEditOpen] = useState(false);
  const [assignOpen, setAssignOpen] = useState(false);
  const [assignDeploymentOpen, setAssignDeploymentOpen] = useState(false);
  const [overrideOpen, setOverrideOpen] = useState(false);
  const [deactivateOpen, setDeactivateOpen] = useState(false);

  // Edit form
  const [editForm, setEditForm] = useState({ firstName: '', lastName: '', isActive: true, isSuperadmin: false });

  // Assign role form
  const [assignProduct, setAssignProduct] = useState('');
  const [assignRoleId, setAssignRoleId] = useState('');

  const [assignSurface, setAssignSurface] = useState<AccessSurfaceId | ''>('');
  const [assignDeployApps, setAssignDeployApps] = useState<string[]>([]);
  const [assignDeployRoleId, setAssignDeployRoleId] = useState('');

  // Override form — multi-select
  const [overrideProduct, setOverrideProduct] = useState('');
  const [selectedOverridePerms, setSelectedOverridePerms] = useState<string[]>([]);
  const [overrideType, setOverrideType] = useState<'GRANT' | 'DENY'>('GRANT');

  // Queries — response is { user, products, overrides }
  const { data: userData, isLoading } = useQuery({
    queryKey: ['admin-user', id],
    queryFn: () => fetchUser(id!),
    enabled: !!id,
  });
  const user = userData?.user;
  const userProducts = userData?.products || [];
  const userOverrides = userData?.overrides || [];
  const userDeploymentAccess = userData?.deploymentAccess || [];

  const { data: products = [] } = useQuery({
    queryKey: ['admin-products'],
    queryFn: fetchAdminProducts,
  });

  // Product-level access is granted under autopilot only: its roles carry the
  // OTA permission family too (unified model), so airborne-ota is never
  // offered here — per-app OTA access goes through Scoped Access instead.
  const grantableProducts = (products as any[])
    .filter((p) => (p.slug || p) !== 'airborne-ota')
    .map((p) => {
      const slug = p.slug || p;
      return {
        value: slug,
        label: slug === 'autopilot' ? 'autopilot (backend · mobile · OTA)' : p.name || slug,
      };
    });

  // ── App-access surfaces ──────────────────────────────────────────
  // A "surface" is a grantable app namespace. Backend + Mobile share the
  // autopilot product slug but draw apps from different sources; Airborne is
  // its own product. Mobile grants are per (app, platform) and enforced.
  const surface = ACCESS_SURFACES.find((s) => s.id === assignSurface);
  const deployProductSlug = surface?.productSlug ?? '';

  const { data: backendAppGroups = [] } = useQuery({
    queryKey: ['app-groups'],
    queryFn: fetchAppGroups,
    enabled: assignSurface === 'backend',
  });
  const { data: mobileApps = [] } = useQuery({
    queryKey: ['mobile-apps-catalog'],
    queryFn: () => mobileApi.listApps(),
    enabled: assignSurface === 'mobile',
  });
  // Apps this user is already granted for the selected surface's product →
  // shown disabled in the multi-select.
  const grantedForProduct = new Set(
    (userDeploymentAccess as any[])
      .filter((d) => d.productSlug === deployProductSlug)
      .map((d) => d.appGroup),
  );
  const markGranted = (o: MultiSelectOption): MultiSelectOption =>
    grantedForProduct.has(o.value) ? { ...o, disabled: true } : o;

  const surfaceAppOptions: MultiSelectOption[] =
    assignSurface === 'backend'
      ? (backendAppGroups as string[]).map((ag) => markGranted({ value: ag, label: ag }))
      : [
          // Fleet-wide wildcard: one grant row covering every current AND
          // future mobile app (builds + OTA). Never matches BE deployments.
          markGranted({
            value: 'mobile/*',
            label: 'All mobile apps',
            hint: 'wildcard — every current and future app · platform, incl. OTA',
            group: 'Fleet',
          }),
          ...(mobileApps as AppCatalogEntry[]).map((a) =>
            // one option per (app, platform) — the unified grant key; the hint
            // names the airborne app this grant's OTA side maps to.
            markGranted({
              value: `${a.name}/${a.platform}`,
              label: `${(a.displayLabel || a.name).replace(/\s*\((Customer|Driver)[^)]*\)/i, '').trim()} · ${a.platform}`,
              hint: a.airborneAppRef ? `OTA: ${a.airborneAppRef}` : 'no OTA (builds only)',
              group: a.surface === 'driver' ? 'Driver' : 'Customer',
            }),
          ),
        ];

  const { data: productRoles = [] } = useQuery({
    queryKey: ['admin-product-roles', assignProduct],
    queryFn: () => fetchProductRoles(assignProduct),
    enabled: !!assignProduct,
  });

  const { data: deployProductRoles = [] } = useQuery({
    queryKey: ['admin-product-roles', deployProductSlug],
    queryFn: () => fetchProductRoles(deployProductSlug),
    enabled: !!deployProductSlug,
  });

  const { data: productPermissions = [] } = useQuery({
    queryKey: ['admin-product-permissions', overrideProduct],
    queryFn: () => fetchProductPermissions(overrideProduct),
    enabled: !!overrideProduct,
  });

  // Selected role details for display
  const selectedRole = productRoles.find((r: any) => String(r.id) === String(assignRoleId));
  const selectedDeployRole = deployProductRoles.find((r: any) => String(r.id) === String(assignDeployRoleId));

  // Mutations
  const updateMut = useMutation({
    mutationFn: () => updateUser(id!, editForm),
    onSuccess: () => {
      toast.success('User updated successfully');
      queryClient.invalidateQueries({ queryKey: ['admin-user', id] });
      queryClient.invalidateQueries({ queryKey: ['admin-users'] });
      setEditOpen(false);
    },
    onError: (err: any) => toast.error(err?.response?.data?.error || err.message || 'Failed to update user'),
  });

  const isUserActive = user?.isActive !== false;

  const toggleActiveMut = useMutation({
    mutationFn: () => isUserActive ? deactivateUser(id!) : updateUser(id!, { isActive: true }),
    onSuccess: () => {
      toast.success(isUserActive ? 'User deactivated' : 'User activated');
      queryClient.invalidateQueries({ queryKey: ['admin-user', id] });
      queryClient.invalidateQueries({ queryKey: ['admin-users'] });
      setDeactivateOpen(false);
    },
    onError: (err: any) => toast.error(err?.response?.data?.error || err.message || 'Failed to update user status'),
  });

  const assignMut = useMutation({
    mutationFn: () => assignRole(id!, { productSlug: assignProduct, roleId: assignRoleId }),
    onSuccess: () => {
      toast.success('Role assigned successfully');
      queryClient.invalidateQueries({ queryKey: ['admin-user', id] });
      setAssignOpen(false);
      setAssignProduct('');
      setAssignRoleId('');
    },
    onError: (err: any) => toast.error(err?.response?.data?.error || err.message || 'Failed to assign role'),
  });

  const revokeMut = useMutation({
    mutationFn: (slug: string) => revokeProductAccess(id!, slug),
    onSuccess: () => {
      toast.success('Product access revoked');
      queryClient.invalidateQueries({ queryKey: ['admin-user', id] });
    },
    onError: (err: any) => toast.error(err?.response?.data?.error || err.message || 'Failed to revoke access'),
  });

  const resetDeployForm = () => {
    setAssignDeploymentOpen(false);
    setAssignSurface('');
    setAssignDeployApps([]);
    setAssignDeployRoleId('');
  };

  const assignDeploymentMut = useMutation({
    // Grant one role across every selected app in the chosen surface.
    mutationFn: async () => {
      if (!deployProductSlug) throw new Error('Select a surface');
      const results = await Promise.allSettled(
        assignDeployApps.map((appGroup) =>
          assignDeploymentRole(id!, {
            productSlug: deployProductSlug,
            appGroup,
            roleId: assignDeployRoleId,
          }),
        ),
      );
      const failed = results.filter((r) => r.status === 'rejected').length;
      return { total: assignDeployApps.length, failed };
    },
    onSuccess: ({ total, failed }) => {
      queryClient.invalidateQueries({ queryKey: ['admin-user', id] });
      if (failed === 0) {
        toast.success(total > 1 ? `Access granted for ${total} apps` : 'Deployment access assigned');
        resetDeployForm();
      } else if (failed < total) {
        toast.warning(`Granted ${total - failed} of ${total}; ${failed} failed — check and retry`);
      } else {
        toast.error('Failed to assign deployment access');
      }
    },
    onError: (err: any) => toast.error(err?.response?.data?.error || err.message || 'Failed to assign deployment access'),
  });

  const revokeDeploymentMut = useMutation({
    mutationFn: ({ productSlug, appGroup }: { productSlug: string; appGroup: string }) =>
      revokeDeploymentAccess(id!, productSlug, appGroup),
    onSuccess: () => {
      toast.success('Deployment access revoked');
      queryClient.invalidateQueries({ queryKey: ['admin-user', id] });
    },
    onError: (err: any) => toast.error(err?.response?.data?.error || err.message || 'Failed to revoke deployment access'),
  });

  const addOverrideMut = useMutation({
    mutationFn: async () => {
      // Add all selected permissions as overrides
      for (const perm of selectedOverridePerms) {
        await addPermissionOverride(id!, {
          productSlug: overrideProduct,
          permissionAction: perm,
          overrideType: overrideType,
        });
      }
    },
    onSuccess: () => {
      toast.success(`${selectedOverridePerms.length} permission override(s) added`);
      queryClient.invalidateQueries({ queryKey: ['admin-user', id] });
      setOverrideOpen(false);
      setOverrideProduct('');
      setSelectedOverridePerms([]);
      setOverrideType('GRANT');
    },
    onError: (err: any) => toast.error(err?.response?.data?.error || err.message || 'Failed to add override'),
  });

  const removeOverrideMut = useMutation({
    mutationFn: (overrideId: string) => removePermissionOverride(id!, overrideId),
    onSuccess: () => {
      toast.success('Permission override removed');
      queryClient.invalidateQueries({ queryKey: ['admin-user', id] });
    },
    onError: (err: any) => toast.error(err?.response?.data?.error || err.message || 'Failed to remove override'),
  });

  // IST everywhere — NammaYatri ops convention.
  const formatDate = (d: string) => {
    if (!d) return '-';
    const date = new Date(d);
    if (isNaN(date.getTime())) return '-';
    return date.toLocaleDateString('en-IN', {
      timeZone: 'Asia/Kolkata',
      month: 'short',
      day: '2-digit',
      year: 'numeric',
    });
  };

  const openEditDialog = () => {
    if (user) {
      setEditForm({
        firstName: user.firstName || '',
        lastName: user.lastName || '',
        isActive: user.isActive !== false,
        isSuperadmin: user.isSuperadmin || false,
      });
    }
    setEditOpen(true);
  };

  if (isLoading) {
    return (
      <div className="flex flex-col w-full max-w-4xl space-y-5">
        <CardSkeleton />
        <CardSkeleton />
        <CardSkeleton />
      </div>
    );
  }
  if (!user) return <div className="p-10 text-center text-zinc-400">User not found.</div>;

  const userName = user.name || `${user.firstName || ''} ${user.lastName || ''}`.trim() || 'User';
  const userStatus = user.status || (user.isActive !== false ? 'active' : 'inactive');

  return (
    <div className="flex flex-col w-full max-w-4xl pb-12">
      {/* Back button + header */}
      <button
        onClick={() => navigate('/admin/users')}
        className="flex items-center gap-1.5 text-sm text-zinc-500 hover:text-zinc-700 cursor-pointer mb-4 transition-colors duration-150 h-9 -ml-1 px-2 rounded-md hover:bg-zinc-100 self-start"
      >
        <ArrowLeft className="w-4 h-4" />
        Back to Users
      </button>

      <div className="flex flex-col sm:flex-row sm:items-start sm:justify-between gap-3 mb-4 sm:mb-5">
        <div className="min-w-0">
          <h1 className="text-lg sm:text-xl font-semibold text-zinc-900 truncate">
            {userName}
          </h1>
          <p className="text-sm text-zinc-500 mt-0.5 font-mono break-all">
            {user.email}
          </p>
        </div>
        <div className="flex items-center gap-2 shrink-0 flex-wrap">
          <Badge variant={userStatus === 'active' ? 'success' : 'muted'} dot>
            {userStatus}
          </Badge>
          <Button size="sm" variant="secondary" onClick={openEditDialog}>
            Edit User
          </Button>
        </div>
      </div>

      {/* User Info Card */}
      <div className="bg-white rounded-xl border border-zinc-200 p-4 sm:p-5 mb-4 sm:mb-5">
        <h2 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider mb-4">
          User Information
        </h2>
        <div className="grid grid-cols-2 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4 text-sm">
          <div>
            <span className="text-zinc-400 text-[11px] uppercase tracking-wider block">First Name</span>
            <div className="text-zinc-800 font-medium mt-0.5">{user.firstName || '-'}</div>
          </div>
          <div>
            <span className="text-zinc-400 text-[11px] uppercase tracking-wider block">Last Name</span>
            <div className="text-zinc-800 font-medium mt-0.5">{user.lastName || '-'}</div>
          </div>
          <div>
            <span className="text-zinc-400 text-[11px] uppercase tracking-wider block">Email</span>
            <div className="text-zinc-800 mt-0.5 font-mono text-xs">{user.email || '-'}</div>
          </div>
          <div>
            <span className="text-zinc-400 text-[11px] uppercase tracking-wider block">Status</span>
            <div className="mt-0.5">
              <Badge variant={user.isActive !== false ? 'success' : 'danger'} dot size="sm">
                {user.isActive !== false ? 'Active' : 'Inactive'}
              </Badge>
            </div>
          </div>
          <div>
            <span className="text-zinc-400 text-[11px] uppercase tracking-wider block">Superadmin</span>
            <div className="mt-0.5">
              <Badge variant={user.isSuperadmin ? 'purple' : 'muted'} size="sm">
                {user.isSuperadmin ? 'Yes' : 'No'}
              </Badge>
            </div>
          </div>
          <div>
            <span className="text-zinc-400 text-[11px] uppercase tracking-wider block">Created</span>
            <div className="text-zinc-800 mt-0.5 font-mono text-xs">
              {formatDate(user.createdAt)}
            </div>
          </div>
        </div>
      </div>

      {/* Product Access */}
      <div className="bg-white rounded-xl border border-zinc-200 p-4 sm:p-5 mb-4 sm:mb-5">
        <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2 mb-4">
          <h2 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider">
            Product Access
          </h2>
          <Button size="sm" variant="secondary" onClick={() => setAssignOpen(true)}>
            <Plus className="w-3.5 h-3.5" />
            <span className="hidden sm:inline">Add Product Access</span>
            <span className="sm:hidden">Add Access</span>
          </Button>
        </div>
        {userProducts && userProducts.length > 0 ? (
          <>
            <div className="hidden md:block overflow-x-auto">
              <table className="w-full text-sm text-left">
                <thead>
                  <tr className="bg-zinc-50 border-b border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                    <th className="px-4 py-2">Product</th>
                    <th className="px-4 py-2">Role</th>
                    <th className="px-4 py-2">Permissions</th>
                    <th className="px-4 py-2 w-24 text-right">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {userProducts.map((p: any, i: number) => (
                    <tr key={p.slug || i} className={cn('border-b border-zinc-100', i % 2 === 1 ? 'bg-zinc-50' : 'bg-white')}>
                      <td className="px-4 py-2.5 font-medium text-zinc-800">{p.slug}</td>
                      <td className="px-4 py-2.5">
                        <Badge variant="info" size="sm">{p.role || p.roleName || '-'}</Badge>
                      </td>
                      <td className="px-4 py-2.5 text-zinc-500 font-mono text-xs">
                        {(p.permissions || []).length} permissions
                      </td>
                      <td className="px-4 py-2.5 text-right">
                        <Button
                          variant="ghost"
                          size="sm"
                          className="text-red-600 hover:text-red-700 hover:bg-red-50"
                          onClick={() => {
                            if (window.confirm(`Remove access to ${p.slug}?`)) {
                              revokeMut.mutate(p.slug);
                            }
                          }}
                          loading={revokeMut.isPending}
                        >
                          <Trash2 className="w-3.5 h-3.5" />
                          Remove
                        </Button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {/* Mobile cards */}
            <div className="md:hidden space-y-2">
              {userProducts.map((p: any, i: number) => (
                <div key={p.slug || i} className="border border-zinc-200 rounded-lg p-3">
                  <div className="flex items-start justify-between gap-2 mb-1.5">
                    <div className="text-sm font-medium text-zinc-800 min-w-0 flex-1 break-all">{p.slug}</div>
                    <Button
                      variant="ghost"
                      size="icon-sm"
                      className="text-red-600 hover:text-red-700 hover:bg-red-50 shrink-0"
                      onClick={() => {
                        if (window.confirm(`Remove access to ${p.slug}?`)) {
                          revokeMut.mutate(p.slug);
                        }
                      }}
                      loading={revokeMut.isPending}
                      aria-label="Remove access"
                    >
                      <Trash2 className="w-4 h-4" />
                    </Button>
                  </div>
                  <div className="flex items-center gap-2 flex-wrap">
                    <Badge variant="info" size="sm">{p.role || p.roleName || '-'}</Badge>
                    <span className="text-xs text-zinc-500 font-mono">{(p.permissions || []).length} perms</span>
                  </div>
                </div>
              ))}
            </div>
          </>
        ) : (
          <p className="text-sm text-zinc-400">No product access assigned.</p>
        )}
      </div>

      {/* Scoped Access — role overrides scoped to a deployment / app across products */}
      <div className="bg-white rounded-xl border border-zinc-200 p-4 sm:p-5 mb-4 sm:mb-5">
        <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2 mb-4">
          <h2 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider">
            Scoped Access
          </h2>
          <Button size="sm" variant="secondary" onClick={() => setAssignDeploymentOpen(true)}>
            <Plus className="w-3.5 h-3.5" />
            <span className="hidden sm:inline">Add Scoped Access</span>
            <span className="sm:hidden">Add Access</span>
          </Button>
        </div>
        {userDeploymentAccess && userDeploymentAccess.length > 0 ? (
          <>
            <div className="hidden md:block overflow-x-auto">
              <table className="w-full text-sm text-left">
                <thead>
                  <tr className="bg-zinc-50 border-b border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                    <th className="px-4 py-2">Product</th>
                    <th className="px-4 py-2">App Group</th>
                    <th className="px-4 py-2">Role</th>
                    <th className="px-4 py-2 w-24 text-right">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {userDeploymentAccess.map((d: any, i: number) => (
                    <tr key={d.id || i} className={cn('border-b border-zinc-100', i % 2 === 1 ? 'bg-zinc-50' : 'bg-white')}>
                      <td className="px-4 py-2.5 font-medium text-zinc-800">{d.productSlug}</td>
                      <td className="px-4 py-2.5 font-mono text-xs text-zinc-700">{d.appGroup}</td>
                      <td className="px-4 py-2.5">
                        <Badge variant="info" size="sm">{d.roleName || '-'}</Badge>
                      </td>
                      <td className="px-4 py-2.5 text-right">
                        <Button
                          variant="ghost"
                          size="sm"
                          className="text-red-600 hover:text-red-700 hover:bg-red-50"
                          onClick={() => {
                            if (window.confirm(`Remove deployment access to ${d.appGroup}?`)) {
                              revokeDeploymentMut.mutate({ productSlug: d.productSlug, appGroup: d.appGroup });
                            }
                          }}
                          loading={revokeDeploymentMut.isPending}
                        >
                          <Trash2 className="w-3.5 h-3.5" />
                          Remove
                        </Button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {/* Mobile cards */}
            <div className="md:hidden space-y-2">
              {userDeploymentAccess.map((d: any, i: number) => (
                <div key={d.id || i} className="border border-zinc-200 rounded-lg p-3">
                  <div className="flex items-start justify-between gap-2 mb-1.5">
                    <div className="text-sm font-medium text-zinc-800 min-w-0 flex-1 break-all">
                      {d.productSlug} <span className="text-zinc-400 font-normal">/</span> {d.appGroup}
                    </div>
                    <Button
                      variant="ghost"
                      size="icon-sm"
                      className="text-red-600 hover:text-red-700 hover:bg-red-50 shrink-0"
                      onClick={() => {
                        if (window.confirm(`Remove deployment access to ${d.appGroup}?`)) {
                          revokeDeploymentMut.mutate({ productSlug: d.productSlug, appGroup: d.appGroup });
                        }
                      }}
                      loading={revokeDeploymentMut.isPending}
                      aria-label="Remove deployment access"
                    >
                      <Trash2 className="w-4 h-4" />
                    </Button>
                  </div>
                  <Badge variant="info" size="sm">{d.roleName || '-'}</Badge>
                </div>
              ))}
            </div>
          </>
        ) : (
          <p className="text-sm text-zinc-400">No scoped access assigned. Product-level roles apply to every deployment and app.</p>
        )}
      </div>

      {/* Permission Overrides */}
      <div className="bg-white rounded-xl border border-zinc-200 p-4 sm:p-5 mb-4 sm:mb-5">
        <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2 mb-4">
          <h2 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider">
            Permission Overrides
          </h2>
          <Button size="sm" variant="secondary" onClick={() => setOverrideOpen(true)}>
            <Plus className="w-3.5 h-3.5" />
            Add Override
          </Button>
        </div>
        {userOverrides && userOverrides.length > 0 ? (
          <>
            <div className="hidden md:block overflow-x-auto">
              <table className="w-full text-sm text-left">
                <thead>
                  <tr className="bg-zinc-50 border-b border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                    <th className="px-4 py-2">Product</th>
                    <th className="px-4 py-2">Permission</th>
                    <th className="px-4 py-2">Type</th>
                    <th className="px-4 py-2 w-24 text-right">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {userOverrides.map((o: any, i: number) => (
                    <tr key={o.id || i} className={cn('border-b border-zinc-100', i % 2 === 1 ? 'bg-zinc-50' : 'bg-white')}>
                      <td className="px-4 py-2.5 text-zinc-800">{o.productSlug}</td>
                      <td className="px-4 py-2.5 font-mono text-xs">
                        {o.permissionAction || o.permission}
                      </td>
                      <td className="px-4 py-2.5">
                        <Badge variant={o.overrideType === 'GRANT' || o.type === 'GRANT' ? 'success' : 'danger'} size="sm">
                          {o.overrideType || o.type}
                        </Badge>
                      </td>
                      <td className="px-4 py-2.5 text-right">
                        <Button
                          variant="ghost"
                          size="sm"
                          className="text-red-600 hover:text-red-700 hover:bg-red-50"
                          onClick={() => {
                            if (window.confirm('Remove this permission override?')) {
                              removeOverrideMut.mutate(o.id);
                            }
                          }}
                          loading={removeOverrideMut.isPending}
                        >
                          <Trash2 className="w-3.5 h-3.5" />
                          Remove
                        </Button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {/* Mobile cards */}
            <div className="md:hidden space-y-2">
              {userOverrides.map((o: any, i: number) => (
                <div key={o.id || i} className="border border-zinc-200 rounded-lg p-3">
                  <div className="flex items-start justify-between gap-2 mb-1.5">
                    <div className="text-sm font-medium text-zinc-800 break-all min-w-0 flex-1">{o.productSlug}</div>
                    <Button
                      variant="ghost"
                      size="icon-sm"
                      className="text-red-600 hover:text-red-700 hover:bg-red-50 shrink-0"
                      onClick={() => {
                        if (window.confirm('Remove this permission override?')) {
                          removeOverrideMut.mutate(o.id);
                        }
                      }}
                      loading={removeOverrideMut.isPending}
                      aria-label="Remove override"
                    >
                      <Trash2 className="w-4 h-4" />
                    </Button>
                  </div>
                  <div className="text-xs text-zinc-600 font-mono break-all mb-1.5">{o.permissionAction || o.permission}</div>
                  <Badge variant={o.overrideType === 'GRANT' || o.type === 'GRANT' ? 'success' : 'danger'} size="sm">
                    {o.overrideType || o.type}
                  </Badge>
                </div>
              ))}
            </div>
          </>
        ) : (
          <p className="text-sm text-zinc-400">No permission overrides.</p>
        )}
      </div>

      {/* Activate / Deactivate User */}
      <div className="flex justify-end pt-2 mb-8">
        <Button variant={isUserActive ? 'danger' : 'success'} size="sm" onClick={() => setDeactivateOpen(true)}>
          {isUserActive ? 'Deactivate User' : 'Activate User'}
        </Button>
      </div>

      {/* ── Edit User Dialog ── */}
      <Dialog open={editOpen} onOpenChange={setEditOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Edit User</DialogTitle>
            <DialogDescription>Update user information.</DialogDescription>
          </DialogHeader>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              updateMut.mutate();
            }}
          >
            <DialogBody className="space-y-4">
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <Input
                  label="First Name"
                  value={editForm.firstName}
                  onChange={(e) => setEditForm((f) => ({ ...f, firstName: e.target.value }))}
                />
                <Input
                  label="Last Name"
                  value={editForm.lastName}
                  onChange={(e) => setEditForm((f) => ({ ...f, lastName: e.target.value }))}
                />
              </div>
              <label className="flex items-center gap-2 cursor-pointer">
                <input
                  type="checkbox"
                  checked={editForm.isActive}
                  onChange={(e) => setEditForm((f) => ({ ...f, isActive: e.target.checked }))}
                  className="rounded border-zinc-300 accent-zinc-900 cursor-pointer"
                />
                <span className="text-sm text-zinc-700">Active</span>
              </label>
              <label className="flex items-center gap-2 cursor-pointer">
                <input
                  type="checkbox"
                  checked={editForm.isSuperadmin}
                  onChange={(e) => setEditForm((f) => ({ ...f, isSuperadmin: e.target.checked }))}
                  className="rounded border-zinc-300 accent-zinc-900 cursor-pointer"
                />
                <span className="text-sm text-zinc-700">Superadmin</span>
              </label>
            </DialogBody>
            <DialogFooter>
              <Button variant="secondary" type="button" onClick={() => setEditOpen(false)}>
                Cancel
              </Button>
              <Button type="submit" loading={updateMut.isPending}>
                Save Changes
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>

      {/* ── Assign Role Dialog ── */}
      <Dialog open={assignOpen} onOpenChange={setAssignOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Add Product Access</DialogTitle>
            <DialogDescription>Assign a role to this user for a product.</DialogDescription>
          </DialogHeader>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              if (!assignProduct || !assignRoleId) {
                toast.error('Select a product and role');
                return;
              }
              assignMut.mutate();
            }}
          >
            <DialogBody className="space-y-4">
              <SelectInput
                label="Product"
                required
                placeholder="Select a product"
                value={assignProduct}
                onChange={(e) => {
                  setAssignProduct(e.target.value);
                  setAssignRoleId('');
                }}
                options={grantableProducts}
              />
              <SelectInput
                label="Role"
                required
                placeholder={assignProduct ? 'Select a role' : 'Select a product first'}
                disabled={!assignProduct}
                value={assignRoleId}
                onChange={(e) => setAssignRoleId(e.target.value)}
                options={productRoles.map((r: any) => ({
                  value: String(r.id),
                  label: r.name,
                }))}
              />
              {selectedRole && selectedRole.permissions && selectedRole.permissions.length > 0 && (
                <div>
                  <span className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-2">
                    Role Permissions
                  </span>
                  <div className="max-h-40 overflow-y-auto border border-zinc-200 rounded-lg p-3 bg-zinc-50">
                    <div className="flex flex-wrap gap-1.5">
                      {selectedRole.permissions.map((perm: string) => (
                        <Badge key={perm} variant="default" size="sm">
                          {perm}
                        </Badge>
                      ))}
                    </div>
                  </div>
                </div>
              )}
            </DialogBody>
            <DialogFooter>
              <Button variant="secondary" type="button" onClick={() => setAssignOpen(false)}>
                Cancel
              </Button>
              <Button type="submit" loading={assignMut.isPending}>
                Assign
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>

      <Dialog open={assignDeploymentOpen} onOpenChange={setAssignDeploymentOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Add Scoped Access</DialogTitle>
            <DialogDescription>
              Grant a role scoped to specific deployments or apps within a product. It
              overrides the product-level role for those only; access to everything else
              keeps using the product-level role.
            </DialogDescription>
          </DialogHeader>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              if (!assignSurface || assignDeployApps.length === 0 || !assignDeployRoleId) {
                toast.error('Select a surface, at least one app, and a role');
                return;
              }
              assignDeploymentMut.mutate();
            }}
          >
            <DialogBody className="space-y-4">
              <SelectInput
                label="Surface"
                required
                placeholder="Select a surface"
                value={assignSurface}
                onChange={(e) => {
                  setAssignSurface(e.target.value as AccessSurfaceId);
                  setAssignDeployRoleId('');
                  setAssignDeployApps([]);
                }}
                options={ACCESS_SURFACES.map((s) => ({ value: s.id, label: s.label }))}
              />
              {surface && !surface.enforced && (
                <div className="flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800">
                  <span className="mt-0.5">⚠</span>
                  <span>
                    Mobile per-app access isn't enforced by the backend yet — grants are saved
                    and become active once mobile handlers check per-app permission. Until then
                    the product-level Mobile role governs access.
                  </span>
                </div>
              )}
              {assignSurface && (
                <MultiSelect
                  label={`${assignSurface === 'backend' ? 'Deployments' : 'Apps'} — grant this role across any number (${surfaceAppOptions.length})`}
                  placeholder={assignSurface === 'backend' ? 'Search deployments…' : 'Search apps…'}
                  options={surfaceAppOptions}
                  value={assignDeployApps}
                  onChange={setAssignDeployApps}
                  groupOrder={['Fleet', 'Customer', 'Driver']}
                  emptyText="No apps available for this surface."
                />
              )}
              <SelectInput
                label="Role"
                required
                placeholder={assignSurface ? 'Select a role' : 'Select a surface first'}
                disabled={!assignSurface}
                value={assignDeployRoleId}
                onChange={(e) => setAssignDeployRoleId(e.target.value)}
                options={deployProductRoles.map((r: any) => ({
                  value: String(r.id),
                  label: r.name,
                }))}
              />
              {selectedDeployRole && selectedDeployRole.permissions && selectedDeployRole.permissions.length > 0 && (
                <div>
                  <span className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-2">
                    Role Permissions
                  </span>
                  <div className="max-h-40 overflow-y-auto border border-zinc-200 rounded-lg p-3 bg-zinc-50">
                    <div className="flex flex-wrap gap-1.5">
                      {selectedDeployRole.permissions.map((perm: string) => (
                        <Badge key={perm} variant="default" size="sm">
                          {perm}
                        </Badge>
                      ))}
                    </div>
                  </div>
                </div>
              )}
            </DialogBody>
            <DialogFooter>
              <Button variant="secondary" type="button" onClick={resetDeployForm}>
                Cancel
              </Button>
              <Button type="submit" loading={assignDeploymentMut.isPending}>
                {assignDeployApps.length > 1
                  ? `Assign to ${assignDeployApps.length} apps`
                  : 'Assign'}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>

      {/* ── Add Override Dialog (multi-select) ── */}
      <Dialog open={overrideOpen} onOpenChange={setOverrideOpen}>
        <DialogContent size="lg">
          <DialogHeader>
            <DialogTitle>Add Permission Overrides</DialogTitle>
            <DialogDescription>Select one or more permissions to grant or deny for this user.</DialogDescription>
          </DialogHeader>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              if (!overrideProduct || selectedOverridePerms.length === 0) {
                toast.error('Select a product and at least one permission');
                return;
              }
              addOverrideMut.mutate();
            }}
          >
            <DialogBody className="space-y-4">
              <SelectInput
                label="Product"
                required
                placeholder="Select a product"
                value={overrideProduct}
                onChange={(e) => {
                  setOverrideProduct(e.target.value);
                  setSelectedOverridePerms([]);
                }}
                options={grantableProducts}
              />

              {/* Override type */}
              <div className="space-y-1.5">
                <span className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider">Type</span>
                <div className="flex items-center gap-4">
                  <label className="flex items-center gap-2 cursor-pointer">
                    <input type="radio" name="overrideType" value="GRANT" checked={overrideType === 'GRANT'} onChange={() => setOverrideType('GRANT')} className="accent-emerald-600 cursor-pointer" />
                    <span className="text-sm text-zinc-700">Grant</span>
                  </label>
                  <label className="flex items-center gap-2 cursor-pointer">
                    <input type="radio" name="overrideType" value="DENY" checked={overrideType === 'DENY'} onChange={() => setOverrideType('DENY')} className="accent-red-600 cursor-pointer" />
                    <span className="text-sm text-zinc-700">Deny</span>
                  </label>
                </div>
              </div>

              {/* Multi-select permissions */}
              <div className="space-y-1.5">
                <div className="flex items-center justify-between">
                  <span className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider">
                    Permissions {selectedOverridePerms.length > 0 && <span className="text-zinc-400">({selectedOverridePerms.length} selected)</span>}
                  </span>
                  {overrideProduct && productPermissions.length > 0 && (
                    <button
                      type="button"
                      className="text-[11px] text-blue-600 hover:text-blue-800 cursor-pointer transition-colors duration-150"
                      onClick={() => {
                        const allPerms = productPermissions.map((p: any) => typeof p === 'string' ? p : p.action || p.name);
                        setSelectedOverridePerms(selectedOverridePerms.length === allPerms.length ? [] : allPerms);
                      }}
                    >
                      {selectedOverridePerms.length === productPermissions.length ? 'Deselect All' : 'Select All'}
                    </button>
                  )}
                </div>
                {!overrideProduct ? (
                  <p className="text-xs text-zinc-400 py-2">Select a product first</p>
                ) : (
                  <div className="max-h-52 overflow-y-auto border border-zinc-200 rounded-lg divide-y divide-zinc-100">
                    {productPermissions.map((perm: any) => {
                      const permName = typeof perm === 'string' ? perm : perm.action || perm.name;
                      const isSelected = selectedOverridePerms.includes(permName);
                      // Check if already overridden
                      const alreadyOverridden = userOverrides.some((o: any) => o.permissionAction === permName || o.permission === permName);
                      return (
                        <label
                          key={permName}
                          className={cn(
                            'flex items-center gap-3 px-3 py-2 cursor-pointer transition-colors duration-100',
                            isSelected ? 'bg-zinc-50' : 'hover:bg-zinc-50',
                            alreadyOverridden && 'opacity-50'
                          )}
                        >
                          <input
                            type="checkbox"
                            checked={isSelected}
                            disabled={alreadyOverridden}
                            onChange={() => {
                              setSelectedOverridePerms(prev =>
                                isSelected ? prev.filter(p => p !== permName) : [...prev, permName]
                              );
                            }}
                            className="accent-zinc-900 cursor-pointer rounded"
                          />
                          <span className="text-xs font-mono text-zinc-700">{permName}</span>
                          {alreadyOverridden && <span className="text-[10px] text-zinc-400 ml-auto">already overridden</span>}
                        </label>
                      );
                    })}
                  </div>
                )}
              </div>
            </DialogBody>
            <DialogFooter>
              <Button variant="secondary" type="button" onClick={() => setOverrideOpen(false)}>
                Cancel
              </Button>
              <Button type="submit" loading={addOverrideMut.isPending} disabled={selectedOverridePerms.length === 0}>
                Add {selectedOverridePerms.length > 0 ? `${selectedOverridePerms.length} Override${selectedOverridePerms.length > 1 ? 's' : ''}` : 'Override'}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>

      {/* ── Activate/Deactivate Confirmation Dialog ── */}
      <Dialog open={deactivateOpen} onOpenChange={setDeactivateOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{isUserActive ? 'Deactivate' : 'Activate'} User</DialogTitle>
            <DialogDescription>
              {isUserActive
                ? <>Are you sure you want to deactivate <strong>{userName}</strong>? They will lose access to all products.</>
                : <>Are you sure you want to activate <strong>{userName}</strong>? They will regain their previous product access.</>
              }
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="secondary" onClick={() => setDeactivateOpen(false)}>
              Cancel
            </Button>
            <Button
              variant={isUserActive ? 'danger' : 'success'}
              onClick={() => toggleActiveMut.mutate()}
              loading={toggleActiveMut.isPending}
            >
              {isUserActive ? 'Deactivate' : 'Activate'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default UserDetail;
