import React, { useState, useCallback, useRef } from 'react';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogFooter,
} from './dialog';
import { Button } from './button';
import { WarningIcon, QuestionIcon } from '@phosphor-icons/react';
import { cn } from '../../lib/utils';

interface ConfirmOptions {
  title: string;
  description: string;
  confirmLabel?: string;
  cancelLabel?: string;
  variant?: 'danger' | 'primary';
}

type ConfirmFn = (options: ConfirmOptions) => Promise<boolean>;

const ConfirmContext = React.createContext<ConfirmFn>(async () => false);

export function useConfirm() {
  return React.useContext(ConfirmContext);
}

/**
 * App-wide confirm dialog, v4 design family (docs/design/
 * mobile-release-summary-mockup-v4.html): scenario-colored top accent bar,
 * eyebrow, icon tile, bold tracking-tight title.
 */
export function ConfirmProvider({ children }: { children: React.ReactNode }) {
  const [open, setOpen] = useState(false);
  const [options, setOptions] = useState<ConfirmOptions>({
    title: '',
    description: '',
  });
  const resolveRef = useRef<(value: boolean) => void>(undefined);

  const confirm = useCallback((opts: ConfirmOptions): Promise<boolean> => {
    setOptions(opts);
    setOpen(true);
    return new Promise<boolean>((resolve) => {
      resolveRef.current = resolve;
    });
  }, []);

  const handleConfirm = () => {
    setOpen(false);
    resolveRef.current?.(true);
  };

  const handleCancel = () => {
    setOpen(false);
    resolveRef.current?.(false);
  };

  const danger = options.variant === 'danger';

  return (
    <ConfirmContext.Provider value={confirm}>
      {children}
      <Dialog open={open} onOpenChange={(v) => { if (!v) handleCancel(); }}>
        <DialogContent size="sm" className="overflow-hidden">
          <div className={cn('h-1 w-full shrink-0', danger ? 'bg-red-500' : 'bg-violet-500')} aria-hidden="true" />
          <DialogHeader>
            <div className="flex items-start gap-3.5">
              <div
                className={cn(
                  'mt-0.5 w-9 h-9 rounded-lg border flex items-center justify-center shrink-0',
                  danger ? 'bg-red-50 border-red-100' : 'bg-violet-50 border-violet-100',
                )}
              >
                {danger ? (
                  <WarningIcon size={17} weight="fill" className="text-red-600" aria-hidden="true" />
                ) : (
                  <QuestionIcon size={17} weight="bold" className="text-violet-600" aria-hidden="true" />
                )}
              </div>
              <div className="min-w-0 flex-1">
                <span
                  className={cn(
                    'block text-[9px] font-bold uppercase tracking-widest mb-0.5',
                    danger ? 'text-red-500' : 'text-violet-500',
                  )}
                >
                  {danger ? 'Destructive action' : 'Confirm'}
                </span>
                <DialogTitle className="font-bold">{options.title}</DialogTitle>
                <DialogDescription className="text-zinc-600">{options.description}</DialogDescription>
              </div>
            </div>
          </DialogHeader>
          <DialogFooter>
            <Button variant="secondary" size="md" onClick={handleCancel}>
              {options.cancelLabel || 'Cancel'}
            </Button>
            <Button
              variant={danger ? 'danger' : 'primary'}
              size="md"
              className="font-bold"
              onClick={handleConfirm}
            >
              {options.confirmLabel || 'Confirm'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </ConfirmContext.Provider>
  );
}
