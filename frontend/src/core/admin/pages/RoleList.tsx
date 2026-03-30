import React from 'react';
import { useQuery } from '@tanstack/react-query';
import { useNavigate } from 'react-router-dom';
import { fetchRoles } from '../api';
import { Badge } from '../../../shared/ui/badge';
import { CardSkeleton } from '../../../shared/ui/skeleton';
import { cn } from '../../../lib/utils';

const RoleList: React.FC = () => {
  const navigate = useNavigate();
  const { data: roles = [], isLoading } = useQuery({ queryKey: ['admin-roles'], queryFn: fetchRoles });

  // Group by product
  const grouped: Record<string, any[]> = {};
  roles.forEach((r: any) => {
    const key = r.productSlug || 'Global';
    if (!grouped[key]) grouped[key] = [];
    grouped[key].push(r);
  });

  return (
    <div className="flex flex-col w-full">
      <h1 className="text-lg font-semibold text-zinc-900 mb-5">Roles</h1>

      {isLoading ? (
        <div className="space-y-5">
          <CardSkeleton />
          <CardSkeleton />
        </div>
      ) : Object.keys(grouped).length === 0 ? (
        <div className="p-10 text-center text-zinc-400">No roles found.</div>
      ) : (
        <div className="space-y-5">
          {Object.entries(grouped).map(([product, productRoles]) => (
            <div key={product} className="bg-white rounded-xl border border-zinc-200 overflow-hidden">
              <div className="px-4 py-3 bg-zinc-50 border-b border-zinc-200">
                <h2 className="text-sm font-semibold text-zinc-700 uppercase tracking-wider">{product}</h2>
              </div>
              <table className="w-full text-left text-sm">
                <thead>
                  <tr className="border-b border-zinc-100 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                    <th className="px-4 py-2">Role</th>
                    <th className="px-4 py-2 w-28">Type</th>
                    <th className="px-4 py-2 w-36">Permissions</th>
                  </tr>
                </thead>
                <tbody>
                  {productRoles.map((role: any, i: number) => (
                    <tr key={role.id} className={cn('border-b border-zinc-100 hover:bg-zinc-100 cursor-pointer transition-colors duration-150', i % 2 === 1 ? 'bg-zinc-50' : 'bg-white')}
                      onClick={() => navigate(`/admin/roles/${role.id}`)}>
                      <td className="px-4 py-2.5 font-medium text-zinc-800">{role.name}</td>
                      <td className="px-4 py-2.5"><Badge variant={role.type === 'system' ? 'info' : 'default'} size="sm">{role.type || 'custom'}</Badge></td>
                      <td className="px-4 py-2.5 font-mono text-xs text-zinc-500">{(role.permissions || []).length} permissions</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ))}
        </div>
      )}
    </div>
  );
};

export default RoleList;
