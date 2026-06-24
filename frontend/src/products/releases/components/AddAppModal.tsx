import { useState } from 'react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Plus } from 'lucide-react';
import {
    Dialog,
    DialogContent,
    DialogHeader,
    DialogTitle,
    DialogBody,
    DialogFooter,
} from '../../../shared/ui/dialog';
import { Button } from '../../../shared/ui/button';
import { Input, SelectInput } from '../../../shared/ui/input';
import { mobileApi } from '../api';
import type { AppCatalogEntry } from '../types';

// Defaults that match how apps are seeded (provider/customer both live in the
// ny-react-native monorepo); the operator overrides per app.
const DEFAULT_REPO = 'nammayatri/ny-react-native';

type FormState = {
    name: string;
    displayLabel: string;
    surface: 'customer' | 'driver';
    platform: 'android' | 'ios';
    githubRepo: string;
    workflowPath: string;
    packageName: string;
    firebaseProjectId: string;
    enabled: boolean;
    managedPublishing: boolean;
};

const EMPTY: FormState = {
    name: '',
    displayLabel: '',
    surface: 'customer',
    platform: 'android',
    githubRepo: DEFAULT_REPO,
    workflowPath: '',
    packageName: '',
    firebaseProjectId: '',
    enabled: true,
    managedPublishing: true,
};

function CheckRow({
    label,
    hint,
    checked,
    onChange,
}: {
    label: string;
    hint?: string;
    checked: boolean;
    onChange: (v: boolean) => void;
}) {
    return (
        <label className="flex cursor-pointer items-start gap-2.5">
            <input
                type="checkbox"
                checked={checked}
                onChange={(e) => onChange(e.target.checked)}
                className="mt-0.5 h-4 w-4 rounded border-zinc-300 accent-zinc-900"
            />
            <span className="text-sm text-zinc-800">
                {label}
                {hint && <span className="mt-0.5 block text-xs font-normal text-zinc-500">{hint}</span>}
            </span>
        </label>
    );
}

/**
 * "Add app" button + modal for registering a new app_catalog entry. Required
 * columns (name, surface, platform, repo, workflow) are enforced before submit;
 * the rest are optional. Managed Publishing defaults on — turn it off for
 * provider/driver apps that publish without the manual-Publish hold.
 */
export function AddAppButton() {
    const qc = useQueryClient();
    const [open, setOpen] = useState(false);
    const [form, setForm] = useState<FormState>(EMPTY);

    const set = <K extends keyof FormState>(k: K, v: FormState[K]) =>
        setForm((f) => ({ ...f, [k]: v }));

    const reset = () => setForm(EMPTY);

    const createMutation = useMutation({
        mutationFn: (body: Partial<AppCatalogEntry>) => mobileApi.createApp(body),
        onSuccess: (app) => {
            qc.invalidateQueries({ queryKey: ['mobile', 'apps'] });
            toast.success(`Added ${app.displayLabel || app.name}`);
            setOpen(false);
            reset();
        },
        onError: (err: any) => {
            toast.error(err?.response?.data?.message || err?.message || 'Failed to add app');
        },
    });

    const trimmed = {
        name: form.name.trim(),
        githubRepo: form.githubRepo.trim(),
        workflowPath: form.workflowPath.trim(),
    };
    const valid = trimmed.name && trimmed.githubRepo && trimmed.workflowPath;

    const submit = () => {
        if (!valid) {
            toast.error('Name, GitHub repo and workflow path are required.');
            return;
        }
        // Send only meaningful values; omit blank optionals so the backend keeps its defaults.
        const body: Partial<AppCatalogEntry> = {
            name: trimmed.name,
            surface: form.surface,
            platform: form.platform,
            githubRepo: trimmed.githubRepo,
            workflowPath: trimmed.workflowPath,
            packageName: form.packageName.trim() || null,
            displayLabel: form.displayLabel.trim() || null,
            firebaseProjectId: form.firebaseProjectId.trim() || null,
            enabled: form.enabled,
            managedPublishing: form.managedPublishing,
        };
        createMutation.mutate(body);
    };

    return (
        <>
            <Button size="sm" onClick={() => setOpen(true)}>
                <Plus size={14} /> Add app
            </Button>

            <Dialog
                open={open}
                onOpenChange={(o) => {
                    if (!o) {
                        setOpen(false);
                        reset();
                    }
                }}
            >
                <DialogContent size="lg">
                    <DialogHeader>
                        <DialogTitle>Add mobile app</DialogTitle>
                    </DialogHeader>

                    <DialogBody className="space-y-4">
                        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
                            <Input
                                label="Name"
                                required
                                placeholder="NammaYatriPartner"
                                hint="Catalyst key sent to the workflow as selected_apps"
                                value={form.name}
                                onChange={(e) => set('name', e.target.value)}
                            />
                            <Input
                                label="Display label"
                                placeholder="Namma Yatri (Driver Android)"
                                value={form.displayLabel}
                                onChange={(e) => set('displayLabel', e.target.value)}
                            />
                            <SelectInput
                                label="Surface"
                                required
                                value={form.surface}
                                onChange={(e) => set('surface', e.target.value as FormState['surface'])}
                                options={[
                                    { value: 'customer', label: 'Customer' },
                                    { value: 'driver', label: 'Driver (provider)' },
                                ]}
                            />
                            <SelectInput
                                label="Platform"
                                required
                                value={form.platform}
                                onChange={(e) => set('platform', e.target.value as FormState['platform'])}
                                options={[
                                    { value: 'android', label: 'Android' },
                                    { value: 'ios', label: 'iOS' },
                                ]}
                            />
                            <Input
                                label="GitHub repo"
                                required
                                placeholder={DEFAULT_REPO}
                                value={form.githubRepo}
                                onChange={(e) => set('githubRepo', e.target.value)}
                            />
                            <Input
                                label="Workflow path"
                                required
                                placeholder=".github/workflows/provider-debug-apk-gen.yaml"
                                value={form.workflowPath}
                                onChange={(e) => set('workflowPath', e.target.value)}
                            />
                            <Input
                                label="Package / bundle id"
                                placeholder="in.juspay.nammayatripartner"
                                value={form.packageName}
                                onChange={(e) => set('packageName', e.target.value)}
                            />
                            <Input
                                label="Firebase project id"
                                placeholder="(optional)"
                                value={form.firebaseProjectId}
                                onChange={(e) => set('firebaseProjectId', e.target.value)}
                            />
                        </div>

                        <div className="space-y-3 border-t border-zinc-100 pt-3">
                            <CheckRow
                                label="Enabled"
                                hint="Shows up on the Create Mobile Release page"
                                checked={form.enabled}
                                onChange={(v) => set('enabled', v)}
                            />
                            <CheckRow
                                label="Play Managed Publishing"
                                hint="Turn off for provider/driver apps that publish without the manual-Publish hold (no API to detect this — set it here)."
                                checked={form.managedPublishing}
                                onChange={(v) => set('managedPublishing', v)}
                            />
                        </div>
                    </DialogBody>

                    <DialogFooter>
                        <Button
                            variant="ghost"
                            onClick={() => {
                                setOpen(false);
                                reset();
                            }}
                        >
                            Cancel
                        </Button>
                        <Button onClick={submit} loading={createMutation.isPending} disabled={!valid}>
                            Add app
                        </Button>
                    </DialogFooter>
                </DialogContent>
            </Dialog>
        </>
    );
}
