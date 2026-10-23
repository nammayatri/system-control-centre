import type { ReactNode } from 'react';

/** A numbered section of a dialog: what it is, and a line saying what to do. */
export default function Step({ n, title, help, children }: { n: number; title: string; help?: string; children: ReactNode }) {
  return (
    <section>
      <div className="mb-2 flex items-start gap-2.5">
        <span className="mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-zinc-900 text-[11px] font-semibold text-white">{n}</span>
        <div>
          <div className="text-sm font-semibold text-zinc-900">{title}</div>
          {help && <div className="text-xs text-zinc-500">{help}</div>}
        </div>
      </div>
      <div className="pl-7">{children}</div>
    </section>
  );
}
