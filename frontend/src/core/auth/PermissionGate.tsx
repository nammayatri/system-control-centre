import React from 'react';
import { usePermissions } from './PermissionsContext';

interface PermissionGateProps {
  product?: string;
  permission?: string;
  permissions?: string[];
  requireAdmin?: boolean;
  fallback?: React.ReactNode;
  children: React.ReactNode;
}

export function PermissionGate({
  product,
  permission,
  permissions,
  requireAdmin,
  fallback = null,
  children,
}: PermissionGateProps) {
  const { hasPermission, hasAnyPermission, isAdmin } = usePermissions();

  if (requireAdmin && !isAdmin) return <>{fallback}</>;

  if (product && permission && !hasPermission(product, permission)) {
    return <>{fallback}</>;
  }

  if (product && permissions && !hasAnyPermission(product, permissions)) {
    return <>{fallback}</>;
  }

  return <>{children}</>;
}
