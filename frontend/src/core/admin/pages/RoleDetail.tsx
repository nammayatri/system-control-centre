import React, { useState, useEffect } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { fetchRole, updateRole } from '../api';
import { Button } from '../../../shared/ui/button';
import { Badge } from '../../../shared/ui/badge';
import { CardSkeleton } from '../../../shared/ui/skeleton';
import { toast } from 'sonner';

const RoleDetail: React.FC = () => {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [selectedPerms, setSelectedPerms] = useState<string[]>([]);

  const { data: role, isLoading } = useQuery({
    queryKey: ['admin-role', id],
    queryFn: () => fetchRole(id!),
    enabled: !!id,
  });

  useEffect(() => {
    if (role?.permissions) setSelectedPerms(role.permissions);
  }, [role]);

  const updateMut = useMutation({
    mutationFn: () => updateRole(id!, { permissions: selectedPerms }),
    onSuccess: () => {
      toast.success('Role permissions updated');
      queryClient.invalidateQueries({ queryKey: ['admin-role', id] });
    },
    onError: (err: any) => { toast.error(err.message || 'Failed to update role'); },
  });

  const togglePerm = (perm: string) => {
    setSelectedPerms(prev => prev.includes(perm) ? prev.filter(p => p !== perm) : [...prev, perm]);
  };

  if (isLoading) {
    return (
      <div className="flex flex-col w-full max-w-3xl space-y-5">
        <CardSkeleton />
      </div>
    );
  }
  if (!role) return <div className="p-10 text-center text-red-500">Role not found.</div>;

  const allPermissions = role.allPermissions || role.availablePermissions || [];

  return (
    <div className="flex flex-col w-full max-w-3xl">
      <div className="flex items-center justify-between mb-5">
        <div>
          <h1 className="text-lg font-semibold text-zinc-900">{role.name}</h1>
          <div className="flex items-center gap-2 mt-1">
            <Badge variant={role.type === 'system' ? 'info' : 'default'} size="sm">{role.type || 'custom'}</Badge>
            <span className="text-sm text-zinc-500">{role.productSlug || 'Global'}</span>
          </div>
        </div>
        <Button onClick={() => updateMut.mutate()} loading={updateMut.isPending}>Save Changes</Button>
      </div>

      {/* Permissions checklist */}
      <div className="bg-white rounded-xl border border-zinc-200 p-6">
        <h2 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider mb-4">Permissions ({selectedPerms.length})</h2>
        {allPermissions.length > 0 ? (
          <div className="grid grid-cols-1 md:grid-cols-2 gap-2">
            {allPermissions.map((perm: string) => (
              <label key={perm} className="flex items-center gap-2.5 px-3 py-2 rounded-lg hover:bg-zinc-50 cursor-pointer transition-colors duration-150">
                <input type="checkbox" checked={selectedPerms.includes(perm)} onChange={() => togglePerm(perm)}
                  className="rounded border-zinc-300 accent-zinc-900 cursor-pointer" />
                <span className="text-sm font-mono text-zinc-700">{perm}</span>
              </label>
            ))}
          </div>
        ) : (
          <p className="text-sm text-zinc-400">No permissions available for this role's product.</p>
        )}
      </div>

      <div className="flex justify-end pt-5">
        <Button variant="secondary" onClick={() => navigate('/admin/roles')}>Back to Roles</Button>
      </div>
    </div>
  );
};

export default RoleDetail;
