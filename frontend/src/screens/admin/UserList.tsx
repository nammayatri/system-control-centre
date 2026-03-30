import React, { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { useNavigate } from 'react-router-dom';
import { fetchUsers } from '../../services/admin';
import { Button } from '../../components/ui/button';
import { Badge } from '../../components/ui/badge';
import { Search, Plus } from 'lucide-react';
import { cn } from '../../lib/utils';
import { usePermissions } from '../../context/PermissionsContext';

const UserList: React.FC = () => {
  const [search, setSearch] = useState('');
  const navigate = useNavigate();
  const { isAdmin } = usePermissions();

  const { data: users = [], isLoading } = useQuery({
    queryKey: ['admin-users'],
    queryFn: fetchUsers,
  });

  const filtered = users.filter((u: any) => {
    const q = search.toLowerCase();
    return !q || u.name?.toLowerCase().includes(q) || u.email?.toLowerCase().includes(q);
  });

  const formatDate = (d: string) => {
    if (!d) return '-';
    return new Date(d).toLocaleDateString('en-US', { month: 'short', day: '2-digit', year: 'numeric' });
  };

  return (
    <div className="flex flex-col w-full">
      <div className="flex items-center justify-between mb-5">
        <h1 className="text-lg font-bold text-zinc-800">Users</h1>
        <div className="flex items-center gap-3">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-zinc-400" />
            <input type="text" placeholder="Search users..." value={search} onChange={e => setSearch(e.target.value)}
              className="pl-9 pr-4 py-2 border border-zinc-200 rounded-lg text-sm w-64 outline-none focus:ring-2 focus:ring-zinc-800 focus:border-transparent" />
          </div>
        </div>
      </div>

      <div className="bg-white rounded-lg border border-border overflow-hidden">
        <table className="w-full text-left">
          <thead>
            <tr className="bg-zinc-50/80 border-b border-border text-xs text-zinc-500 font-medium">
              <th className="px-4 py-3">Name</th>
              <th className="px-4 py-3">Email</th>
              <th className="px-4 py-3 w-28">Status</th>
              <th className="px-4 py-3 w-36">Created</th>
            </tr>
          </thead>
          <tbody className="text-sm">
            {isLoading ? (
              <tr><td colSpan={4} className="py-16 text-center text-zinc-400">Loading users...</td></tr>
            ) : filtered.length === 0 ? (
              <tr><td colSpan={4} className="py-16 text-center text-zinc-400">No users found.</td></tr>
            ) : (
              filtered.map((user: any, i: number) => (
                <tr key={user.id} className={cn('border-b border-border-light hover:bg-zinc-50/50 cursor-pointer transition-colors', i % 2 === 1 && 'bg-zinc-50/30')}
                  onClick={() => navigate(`/admin/users/${user.id}`)}>
                  <td className="px-4 py-3 font-medium text-zinc-800">{user.name || '-'}</td>
                  <td className="px-4 py-3 text-zinc-600 font-mono text-xs">{user.email}</td>
                  <td className="px-4 py-3">
                    <Badge variant={user.status === 'active' ? 'success' : 'muted'} dot size="sm">
                      {user.status || 'active'}
                    </Badge>
                  </td>
                  <td className="px-4 py-3 font-mono text-xs text-zinc-500">{formatDate(user.createdAt)}</td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
};

export default UserList;
