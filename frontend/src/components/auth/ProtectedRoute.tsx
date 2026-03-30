import React from 'react';
import { Navigate } from 'react-router-dom';
import { useAuth } from '../../context/AuthContext';
import { usePermissions } from '../../context/PermissionsContext';
import { ShieldAlert } from 'lucide-react';

interface ProtectedRouteProps {
  product?: string;
  permission?: string;    // specific permission required (e.g., 'RELEASE_CREATE')
  requireAdmin?: boolean;
  children: React.ReactNode;
}

export function ProtectedRoute({ product, permission, requireAdmin, children }: ProtectedRouteProps) {
  const { isAuthenticated, loading } = useAuth();
  const { isAdmin, hasPermission, userPermissions } = usePermissions();

  if (loading) {
    return (
      <div className="flex items-center justify-center h-full">
        <div className="animate-spin h-6 w-6 border-2 border-zinc-300 border-t-zinc-800 rounded-full" />
      </div>
    );
  }

  if (!isAuthenticated) {
    return <Navigate to="/login" replace />;
  }

  if (requireAdmin && !isAdmin) {
    return (
      <div className="flex flex-col items-center justify-center h-full text-center py-20">
        <ShieldAlert className="w-12 h-12 text-zinc-300 mb-4" />
        <h2 className="text-lg font-semibold text-zinc-700 mb-1">Access Denied</h2>
        <p className="text-sm text-zinc-500">You do not have admin privileges to access this page.</p>
      </div>
    );
  }

  if (product && !isAdmin && !userPermissions[product]) {
    return (
      <div className="flex flex-col items-center justify-center h-full text-center py-20">
        <ShieldAlert className="w-12 h-12 text-zinc-300 mb-4" />
        <h2 className="text-lg font-semibold text-zinc-700 mb-1">Access Denied</h2>
        <p className="text-sm text-zinc-500">
          You do not have access to this product. Contact your admin for permissions.
        </p>
      </div>
    );
  }

  if (product && permission && !isAdmin && !hasPermission(product, permission)) {
    return (
      <div className="flex flex-col items-center justify-center h-full text-center py-20">
        <ShieldAlert className="w-12 h-12 text-zinc-300 mb-4" />
        <h2 className="text-lg font-semibold text-zinc-700 mb-1">Permission Denied</h2>
        <p className="text-sm text-zinc-500">
          You do not have the required permission ({permission}) for this action.
        </p>
      </div>
    );
  }

  return <>{children}</>;
}
