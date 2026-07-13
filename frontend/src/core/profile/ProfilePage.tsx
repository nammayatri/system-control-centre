import React, { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { ChevronLeft, KeyRound, Plus, Copy, Check, Trash2, ShieldAlert } from 'lucide-react';
import { toast } from 'sonner';
import { useAuth } from '../auth/AuthContext';
import { listMcpKeys, createMcpKey, revokeMcpKey, type McpPatKey, type CreatedMcpPatKey } from '../auth/api';
import { API_BASE_URL } from '../../lib/constants';
import { Card, CardHeader, CardContent, CardTitle } from '../../shared/ui/card';
import { Button } from '../../shared/ui/button';
import { Input } from '../../shared/ui/input';
import { Badge } from '../../shared/ui/badge';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogBody,
  DialogFooter,
} from '../../shared/ui/dialog';
import { useConfirm } from '../../shared/ui/confirm-dialog';

const MAX_VALIDITY_DAYS = 60;

function addDays(days: number): Date {
  const d = new Date();
  d.setDate(d.getDate() + days);
  return d;
}

function toDateInputValue(d: Date): string {
  return d.toISOString().slice(0, 10);
}

function formatDateTime(iso: string | null): string {
  if (!iso) return '—';
  const d = new Date(iso);
  if (isNaN(d.getTime())) return '—';
  return d.toLocaleString('en-IN', {
    timeZone: 'Asia/Kolkata',
    month: 'short',
    day: '2-digit',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
}

function keyStatus(key: McpPatKey): { label: string; variant: 'success' | 'danger' | 'muted' } {
  if (key.revoked) return { label: 'Revoked', variant: 'muted' };
  if (new Date(key.expiresAt).getTime() < Date.now()) return { label: 'Expired', variant: 'danger' };
  return { label: 'Active', variant: 'success' };
}

const ProfilePage: React.FC = () => {
  const navigate = useNavigate();
  const { user } = useAuth();
  const queryClient = useQueryClient();
  const confirm = useConfirm();

  const [createOpen, setCreateOpen] = useState(false);
  const [label, setLabel] = useState('');
  const [expiresAt, setExpiresAt] = useState(toDateInputValue(addDays(30)));
  const [revealed, setRevealed] = useState<CreatedMcpPatKey | null>(null);
  const [copied, setCopied] = useState<'token' | 'command' | null>(null);

  const { data: keys = [], isLoading } = useQuery({
    queryKey: ['mcp-keys'],
    queryFn: listMcpKeys,
  });

  const createMut = useMutation({
    mutationFn: () => createMcpKey(label.trim(), new Date(expiresAt).toISOString()),
    onSuccess: (created) => {
      queryClient.invalidateQueries({ queryKey: ['mcp-keys'] });
      setCreateOpen(false);
      setLabel('');
      setRevealed(created);
    },
    onError: (err: any) => {
      toast.error(err?.response?.data?.error || err.message || 'Failed to create key');
    },
  });

  const revokeMut = useMutation({
    mutationFn: (id: string) => revokeMcpKey(id),
    onSuccess: () => {
      toast.success('Key revoked');
      queryClient.invalidateQueries({ queryKey: ['mcp-keys'] });
    },
    onError: (err: any) => {
      toast.error(err?.response?.data?.error || err.message || 'Failed to revoke key');
    },
  });

  const handleRevoke = async (key: McpPatKey) => {
    const ok = await confirm({
      title: 'Revoke MCP key?',
      description: `"${key.label}" (${key.prefix}…) will stop working immediately. This can't be undone.`,
      confirmLabel: 'Revoke',
      variant: 'danger',
    });
    if (ok) revokeMut.mutate(key.id);
  };

  const handleCreate = (e: React.FormEvent) => {
    e.preventDefault();
    if (!label.trim()) {
      toast.error('Give this key a label so you can recognize it later');
      return;
    }
    createMut.mutate();
  };
  const mcpCommand = revealed
    ? `claude mcp add scc -- npx -y mcp-remote ${(revealed.baseUrl || API_BASE_URL).replace(/\/$/, '')}/mcp --allow-http --header "Authorization:ApiKey ${revealed.token}"`
    : '';

  const copy = (text: string, which: 'token' | 'command') => {
    navigator.clipboard.writeText(text);
    setCopied(which);
    setTimeout(() => setCopied(null), 1500);
  };

  return (
    <div className="min-h-screen bg-zinc-50">
      <div className="h-14 border-b border-zinc-200 bg-white flex items-center px-3 sm:px-6 gap-2">
        <button
          onClick={() => navigate('/')}
          className="w-9 h-9 rounded-lg flex items-center justify-center text-zinc-500 hover:text-zinc-900 hover:bg-zinc-100 cursor-pointer transition-colors duration-150"
          aria-label="Back to launcher"
        >
          <ChevronLeft className="w-4 h-4" />
        </button>
        <span className="text-sm font-semibold text-zinc-900">Profile</span>
      </div>

      <div className="max-w-3xl mx-auto px-4 py-6 sm:px-6 space-y-5">
        <Card>
          <CardHeader>
            <CardTitle>Account</CardTitle>
          </CardHeader>
          <CardContent className="space-y-1">
            <div className="text-sm font-medium text-zinc-900">{user?.name || '—'}</div>
            <div className="text-sm text-zinc-500">{user?.email}</div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="flex flex-row items-center justify-between gap-3">
            <div className="flex items-center gap-2">
              <KeyRound className="w-4 h-4 text-zinc-400" />
              <CardTitle>MCP Access</CardTitle>
            </div>
            <Button size="sm" onClick={() => setCreateOpen(true)}>
              <Plus className="w-3.5 h-3.5" />
              New key
            </Button>
          </CardHeader>
          <CardContent>
            <p className="text-sm text-zinc-500 mb-4">
              Generate a personal access token to connect Claude to this dashboard over MCP. A key
              carries the exact same permissions your account already has — nothing more.
            </p>

            {isLoading ? (
              <div className="text-sm text-zinc-400 py-6 text-center">Loading…</div>
            ) : keys.length === 0 ? (
              <div className="flex flex-col items-center justify-center py-10 text-center">
                <ShieldAlert className="w-8 h-8 text-zinc-300 mb-2" />
                <p className="text-sm text-zinc-500">No MCP keys yet.</p>
              </div>
            ) : (
              <div className="divide-y divide-zinc-100">
                {keys.map((key) => {
                  const status = keyStatus(key);
                  return (
                    <div key={key.id} className="py-3 flex items-center justify-between gap-3">
                      <div className="min-w-0">
                        <div className="flex items-center gap-2">
                          <span className="text-sm font-medium text-zinc-900 truncate">{key.label}</span>
                          <Badge variant={status.variant} size="sm">
                            {status.label}
                          </Badge>
                        </div>
                        <div className="text-xs text-zinc-500 mt-0.5 font-mono">{key.prefix}…</div>
                        <div className="text-xs text-zinc-400 mt-0.5">
                          Created {formatDateTime(key.createdAt)} · Expires {formatDateTime(key.expiresAt)}
                          {key.lastUsedAt ? ` · Last used ${formatDateTime(key.lastUsedAt)}` : ' · Never used'}
                        </div>
                      </div>
                      {!key.revoked && (
                        <Button
                          variant="ghost"
                          size="icon-sm"
                          onClick={() => handleRevoke(key)}
                          aria-label="Revoke key"
                        >
                          <Trash2 className="w-3.5 h-3.5 text-red-500" />
                        </Button>
                      )}
                    </div>
                  );
                })}
              </div>
            )}
          </CardContent>
        </Card>
      </div>

      {/* Create key dialog */}
      <Dialog open={createOpen} onOpenChange={setCreateOpen}>
        <DialogContent size="sm">
          <form onSubmit={handleCreate}>
            <DialogHeader>
              <DialogTitle>New MCP key</DialogTitle>
              <DialogDescription>
                The token is shown once, immediately after creation — copy it somewhere safe.
              </DialogDescription>
            </DialogHeader>
            <DialogBody className="space-y-4">
              <Input
                label="Label"
                placeholder="e.g. My laptop's Claude"
                value={label}
                onChange={(e) => setLabel(e.target.value)}
                required
                autoFocus
              />
              <Input
                label="Expires"
                type="date"
                value={expiresAt}
                min={toDateInputValue(addDays(1))}
                max={toDateInputValue(addDays(MAX_VALIDITY_DAYS))}
                onChange={(e) => setExpiresAt(e.target.value)}
                hint={`Max validity is ${MAX_VALIDITY_DAYS} days.`}
                required
              />
            </DialogBody>
            <DialogFooter>
              <Button type="button" variant="secondary" onClick={() => setCreateOpen(false)}>
                Cancel
              </Button>
              <Button type="submit" loading={createMut.isPending}>
                Generate key
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>

      {/* One-time token reveal */}
      <Dialog open={!!revealed} onOpenChange={(open) => !open && setRevealed(null)}>
        <DialogContent size="lg">
          <DialogHeader>
            <DialogTitle>Key created</DialogTitle>
            <DialogDescription>
              This is the only time the full token is shown. Store it somewhere safe — if you lose
              it, revoke this key and generate a new one.
            </DialogDescription>
          </DialogHeader>
          <DialogBody className="space-y-4">
            <div>
              <div className="text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">
                Token
              </div>
              <div className="flex items-center gap-2">
                <code className="flex-1 min-w-0 truncate rounded-lg border border-zinc-300 bg-zinc-50 px-3 py-2 text-xs font-mono text-zinc-800">
                  {revealed?.token}
                </code>
                <Button
                  variant="secondary"
                  size="icon-sm"
                  onClick={() => revealed && copy(revealed.token, 'token')}
                  aria-label="Copy token"
                >
                  {copied === 'token' ? <Check className="w-3.5 h-3.5 text-emerald-600" /> : <Copy className="w-3.5 h-3.5" />}
                </Button>
              </div>
            </div>

            <div>
              <div className="text-[11px] font-medium text-zinc-600 uppercase tracking-wider mb-1.5">
                Set up in Claude
              </div>
              <div className="flex items-start gap-2">
                <pre className="flex-1 min-w-0 overflow-x-auto rounded-lg border border-zinc-300 bg-zinc-50 px-3 py-2 text-xs font-mono text-zinc-800 whitespace-pre-wrap break-all">
                  {mcpCommand}
                </pre>
                <Button variant="secondary" size="icon-sm" onClick={() => copy(mcpCommand, 'command')} aria-label="Copy command">
                  {copied === 'command' ? <Check className="w-3.5 h-3.5 text-emerald-600" /> : <Copy className="w-3.5 h-3.5" />}
                </Button>
              </div>
              <p className="text-xs text-zinc-400 mt-1.5">
                Run this on a machine that can reach the VPN. Once connected, the same permissions
                your dashboard account has become available as MCP tools in Claude.
              </p>
            </div>
          </DialogBody>
          <DialogFooter>
            <Button onClick={() => setRevealed(null)}>Done</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default ProfilePage;
