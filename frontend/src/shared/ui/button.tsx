import { forwardRef } from 'react';
import { cn } from '../../lib/utils';

interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: 'primary' | 'secondary' | 'danger' | 'ghost' | 'outline' | 'success';
  size?: 'sm' | 'md' | 'lg' | 'icon' | 'icon-sm';
  loading?: boolean;
  fullWidth?: boolean;
}

const variants: Record<string, string> = {
  primary: 'bg-zinc-900 text-white hover:bg-zinc-800 active:bg-zinc-950 border border-zinc-900',
  secondary: 'bg-white text-zinc-700 border border-zinc-300 hover:bg-zinc-50 active:bg-zinc-100',
  danger: 'bg-red-600 text-white hover:bg-red-700 active:bg-red-800 border border-red-600',
  ghost: 'text-zinc-600 hover:bg-zinc-100 active:bg-zinc-200 border border-transparent',
  outline: 'border border-zinc-300 text-zinc-700 hover:bg-zinc-50 bg-white',
  success: 'bg-emerald-600 text-white hover:bg-emerald-700 active:bg-emerald-800 border border-emerald-600',
};

// Mobile-first sizing: tap targets >= 40px on mobile, can shrink on sm+ for density.
const sizes: Record<string, string> = {
  sm: 'h-9 sm:h-8 px-3 text-[13px] gap-1.5',
  md: 'h-10 sm:h-9 px-4 text-[13px] gap-2',
  lg: 'h-11 sm:h-10 px-5 text-sm gap-2',
  icon: 'h-10 w-10 sm:h-9 sm:w-9 p-0 justify-center',
  'icon-sm': 'h-9 w-9 sm:h-8 sm:w-8 p-0 justify-center',
};

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant = 'primary', size = 'md', loading, disabled, fullWidth, type = 'button', children, ...props }, ref) => (
    <button
      ref={ref}
      // Default to type="button" so a Button placed inside a <form> never
      // accidentally submits it (the native default is "submit"). Submit
      // buttons opt in explicitly with type="submit".
      type={type}
      className={cn(
        'inline-flex items-center justify-center rounded-lg font-medium cursor-pointer whitespace-nowrap',
        'transition-colors duration-150',
        'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-zinc-400 focus-visible:ring-offset-1',
        'disabled:opacity-50 disabled:pointer-events-none',
        fullWidth && 'w-full',
        variants[variant],
        sizes[size],
        className
      )}
      disabled={disabled || loading}
      {...props}
    >
      {loading && (
        <svg className="animate-spin h-3.5 w-3.5 shrink-0" viewBox="0 0 24 24" fill="none">
          <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
          <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
        </svg>
      )}
      {children}
    </button>
  )
);

Button.displayName = 'Button';
