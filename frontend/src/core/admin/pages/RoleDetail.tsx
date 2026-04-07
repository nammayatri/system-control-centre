import React, { useState, useEffect } from 'react';
import { useParams, useNavigate, useLocation } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { fetchProductRoles, fetchProductPermissions, updateRole, fetchAdminProducts } from '../api';
import { Button } from '../../../shared/ui/button';
import { Badge } from '../../../shared/ui/badge';
import { CardSkeleton } from '../../../shared/ui/skeleton';
import { toast } from 'sonner';
import { ArrowLeft } from 'lucide-react';

const RoleDetail: React.FC = () => {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const location = useLocation();
  const queryClient = useQueryClient();
  const [selectedPerms, setSelectedPerms] = useState<string[]>([]);
  const [description, setDescription] = useState('');
  const [dirty, setDirty] = useState(false);

  // Try to get productSlug from navigation state, otherwise we need to find it
  const passedSlug = (location.state as any)?.productSlug || '';
  const [productSlug, setProductSlug] = useState(passedSlug);

  // If no slug passed, fetch all products and find the role
  const { data: products = [] } = useQuery({
    queryKey: ['admin-products'],
    queryFn: fetchAdminProducts,
    enabled: !productSlug,
  });

  // Find the role across products if slug not provided
  const { data: foundRole, isLoading: searchLoading } = useQuery({
    queryKey: ['admin-find-role', id, products],
    queryFn: async () => {
      for (const p of products) {
        const slug = p.slug || p;
        try {
          const roles = await fetchProductRoles(slug);
          const found = roles.find((r: any) => String(r.id) === String(id));
          if (found) {
            setProductSlug(slug);
            return { ...found, productSlug: slug };
          }
        } catch {
          // skip
        }
      }
      return null;
    },
    enabled: !productSlug && products.length > 0,
  });

  // Fetch roles for the known product
  const { data: productRoles = [], isLoading: rolesLoading } = useQuery({
    queryKey: ['admin-product-roles', productSlug],
    queryFn: () => fetchProductRoles(productSlug),
    enabled: !!productSlug,
  });

  // Find our specific role
  const role = productRoles.find((r: any) => String(r.id) === String(id)) || foundRole;

  // Fetch all permissions for this product (for the checklist)
  const { data: allPermissions = [] } = useQuery({
    queryKey: ['admin-product-permissions', productSlug],
    queryFn: () => fetchProductPermissions(productSlug),
    enabled: !!productSlug,
  });

  // Initialize state when role loads
  useEffect(() => {
    if (role) {
      setSelectedPerms(role.permissions || []);
      setDescription(role.description || '');
      setDirty(false);
    }
  }, [role]);

  const isSystem = role?.type === 'system';

  const updateMut = useMutation({
    mutationFn: () =>
      updateRole(productSlug, id!, {
        description,
        permissions: selectedPerms,
      }),
    onSuccess: () => {
      toast.success('Role updated successfully');
      queryClient.invalidateQueries({ queryKey: ['admin-product-roles', productSlug] });
      queryClient.invalidateQueries({ queryKey: ['admin-all-product-roles'] });
      setDirty(false);
    },
    onError: (err: any) => toast.error(err?.response?.data?.error || err.message || 'Failed to update role'),
  });

  const togglePerm = (perm: string) => {
    setSelectedPerms((prev) => {
      const next = prev.includes(perm) ? prev.filter((p) => p !== perm) : [...prev, perm];
      setDirty(true);
      return next;
    });
  };

  const isLoading = rolesLoading || searchLoading;

  if (isLoading) {
    return (
      <div className="flex flex-col w-full max-w-3xl space-y-5">
        <CardSkeleton />
      </div>
    );
  }

  if (!role) {
    return <div className="p-10 text-center text-zinc-400">Role not found.</div>;
  }

  const permList: string[] = allPermissions.map((p: any) => (typeof p === 'string' ? p : p.action || p.name));

  return (
    <div className="flex flex-col w-full max-w-3xl pb-12">
      {/* Back button */}
      <button
        onClick={() => navigate('/admin/roles')}
        className="flex items-center gap-1.5 text-sm text-zinc-500 hover:text-zinc-700 cursor-pointer mb-4 transition-colors duration-150 h-9 -ml-1 px-2 rounded-md hover:bg-zinc-100 self-start"
      >
        <ArrowLeft className="w-4 h-4" />
        Back to Roles
      </button>

      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-start sm:justify-between gap-3 mb-4 sm:mb-5">
        <div>
          <h1 className="text-lg sm:text-xl font-semibold text-zinc-900 break-all">
            {role.name}
          </h1>
          <div className="flex items-center gap-2 mt-1 flex-wrap">
            <Badge variant={isSystem ? 'info' : 'default'} size="sm">
              {role.type || 'custom'}
            </Badge>
            <span className="text-sm text-zinc-500">{productSlug}</span>
          </div>
        </div>
        {!isSystem && (
          <Button onClick={() => updateMut.mutate()} loading={updateMut.isPending} disabled={!dirty}>
            Save Changes
          </Button>
        )}
      </div>

      {/* Role info card */}
      <div className="bg-white rounded-xl border border-zinc-200 p-4 sm:p-5 mb-4 sm:mb-5">
        <h2 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider mb-3">
          Role Information
        </h2>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4 text-sm">
          <div>
            <span className="text-zinc-400 text-[11px] uppercase tracking-wider block">Name</span>
            <div className="text-zinc-800 font-medium mt-0.5">{role.name}</div>
          </div>
          <div>
            <span className="text-zinc-400 text-[11px] uppercase tracking-wider block">Product</span>
            <div className="text-zinc-800 font-medium mt-0.5">{productSlug}</div>
          </div>
          <div>
            <span className="text-zinc-400 text-[11px] uppercase tracking-wider block">Type</span>
            <div className="mt-0.5">
              <Badge variant={isSystem ? 'info' : 'default'} size="sm">
                {isSystem ? 'System' : 'Custom'}
              </Badge>
            </div>
          </div>
          <div>
            <span className="text-zinc-400 text-[11px] uppercase tracking-wider block">Description</span>
            {isSystem ? (
              <div className="text-zinc-800 mt-0.5">{role.description || '-'}</div>
            ) : (
              <input
                type="text"
                value={description}
                onChange={(e) => {
                  setDescription(e.target.value);
                  setDirty(true);
                }}
                className="mt-0.5 w-full h-10 sm:h-9 border border-zinc-300 rounded-lg px-3 text-sm text-zinc-900 focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150"
                placeholder="Add a description"
              />
            )}
          </div>
        </div>
      </div>

      {/* Permissions */}
      <div className="bg-white rounded-xl border border-zinc-200 p-4 sm:p-5">
        <h2 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider mb-4">
          Permissions ({selectedPerms.length})
        </h2>

        {isSystem ? (
          // System roles: read-only permission list
          <div>
            {selectedPerms.length > 0 ? (
              <div className="flex flex-wrap gap-1.5">
                {selectedPerms.map((perm) => (
                  <Badge key={perm} variant="default" size="sm">
                    {perm}
                  </Badge>
                ))}
              </div>
            ) : (
              <p className="text-sm text-zinc-400">No permissions assigned to this role.</p>
            )}
          </div>
        ) : (
          // Custom roles: editable checklist
          <div>
            {permList.length > 0 ? (
              <div className="grid grid-cols-1 md:grid-cols-2 gap-1">
                {permList.map((perm) => (
                  <label
                    key={perm}
                    className="flex items-center gap-2.5 px-3 py-2 rounded-lg hover:bg-zinc-50 cursor-pointer transition-colors duration-150"
                  >
                    <input
                      type="checkbox"
                      checked={selectedPerms.includes(perm)}
                      onChange={() => togglePerm(perm)}
                      className="rounded border-zinc-300 accent-zinc-900 cursor-pointer"
                    />
                    <span className="text-sm text-zinc-700 font-mono">
                      {perm}
                    </span>
                  </label>
                ))}
              </div>
            ) : (
              <p className="text-sm text-zinc-400">No permissions available for this product.</p>
            )}
          </div>
        )}
      </div>
    </div>
  );
};

export default RoleDetail;
