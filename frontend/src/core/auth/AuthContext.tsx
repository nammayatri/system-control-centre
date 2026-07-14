import React, { createContext, useContext, useState, useEffect, useCallback } from 'react';
import { login as loginApi, getProfile, logout as logoutApi } from './api';
import type { AuthUser, ProductAccess, DeploymentAccess } from './api';
import { TOKEN_KEY } from '../../lib/constants';

interface AuthContextType {
  user: AuthUser | null;
  token: string | null;
  products: ProductAccess[];
  deploymentAccess: DeploymentAccess[];
  // Cosmetic deployment env label from SC_ENV (display only — do NOT branch on it).
  env: string;
  // Deployment build type — 'debug' or 'release'. Sourced from the
  // mobile_build_type server_config (not the env label), so it's runtime-
  // configurable without a redeploy. This is the single knob the UI keys off for
  // debug vs release. Defaults to 'release'.
  buildType: 'debug' | 'release';
  // Whether Slack posting is enabled (slack_enabled server_config). The mobile
  // create form hides its "Send changelog to Slack" opt-in when this is false.
  slackEnabled: boolean;
  login: (email: string, password: string) => Promise<void>;
  logout: () => void;
  isAuthenticated: boolean;
  loading: boolean;
}

const AuthContext = createContext<AuthContextType>({
  user: null,
  token: null,
  products: [],
  deploymentAccess: [],
  env: 'UAT',
  buildType: 'release',
  slackEnabled: true,
  login: async () => { },
  logout: () => { },
  isAuthenticated: false,
  loading: true,
});

type BuildType = 'debug' | 'release';
const asBuildType = (v: unknown): BuildType => (v === 'debug' ? 'debug' : 'release');

// Hydrate from localStorage so the app paints an authed UI before the profile request returns.
function loadCached(): { user: AuthUser | null; products: ProductAccess[]; deploymentAccess: DeploymentAccess[]; env: string; buildType: BuildType; slackEnabled: boolean } {
  try {
    const user = JSON.parse(localStorage.getItem('auth_user') || 'null');
    const products = JSON.parse(localStorage.getItem('auth_products') || '[]');
    const deploymentAccess = JSON.parse(localStorage.getItem('auth_deployment_access') || '[]');
    const env = localStorage.getItem('auth_env') || 'UAT';
    const buildType = asBuildType(localStorage.getItem('auth_build_type'));
    // Default true unless explicitly cached false, so the opt-in isn't hidden
    // before the profile request confirms the config.
    const slackEnabled = localStorage.getItem('auth_slack_enabled') !== 'false';
    return { user, products, deploymentAccess, env, buildType, slackEnabled };
  } catch {
    return { user: null, products: [], deploymentAccess: [], env: 'UAT', buildType: 'release', slackEnabled: true };
  }
}

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const cached = loadCached();
  const storedToken = localStorage.getItem('sc_token');
  const [user, setUser] = useState<AuthUser | null>(storedToken ? cached.user : null);
  const [token, setToken] = useState<string | null>(storedToken);
  const [products, setProducts] = useState<ProductAccess[]>(storedToken ? cached.products : []);
  const [deploymentAccess, setDeploymentAccess] = useState<DeploymentAccess[]>(storedToken ? cached.deploymentAccess : []);
  const [env, setEnv] = useState<string>(cached.env);
  const [buildType, setBuildType] = useState<BuildType>(cached.buildType);
  const [slackEnabled, setSlackEnabled] = useState<boolean>(cached.slackEnabled);
  const [loading, setLoading] = useState(!cached.user && !!storedToken);

  const clearAuth = useCallback(() => {
    setUser(null);
    setToken(null);
    setProducts([]);
    setDeploymentAccess([]);
    localStorage.removeItem('sc_token');
    localStorage.removeItem('auth_user');
    localStorage.removeItem('auth_products');
    localStorage.removeItem('auth_deployment_access');
    localStorage.removeItem('auth_env');
    localStorage.removeItem('auth_build_type');
    localStorage.removeItem('auth_slack_enabled');
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
        setDeploymentAccess(data.deploymentAccess || []);
        setToken(storedToken);
        const newEnv = data.config?.env || 'UAT';
        const newBuildType = asBuildType(data.config?.buildType);
        const newSlack = data.config?.slackEnabled ?? true;
        setEnv(newEnv);
        setBuildType(newBuildType);
        setSlackEnabled(newSlack);
        localStorage.setItem('auth_user', JSON.stringify(data.person));
        localStorage.setItem('auth_products', JSON.stringify(data.products || []));
        localStorage.setItem('auth_deployment_access', JSON.stringify(data.deploymentAccess || []));
        localStorage.setItem('auth_env', newEnv);
        localStorage.setItem('auth_build_type', newBuildType);
        localStorage.setItem('auth_slack_enabled', String(newSlack));
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
    setDeploymentAccess(data.deploymentAccess || []);
    const newEnv = data.config?.env || 'UAT';
    const newBuildType = asBuildType(data.config?.buildType);
    const newSlack = data.config?.slackEnabled ?? true;
    setEnv(newEnv);
    setBuildType(newBuildType);
    setSlackEnabled(newSlack);
    localStorage.setItem('sc_token', data.token);
    localStorage.setItem('auth_user', JSON.stringify(data.person));
    localStorage.setItem('auth_products', JSON.stringify(data.products || []));
    localStorage.setItem('auth_deployment_access', JSON.stringify(data.deploymentAccess || []));
    localStorage.setItem('auth_env', newEnv);
    localStorage.setItem('auth_build_type', newBuildType);
    localStorage.setItem('auth_slack_enabled', String(newSlack));
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
        deploymentAccess,
        env,
        buildType,
        slackEnabled,
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
