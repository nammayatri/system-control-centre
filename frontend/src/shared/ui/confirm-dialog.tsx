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
import { AlertTriangle } from 'lucide-react';

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

  return (
    <ConfirmContext.Provider value={confirm}>
      {children}
      <Dialog open={open} onOpenChange={(v) => { if (!v) handleCancel(); }}>
        <DialogContent size="sm">
          <DialogHeader>
            <div className="flex items-start gap-3">
              {options.variant === 'danger' && (
                <div className="mt-0.5 w-9 h-9 rounded-full bg-red-50 border border-red-100 flex items-center justify-center shrink-0">
                  <AlertTriangle className="w-4 h-4 text-red-600" />
                </div>
              )}
              <div className="min-w-0 flex-1">
                <DialogTitle>{options.title}</DialogTitle>
                <DialogDescription>{options.description}</DialogDescription>
              </div>
            </div>
          </DialogHeader>
          <DialogFooter>
            <Button variant="secondary" size="md" onClick={handleCancel}>
              {options.cancelLabel || 'Cancel'}
            </Button>
            <Button
              variant={options.variant === 'danger' ? 'danger' : 'primary'}
              size="md"
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
