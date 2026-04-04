<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# FSD Implementation Patterns

Sources: [Tutorial](https://feature-sliced.design/docs/get-started/tutorial) | [Examples](https://github.com/feature-sliced/examples) | [Awesome FSD](https://github.com/feature-sliced/awesome)

> Layer rules and import constraints: [LAYERS.md](LAYERS.md). Public API barrel patterns: [PUBLIC-API.md](PUBLIC-API.md). File structure templates: [CHEATSHEET.md](CHEATSHEET.md).

## Segment Roles

| Segment | Contains | Key pattern |
|---------|----------|-------------|
| `model/types.ts` | Domain types + DTOs | Separate `User` (domain) from `UserDTO` (API shape) |
| `model/mapper.ts` | DTO-to-domain conversion | `mapUserDTO(dto: UserDTO): User` |
| `model/schema.ts` | Zod validation | `z.object({...})` + `z.infer<typeof schema>` |
| `model/store.ts` | Zustand state (features only) | `create<State>()(persist(...))` |
| `api/userApi.ts` | Fetch functions | Always apply mapper before returning |
| `api/queries.ts` | TanStack Query hooks | Query key factory + `useQuery` |
| `ui/*.tsx` | Components | Import types from `../model/types` |
| `index.ts` | Public API barrel | Explicit named exports only — no `export *` |

## Entity: User (canonical example)

```typescript
// entities/user/model/types.ts
export interface User { id: string; email: string; name: string; avatar?: string; role: UserRole; createdAt: Date; }
export type UserRole = 'admin' | 'user' | 'guest';
export interface UserDTO { id: number; email: string; name: string; avatar_url: string | null; role: string; created_at: string; }
```

```typescript
// entities/user/model/mapper.ts
import type { User, UserDTO, UserRole } from './types';
export function mapUserDTO(dto: UserDTO): User {
  return { id: String(dto.id), email: dto.email, name: dto.name, avatar: dto.avatar_url ?? undefined, role: dto.role as UserRole, createdAt: new Date(dto.created_at) };
}
```

```typescript
// entities/user/api/queries.ts — TanStack Query key factory pattern
import { useQuery } from '@tanstack/react-query';
import { getCurrentUser, getUserById } from './userApi';

export const userKeys = {
  all: ['users'] as const,
  current: () => [...userKeys.all, 'current'] as const,
  detail: (id: string) => [...userKeys.all, 'detail', id] as const,
};

export function useCurrentUser() { return useQuery({ queryKey: userKeys.current(), queryFn: getCurrentUser }); }
export function useUser(id: string) { return useQuery({ queryKey: userKeys.detail(id), queryFn: () => getUserById(id), enabled: !!id }); }
```

```typescript
// entities/user/index.ts — barrel (public API)
export { UserAvatar } from './ui/UserAvatar';
export { getCurrentUser, getUserById } from './api/userApi';
export { useCurrentUser, useUser, userKeys } from './api/queries';
export type { User, UserRole, UserDTO } from './model/types';
export { mapUserDTO } from './model/mapper';
export { userSchema, type UserFormData } from './model/schema';
```

## Feature: Authentication

```typescript
// features/auth/model/store.ts — Zustand with persistence
import { create } from 'zustand';
import { persist } from 'zustand/middleware';
import type { User } from '@/entities/user';
import type { AuthTokens } from './types';

export const useAuthStore = create<{ user: User | null; tokens: AuthTokens | null; isAuthenticated: boolean; setAuth: (u: User, t: AuthTokens) => void; clearAuth: () => void; }>()(
  persist(
    (set) => ({
      user: null, tokens: null, isAuthenticated: false,
      setAuth: (user, tokens) => set({ user, tokens, isAuthenticated: true }),
      clearAuth: () => set({ user: null, tokens: null, isAuthenticated: false }),
    }),
    { name: 'auth-storage' }
  )
);
```

```typescript
// features/auth/api/authApi.ts — imports mapUserDTO from entity
import { apiClient } from '@/shared/api';
import { mapUserDTO, type User, type UserDTO } from '@/entities/user';
import type { LoginCredentials, AuthTokens } from '../model/types';

interface AuthResponse { user: UserDTO; access_token: string; refresh_token: string; }

export async function login(credentials: LoginCredentials): Promise<{ user: User; tokens: AuthTokens }> {
  const { data } = await apiClient.post<AuthResponse>('/auth/login', credentials);
  return { user: mapUserDTO(data.user), tokens: { accessToken: data.access_token, refreshToken: data.refresh_token } };
}
export async function logout(): Promise<void> { await apiClient.post('/auth/logout'); }
```

```tsx
// features/auth/ui/LoginForm.tsx — react-hook-form + Zod
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { Button, Input } from '@/shared/ui';
import { login } from '../api/authApi';
import { useAuthStore } from '../model/store';

const loginSchema = z.object({ email: z.string().email(), password: z.string().min(8) });
type LoginFormData = z.infer<typeof loginSchema>;

export function LoginForm() {
  const setAuth = useAuthStore((s) => s.setAuth);
  const { register, handleSubmit, formState: { errors, isSubmitting } } = useForm<LoginFormData>({ resolver: zodResolver(loginSchema) });
  const onSubmit = async (data: LoginFormData) => { const { user, tokens } = await login(data); setAuth(user, tokens); };
  return (
    <form onSubmit={handleSubmit(onSubmit)} className="space-y-4">
      <Input {...register('email')} type="email" placeholder="Email" error={errors.email?.message} />
      <Input {...register('password')} type="password" placeholder="Password" error={errors.password?.message} />
      <Button type="submit" loading={isSubmitting}>Sign In</Button>
    </form>
  );
}
```

## Widget: Header

```tsx
// widgets/header/ui/Header.tsx
import { Link } from 'react-router-dom';
import { UserAvatar } from '@/entities/user';
import { LogoutButton, useAuthStore } from '@/features/auth';
import { SearchBox } from '@/features/search';
import { Logo } from '@/shared/ui';

export function Header() {
  const { user, isAuthenticated } = useAuthStore();
  return (
    <header className="flex items-center justify-between px-6 py-4 border-b">
      <Link to="/"><Logo /></Link>
      <SearchBox />
      <nav className="flex items-center gap-4">
        {isAuthenticated ? (<><UserAvatar user={user!} size="sm" /><LogoutButton /></>) : (<Link to="/login">Sign In</Link>)}
      </nav>
    </header>
  );
}
// widgets/header/index.ts
export { Header } from './ui/Header';
```

## Page: Product Detail

```tsx
// pages/product-detail/ui/ProductDetailPage.tsx
import { useLoaderData } from 'react-router-dom';
import { ProductCard, type Product } from '@/entities/product';
import { AddToCartButton } from '@/features/cart';
import { Header } from '@/widgets/header';

export function ProductDetailPage() {
  const { product } = useLoaderData() as { product: Product };
  return (<><Header /><main className="max-w-4xl mx-auto py-8"><ProductCard product={product} /><AddToCartButton productId={product.id} /></main></>);
}
// pages/product-detail/index.ts
export { ProductDetailPage } from './ui/ProductDetailPage';
export { productDetailLoader } from './api/loader';
```

## Shared: API Client

```typescript
// shared/api/client.ts
import axios from 'axios';

export const apiClient = axios.create({ baseURL: import.meta.env.VITE_API_URL, headers: { 'Content-Type': 'application/json' } });

// Auth interceptor — reads persisted tokens from zustand storage
apiClient.interceptors.request.use((config) => {
  const storage = localStorage.getItem('auth-storage');
  if (storage) { const { state } = JSON.parse(storage); if (state?.tokens?.accessToken) config.headers.Authorization = `Bearer ${state.tokens.accessToken}`; }
  return config;
});

// 401 interceptor — clears auth and redirects on token expiry
apiClient.interceptors.response.use(
  (response) => response,
  (error) => { if (error.response?.status === 401) { localStorage.removeItem('auth-storage'); window.location.href = '/login'; } return Promise.reject(error); }
);

// shared/api/index.ts
export { apiClient } from './client';
```

## App: Providers and Router

```tsx
// app/providers/index.tsx
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { ThemeProvider } from './ThemeProvider';

const queryClient = new QueryClient({ defaultOptions: { queries: { staleTime: 1000 * 60 * 5, retry: 1 } } });

export function Providers({ children }: { children: React.ReactNode }) {
  return <QueryClientProvider client={queryClient}><ThemeProvider>{children}</ThemeProvider></QueryClientProvider>;
}
```

```tsx
// app/routes/router.tsx
import { createBrowserRouter } from 'react-router-dom';
import { HomePage } from '@/pages/home';
import { ProductDetailPage, productDetailLoader } from '@/pages/product-detail';
import { LoginPage } from '@/pages/login';

export const router = createBrowserRouter([
  { path: '/', element: <HomePage /> },
  { path: '/products/:id', element: <ProductDetailPage />, loader: productDetailLoader },
  { path: '/login', element: <LoginPage /> },
]);
```

## TypeScript Path Aliases

```json
{ "compilerOptions": { "baseUrl": ".", "paths": { "@/*": ["./src/*"] } } }
```
