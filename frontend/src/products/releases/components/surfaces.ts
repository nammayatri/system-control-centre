import { User, Car, type LucideIcon } from 'lucide-react';

/**
 * Surface (consumer / driver) identity — label + icon + tint. Single source of
 * truth shared by the App Release Monitor cards and the bulk promote/rollout panel
 * so the two never drift on how a surface is shown.
 */
export type SurfaceKey = 'consumer' | 'driver' | 'other';

export function surfaceKeyOf(surface: string): SurfaceKey {
  const s = surface.toLowerCase();
  if (s === 'customer' || s === 'consumer') return 'consumer';
  if (s === 'driver' || s === 'provider' || s === 'partner') return 'driver';
  return 'other';
}

export const SURFACE_META: Record<SurfaceKey, { label: string; Icon: LucideIcon; tint: string }> = {
  consumer: { label: 'Consumer', Icon: User, tint: 'text-sky-600' },
  driver: { label: 'Driver', Icon: Car, tint: 'text-emerald-600' },
  other: { label: 'Other', Icon: User, tint: 'text-zinc-500' },
};

export const SURFACE_ORDER: SurfaceKey[] = ['consumer', 'driver', 'other'];

/** Surface meta straight from a raw `service` string. */
export const surfaceMeta = (service: string) => SURFACE_META[surfaceKeyOf(service)];
