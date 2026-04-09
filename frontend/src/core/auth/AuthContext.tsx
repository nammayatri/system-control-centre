import React, { createContext, useContext, useState, useEffect, useCallback } from 'react';
import { login as loginApi, getProfile, logout as logoutApi } from './api';
import type { AuthUser, ProductAccess } from './api';
import { TOKEN_KEY } from '../../lib/constants';

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

// Hydrate from localStorage so the app paints an authed UI before the profile request returns.
function loadCached(): { user: AuthUser | null; products: ProductAccess[] } {
  try {
    const user = JSON.parse(localStorage.getItem('auth_user') || 'null');
    const products = JSON.parse(localStorage.getItem('auth_products') || '[]');
    return { user, products };
  } catch {
    return { user: null, products: [] };
  }
}

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const cached = loadCached();
  const storedToken = localStorage.getItem('sc_token');
  const [user, setUser] = useState<AuthUser | null>(storedToken ? cached.user : null);
  const [token, setToken] = useState<string | null>(storedToken);
  const [products, setProducts] = useState<ProductAccess[]>(storedToken ? cached.products : []);
  const [loading, setLoading] = useState(!cached.user && !!storedToken);

  const clearAuth = useCallback(() => {
    setUser(null);
    setToken(null);
    setProducts([]);
    localStorage.removeItem('sc_token');
    localStorage.removeItem('auth_user');
    localStorage.removeItem('auth_products');
  }, []);

  // Validate token on mount — only logout on 401, not network errors
  useEffect(() => {
    if (!storedToken) {
      setLoading(false);
      return;
    }

    getProfile()
      .then((data) => {
        setUser(data.person);
        setProducts(data.products || []);
        setToken(storedToken);
        localStorage.setItem('auth_user', JSON.stringify(data.person));
        localStorage.setItem('auth_products', JSON.stringify(data.products || []));
      })
      .catch((err) => {
        // Only 401 clears auth — network errors keep the cached user so a transient
        // backend outage doesn't sign everyone out.
        if (err?.response?.status === 401) {
          clearAuth();
        }
      })
      .finally(() => setLoading(false));
  }, [clearAuth]);

  const login = useCallback(async (email: string, password: string) => {
    const data = await loginApi(email, password);
    setUser(data.person);
    setToken(data.token);
    setProducts(data.products || []);
    localStorage.setItem('sc_token', data.token);
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
