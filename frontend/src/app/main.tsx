import { createRoot } from 'react-dom/client';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { TooltipProvider } from '../shared/ui/tooltip';
import { Toaster } from 'sonner';
import { AuthProvider } from '../core/auth/AuthContext';
import { PermissionsProvider } from '../core/auth/PermissionsContext';
import { ConfirmProvider } from '../shared/ui/confirm-dialog';
import '../index.css';
import App from './App';

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 60000,
      retry: 1,
      refetchOnWindowFocus: false,
    },
  },
});

createRoot(document.getElementById('root')!).render(
  <QueryClientProvider client={queryClient}>
    <TooltipProvider>
      <AuthProvider>
        <PermissionsProvider>
          <ConfirmProvider>
            <App />
            <Toaster position="top-right" richColors closeButton />
          </ConfirmProvider>
        </PermissionsProvider>
      </AuthProvider>
    </TooltipProvider>
  </QueryClientProvider>
);
