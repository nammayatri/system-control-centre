import React, { createContext, useContext, useState, useEffect, useCallback } from 'react';
import { login as loginApi, getProfile, logout as logoutApi } from './api';
import type { AuthUser, ProductAccess } from './api';
import { TOKEN_KEY } from '../../lib/constants';

interface AuthContextType {
  user: AuthUser | null;
  token: string | null;
  products: ProductAccess[];
  // Cosmetic deployment env label from SC_ENV (display only — do NOT branch on it).
  env: string;
  // Deployment build type — 'debug' or 'release'. Sourced from the
  // mobile_build_type server_config (not the env label), so it's runtime-
  // configurable without a redeploy. This is the single knob the UI keys off for
  // debug vs release. Defaults to 'release'.
  buildType: 'debug' | 'release';
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
  buildType: 'release',
  login: async () => {},
  logout: () => {},
  isAuthenticated: false,
  loading: true,
});

type BuildType = 'debug' | 'release';
const asBuildType = (v: unknown): BuildType => (v === 'debug' ? 'debug' : 'release');

// Hydrate from localStorage so the app paints an authed UI before the profile request returns.
function loadCached(): { user: AuthUser | null; products: ProductAccess[]; env: string; buildType: BuildType } {
  try {
    const user = JSON.parse(localStorage.getItem('auth_user') || 'null');
    const products = JSON.parse(localStorage.getItem('auth_products') || '[]');
    const env = localStorage.getItem('auth_env') || 'UAT';
    const buildType = asBuildType(localStorage.getItem('auth_build_type'));
    return { user, products, env, buildType };
  } catch {
    return { user: null, products: [], env: 'UAT', buildType: 'release' };
  }
}

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const cached = loadCached();
  const storedToken = localStorage.getItem('sc_token');
  const [user, setUser] = useState<AuthUser | null>(storedToken ? cached.user : null);
  const [token, setToken] = useState<string | null>(storedToken);
  const [products, setProducts] = useState<ProductAccess[]>(storedToken ? cached.products : []);
  const [env, setEnv] = useState<string>(cached.env);
  const [buildType, setBuildType] = useState<BuildType>(cached.buildType);
  const [loading, setLoading] = useState(!cached.user && !!storedToken);

  const clearAuth = useCallback(() => {
    setUser(null);
    setToken(null);
    setProducts([]);
    localStorage.removeItem('sc_token');
    localStorage.removeItem('auth_user');
    localStorage.removeItem('auth_products');
    localStorage.removeItem('auth_env');
    localStorage.removeItem('auth_build_type');
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
        const newBuildType = asBuildType(data.config?.buildType);
        setEnv(newEnv);
        setBuildType(newBuildType);
        localStorage.setItem('auth_user', JSON.stringify(data.person));
        localStorage.setItem('auth_products', JSON.stringify(data.products || []));
        localStorage.setItem('auth_env', newEnv);
        localStorage.setItem('auth_build_type', newBuildType);
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
    const newBuildType = asBuildType(data.config?.buildType);
    setEnv(newEnv);
    setBuildType(newBuildType);
    localStorage.setItem('sc_token', data.token);
    localStorage.setItem('auth_user', JSON.stringify(data.person));
    localStorage.setItem('auth_products', JSON.stringify(data.products || []));
    localStorage.setItem('auth_env', newEnv);
    localStorage.setItem('auth_build_type', newBuildType);
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
        buildType,
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
