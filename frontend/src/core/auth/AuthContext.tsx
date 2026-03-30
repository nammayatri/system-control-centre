import React, { createContext, useContext, useState, useEffect, useCallback } from 'react';
import { login as loginApi, getProfile, logout as logoutApi } from './api';
import type { AuthUser, ProductAccess } from './api';

interface AuthContextType {
  user: AuthUser | null;
  token: string | null;
  products: ProductAccess[];
  login: (email: string, password: string) => Promise<void>;
  logout: () => void;
  isAuthenticated: boolean;
  loading: boolean;
}

const AuthContext = createContext<AuthContextType>({
  user: null,
  token: null,
  products: [],
  login: async () => {},
  logout: () => {},
  isAuthenticated: false,
  loading: true,
});

// DEV MODE: set to true to bypass auth and see full UI without backend
const DEV_BYPASS = import.meta.env.VITE_DEV_BYPASS === 'true' || import.meta.env.DEV;

const DEV_USER: AuthUser = {
  id: 'dev-user-id',
  email: 'admin@juspay.in',
  name: 'Admin User',
  status: 'active',
};

const DEV_PRODUCTS: ProductAccess[] = [
  {
    slug: 'autopilot',
    role: 'Admin',
    permissions: [
      'AP_RELEASE_VIEW', 'AP_RELEASE_CREATE', 'AP_RELEASE_APPROVE',
      'AP_RELEASE_REVERT', 'AP_RELEASE_DISCARD', 'AP_RELEASE_PAUSE',
      'AP_RELEASE_RESUME', 'AP_RELEASE_ABORT', 'AP_RELEASE_UPDATE',
      'AP_MANAGE_STAGGER', 'AP_PRODUCT_CONFIG_VIEW', 'AP_PRODUCT_CONFIG_EDIT',
      'AP_SERVICE_CONFIG_VIEW', 'AP_SERVICE_CONFIG_EDIT',
    ],
  },
  {
    slug: 'config-manager',
    role: 'Admin',
    permissions: [
      'CM_CONFIG_VIEW', 'CM_CONFIG_CREATE', 'CM_CONFIG_APPLY',
      'CM_CONFIG_ROLLBACK', 'CM_CONFIG_UPDATE',
    ],
  },
];

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [user, setUser] = useState<AuthUser | null>(DEV_BYPASS ? DEV_USER : null);
  const [token, setToken] = useState<string | null>(DEV_BYPASS ? 'dev-token' : localStorage.getItem('auth_token'));
  const [products, setProducts] = useState<ProductAccess[]>(DEV_BYPASS ? DEV_PRODUCTS : []);
  const [loading, setLoading] = useState(DEV_BYPASS ? false : true);

  const clearAuth = useCallback(() => {
    setUser(null);
    setToken(null);
    setProducts([]);
    localStorage.removeItem('auth_token');
    localStorage.removeItem('auth_user');
    localStorage.removeItem('auth_products');
  }, []);

  // Validate token on mount (skip in dev bypass mode)
  useEffect(() => {
    if (DEV_BYPASS) return;

    const storedToken = localStorage.getItem('auth_token');
    if (!storedToken) {
      setLoading(false);
      return;
    }

    getProfile()
      .then((data) => {
        setUser(data.person);
        setProducts(data.products || []);
        setToken(storedToken);
      })
      .catch(() => {
        clearAuth();
      })
      .finally(() => setLoading(false));
  }, [clearAuth]);

  const login = useCallback(async (email: string, password: string) => {
    if (DEV_BYPASS) {
      setUser(DEV_USER);
      setToken('dev-token');
      setProducts(DEV_PRODUCTS);
      return;
    }
    const data = await loginApi(email, password);
    setUser(data.person);
    setToken(data.token);
    setProducts(data.products || []);
    localStorage.setItem('auth_token', data.token);
    localStorage.setItem('auth_user', JSON.stringify(data.person));
    localStorage.setItem('auth_products', JSON.stringify(data.products || []));
  }, []);

  const logout = useCallback(() => {
    logoutApi();
    clearAuth();
    window.location.href = '/login';
  }, [clearAuth]);

  return (
    <AuthContext.Provider
      value={{
        user,
        token,
        products,
        login,
        logout,
        isAuthenticated: !!token && !!user,
        loading,
      }}
    >
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  return useContext(AuthContext);
}

export default AuthContext;
