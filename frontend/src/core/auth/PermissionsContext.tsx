import React, { createContext, useContext, useMemo } from 'react';
import { useAuth } from './AuthContext';

interface PermissionsContextType {
  hasPermission: (product: string, action: string, appGroup?: string) => boolean;
  hasAnyPermission: (product: string, actions: string[], appGroup?: string) => boolean;
  hasAnyDeploymentPermission: (product: string, action: string) => boolean;
  // True if the user has ANY per-app (deployment) grant for the product,
  // regardless of action — used by the coarse product gate so per-app-only
  // users can enter the product (the app list itself is filtered server-side).
  hasAnyDeploymentAccess: (product: string) => boolean;
  isAdmin: boolean;
  userPermissions: Record<string, string[]>;
}

const PermissionsContext = createContext<PermissionsContextType>({
  hasPermission: () => true,
  hasAnyPermission: () => true,
  hasAnyDeploymentPermission: () => true,
  hasAnyDeploymentAccess: () => true,
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

  // airborne-ota permissions may be carried by autopilot grants (the unified
  // per-app model) — mirror of the backend's aliasGrantSlugs.
  const otaAliasHas = (action: string): boolean => {
    if (permMap['autopilot']?.includes(action)) return true;
    const groups = deploymentPermMap['autopilot'];
    return !!groups && Object.values(groups).some((perms) => perms.includes(action));
  };

  const hasPermission = (product: string, action: string, appGroup?: string): boolean => {
    if (isAdmin) return true;
    if (appGroup) {
      // Exact per-app grant wins; 'mobile/*' covers every "<name>/<platform>"
      // mobile key (server deployment names never contain '/').
      const productMap = deploymentPermMap[product];
      const deployPerms =
        productMap?.[appGroup] ??
        (appGroup.includes('/') && appGroup !== 'mobile/*' ? productMap?.['mobile/*'] : undefined);
      if (deployPerms) {
        return deployPerms.includes(action) || deployPerms.includes('*');
      }
    }
    const perms = permMap[product];
    if (perms && (perms.includes(action) || perms.includes('*'))) return true;
    return product === 'airborne-ota' && otaAliasHas(action);
  };

  const hasAnyPermission = (product: string, actions: string[], appGroup?: string): boolean => {
    return actions.some((a) => hasPermission(product, a, appGroup));
  };

  const hasAnyDeploymentPermission = (product: string, action: string): boolean => {
    if (isAdmin) return true;
    const groups = deploymentPermMap[product];
    if (groups && Object.values(groups).some((perms) => perms.includes(action) || perms.includes('*')))
      return true;
    return product === 'airborne-ota' && otaAliasHas(action);
  };

  const hasAnyDeploymentAccess = (product: string): boolean => {
    if (isAdmin) return true;
    const groups = deploymentPermMap[product];
    if (!!groups && Object.keys(groups).length > 0) return true;
    // Autopilot grants carrying any OTA_* perm confer airborne-ota access.
    if (product === 'airborne-ota') {
      if (permMap['autopilot']?.some((x) => x.startsWith('OTA_'))) return true;
      const ap = deploymentPermMap['autopilot'];
      return !!ap && Object.values(ap).some((perms) => perms.some((x) => x.startsWith('OTA_')));
    }
    return false;
  };

  return (
    <PermissionsContext.Provider
      value={{ hasPermission, hasAnyPermission, hasAnyDeploymentPermission, hasAnyDeploymentAccess, isAdmin, userPermissions: permMap }}
    >
      {children}
    </PermissionsContext.Provider>
  );
}

export function usePermissions() {
  return useContext(PermissionsContext);
}

export default PermissionsContext;
