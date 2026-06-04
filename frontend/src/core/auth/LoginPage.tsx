import React, { useState, useEffect, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from './AuthContext';
import { Eye, EyeOff } from 'lucide-react';
import { motion, AnimatePresence } from 'framer-motion';
import nyLogo from '../../assets/ny-logo.svg';
import { apiClient } from '../../lib/api-client';

const LoginPage: React.FC = () => {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const { login, isAuthenticated } = useAuth();
  const navigate = useNavigate();
  const emailRef = useRef<HTMLInputElement>(null);

  const [showReset, setShowReset] = useState(false);
  const [resetEmail, setResetEmail] = useState('');
  const [resetPassword, setResetPassword] = useState('');
  const [resetConfirm, setResetConfirm] = useState('');
  const [showResetPassword, setShowResetPassword] = useState(false);
  const [resetError, setResetError] = useState('');
  const [resetSuccess, setResetSuccess] = useState(false);
  const [resetLoading, setResetLoading] = useState(false);

  const handleReset = async (e: React.FormEvent) => {
    e.preventDefault();
    setResetError('');
    if (resetPassword !== resetConfirm) {
      setResetError('Passwords do not match');
      return;
    }
    if (resetPassword.length < 6) {
      setResetError('Password must be at least 6 characters');
      return;
    }
    setResetLoading(true);
    try {
      await apiClient.post('/auth/reset-password', { email: resetEmail, newPassword: resetPassword });
      setResetSuccess(true);
    } catch (err: any) {
      setResetError(err.response?.data?.message || 'Failed to reset password');
    } finally {
      setResetLoading(false);
    }
  };

  const handleBackToLogin = () => {
    setShowReset(false);
    setResetEmail('');
    setResetPassword('');
    setResetConfirm('');
    setResetError('');
    setResetSuccess(false);
  };

  useEffect(() => {
    if (isAuthenticated) {
      navigate('/', { replace: true });
    }
  }, [isAuthenticated, navigate]);

  useEffect(() => {
    emailRef.current?.focus();
  }, []);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    setLoading(true);

    try {
      await login(email, password);
      navigate('/', { replace: true });
    } catch (err: any) {
      setError(
        err.response?.data?.message ||
        err.message ||
        'Login failed. Please check your credentials.'
      );
    } finally {
      setLoading(false);
    }
  };

  if (isAuthenticated) return null;

  return (
    <div className="min-h-screen flex items-center justify-center bg-zinc-100 px-4 py-8">
      <motion.div
        className="w-full max-w-sm"
        initial={{ opacity: 0, y: 6 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.25, ease: 'easeOut' }}
      >
        <div className="bg-white rounded-xl shadow-sm border border-zinc-200">
          <div className="px-6 sm:px-8 pt-7 sm:pt-8 pb-2 text-center">
            <div className="flex items-center justify-center mb-3">
              <img src={nyLogo} alt="Logo" className="h-8 w-auto" />
            </div>
            <h1 className="text-base sm:text-lg font-semibold text-zinc-900">System Control Centre</h1>
            <p className="text-sm text-zinc-500 mt-1">
              {showReset ? 'Reset your password' : 'Sign in to your account'}
            </p>
          </div>

          <AnimatePresence mode="wait">
            {!showReset ? (
              <motion.form
                key="login"
                onSubmit={handleSubmit}
                className="px-6 sm:px-8 pb-7 sm:pb-8 pt-4 space-y-4"
                initial={{ opacity: 0, x: -8 }}
                animate={{ opacity: 1, x: 0 }}
                exit={{ opacity: 0, x: 8 }}
                transition={{ duration: 0.15 }}
              >
                <div className="space-y-1.5">
                  <label
                    htmlFor="login-email"
                    className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider"
                  >
                    Email
                  </label>
                  <input
                    ref={emailRef}
                    id="login-email"
                    type="email"
                    autoComplete="email"
                    value={email}
                    onChange={(e) => setEmail(e.target.value)}
                    required
                    disabled={loading}
                    placeholder="you@company.com"
                    className="w-full h-10 border border-zinc-300 rounded-lg px-3 text-sm text-zinc-900 placeholder:text-zinc-400 focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent disabled:bg-zinc-50 disabled:text-zinc-500 transition-shadow duration-150"
                  />
                </div>

                <div className="space-y-1.5">
                  <div className="flex items-center justify-between">
                    <label
                      htmlFor="login-password"
                      className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider"
                    >
                      Password
                    </label>
                    <button
                      type="button"
                      onClick={() => { setShowReset(true); setResetEmail(email); }}
                      className="text-[11px] text-zinc-400 hover:text-zinc-600 transition-colors duration-150 cursor-pointer"
                    >
                      Forgot password?
                    </button>
                  </div>
                  <div className="relative">
                    <input
                      id="login-password"
                      type={showPassword ? 'text' : 'password'}
                      autoComplete="current-password"
                      value={password}
                      onChange={(e) => setPassword(e.target.value)}
                      required
                      disabled={loading}
                      placeholder="Enter password"
                      className="w-full h-10 border border-zinc-300 rounded-lg px-3 pr-10 text-sm text-zinc-900 placeholder:text-zinc-400 focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent disabled:bg-zinc-50 disabled:text-zinc-500 transition-shadow duration-150"
                    />
                    <button
                      type="button"
                      onClick={() => setShowPassword(!showPassword)}
                      className="absolute right-1.5 top-1/2 -translate-y-1/2 w-8 h-8 flex items-center justify-center text-zinc-400 hover:text-zinc-600 cursor-pointer transition-colors duration-150 rounded"
                      tabIndex={-1}
                      aria-label={showPassword ? 'Hide password' : 'Show password'}
                    >
                      {showPassword ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
                    </button>
                  </div>
                </div>

                <button
                  type="submit"
                  disabled={loading}
                  className="w-full h-11 bg-zinc-900 hover:bg-zinc-800 disabled:opacity-50 disabled:pointer-events-none text-white rounded-lg font-medium text-sm transition-colors duration-150 cursor-pointer flex items-center justify-center gap-2"
                >
                  {loading ? (
                    <>
                      <svg className="animate-spin h-4 w-4" viewBox="0 0 24 24" fill="none">
                        <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                        <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
                      </svg>
                      Signing in...
                    </>
                  ) : (
                    'Sign in'
                  )}
                </button>

                {error && (
                  <p className="text-[13px] text-red-600 text-center">{error}</p>
                )}
              </motion.form>
            ) : (
              <motion.form
                key="reset"
                onSubmit={handleReset}
                className="px-6 sm:px-8 pb-7 sm:pb-8 pt-4 space-y-4"
                initial={{ opacity: 0, x: 8 }}
                animate={{ opacity: 1, x: 0 }}
                exit={{ opacity: 0, x: -8 }}
                transition={{ duration: 0.15 }}
              >
                {resetSuccess ? (
                  <div className="space-y-4">
                    <div className="rounded-lg bg-green-50 border border-green-200 px-4 py-3 text-sm text-green-700 text-center">
                      Password reset successfully. You can now sign in with your new password.
                    </div>
                    <button
                      type="button"
                      onClick={handleBackToLogin}
                      className="w-full h-11 bg-zinc-900 hover:bg-zinc-800 text-white rounded-lg font-medium text-sm transition-colors duration-150 cursor-pointer"
                    >
                      Back to sign in
                    </button>
                  </div>
                ) : (
                  <>
                    <div className="space-y-1.5">
                      <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider">
                        Email
                      </label>
                      <input
                        type="email"
                        autoComplete="email"
                        value={resetEmail}
                        onChange={(e) => setResetEmail(e.target.value)}
                        required
                        disabled={resetLoading}
                        placeholder="you@company.com"
                        className="w-full h-10 border border-zinc-300 rounded-lg px-3 text-sm text-zinc-900 placeholder:text-zinc-400 focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent disabled:bg-zinc-50 disabled:text-zinc-500 transition-shadow duration-150"
                      />
                    </div>

                    <div className="space-y-1.5">
                      <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider">
                        New Password
                      </label>
                      <div className="relative">
                        <input
                          type={showResetPassword ? 'text' : 'password'}
                          autoComplete="new-password"
                          value={resetPassword}
                          onChange={(e) => setResetPassword(e.target.value)}
                          required
                          disabled={resetLoading}
                          placeholder="Min. 6 characters"
                          className="w-full h-10 border border-zinc-300 rounded-lg px-3 pr-10 text-sm text-zinc-900 placeholder:text-zinc-400 focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent disabled:bg-zinc-50 disabled:text-zinc-500 transition-shadow duration-150"
                        />
                        <button
                          type="button"
                          onClick={() => setShowResetPassword(!showResetPassword)}
                          className="absolute right-1.5 top-1/2 -translate-y-1/2 w-8 h-8 flex items-center justify-center text-zinc-400 hover:text-zinc-600 cursor-pointer transition-colors duration-150 rounded"
                          tabIndex={-1}
                        >
                          {showResetPassword ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
                        </button>
                      </div>
                    </div>

                    <div className="space-y-1.5">
                      <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider">
                        Confirm Password
                      </label>
                      <input
                        type={showResetPassword ? 'text' : 'password'}
                        autoComplete="new-password"
                        value={resetConfirm}
                        onChange={(e) => setResetConfirm(e.target.value)}
                        required
                        disabled={resetLoading}
                        placeholder="Re-enter new password"
                        className="w-full h-10 border border-zinc-300 rounded-lg px-3 text-sm text-zinc-900 placeholder:text-zinc-400 focus:outline-none focus:ring-2 focus:ring-zinc-400 focus:border-transparent disabled:bg-zinc-50 disabled:text-zinc-500 transition-shadow duration-150"
                      />
                    </div>

                    {resetError && (
                      <p className="text-[13px] text-red-600 text-center">{resetError}</p>
                    )}

                    <button
                      type="submit"
                      disabled={resetLoading}
                      className="w-full h-11 bg-zinc-900 hover:bg-zinc-800 disabled:opacity-50 disabled:pointer-events-none text-white rounded-lg font-medium text-sm transition-colors duration-150 cursor-pointer flex items-center justify-center gap-2"
                    >
                      {resetLoading ? (
                        <>
                          <svg className="animate-spin h-4 w-4" viewBox="0 0 24 24" fill="none">
                            <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                            <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
                          </svg>
                          Resetting...
                        </>
                      ) : (
                        'Reset Password'
                      )}
                    </button>

                    <button
                      type="button"
                      onClick={handleBackToLogin}
                      className="w-full text-center text-[12px] text-zinc-400 hover:text-zinc-600 transition-colors duration-150 cursor-pointer"
                    >
                      Back to sign in
                    </button>
                  </>
                )}
              </motion.form>
            )}
          </AnimatePresence>
        </div>
      </motion.div>
    </div>
  );
};

export default LoginPage;
