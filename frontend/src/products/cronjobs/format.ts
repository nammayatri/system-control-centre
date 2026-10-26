export function fmtTime(iso?: string | null): string {
  if (!iso) return '—';
  const d = new Date(iso);
  if (isNaN(d.getTime())) return '—';
  return d.toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit', hour12: false }) + ' IST';
}

export function relTime(iso?: string | null): string {
  if (!iso) return '';
  const mins = Math.round(Math.abs(Date.now() - new Date(iso).getTime()) / 60000);
  const text = mins < 1 ? 'moments' : mins < 60 ? `${mins}m` : mins < 1440 ? `${Math.round(mins / 60)}h` : `${Math.round(mins / 1440)}d`;
  return new Date(iso).getTime() > Date.now() ? `in ${text}` : `${text} ago`;
}

/** Last path segment of an image reference, e.g. `registry/app:tag` → `app:tag`. */
export function shortImage(image: string): string {
  return image.split('/').pop() ?? image;
}

/** Same rule as the backend's isSensitiveName, only used to nudge the editor toward a Secret reference. */
export function looksSensitive(name: string): boolean {
  const up = name.toUpperCase();
  const toks = up.split(/[_.-]/);
  if (['FILE', 'PATH', 'NAME', 'URL', 'URI', 'HOST', 'PORT', 'ENDPOINT', 'TTL', 'EXPIRY', 'SECONDS', 'ENABLED', 'LENGTH', 'POLICY'].includes(toks[toks.length - 1])) return false;
  return (
    ['PASSWORD', 'PASSWD', 'SECRET', 'TOKEN', 'PRIVATE_KEY', 'PRIVATEKEY', 'API_KEY', 'APIKEY', 'ACCESS_KEY', 'CREDENTIAL', 'AUTH_KEY', 'SIGNING_KEY', 'ENCRYPTION_KEY'].some((k) => up.includes(k)) ||
    toks.some((t) => t === 'PASS' || t === 'PWD' || t === 'PASSWD')
  );
}
