import { useEffect, useState } from 'react';
import { Button } from '../../shared/ui/button';
import { Dialog, DialogBody, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '../../shared/ui/dialog';
import { Input } from '../../shared/ui/input';
import { splitImage } from './format';

interface Props {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  container: string;
  image: string;
  saving: boolean;
  onSave: (image: string) => void;
}

/** Change the version (tag) of a container's image, as a release does. The repository can be edited too but is flagged when it differs. */
export function ImageDialog({ open, onOpenChange, container, image, saving, onSave }: Props) {
  const [repo, setRepo] = useState('');
  const [tag, setTag] = useState('');

  useEffect(() => {
    if (!open) return;
    const s = splitImage(image);
    setRepo(s.repo);
    setTag(s.tag);
  }, [open, image]);

  const pinned = image.includes('@'); // digest reference: no tag to swap
  const next = pinned ? repo.trim() : tag.trim() ? `${repo.trim()}:${tag.trim()}` : repo.trim();
  const valid = next !== '' && !/\s/.test(next) && !next.startsWith('-');
  const repoChanged = repo.trim() !== splitImage(image).repo;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent size="lg">
        <DialogHeader>
          <DialogTitle>Change version · {container}</DialogTitle>
          <DialogDescription>Applies from the next scheduled run. A job that is already running keeps the image it started with.</DialogDescription>
        </DialogHeader>
        <DialogBody className="space-y-4">
          <div>
            <div className="text-[11px] font-medium uppercase tracking-wider text-zinc-600">Current</div>
            <div className="mt-1 break-all font-mono text-xs text-zinc-600">{image}</div>
          </div>
          <Input label="Version (tag)" value={tag} disabled={pinned} onChange={(e) => setTag(e.target.value)} className="font-mono"
            hint={pinned ? 'This image is pinned by digest; edit the full reference below.' : undefined} autoFocus />
          <Input label={pinned ? 'Image' : 'Repository'} value={repo} onChange={(e) => setRepo(e.target.value)} className="font-mono" />
          {repoChanged && !pinned && (
            <p className="rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800">You are changing the repository, not just the version.</p>
          )}
          <div>
            <div className="text-[11px] font-medium uppercase tracking-wider text-zinc-600">New image</div>
            <div className="mt-1 break-all font-mono text-xs text-zinc-900">{next || '—'}</div>
          </div>
        </DialogBody>
        <DialogFooter>
          <Button variant="secondary" onClick={() => onOpenChange(false)}>Cancel</Button>
          <Button loading={saving} disabled={!valid || next === image} onClick={() => onSave(next)}>Update image</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
