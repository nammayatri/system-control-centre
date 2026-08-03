import { useState } from 'react';
import { cn } from '../../../lib/utils';

/**
 * Per-brand logo for the App Release Monitor. Auto-discovers any image dropped into
 * `src/assets/brands/<brand-slug>.{svg,png,webp,jpg}` (slug = lowercased brand, every
 * run of non-alphanumerics → '-'). Brands without a file — or whose image fails to
 * load — render a deterministic colored initials monogram, so every brand always
 * shows something. Drop a file in to light up its real logo; no code change needed.
 */

// Vite resolves each match to a hashed asset URL at build time (path → url).
const LOGO_URLS = import.meta.glob('../../../assets/brands/*.{svg,png,webp,jpg,jpeg}', {
  eager: true,
  query: '?url',
  import: 'default',
}) as Record<string, string>;

// Key the resolved URLs by bare filename (the brand slug), e.g. 'namma-yatri'.
const LOGOS: Record<string, string> = Object.fromEntries(
  Object.entries(LOGO_URLS).map(([path, url]) => [
    path.split('/').pop()!.replace(/\.[^.]+$/, '').toLowerCase(),
    url,
  ]),
);

// Normalize any app/brand string — "NammaYatri", "Namma Yatri",
// "Namma Yatri (Customer Android)", "OdishaYatriPartner" — to a clean brand name.
export function normalizeBrand(brand: string): string {
  return brand
    .replace(/\s*\(.*$/, '') // drop "(Customer Android)"
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2') // split camelCase
    .replace(/\b(Partner|Driver|Provider|Customer|Consumer)\b/gi, '') // drop surface words
    .replace(/\s+/g, ' ')
    .trim();
}

export function brandSlug(brand: string): string {
  return normalizeBrand(brand)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
}

function initials(brand: string): string {
  const words = normalizeBrand(brand).split(/\s+/).filter(Boolean);
  const raw = words.length >= 2 ? words[0][0] + words[1][0] : (words[0] || brand).slice(0, 2);
  return raw.toUpperCase();
}

// Stable tint per brand — hashed so a brand keeps the same color across renders/pages.
const TINTS = [
  'bg-sky-100 text-sky-700',
  'bg-emerald-100 text-emerald-700',
  'bg-amber-100 text-amber-700',
  'bg-violet-100 text-violet-700',
  'bg-rose-100 text-rose-700',
  'bg-teal-100 text-teal-700',
  'bg-indigo-100 text-indigo-700',
  'bg-orange-100 text-orange-700',
];

function tintFor(brand: string): string {
  const key = normalizeBrand(brand);
  let h = 0;
  for (let i = 0; i < key.length; i++) h = (h * 31 + key.charCodeAt(i)) >>> 0;
  return TINTS[h % TINTS.length];
}

const SIZES = {
  sm: 'h-6 w-6 text-[10px]',
  md: 'h-7 w-7 text-[11px]',
  lg: 'h-9 w-9 text-xs',
} as const;

export function BrandLogo({
  brand,
  surface,
  size = 'md',
  className,
  platform,
}: {
  brand: string;
  surface?: 'consumer' | 'driver';
  size?: keyof typeof SIZES;
  className?: string;
  // Opt-in corner badge (app-store convention): emerald Android robot /
  // black Apple mark pinned bottom-right, ringed so it reads on any row bg.
  platform?: 'android' | 'ios';
}) {
  const slug = brandSlug(brand);
  // Prefer the surface-specific icon (the driver app ships its own logo); fall back to
  // the brand logo, then a monogram.
  const src = (surface === 'driver' ? [`${slug}-driver`, slug] : [slug])
    .map((k) => LOGOS[k])
    .find(Boolean);
  const [broken, setBroken] = useState(false);
  const showImg = Boolean(src) && !broken;
  const logo = (
    <span
      className={cn(
        'inline-flex shrink-0 items-center justify-center overflow-hidden rounded-lg ring-1 ring-black/5',
        SIZES[size],
        !showImg && tintFor(brand),
        !platform && className,
      )}
      title={normalizeBrand(brand) || brand}
    >
      {showImg ? (
        <img
          src={src}
          alt=""
          className="h-full w-full object-contain"
          loading="lazy"
          onError={() => setBroken(true)}
        />
      ) : (
        <span className="font-semibold leading-none" aria-hidden>
          {initials(brand)}
        </span>
      )}
    </span>
  );
  if (!platform) return logo;
  return (
    <span className={cn('relative inline-flex shrink-0', className)}>
      {logo}
      <span
        className={cn(
          'absolute -bottom-1 -right-1 flex h-3.5 w-3.5 items-center justify-center rounded-full ring-2 ring-white',
          platform === 'android' ? 'bg-emerald-500' : 'bg-zinc-950',
        )}
        aria-label={platform}
      >
        {platform === 'android' ? (
          <svg viewBox="0 0 24 24" className="h-2 w-2 fill-white" aria-hidden>
            <path d="M17.6 9.48l1.84-3.18a.38.38 0 00-.66-.38l-1.86 3.22a11.46 11.46 0 00-9.84 0L5.22 5.92a.38.38 0 00-.66.38L6.4 9.48A10.86 10.86 0 001 18h22a10.86 10.86 0 00-5.4-8.52zM7 15.25a1.25 1.25 0 111.25-1.25A1.25 1.25 0 017 15.25zm10 0a1.25 1.25 0 111.25-1.25A1.25 1.25 0 0117 15.25z" />
          </svg>
        ) : (
          <svg viewBox="0 0 24 24" className="h-2 w-2 fill-white" aria-hidden>
            <path d="M17.05 20.28c-.98.95-2.05.8-3.08.35-1.09-.46-2.09-.48-3.24 0-1.44.62-2.2.44-3.06-.35C2.79 15.25 3.51 7.59 9.05 7.31c1.35.07 2.29.74 3.08.8 1.18-.24 2.31-.93 3.57-.84 1.51.12 2.65.72 3.4 1.8-3.12 1.87-2.38 5.98.48 7.13-.57 1.5-1.31 2.99-2.53 4.09zM12.03 7.25c-.15-2.23 1.66-4.07 3.74-4.25.29 2.58-2.34 4.5-3.74 4.25z" />
          </svg>
        )}
      </span>
    </span>
  );
}
