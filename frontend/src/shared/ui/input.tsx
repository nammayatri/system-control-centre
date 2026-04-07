import { forwardRef } from 'react';
import { cn } from '../../lib/utils';

interface InputProps extends React.InputHTMLAttributes<HTMLInputElement> {
  label?: string;
  error?: string;
  hint?: string;
  icon?: React.ReactNode;
}

// Mobile-first inputs: 40px tap target on mobile, can shrink on sm+ for density.
const fieldBase =
  'w-full h-10 sm:h-9 rounded-lg border border-zinc-300 bg-white px-3 text-sm text-zinc-900 ' +
  'placeholder:text-zinc-400 ' +
  'focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent ' +
  'disabled:bg-zinc-50 disabled:text-zinc-500 disabled:cursor-not-allowed ' +
  'transition-shadow duration-150';

const labelBase =
  'block text-[11px] font-medium text-zinc-600 uppercase tracking-wider';

export const Input = forwardRef<HTMLInputElement, InputProps>(
  ({ className, label, error, hint, icon, id, ...props }, ref) => {
    const inputId = id || label?.toLowerCase().replace(/\s+/g, '-');
    return (
      <div className="space-y-1.5">
        {label && (
          <label htmlFor={inputId} className={labelBase}>
            {label}
            {props.required && <span className="text-red-500 ml-0.5">*</span>}
          </label>
        )}
        <div className="relative">
          {icon && (
            <div className="absolute left-3 top-1/2 -translate-y-1/2 text-zinc-400 pointer-events-none">{icon}</div>
          )}
          <input
            ref={ref}
            id={inputId}
            className={cn(
              fieldBase,
              icon && 'pl-9',
              error && 'border-red-400 focus:ring-red-400',
              className
            )}
            {...props}
          />
        </div>
        {error && <p className="text-xs text-red-500">{error}</p>}
        {!error && hint && <p className="text-xs text-zinc-500">{hint}</p>}
      </div>
    );
  }
);

Input.displayName = 'Input';

interface SelectInputProps extends React.SelectHTMLAttributes<HTMLSelectElement> {
  label?: string;
  error?: string;
  hint?: string;
  options: { value: string; label: string }[];
  placeholder?: string;
}

export const SelectInput = forwardRef<HTMLSelectElement, SelectInputProps>(
  ({ className, label, error, hint, options, placeholder, id, ...props }, ref) => {
    const selectId = id || label?.toLowerCase().replace(/\s+/g, '-');
    return (
      <div className="space-y-1.5">
        {label && (
          <label htmlFor={selectId} className={labelBase}>
            {label}
            {props.required && <span className="text-red-500 ml-0.5">*</span>}
          </label>
        )}
        <select
          ref={ref}
          id={selectId}
          className={cn(
            fieldBase,
            'cursor-pointer pr-8 appearance-none bg-no-repeat',
            error && 'border-red-400 focus:ring-red-400',
            className
          )}
          style={{
            backgroundImage:
              "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 20 20' fill='%2371717a'%3E%3Cpath fill-rule='evenodd' d='M5.23 7.21a.75.75 0 011.06.02L10 11.06l3.71-3.83a.75.75 0 111.08 1.04l-4.25 4.39a.75.75 0 01-1.08 0L5.21 8.27a.75.75 0 01.02-1.06z' clip-rule='evenodd'/%3E%3C/svg%3E\")",
            backgroundPosition: 'right 0.5rem center',
            backgroundSize: '1.25rem 1.25rem',
          }}
          {...props}
        >
          {placeholder && <option value="">{placeholder}</option>}
          {options.map(o => (
            <option key={o.value} value={o.value}>{o.label}</option>
          ))}
        </select>
        {error && <p className="text-xs text-red-500">{error}</p>}
        {!error && hint && <p className="text-xs text-zinc-500">{hint}</p>}
      </div>
    );
  }
);

SelectInput.displayName = 'SelectInput';

interface TextareaProps extends React.TextareaHTMLAttributes<HTMLTextAreaElement> {
  label?: string;
  error?: string;
  hint?: string;
}

export const Textarea = forwardRef<HTMLTextAreaElement, TextareaProps>(
  ({ className, label, error, hint, id, ...props }, ref) => {
    const textareaId = id || label?.toLowerCase().replace(/\s+/g, '-');
    return (
      <div className="space-y-1.5">
        {label && (
          <label htmlFor={textareaId} className={labelBase}>
            {label}
            {props.required && <span className="text-red-500 ml-0.5">*</span>}
          </label>
        )}
        <textarea
          ref={ref}
          id={textareaId}
          className={cn(
            'w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900',
            'placeholder:text-zinc-400',
            'focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent',
            'disabled:bg-zinc-50 disabled:text-zinc-500',
            'transition-shadow duration-150 resize-none',
            error && 'border-red-400 focus:ring-red-400',
            className
          )}
          {...props}
        />
        {error && <p className="text-xs text-red-500">{error}</p>}
        {!error && hint && <p className="text-xs text-zinc-500">{hint}</p>}
      </div>
    );
  }
);

Textarea.displayName = 'Textarea';
