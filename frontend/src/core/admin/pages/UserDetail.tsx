import React, { useState } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import {
  fetchUser,
  updateUser,
  deactivateUser,
  assignRole,
  revokeProductAccess,
  addPermissionOverride,
  removePermissionOverride,
  fetchAdminProducts,
  fetchProductPermissions,
  fetchProductRoles,
} from '../api';
import { Button } from '../../../shared/ui/button';
import { Badge } from '../../../shared/ui/badge';
import { Input, SelectInput } from '../../../shared/ui/input';
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
  const [overrideOpen, setOverrideOpen] = useState(false);
  const [deactivateOpen, setDeactivateOpen] = useState(false);

  // Edit form
  const [editForm, setEditForm] = useState({ firstName: '', lastName: '', isActive: true, isSuperadmin: false });

  // Assign role form
  const [assignProduct, setAssignProduct] = useState('');
  const [assignRoleId, setAssignRoleId] = useState('');

  // Override form
  const [overrideProduct, setOverrideProduct] = useState('');
  const [overridePermission, setOverridePermission] = useState('');
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

  const { data: products = [] } = useQuery({
    queryKey: ['admin-products'],
    queryFn: fetchAdminProducts,
  });

  const { data: productRoles = [] } = useQuery({
    queryKey: ['admin-product-roles', assignProduct],
    queryFn: () => fetchProductRoles(assignProduct),
    enabled: !!assignProduct,
  });

  const { data: productPermissions = [] } = useQuery({
    queryKey: ['admin-product-permissions', overrideProduct],
    queryFn: () => fetchProductPermissions(overrideProduct),
    enabled: !!overrideProduct,
  });

  // Selected role details for display
  const selectedRole = productRoles.find((r: any) => String(r.id) === String(assignRoleId));

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

  const addOverrideMut = useMutation({
    mutationFn: () =>
      addPermissionOverride(id!, {
        productSlug: overrideProduct,
        permissionAction: overridePermission,
        overrideType: overrideType,
      }),
    onSuccess: () => {
      toast.success('Permission override added');
      queryClient.invalidateQueries({ queryKey: ['admin-user', id] });
      setOverrideOpen(false);
      setOverrideProduct('');
      setOverridePermission('');
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

  const formatDate = (d: string) => {
    if (!d) return '-';
    return new Date(d).toLocaleDateString('en-US', { month: 'short', day: '2-digit', year: 'numeric' });
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
    <div className="flex flex-col w-full max-w-4xl">
      {/* Back button + header */}
      <button
        onClick={() => navigate('/admin/users')}
        className="flex items-center gap-1.5 text-sm text-zinc-500 hover:text-zinc-700 cursor-pointer mb-4 transition-colors duration-150"
      >
        <ArrowLeft className="w-4 h-4" />
        Back to Users
      </button>

      <div className="flex items-center justify-between mb-5">
        <div>
          <h1 className="text-lg font-semibold text-zinc-900" style={{ fontFamily: 'Fira Sans, sans-serif' }}>
            {userName}
          </h1>
          <p className="text-sm text-zinc-500 mt-0.5" style={{ fontFamily: 'Fira Code, monospace' }}>
            {user.email}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Badge variant={userStatus === 'active' ? 'success' : 'muted'} dot>
            {userStatus}
          </Badge>
          <Button size="sm" variant="secondary" onClick={openEditDialog}>
            Edit User
          </Button>
        </div>
      </div>

      {/* User Info Card */}
      <div className="bg-white rounded-xl border border-zinc-200 p-5 mb-5">
        <h2 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider mb-4" style={{ fontFamily: 'Fira Sans, sans-serif' }}>
          User Information
        </h2>
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4 text-sm">
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
            <div className="text-zinc-800 mt-0.5" style={{ fontFamily: 'Fira Code, monospace', fontSize: '12px' }}>{user.email || '-'}</div>
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
            <div className="text-zinc-800 mt-0.5" style={{ fontFamily: 'Fira Code, monospace', fontSize: '12px' }}>
              {formatDate(user.createdAt)}
            </div>
          </div>
        </div>
      </div>

      {/* Product Access */}
      <div className="bg-white rounded-xl border border-zinc-200 p-5 mb-5">
        <div className="flex items-center justify-between mb-4">
          <h2 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider" style={{ fontFamily: 'Fira Sans, sans-serif' }}>
            Product Access
          </h2>
          <Button size="sm" variant="secondary" onClick={() => setAssignOpen(true)}>
            <Plus className="w-3.5 h-3.5" />
            Add Product Access
          </Button>
        </div>
        {userProducts && userProducts.length > 0 ? (
          <div className="overflow-x-auto">
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
                    <td className="px-4 py-2.5 text-zinc-500" style={{ fontFamily: 'Fira Code, monospace', fontSize: '12px' }}>
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
        ) : (
          <p className="text-sm text-zinc-400">No product access assigned.</p>
        )}
      </div>

      {/* Permission Overrides */}
      <div className="bg-white rounded-xl border border-zinc-200 p-5 mb-5">
        <div className="flex items-center justify-between mb-4">
          <h2 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider" style={{ fontFamily: 'Fira Sans, sans-serif' }}>
            Permission Overrides
          </h2>
          <Button size="sm" variant="secondary" onClick={() => setOverrideOpen(true)}>
            <Plus className="w-3.5 h-3.5" />
            Add Override
          </Button>
        </div>
        {userOverrides && userOverrides.length > 0 ? (
          <div className="overflow-x-auto">
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
                    <td className="px-4 py-2.5" style={{ fontFamily: 'Fira Code, monospace', fontSize: '12px' }}>
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
              <div className="grid grid-cols-2 gap-4">
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
                options={products.map((p: any) => ({
                  value: p.slug || p,
                  label: p.name || p.slug || p,
                }))}
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

      {/* ── Add Override Dialog ── */}
      <Dialog open={overrideOpen} onOpenChange={setOverrideOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Add Permission Override</DialogTitle>
            <DialogDescription>Grant or deny a specific permission for this user.</DialogDescription>
          </DialogHeader>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              if (!overrideProduct || !overridePermission) {
                toast.error('Select a product and permission');
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
                  setOverridePermission('');
                }}
                options={products.map((p: any) => ({
                  value: p.slug || p,
                  label: p.name || p.slug || p,
                }))}
              />
              <SelectInput
                label="Permission"
                required
                placeholder={overrideProduct ? 'Select a permission' : 'Select a product first'}
                disabled={!overrideProduct}
                value={overridePermission}
                onChange={(e) => setOverridePermission(e.target.value)}
                options={productPermissions.map((perm: any) => ({
                  value: typeof perm === 'string' ? perm : perm.action || perm.name,
                  label: typeof perm === 'string' ? perm : perm.action || perm.name,
                }))}
              />
              <div className="space-y-1.5">
                <span className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider">Type</span>
                <div className="flex items-center gap-4">
                  <label className="flex items-center gap-2 cursor-pointer">
                    <input
                      type="radio"
                      name="overrideType"
                      value="GRANT"
                      checked={overrideType === 'GRANT'}
                      onChange={() => setOverrideType('GRANT')}
                      className="accent-emerald-600 cursor-pointer"
                    />
                    <span className="text-sm text-zinc-700">Grant</span>
                  </label>
                  <label className="flex items-center gap-2 cursor-pointer">
                    <input
                      type="radio"
                      name="overrideType"
                      value="DENY"
                      checked={overrideType === 'DENY'}
                      onChange={() => setOverrideType('DENY')}
                      className="accent-red-600 cursor-pointer"
                    />
                    <span className="text-sm text-zinc-700">Deny</span>
                  </label>
                </div>
              </div>
            </DialogBody>
            <DialogFooter>
              <Button variant="secondary" type="button" onClick={() => setOverrideOpen(false)}>
                Cancel
              </Button>
              <Button type="submit" loading={addOverrideMut.isPending}>
                Add Override
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
