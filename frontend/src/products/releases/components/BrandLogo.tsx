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
}: {
  brand: string;
  surface?: 'consumer' | 'driver';
  size?: keyof typeof SIZES;
  className?: string;
}) {
  const slug = brandSlug(brand);
  // Prefer the surface-specific icon (the driver app ships its own logo); fall back to
  // the brand logo, then a monogram.
  const src = (surface === 'driver' ? [`${slug}-driver`, slug] : [slug])
    .map((k) => LOGOS[k])
    .find(Boolean);
  const [broken, setBroken] = useState(false);
  const showImg = Boolean(src) && !broken;
  return (
    <span
      className={cn(
        'inline-flex shrink-0 items-center justify-center overflow-hidden rounded-lg ring-1 ring-black/5',
        SIZES[size],
        !showImg && tintFor(brand),
        className,
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
}
