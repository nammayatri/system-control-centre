import * as React from 'react';
import * as DialogPrimitive from '@radix-ui/react-dialog';
import { X } from 'lucide-react';
import { cn } from '../../lib/utils';

export const Dialog = DialogPrimitive.Root;
export const DialogTrigger = DialogPrimitive.Trigger;
export const DialogClose = DialogPrimitive.Close;

export const DialogOverlay = React.forwardRef<
  React.ComponentRef<typeof DialogPrimitive.Overlay>,
  React.ComponentPropsWithoutRef<typeof DialogPrimitive.Overlay>
>(({ className, ...props }, ref) => (
  <DialogPrimitive.Overlay
    ref={ref}
    className={cn(
      'fixed inset-0 z-40 bg-black/50',
      'data-[state=open]:animate-in data-[state=open]:fade-in-0',
      'data-[state=closed]:animate-out data-[state=closed]:fade-out-0',
      'duration-200',
      className
    )}
    {...props}
  />
));

DialogOverlay.displayName = 'DialogOverlay';

interface DialogContentProps extends React.ComponentPropsWithoutRef<typeof DialogPrimitive.Content> {
  /**
   * On mobile, dialogs default to full-screen sheets that slide up from the bottom.
   * Set fullScreen={false} to keep them centered even on mobile (rare).
   */
  fullScreenOnMobile?: boolean;
  size?: 'sm' | 'md' | 'lg' | 'xl' | '2xl';
}

const sizeMap: Record<string, string> = {
  sm: 'sm:max-w-sm',
  md: 'sm:max-w-md',
  lg: 'sm:max-w-lg',
  xl: 'sm:max-w-2xl',
  '2xl': 'sm:max-w-4xl',
};

export const DialogContent = React.forwardRef<
  React.ComponentRef<typeof DialogPrimitive.Content>,
  DialogContentProps
>(({ className, children, fullScreenOnMobile = true, size = 'lg', ...props }, ref) => (
  <DialogPrimitive.Portal>
    <DialogOverlay />
    <DialogPrimitive.Content
      ref={ref}
      className={cn(
        // Mobile: full-screen sheet anchored to bottom (or full screen)
        fullScreenOnMobile
          ? 'fixed inset-x-0 bottom-0 top-auto z-50 max-h-[92vh] w-full rounded-t-2xl border-x-0 border-b-0 border-t border-zinc-200 bg-white flex flex-col'
          : 'fixed left-1/2 top-1/2 z-50 w-[calc(100vw-2rem)] -translate-x-1/2 -translate-y-1/2 max-h-[92vh] rounded-2xl border border-zinc-200 bg-white flex flex-col',
        // Desktop: centered modal
        'sm:fixed sm:left-1/2 sm:top-1/2 sm:bottom-auto sm:inset-x-auto sm:w-full sm:-translate-x-1/2 sm:-translate-y-1/2 sm:rounded-2xl sm:border sm:border-zinc-200 sm:max-h-[88vh]',
        sizeMap[size],
        'shadow-sm',
        // Animations: slide up on mobile, scale on desktop
        'data-[state=open]:animate-in data-[state=open]:fade-in-0',
        'data-[state=open]:slide-in-from-bottom-4 sm:data-[state=open]:slide-in-from-bottom-0 sm:data-[state=open]:zoom-in-95',
        'data-[state=closed]:animate-out data-[state=closed]:fade-out-0',
        'data-[state=closed]:slide-out-to-bottom-4 sm:data-[state=closed]:slide-out-to-bottom-0 sm:data-[state=closed]:zoom-out-95',
        'duration-200',
        className
      )}
      {...props}
    >
      {children}
      <DialogPrimitive.Close className="absolute right-3 top-3 sm:right-4 sm:top-4 rounded-lg p-1.5 text-zinc-400 hover:text-zinc-700 hover:bg-zinc-100 transition-colors duration-150 cursor-pointer focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-zinc-400">
        <X className="h-4 w-4" />
      </DialogPrimitive.Close>
    </DialogPrimitive.Content>
  </DialogPrimitive.Portal>
));

DialogContent.displayName = 'DialogContent';

export function DialogHeader({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn('px-4 pt-5 pb-3 sm:px-6 sm:pt-6 sm:pb-3 shrink-0', className)} {...props} />;
}

export function DialogBody({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn('px-4 py-3 sm:px-6 sm:py-4 overflow-y-auto flex-1', className)} {...props} />;
}

export function DialogFooter({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      className={cn(
        'px-4 py-3 sm:px-6 sm:py-4 bg-zinc-50 border-t border-zinc-100 sm:rounded-b-2xl shrink-0',
        'flex flex-col-reverse sm:flex-row sm:items-center sm:justify-end gap-2 sm:gap-2.5',
        className
      )}
      {...props}
    />
  );
}

export function DialogTitle({ className, ...props }: React.HTMLAttributes<HTMLHeadingElement>) {
  return (
    <DialogPrimitive.Title
      className={cn('text-base sm:text-lg font-semibold text-zinc-900 tracking-tight pr-8', className)}
      {...props}
    />
  );
}

export function DialogDescription({ className, ...props }: React.HTMLAttributes<HTMLParagraphElement>) {
  return (
    <DialogPrimitive.Description
      className={cn('text-sm text-zinc-500 mt-1 leading-relaxed', className)}
      {...props}
    />
  );
}
