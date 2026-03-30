import React from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { fetchUser, deactivateUser } from '../api';
import { Button } from '../../../shared/ui/button';
import { Badge } from '../../../shared/ui/badge';
import { CardSkeleton } from '../../../shared/ui/skeleton';
import { cn } from '../../../lib/utils';
import { toast } from 'sonner';

const UserDetail: React.FC = () => {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  const { data: user, isLoading } = useQuery({
    queryKey: ['admin-user', id],
    queryFn: () => fetchUser(id!),
    enabled: !!id,
  });

  const deactivateMut = useMutation({
    mutationFn: () => deactivateUser(id!),
    onSuccess: () => { toast.success('User deactivated'); queryClient.invalidateQueries({ queryKey: ['admin-user', id] }); },
    onError: (err: any) => { toast.error(err.message || 'Failed to deactivate'); },
  });

  if (isLoading) {
    return (
      <div className="flex flex-col w-full max-w-4xl space-y-5">
        <CardSkeleton />
        <CardSkeleton />
      </div>
    );
  }
  if (!user) return <div className="p-10 text-center text-red-500">User not found.</div>;

  return (
    <div className="flex flex-col w-full max-w-4xl">
      <div className="flex items-center justify-between mb-5">
        <div>
          <h1 className="text-lg font-semibold text-zinc-900">{user.name || 'User'}</h1>
          <p className="text-sm text-zinc-500 font-mono">{user.email}</p>
        </div>
        <div className="flex items-center gap-2">
          <Badge variant={user.status === 'active' ? 'success' : 'muted'} dot>{user.status || 'active'}</Badge>
          <Button size="sm" variant="danger" onClick={() => { if (confirm('Deactivate this user?')) deactivateMut.mutate(); }} loading={deactivateMut.isPending}>
            Deactivate
          </Button>
        </div>
      </div>

      {/* User Info */}
      <div className="bg-white rounded-xl border border-zinc-200 p-6 mb-5">
        <h2 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider mb-4">User Information</h2>
        <div className="grid grid-cols-2 gap-4 text-sm">
          <div><span className="text-zinc-400 text-[11px] uppercase tracking-wider">Name</span><div className="text-zinc-800 font-medium mt-0.5">{user.name || '-'}</div></div>
          <div><span className="text-zinc-400 text-[11px] uppercase tracking-wider">Email</span><div className="text-zinc-800 font-mono text-xs mt-0.5">{user.email}</div></div>
          <div><span className="text-zinc-400 text-[11px] uppercase tracking-wider">Status</span><div className="mt-0.5">{user.status || 'active'}</div></div>
          <div><span className="text-zinc-400 text-[11px] uppercase tracking-wider">Created</span><div className="text-zinc-800 font-mono text-xs mt-0.5">{user.createdAt || '-'}</div></div>
        </div>
      </div>

      {/* Product Access */}
      <div className="bg-white rounded-xl border border-zinc-200 p-6 mb-5">
        <div className="flex items-center justify-between mb-4">
          <h2 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider">Product Access</h2>
        </div>
        {user.products && user.products.length > 0 ? (
          <div className="overflow-x-auto">
            <table className="w-full text-sm text-left">
              <thead><tr className="bg-zinc-50 border-b border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                <th className="px-4 py-2">Product</th><th className="px-4 py-2">Role</th><th className="px-4 py-2">Permissions</th>
              </tr></thead>
              <tbody>
                {user.products.map((p: any, i: number) => (
                  <tr key={i} className={cn('border-b border-zinc-100', i % 2 === 1 ? 'bg-zinc-50' : 'bg-white')}>
                    <td className="px-4 py-2 font-medium text-zinc-800">{p.slug}</td>
                    <td className="px-4 py-2"><Badge variant="info" size="sm">{p.role}</Badge></td>
                    <td className="px-4 py-2 text-zinc-500 font-mono text-xs">{(p.permissions || []).length} permissions</td>
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
      <div className="bg-white rounded-xl border border-zinc-200 p-6 mb-5">
        <h2 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider mb-4">Permission Overrides</h2>
        {user.overrides && user.overrides.length > 0 ? (
          <div className="overflow-x-auto">
            <table className="w-full text-sm text-left">
              <thead><tr className="bg-zinc-50 border-b border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                <th className="px-4 py-2">Product</th><th className="px-4 py-2">Permission</th><th className="px-4 py-2">Type</th>
              </tr></thead>
              <tbody>
                {user.overrides.map((o: any, i: number) => (
                  <tr key={i} className={cn('border-b border-zinc-100', i % 2 === 1 ? 'bg-zinc-50' : 'bg-white')}>
                    <td className="px-4 py-2">{o.productSlug}</td>
                    <td className="px-4 py-2 font-mono text-xs">{o.permission}</td>
                    <td className="px-4 py-2"><Badge variant={o.type === 'GRANT' ? 'success' : 'danger'} size="sm">{o.type}</Badge></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <p className="text-sm text-zinc-400">No permission overrides.</p>
        )}
      </div>

      <div className="flex justify-end pt-2">
        <Button variant="secondary" onClick={() => navigate('/admin/users')}>Back to Users</Button>
      </div>
    </div>
  );
};

export default UserDetail;
