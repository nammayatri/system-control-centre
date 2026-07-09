import React from 'react';
import { usePermissions } from './PermissionsContext';

interface PermissionGateProps {
  product?: string;
  permission?: string;
  permissions?: string[];
  appGroup?: string;
  requireAdmin?: boolean;
  fallback?: React.ReactNode;
  children: React.ReactNode;
}

export function PermissionGate({
  product,
  permission,
  permissions,
  appGroup,
  requireAdmin,
  fallback = null,
  children,
}: PermissionGateProps) {
  const { hasPermission, hasAnyPermission, hasAnyDeploymentPermission, isAdmin } = usePermissions();

  if (requireAdmin && !isAdmin) return <>{fallback}</>;

  if (product && permission) {
    const allowed = appGroup
      ? hasPermission(product, permission, appGroup)
      : hasPermission(product, permission) || hasAnyDeploymentPermission(product, permission);
    if (!allowed) return <>{fallback}</>;
  }

  if (product && permissions) {
    const allowed = appGroup
      ? hasAnyPermission(product, permissions, appGroup)
      : hasAnyPermission(product, permissions) || permissions.some((p) => hasAnyDeploymentPermission(product, p));
    if (!allowed) return <>{fallback}</>;
  }

  return <>{children}</>;
}
