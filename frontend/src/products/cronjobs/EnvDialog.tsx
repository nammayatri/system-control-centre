import { useEffect, useState } from 'react';
import { Button } from '../../shared/ui/button';
import { Dialog, DialogBody, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '../../shared/ui/dialog';
import { Input, SelectInput } from '../../shared/ui/input';
import { looksSensitive } from './format';
import type { EnvEntry } from './types';

type Source = 'value' | 'secret' | 'configmap';

function sourceOf(e?: EnvEntry): Source {
  if (e?.valueFrom?.secretKeyRef) return 'secret';
  if (e?.valueFrom?.configMapKeyRef) return 'configmap';
  return 'value';
}

interface Props {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  container: string;
  /** Present when editing; absent when adding. */
  entry?: EnvEntry;
  saving: boolean;
  onSave: (entry: Pick<EnvEntry, 'name' | 'value' | 'valueFrom'>) => void;
}

export function EnvDialog({ open, onOpenChange, container, entry, saving, onSave }: Props) {
  const [name, setName] = useState('');
  const [source, setSource] = useState<Source>('value');
  const [value, setValue] = useState('');
  const [refName, setRefName] = useState('');
  const [refKey, setRefKey] = useState('');

  useEffect(() => {
    if (!open) return;
    setName(entry?.name ?? '');
    setSource(sourceOf(entry));
    setValue(entry?.value ?? '');
    const ref = entry?.valueFrom?.secretKeyRef ?? entry?.valueFrom?.configMapKeyRef;
    setRefName(ref?.name ?? '');
    setRefKey(ref?.key ?? '');
  }, [open, entry]);

  const editing = !!entry;
  const readonlySource = !!entry?.valueFrom && !entry.valueFrom.secretKeyRef && !entry.valueFrom.configMapKeyRef;
  const nameOk = /^[A-Za-z_.-][A-Za-z0-9_.-]*$/.test(name);
  const ok = nameOk && (source === 'value' ? true : refName.trim() !== '' && refKey.trim() !== '');

  const submit = () => {
    if (source === 'value') onSave({ name, value });
    else onSave({ name, valueFrom: { [source === 'secret' ? 'secretKeyRef' : 'configMapKeyRef']: { name: refName.trim(), key: refKey.trim() } } });
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent size="lg">
        <DialogHeader>
          <DialogTitle>{editing ? `Edit ${entry.name}` : 'Add environment variable'}</DialogTitle>
          <DialogDescription>Container {container}. The Secret or ConfigMap and its key are checked against the cluster before saving.</DialogDescription>
        </DialogHeader>
        <DialogBody className="space-y-4">
          {readonlySource ? (
            <p className="text-sm text-zinc-600">This variable is filled from the pod's own metadata or resources and can't be edited here. Remove it, then add it again as a plain value or a reference.</p>
          ) : (
            <>
              <Input label="Name" value={name} disabled={editing} onChange={(e) => setName(e.target.value)} error={name && !nameOk ? 'Letters, digits, _ . - ; not starting with a digit' : undefined} />
              <SelectInput label="Value comes from" value={source} onChange={(e) => setSource(e.target.value as Source)}
                options={[{ value: 'value', label: 'A plain value' }, { value: 'secret', label: 'A Secret key' }, { value: 'configmap', label: 'A ConfigMap key' }]} />
              {source === 'value' ? (
                <>
                  <Input label="Value" value={value} onChange={(e) => setValue(e.target.value)} placeholder={entry?.masked ? 'Hidden — type a new value to replace it' : undefined} />
                  {looksSensitive(name) && (
                    <p className="rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800">
                      {name} looks like a credential. Inline credentials are rejected — store it in a Secret and reference it instead.
                    </p>
                  )}
                </>
              ) : (
                <div className="grid gap-4 sm:grid-cols-2">
                  <Input label={source === 'secret' ? 'Secret name' : 'ConfigMap name'} value={refName} onChange={(e) => setRefName(e.target.value)} />
                  <Input label="Key" value={refKey} onChange={(e) => setRefKey(e.target.value)} />
                </div>
              )}
            </>
          )}
        </DialogBody>
        <DialogFooter>
          <Button variant="secondary" onClick={() => onOpenChange(false)}>Cancel</Button>
          {!readonlySource && <Button loading={saving} disabled={!ok} onClick={submit}>{editing ? 'Save' : 'Add'}</Button>}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
