import React, { useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useNavigate } from 'react-router-dom';
import { fetchUsers, createUser } from '../api';
import { Badge } from '../../../shared/ui/badge';
import { Button } from '../../../shared/ui/button';
import { Input } from '../../../shared/ui/input';
import { TableSkeleton } from '../../../shared/ui/skeleton';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogBody,
  DialogFooter,
} from '../../../shared/ui/dialog';
import { Search, Plus, Eye, EyeOff } from 'lucide-react';
import { cn } from '../../../lib/utils';
import { toast } from 'sonner';

const UserList: React.FC = () => {
  const [search, setSearch] = useState('');
  const [addOpen, setAddOpen] = useState(false);
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  const { data: users = [], isLoading } = useQuery({
    queryKey: ['admin-users'],
    queryFn: fetchUsers,
  });

  // Add user form state
  const [showPassword, setShowPassword] = useState(false);

  const [form, setForm] = useState({
    firstName: '',
    lastName: '',
    email: '',
    password: '',
    isSuperadmin: false,
  });

  const createMut = useMutation({
    mutationFn: () => createUser(form),
    onSuccess: () => {
      toast.success('User created successfully');
      queryClient.invalidateQueries({ queryKey: ['admin-users'] });
      setAddOpen(false);
      setShowPassword(false);
      setForm({ firstName: '', lastName: '', email: '', password: '', isSuperadmin: false });
    },
    onError: (err: any) => {
      toast.error(err?.response?.data?.error || err.message || 'Failed to create user');
    },
  });

  const filtered = users.filter((u: any) => {
    const q = search.toLowerCase();
    const name = (u.name || `${u.firstName || ''} ${u.lastName || ''}`).toLowerCase();
    return !q || name.includes(q) || u.email?.toLowerCase().includes(q);
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

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.firstName || !form.lastName || !form.email || !form.password) {
      toast.error('All fields are required');
      return;
    }
    createMut.mutate();
  };

  return (
    <div className="flex flex-col w-full pb-12">
      {/* Page header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 mb-4 sm:mb-5">
        <h1 className="text-lg sm:text-xl font-semibold text-zinc-900">Users</h1>
        <div className="flex items-center gap-2 sm:gap-3">
          <div className="relative flex-1 sm:flex-none">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-zinc-400" />
            <input
              type="text"
              placeholder="Search by name or email"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              className="pl-9 pr-4 h-10 sm:h-9 w-full sm:w-64 border border-zinc-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150"
            />
          </div>
          <Button size="md" onClick={() => setAddOpen(true)}>
            <Plus className="w-4 h-4" />
            <span className="hidden sm:inline">Add User</span>
            <span className="sm:hidden">Add</span>
          </Button>
        </div>
      </div>

      {/* Users table */}
      <div className="bg-white rounded-xl border border-zinc-200 overflow-hidden">
        <div className="hidden md:block overflow-x-auto">
          {isLoading ? (
            <TableSkeleton rows={6} cols={6} />
          ) : (
            <table className="w-full text-left">
              <thead>
                <tr className="bg-zinc-50 border-b border-zinc-200 text-[12px] text-zinc-500 font-medium uppercase tracking-wider">
                  <th className="px-4 py-3">Name</th>
                  <th className="px-4 py-3">Email</th>
                  <th className="px-4 py-3 w-28">Status</th>
                  <th className="px-4 py-3 w-28">Superadmin</th>
                  <th className="px-4 py-3 w-36">Created</th>
                  <th className="px-4 py-3 w-20">Actions</th>
                </tr>
              </thead>
              <tbody className="text-sm">
                {filtered.length === 0 ? (
                  <tr>
                    <td colSpan={6} className="py-16 text-center text-zinc-400">
                      No users found.
                    </td>
                  </tr>
                ) : (
                  filtered.map((user: any, i: number) => (
                    <tr
                      key={user.id}
                      className={cn(
                        'border-b border-zinc-100 hover:bg-zinc-100 cursor-pointer transition-colors duration-150',
                        i % 2 === 1 ? 'bg-zinc-50' : 'bg-white'
                      )}
                      onClick={() => navigate(`/admin/users/${user.id}`)}
                    >
                      <td className="px-4 py-3 font-medium text-zinc-800">
                        {user.name || `${user.firstName || ''} ${user.lastName || ''}`.trim() || '-'}
                      </td>
                      <td className="px-4 py-3 text-zinc-600 font-mono text-xs">
                        {user.email}
                      </td>
                      <td className="px-4 py-3">
                        <Badge variant={user.status === 'active' || user.isActive !== false ? 'success' : 'muted'} dot size="sm">
                          {user.status || (user.isActive !== false ? 'active' : 'inactive')}
                        </Badge>
                      </td>
                      <td className="px-4 py-3 text-sm text-zinc-600">
                        {user.isSuperadmin ? 'Yes' : 'No'}
                      </td>
                      <td className="px-4 py-3 text-zinc-500 font-mono text-xs">
                        {formatDate(user.createdAt)}
                      </td>
                      <td className="px-4 py-3">
                        <Button
                          variant="ghost"
                          size="sm"
                          onClick={(e) => {
                            e.stopPropagation();
                            navigate(`/admin/users/${user.id}`);
                          }}
                        >
                          View
                        </Button>
                      </td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
          )}
        </div>

        {/* Mobile cards */}
        <div className="md:hidden">
          {isLoading ? (
            <TableSkeleton rows={4} cols={3} />
          ) : filtered.length === 0 ? (
            <div className="py-16 text-center text-zinc-400 text-sm">No users found.</div>
          ) : (
            <div className="divide-y divide-zinc-100">
              {filtered.map((user: any) => (
                <div
                  key={user.id}
                  onClick={() => navigate(`/admin/users/${user.id}`)}
                  className="p-4 cursor-pointer hover:bg-zinc-50 active:bg-zinc-100 transition-colors"
                >
                  <div className="flex items-start justify-between gap-2 mb-1">
                    <div className="text-sm font-medium text-zinc-900 truncate min-w-0 flex-1">
                      {user.name || `${user.firstName || ''} ${user.lastName || ''}`.trim() || '-'}
                    </div>
                    <Badge variant={user.status === 'active' || user.isActive !== false ? 'success' : 'muted'} dot size="sm">
                      {user.status || (user.isActive !== false ? 'active' : 'inactive')}
                    </Badge>
                  </div>
                  <div className="text-xs text-zinc-500 font-mono truncate">{user.email}</div>
                  <div className="flex items-center gap-2 text-[11px] text-zinc-500 mt-1.5">
                    {user.isSuperadmin && <Badge variant="purple" size="sm">Superadmin</Badge>}
                    <span className="font-mono">{formatDate(user.createdAt)}</span>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      {/* Add User Dialog */}
      <Dialog open={addOpen} onOpenChange={setAddOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Add User</DialogTitle>
            <DialogDescription>Create a new user account.</DialogDescription>
          </DialogHeader>
          <form onSubmit={handleSubmit}>
            <DialogBody className="space-y-4">
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <Input
                  label="First Name"
                  required
                  value={form.firstName}
                  onChange={(e) => setForm((f) => ({ ...f, firstName: e.target.value }))}
                  placeholder="John"
                />
                <Input
                  label="Last Name"
                  required
                  value={form.lastName}
                  onChange={(e) => setForm((f) => ({ ...f, lastName: e.target.value }))}
                  placeholder="Doe"
                />
              </div>
              <Input
                label="Email"
                type="email"
                required
                value={form.email}
                onChange={(e) => setForm((f) => ({ ...f, email: e.target.value }))}
                placeholder="john@example.com"
              />
              <div className="space-y-1.5">
                <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider">
                  Password <span className="text-red-500">*</span>
                </label>
                <div className="relative">
                  <input
                    type={showPassword ? 'text' : 'password'}
                    required
                    value={form.password}
                    onChange={(e) => setForm((f) => ({ ...f, password: e.target.value }))}
                    placeholder="Min 6 characters"
                    className="w-full h-10 border border-zinc-300 rounded-lg px-3 pr-10 text-sm text-zinc-900 placeholder:text-zinc-400 focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent transition-shadow duration-150"
                  />
                  <button
                    type="button"
                    onClick={() => setShowPassword((v) => !v)}
                    className="absolute right-1.5 top-1/2 -translate-y-1/2 w-8 h-8 flex items-center justify-center text-zinc-400 hover:text-zinc-600 transition-colors duration-150 rounded cursor-pointer"
                    tabIndex={-1}
                    aria-label={showPassword ? 'Hide password' : 'Show password'}
                  >
                    {showPassword ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
                  </button>
                </div>
              </div>
              <label className="flex items-center gap-2 cursor-pointer">
                <input
                  type="checkbox"
                  checked={form.isSuperadmin}
                  onChange={(e) => setForm((f) => ({ ...f, isSuperadmin: e.target.checked }))}
                  className="rounded border-zinc-300 accent-zinc-900 cursor-pointer"
                />
                <span className="text-sm text-zinc-700">Superadmin</span>
              </label>
            </DialogBody>
            <DialogFooter>
              <Button variant="secondary" type="button" onClick={() => setAddOpen(false)}>
                Cancel
              </Button>
              <Button type="submit" loading={createMut.isPending}>
                Create User
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default UserList;
