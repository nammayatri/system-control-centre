import React, { useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useNavigate } from 'react-router-dom';
import { fetchAdminProducts, fetchProductRoles, fetchProductPermissions, createRole } from '../api';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { Input, Textarea } from '../../../shared/ui/input';
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
import { Plus } from 'lucide-react';

interface ProductWithRoles {
  slug: string;
  name: string;
  roles: any[];
}

const RoleList: React.FC = () => {
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  // Create role dialog state
  const [createOpen, setCreateOpen] = useState(false);
  const [createProduct, setCreateProduct] = useState('');
  const [createForm, setCreateForm] = useState({ name: '', description: '' });
  const [selectedPerms, setSelectedPerms] = useState<string[]>([]);

  // Fetch all products
  const { data: products = [], isLoading: productsLoading } = useQuery({
    queryKey: ['admin-products'],
    queryFn: fetchAdminProducts,
  });

  // Fetch roles per product — we need to build a combined view
  const productSlugs = products.map((p: any) => p.slug || p);
  const roleQueries = useQuery({
    queryKey: ['admin-all-product-roles', productSlugs],
    queryFn: async () => {
      const results: ProductWithRoles[] = [];
      for (const p of products) {
        const slug = p.slug || p;
        const name = p.name || slug;
        try {
          const roles = await fetchProductRoles(slug);
          results.push({ slug, name, roles });
        } catch {
          results.push({ slug, name, roles: [] });
        }
      }
      return results;
    },
    enabled: products.length > 0,
  });

  const productData: ProductWithRoles[] = roleQueries.data || [];
  const isLoading = productsLoading || roleQueries.isLoading;

  // Fetch permissions for create dialog
  const { data: createPermissions = [] } = useQuery({
    queryKey: ['admin-product-permissions', createProduct],
    queryFn: () => fetchProductPermissions(createProduct),
    enabled: !!createProduct,
  });

  const createMut = useMutation({
    mutationFn: () =>
      createRole(createProduct, {
        name: createForm.name,
        description: createForm.description || undefined,
        permissions: selectedPerms,
      }),
    onSuccess: () => {
      toast.success('Role created successfully');
      queryClient.invalidateQueries({ queryKey: ['admin-all-product-roles'] });
      setCreateOpen(false);
      setCreateProduct('');
      setCreateForm({ name: '', description: '' });
      setSelectedPerms([]);
    },
    onError: (err: any) => toast.error(err?.response?.data?.error || err.message || 'Failed to create role'),
  });

  const togglePerm = (perm: string) => {
    setSelectedPerms((prev) => (prev.includes(perm) ? prev.filter((p) => p !== perm) : [...prev, perm]));
  };

  const openCreateDialog = (productSlug: string) => {
    setCreateProduct(productSlug);
    setCreateForm({ name: '', description: '' });
    setSelectedPerms([]);
    setCreateOpen(true);
  };

  return (
    <div className="flex flex-col w-full pb-12">
      <h1 className="text-lg sm:text-xl font-semibold text-zinc-900 mb-4 sm:mb-5">
        Roles
      </h1>

      {isLoading ? (
        <div className="space-y-5">
          <CardSkeleton />
          <CardSkeleton />
        </div>
      ) : productData.length === 0 ? (
        <div className="p-10 text-center text-zinc-400">No products found.</div>
      ) : (
        <div className="space-y-5">
          {productData.map((product) => (
            <div key={product.slug} className="bg-white rounded-xl border border-zinc-200 overflow-hidden">
              <div className="px-3 sm:px-4 py-3 bg-zinc-50 border-b border-zinc-200 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2">
                <h2 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider truncate">
                  {product.name}
                </h2>
                <Button size="sm" variant="secondary" onClick={() => openCreateDialog(product.slug)}>
                  <Plus className="w-3.5 h-3.5" />
                  <span className="hidden sm:inline">Create Custom Role</span>
                  <span className="sm:hidden">Add Custom Role</span>
                </Button>
              </div>
              {product.roles.length === 0 ? (
                <div className="px-4 py-6 text-center text-sm text-zinc-400">No roles for this product.</div>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full text-left text-sm">
                    <thead>
                      <tr className="border-b border-zinc-100 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                        <th className="px-4 py-2">Role</th>
                        <th className="px-4 py-2 w-28">Type</th>
                        <th className="px-4 py-2 w-36">Permissions</th>
                      </tr>
                    </thead>
                    <tbody>
                      {product.roles.map((role: any, i: number) => (
                        <tr
                          key={role.id}
                          className={cn(
                            'border-b border-zinc-100 hover:bg-zinc-100 cursor-pointer transition-colors duration-150',
                            i % 2 === 1 ? 'bg-zinc-50' : 'bg-white'
                          )}
                          onClick={() => navigate(`/admin/roles/${role.id}`, { state: { productSlug: product.slug } })}
                        >
                          <td className="px-4 py-2.5 font-medium text-zinc-800">{role.name}</td>
                          <td className="px-4 py-2.5">
                            <Badge variant={role.type === 'system' ? 'info' : 'default'} size="sm">
                              {role.type || 'custom'}
                            </Badge>
                          </td>
                          <td className="px-4 py-2.5 text-zinc-500 font-mono text-xs">
                            {(role.permissions || []).length} permissions
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
          ))}
        </div>
      )}

      {/* ── Create Custom Role Dialog ── */}
      <Dialog open={createOpen} onOpenChange={setCreateOpen}>
        <DialogContent size="xl">
          <DialogHeader>
            <DialogTitle>Create Custom Role</DialogTitle>
            <DialogDescription>
              Create a new role for <strong>{createProduct}</strong>.
            </DialogDescription>
          </DialogHeader>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              if (!createForm.name.trim()) {
                toast.error('Role name is required');
                return;
              }
              createMut.mutate();
            }}
          >
            <DialogBody className="space-y-4">
              <Input
                label="Role Name"
                required
                value={createForm.name}
                onChange={(e) => setCreateForm((f) => ({ ...f, name: e.target.value }))}
                placeholder="e.g. Release Manager"
              />
              <Textarea
                label="Description"
                value={createForm.description}
                onChange={(e) => setCreateForm((f) => ({ ...f, description: e.target.value }))}
                placeholder="Optional description"
                rows={2}
              />
              <div>
                <span className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-2">
                  Permissions ({selectedPerms.length} selected)
                </span>
                {createPermissions.length > 0 ? (
                  <div className="max-h-52 overflow-y-auto border border-zinc-200 rounded-lg p-3 bg-zinc-50">
                    <div className="grid grid-cols-1 md:grid-cols-2 gap-1">
                      {createPermissions.map((perm: any) => {
                        const permStr = typeof perm === 'string' ? perm : perm.action || perm.name;
                        return (
                          <label key={permStr} className="flex items-center gap-2 px-2 py-1.5 rounded hover:bg-zinc-100 cursor-pointer transition-colors duration-150">
                            <input
                              type="checkbox"
                              checked={selectedPerms.includes(permStr)}
                              onChange={() => togglePerm(permStr)}
                              className="rounded border-zinc-300 accent-zinc-900 cursor-pointer"
                            />
                            <span className="text-xs text-zinc-700 font-mono">
                              {permStr}
                            </span>
                          </label>
                        );
                      })}
                    </div>
                  </div>
                ) : (
                  <p className="text-sm text-zinc-400">
                    {createProduct ? 'No permissions available.' : 'Select a product first.'}
                  </p>
                )}
              </div>
            </DialogBody>
            <DialogFooter>
              <Button variant="secondary" type="button" onClick={() => setCreateOpen(false)}>
                Cancel
              </Button>
              <Button type="submit" loading={createMut.isPending}>
                Create Role
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default RoleList;
