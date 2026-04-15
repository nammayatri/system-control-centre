import React, { createContext, useContext, useState, useEffect, useCallback } from 'react';
import { login as loginApi, getProfile, logout as logoutApi } from './api';
import type { AuthUser, ProductAccess } from './api';
import { TOKEN_KEY } from '../../lib/constants';

interface AuthContextType {
  user: AuthUser | null;
  token: string | null;
  products: ProductAccess[];
  // Deployment env label (e.g. "UAT", "PROD"). Single value — one SCC instance
  // serves one env, set via SC_ENV on the backend deployment. Defaults to "UAT"
  // if the backend hasn't responded yet or didn't send the field.
  env: string;
  login: (email: string, password: string) => Promise<void>;
  logout: () => void;
  isAuthenticated: boolean;
  loading: boolean;
}

const AuthContext = createContext<AuthContextType>({
  user: null,
  token: null,
  products: [],
  env: 'UAT',
  login: async () => {},
  logout: () => {},
  isAuthenticated: false,
  loading: true,
});

// Hydrate from localStorage so the app paints an authed UI before the profile request returns.
function loadCached(): { user: AuthUser | null; products: ProductAccess[]; env: string } {
  try {
    const user = JSON.parse(localStorage.getItem('auth_user') || 'null');
    const products = JSON.parse(localStorage.getItem('auth_products') || '[]');
    const env = localStorage.getItem('auth_env') || 'UAT';
    return { user, products, env };
  } catch {
    return { user: null, products: [], env: 'UAT' };
  }
}

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const cached = loadCached();
  const storedToken = localStorage.getItem('sc_token');
  const [user, setUser] = useState<AuthUser | null>(storedToken ? cached.user : null);
  const [token, setToken] = useState<string | null>(storedToken);
  const [products, setProducts] = useState<ProductAccess[]>(storedToken ? cached.products : []);
  const [env, setEnv] = useState<string>(cached.env);
  const [loading, setLoading] = useState(!cached.user && !!storedToken);

  const clearAuth = useCallback(() => {
    setUser(null);
    setToken(null);
    setProducts([]);
    localStorage.removeItem('sc_token');
    localStorage.removeItem('auth_user');
    localStorage.removeItem('auth_products');
    localStorage.removeItem('auth_env');
  }, []);

  // Validate token on mount — only logout on 401, not network errors
  useEffect(() => {
    if (!storedToken) {
      setLoading(false);
      return;
    }

    getProfile()
      .then((data: any) => {
        setUser(data.person);
        setProducts(data.products || []);
        setToken(storedToken);
        const newEnv = data.config?.env || 'UAT';
        setEnv(newEnv);
        localStorage.setItem('auth_user', JSON.stringify(data.person));
        localStorage.setItem('auth_products', JSON.stringify(data.products || []));
        localStorage.setItem('auth_env', newEnv);
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
    const data: any = await loginApi(email, password);
    setUser(data.person);
    setToken(data.token);
    setProducts(data.products || []);
    const newEnv = data.config?.env || 'UAT';
    setEnv(newEnv);
    localStorage.setItem('sc_token', data.token);
    localStorage.setItem('auth_user', JSON.stringify(data.person));
    localStorage.setItem('auth_products', JSON.stringify(data.products || []));
    localStorage.setItem('auth_env', newEnv);
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
        env,
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
