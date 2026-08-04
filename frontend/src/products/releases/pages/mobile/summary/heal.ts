import type { APRelease, RolloutEvent } from '../../../api';

// Heal-state derivation from the release event stream — no dedicated API.
// The backend appends BUILD_HEALED_FROM_STORE when a CI-failed build is
// verified against store truth (auto gate or the Verify-on-store button),
// and TAG_CONFLICT when ConfirmTag finds the expected tag pointing at a
// commit this build didn't ship.

export interface HealInfo {
  trigger: 'auto' | 'manual' | null;
  observedCode: number | null;
}

/** Latest BUILD_HEALED_FROM_STORE event, if any — this build passed because
 * the store confirmed the artifact, not because CI went green. */
export function healInfoOf(events: RolloutEvent[]): HealInfo | null {
  const e = [...events].sort((a, b) => b.timestamp.localeCompare(a.timestamp)).find((ev) => ev.label === 'BUILD_HEALED_FROM_STORE');
  if (!e) return null;
  try {
    const d = JSON.parse(e.data || '{}');
    return {
      trigger: d.trigger === 'auto' || d.trigger === 'manual' ? d.trigger : null,
      observedCode: typeof d.observed_code === 'number' ? d.observed_code : null,
    };
  } catch {
    return { trigger: null, observedCode: null };
  }
}

/** Decode a Haskell `show`-rendered string body: `\&` separators, `\NNNN`
 * decimal codepoints (em-dashes etc.), and the usual backslash escapes. */
function decodeHaskellShow(s: string): string {
  return s
    .replace(/\\&/g, '')
    .replace(/\\(\d+)/g, (_, code) => {
      try {
        return String.fromCodePoint(Number(code));
      } catch {
        return '';
      }
    })
    .replace(/\\n/g, '\n')
    .replace(/\\t/g, '\t')
    .replace(/\\"/g, '"')
    .replace(/\\\\/g, '\\');
}

/** The MBFailed reason carried in release_context.mb_wf_status — the wire value
 * is the Haskell `show` rendering, e.g. `MBFailed "matrix job ended with …"`.
 * Null for non-failed rows and reasonless terminals (user aborts). */
export function failureReasonOf(release: APRelease): string | null {
  const raw = release.release_context?.mb_wf_status;
  if (typeof raw !== 'string') return null;
  const m = raw.match(/^MBFailed\s+"([\s\S]*)"$/);
  return m ? decodeHaskellShow(m[1]) : null;
}

/** GH-side failure cause captured at failure time (BUILD_FAILURE_DETAIL):
 * the failed step + the ##[error] excerpt from the job log. Composed into
 * the text the failed card's dark block renders. */
export function ghFailureDetailOf(events: RolloutEvent[]): string | null {
  const e = [...events].sort((a, b) => b.timestamp.localeCompare(a.timestamp)).find((ev) => ev.label === 'BUILD_FAILURE_DETAIL');
  if (!e) return null;
  try {
    const d = JSON.parse(e.data || '{}');
    const step = typeof d.failed_step === 'string' && d.failed_step ? `Failed step: ${d.failed_step}` : null;
    const excerpt = typeof d.excerpt === 'string' && d.excerpt ? d.excerpt : null;
    if (step && excerpt) return `${step}\n\n${excerpt}`;
    return excerpt ?? step;
  } catch {
    return null;
  }
}

export interface TagConflict {
  tag: string;
  tagCommit: string;
  buildCommit: string;
  remediation: string;
}

/** Latest UNRESOLVED tag conflict. A TAG_OBSERVED event after the conflict
 * means the retag landed and ConfirmTag adopted it — conflict cleared. */
export function tagConflictOf(events: RolloutEvent[]): TagConflict | null {
  const sorted = [...events].sort((a, b) => a.timestamp.localeCompare(b.timestamp));
  let conflict: TagConflict | null = null;
  for (const ev of sorted) {
    if (ev.label === 'TAG_CONFLICT') {
      try {
        const d = JSON.parse(ev.data || '{}');
        conflict = {
          tag: String(d.tag ?? ''),
          tagCommit: String(d.tag_commit ?? ''),
          buildCommit: String(d.build_commit ?? ''),
          remediation: String(d.remediation ?? ''),
        };
      } catch {
        // unparseable payload — keep any prior conflict state
      }
    } else if (ev.label === 'TAG_OBSERVED') {
      conflict = null;
    }
  }
  return conflict;
}
