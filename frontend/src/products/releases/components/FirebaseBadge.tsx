import { Badge } from '../../../shared/ui/badge';

/**
 * A release is an INTERNAL Firebase App Distribution build when it's a provider
 * PROD Android build whose destination is "Firebase" — it goes to Firebase, NOT
 * Google Play, so it owns no store identity and its version/code repeats. Keyed
 * off the persisted mbContext destination the backend serializes into
 * `release_context`. The narrow shape keeps this usable from any release-like row.
 */
export function isFirebaseInternal(release: {
  tracker_type?: string;
  release_context?: { destination?: string | null } | null;
}): boolean {
  return (
    release.tracker_type === 'MobileBuild' &&
    release.release_context?.destination === 'Firebase'
  );
}

/**
 * Badge marking an internal Firebase App Distribution build so operators don't
 * mistake it for a store (Google Play) release. Render it next to the status
 * wherever a Firebase build can appear (lists, group detail, release detail).
 */
export function FirebaseInternalBadge() {
  return (
    <span title="Internal build — distributed via Firebase App Distribution, not published to Google Play">
      <Badge variant="warning">Firebase internal</Badge>
    </span>
  );
}
