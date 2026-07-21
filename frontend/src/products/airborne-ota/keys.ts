import type { OtaFile, OtaPackage } from './types';

// Airborne key builders. file key = "<file_path>@version:<n>" (or @tag:<t>);
// package_id = "version:<n>" (or "tag:<t>"). All built tolerantly.

export function otaFileKey(f: OtaFile): string | null {
  if (!f.file_path) return null;
  if (f.version != null) return `${f.file_path}@version:${f.version}`;
  if (f.tag) return `${f.file_path}@tag:${f.tag}`;
  // Bare paths are rejected upstream ("Invalid file key format") — no fallback.
  return null;
}

// GET-release Resource/ServeFile objects carry the full key in file_id (or id).
export function otaFileKeyFromObj(f: OtaFile): string | null {
  for (const field of ['file_id', 'id'] as const) {
    const v = f[field];
    if (typeof v === 'string' && v.includes('@')) return v;
  }
  return otaFileKey(f);
}

export function otaPackageId(p: OtaPackage): string | null {
  if (p.version != null) return `version:${p.version}`;
  if (p.tag) return `tag:${p.tag}`;
  return null;
}

// Release.resources entries may be file-key strings or file objects.
export function otaResourceKey(r: unknown): string | null {
  if (typeof r === 'string') return r || null;
  if (r && typeof r === 'object') return otaFileKeyFromObj(r as OtaFile);
  return null;
}
