import { isAxiosError } from 'axios';
import { ShieldAlert } from 'lucide-react';

export function isForbidden(err: unknown): boolean {
  return isAxiosError(err) && err.response?.status === 403;
}

/** Error state for airborne queries: a 403 renders an honest "permission
needed" card (access is the problem, not the service); anything else keeps
the red fetch-failure box. `what` names the thing that failed, lowercase
("OTA apps", "releases for this app"). */
export function OtaErrorState({ error, what }: { error: unknown; what: string }) {
  if (isForbidden(error)) {
    return (
      <div className="rounded-xl border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900 py-14 px-6 text-center">
        <ShieldAlert className="mx-auto mb-3 h-10 w-10 text-zinc-300 dark:text-zinc-600" />
        <h2 className="text-sm font-semibold text-zinc-700 dark:text-zinc-300">
          Permission needed
        </h2>
        <p className="mx-auto mt-1 max-w-md text-sm text-zinc-500 dark:text-zinc-400">
          You don&rsquo;t have access to {what}. Ask an admin for a mobile grant — per-app for one
          app, or product-level for the fleet.
        </p>
      </div>
    );
  }
  return (
    <div className="rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">
      Failed to load {what}. Refresh to retry.
    </div>
  );
}
