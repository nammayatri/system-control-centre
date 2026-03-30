import React, { createContext, useContext, useMemo } from 'react';
import { useAuth } from './AuthContext';

interface PermissionsContextType {
  hasPermission: (product: string, action: string) => boolean;
  hasAnyPermission: (product: string, actions: string[]) => boolean;
  isAdmin: boolean;
  userPermissions: Record<string, string[]>;
}

const PermissionsContext = createContext<PermissionsContextType>({
  hasPermission: () => true,
  hasAnyPermission: () => true,
  isAdmin: false,
  userPermissions: {},
});

export function PermissionsProvider({ children }: { children: React.ReactNode }) {
  const { products, user } = useAuth();

  const permMap = useMemo(() => {
    const map: Record<string, string[]> = {};
    for (const p of products) {
      map[p.slug] = p.permissions || [];
    }
    return map;
  }, [products]);

  const isAdmin = useMemo(() => {
    return products.some(
      (p) => p.role === 'superadmin' || p.role === 'admin'
    );
  }, [products]);

  const hasPermission = (product: string, action: string): boolean => {
    if (isAdmin) return true;
    const perms = permMap[product];
    if (!perms) return false;
    return perms.includes(action) || perms.includes('*');
  };

  const hasAnyPermission = (product: string, actions: string[]): boolean => {
    return actions.some((a) => hasPermission(product, a));
  };

  return (
    <PermissionsContext.Provider
      value={{ hasPermission, hasAnyPermission, isAdmin, userPermissions: permMap }}
    >
      {children}
    </PermissionsContext.Provider>
  );
}

export function usePermissions() {
  return useContext(PermissionsContext);
}

export default PermissionsContext;
