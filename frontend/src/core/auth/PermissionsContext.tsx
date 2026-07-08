import React, { createContext, useContext, useMemo } from 'react';
import { useAuth } from './AuthContext';

interface PermissionsContextType {
  hasPermission: (product: string, action: string, appGroup?: string) => boolean;
  hasAnyPermission: (product: string, actions: string[]) => boolean;
  hasAnyDeploymentPermission: (product: string, action: string) => boolean;
  isAdmin: boolean;
  userPermissions: Record<string, string[]>;
}

const PermissionsContext = createContext<PermissionsContextType>({
  hasPermission: () => true,
  hasAnyPermission: () => true,
  hasAnyDeploymentPermission: () => true,
  isAdmin: false,
  userPermissions: {},
});

export function PermissionsProvider({ children }: { children: React.ReactNode }) {
  const { products, deploymentAccess, user } = useAuth();

  const permMap = useMemo(() => {
    const map: Record<string, string[]> = {};
    for (const p of products) {
      map[p.slug] = p.permissions || [];
    }
    return map;
  }, [products]);

  // Nested map: productSlug -> appGroup -> permissions, from deployment-level grants.
  const deploymentPermMap = useMemo(() => {
    const map: Record<string, Record<string, string[]>> = {};
    for (const d of deploymentAccess) {
      if (!map[d.productSlug]) map[d.productSlug] = {};
      map[d.productSlug][d.appGroup] = d.permissions || [];
    }
    return map;
  }, [deploymentAccess]);

  const isAdmin = useMemo(() => {
    return products.some(
      (p) => p.role?.toLowerCase() === 'superadmin' || p.role?.toLowerCase() === 'admin'
    );
  }, [products]);

  const hasPermission = (product: string, action: string, appGroup?: string): boolean => {
    if (isAdmin) return true;
    if (appGroup) {
      const deployPerms = deploymentPermMap[product]?.[appGroup];
      if (deployPerms) {
        return deployPerms.includes(action) || deployPerms.includes('*');
      }
    }
    const perms = permMap[product];
    if (!perms) return false;
    return perms.includes(action) || perms.includes('*');
  };

  const hasAnyPermission = (product: string, actions: string[]): boolean => {
    return actions.some((a) => hasPermission(product, a));
  };

  const hasAnyDeploymentPermission = (product: string, action: string): boolean => {
    if (isAdmin) return true;
    const groups = deploymentPermMap[product];
    if (!groups) return false;
    return Object.values(groups).some((perms) => perms.includes(action) || perms.includes('*'));
  };

  return (
    <PermissionsContext.Provider
      value={{ hasPermission, hasAnyPermission, hasAnyDeploymentPermission, isAdmin, userPermissions: permMap }}
    >
      {children}
    </PermissionsContext.Provider>
  );
}

export function usePermissions() {
  return useContext(PermissionsContext);
}

export default PermissionsContext;
