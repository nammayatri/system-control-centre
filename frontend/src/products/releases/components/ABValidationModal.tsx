import React, { useState } from 'react';
import {
    fetchValidABStatuses,
    updateABValidation,
    AB_STATUS_LABELS,
    type ABValidationStatus,
    type ABValidation,
} from '../api';
import { Button } from '../../../shared/ui/button';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { cn } from '../../../lib/utils';
import { CheckCircle2, XCircle, Clock } from 'lucide-react';

interface Props {
    releaseId: string;
    currentStatus?: ABValidationStatus | null;
    abValidation?: ABValidation | null;
    onClose: () => void;
}

const NEEDS_RCA: ABValidationStatus[] = ['MISSED_ABORT', 'FALSE_ABORT', 'TRUE_ABORT'];

export const ABValidationModal: React.FC<Props> = ({
    releaseId,
    currentStatus,
    abValidation,
    onClose,
}) => {
    const qc = useQueryClient();
    const [selectedStatus, setSelectedStatus] = useState<ABValidationStatus | ''>('');
    const [isApproved, setIsApproved] = useState(abValidation?.abvIsApproved ?? false);
    const [rcaDesc, setRcaDesc] = useState(abValidation?.abvRcaDesc ?? '');
    const [showHistory, setShowHistory] = useState(false);

    const { data, isLoading } = useQuery({
        queryKey: ['ab-statuses', releaseId],
        queryFn: () => fetchValidABStatuses(releaseId),
    });

    const mutation = useMutation({
        mutationFn: () =>
            updateABValidation(releaseId, {
                status: selectedStatus as ABValidationStatus,
                is_approved: isApproved,
                rca_description: rcaDesc || undefined,
            }),
        onSuccess: (res) => {
            if (res.status === 'SUCCESS') {
                toast.success('AB validation updated');
                qc.invalidateQueries({ queryKey: ['release', releaseId] });
                qc.invalidateQueries({ queryKey: ['ab-statuses', releaseId] });
                onClose();
            } else {
                toast.error(res.message || 'Update failed');
            }
        },
        onError: () => toast.error('Failed to update AB validation'),
    });

    const validStatuses = data?.statusList ?? [];
    const cur = (data?.currentStatus ?? currentStatus ?? 'UNASSIGNED') as ABValidationStatus;
    const rcaRequired = selectedStatus !== '' && NEEDS_RCA.includes(selectedStatus as ABValidationStatus);
    const canSubmit = selectedStatus !== '' && (!rcaRequired || rcaDesc.trim().length > 0);

    const history = abValidation?.abvHistory ?? [];

    return (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40">
            <div className="bg-white rounded-xl shadow-xl w-full max-w-lg mx-4 flex flex-col max-h-[90vh]">
                <div className="flex items-center justify-between px-5 py-4 border-b border-zinc-200">
                    <h2 className="text-base font-semibold text-zinc-900">AB Validation</h2>
                    <button onClick={onClose} className="text-zinc-400 hover:text-zinc-600">
                        <XCircle className="w-5 h-5" />
                    </button>
                </div>

                <div className="overflow-y-auto p-5 flex flex-col gap-4">
                    {/* Current status */}
                    <div className="flex items-center gap-2 text-sm text-zinc-600">
                        <span className="font-medium">Current status:</span>
                        <span className={cn('px-2 py-0.5 rounded text-xs font-medium', statusBadgeClass(cur))}>
                            {AB_STATUS_LABELS[cur] ?? cur}
                        </span>
                    </div>

                    {/* Status selector */}
                    {isLoading ? (
                        <div className="text-sm text-zinc-400">Loading valid transitions…</div>
                    ) : validStatuses.length === 0 ? (
                        <div className="text-sm text-zinc-500 italic">
                            No further transitions available for this release.
                        </div>
                    ) : (
                        <>
                            <div>
                                <label className="block text-xs font-medium text-zinc-500 uppercase tracking-wider mb-2">
                                    Set Status
                                </label>
                                <div className="flex flex-wrap gap-2">
                                    {validStatuses.map((s) => (
                                        <button
                                            key={s}
                                            onClick={() => setSelectedStatus(s)}
                                            className={cn(
                                                'px-3 py-1.5 rounded-lg text-sm font-medium border transition-colors',
                                                selectedStatus === s
                                                    ? 'border-zinc-900 bg-zinc-900 text-white'
                                                    : 'border-zinc-200 bg-white text-zinc-700 hover:border-zinc-400'
                                            )}
                                        >
                                            {AB_STATUS_LABELS[s] ?? s}
                                        </button>
                                    ))}
                                </div>
                            </div>

                            <label className="flex items-center gap-2 text-sm text-zinc-700 cursor-pointer select-none">
                                <input
                                    type="checkbox"
                                    checked={isApproved}
                                    onChange={(e) => setIsApproved(e.target.checked)}
                                    className="rounded border-zinc-300"
                                />
                                Mark as Approved
                            </label>

                            <div>
                                <label className="block text-xs font-medium text-zinc-500 uppercase tracking-wider mb-1">
                                    RCA Description{rcaRequired ? ' *' : ''}
                                </label>
                                <textarea
                                    rows={3}
                                    value={rcaDesc}
                                    onChange={(e) => setRcaDesc(e.target.value)}
                                    placeholder={rcaRequired ? 'Required for this status' : 'Optional'}
                                    className="w-full border border-zinc-200 rounded-lg px-3 py-2 text-sm resize-none focus:outline-none focus:ring-1 focus:ring-zinc-400"
                                />
                            </div>

                            <Button
                                onClick={() => mutation.mutate()}
                                disabled={!canSubmit || mutation.isPending}
                                loading={mutation.isPending}
                                className="self-end"
                            >
                                Save
                            </Button>
                        </>
                    )}

                    {/* History toggle */}
                    {history.length > 0 && (
                        <div className="border-t border-zinc-100 pt-3">
                            <button
                                onClick={() => setShowHistory((v) => !v)}
                                className="text-xs text-zinc-500 hover:text-zinc-700 flex items-center gap-1"
                            >
                                <Clock className="w-3 h-3" />
                                {showHistory ? 'Hide' : 'Show'} history ({history.length})
                            </button>

                            {showHistory && (
                                <div className="mt-3 flex flex-col gap-2">
                                    {[...history].reverse().map((entry, i) => (
                                        <div key={i} className="border border-zinc-100 rounded-lg px-3 py-2 text-xs text-zinc-600">
                                            <div className="flex items-center gap-2 mb-1">
                                                <span className={cn('px-1.5 py-0.5 rounded font-medium', statusBadgeClass(entry.abveStatus))}>
                                                    {AB_STATUS_LABELS[entry.abveStatus] ?? entry.abveStatus}
                                                </span>
                                                {entry.abveIsApproved && (
                                                    <span className="flex items-center gap-0.5 text-green-600">
                                                        <CheckCircle2 className="w-3 h-3" /> Approved
                                                    </span>
                                                )}
                                                <span className="text-zinc-400 ml-auto">{entry.abveUpdatedAt}</span>
                                            </div>
                                            <div className="text-zinc-500">By {entry.abveChangedBy}</div>
                                            {entry.abveRcaDesc && (
                                                <div className="mt-1 text-zinc-700 italic">"{entry.abveRcaDesc}"</div>
                                            )}
                                        </div>
                                    ))}
                                </div>
                            )}
                        </div>
                    )}
                </div>
            </div>
        </div>
    );
};

function statusBadgeClass(s: ABValidationStatus): string {
    switch (s) {
        case 'VERIFIED': return 'bg-green-100 text-green-700';
        case 'MISSED_ABORT': return 'bg-orange-100 text-orange-700';
        case 'FALSE_ABORT': return 'bg-yellow-100 text-yellow-700';
        case 'TRUE_ABORT': return 'bg-red-100 text-red-700';
        case 'INVALID': return 'bg-gray-200 text-gray-600';
        default: return 'bg-zinc-100 text-zinc-500';
    }
}
