import { Badge } from '../../../shared/ui/badge';
import { STATUS_LABEL, roleVariant, statusVariant } from '../format';
import type { ApplyStatus, HpaRole } from '../types';

export function ApplyStatusBadge({ status }: { status: ApplyStatus }) {
  return <Badge variant={statusVariant(status)} dot>{STATUS_LABEL[status] ?? status}</Badge>;
}

export function RoleBadge({ role }: { role: HpaRole }) {
  return <Badge variant={roleVariant(role)}>{role.charAt(0) + role.slice(1).toLowerCase()}</Badge>;
}
