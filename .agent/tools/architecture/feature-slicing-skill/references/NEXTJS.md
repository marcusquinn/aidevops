# FSD with Next.js Integration

> **Source:** [Official Next.js Guide](https://feature-sliced.design/docs/guides/tech/with-nextjs) | [FSD Pure Next.js Template](https://github.com/yunglocokid/FSD-Pure-Next.js-Template)

## The Challenge

FSD conflicts with Next.js's built-in `app/` and `pages/` folders. Both expect specific file structures for routing. FSD uses flat slice architecture.

## Solution Overview

Place the Next.js App Router in `src/app/` (Next.js ignores `src/app/` if root `app/` exists). This directory serves double duty: Next.js routing AND the FSD app layer. Re-export page components from FSD `pages/` layer.

---

## App Router Setup (Next.js 13+)

### Directory Structure

```
project-root/
├── src/
│   ├── app/                  # Next.js App Router + FSD app layer
│   │   ├── layout.tsx        # Root layout with providers
│   │   ├── page.tsx          # Home → re-exports from pages/
│   │   ├── products/
│   │   │   ├── page.tsx
│   │   │   └── [id]/
│   │   │       └── page.tsx
│   │   ├── login/
│   │   │   └── page.tsx
│   │   ├── api/              # API routes
│   │   ├── providers/        # FSD: React context providers
│   │   │   └── index.tsx
│   │   └── styles/           # FSD: Global styles
│   │       └── globals.css
│   ├── pages/                # FSD pages layer (NOT Next.js)
│   │   ├── home/
│   │   ├── products/
│   │   ├── product-detail/
│   │   └── login/
│   ├── widgets/
│   ├── features/
│   ├── entities/
│   └── shared/
├── middleware.ts             # Next.js middleware (root)
└── next.config.js
```

### Page Re-Export Pattern

```typescript
// src/app/page.tsx
export { HomePage as default } from '@/pages/home';

// src/app/products/page.tsx
export { ProductsPage as default } from '@/pages/products';

// src/app/products/[id]/page.tsx
export { ProductDetailPage as default } from '@/pages/product-detail';
```

### FSD Page Implementation

```typescript
// src/pages/home/ui/HomePage.tsx
import { Header } from '@/widgets/header';
import { FeaturedProducts } from '@/widgets/featured-products';
import { HeroSection } from './HeroSection';

export function HomePage() {
  return (
    <>
      <Header />
      <main>
        <HeroSection />
        <FeaturedProducts />
      </main>
    </>
  );
}

// src/pages/home/index.ts
export { HomePage } from './ui/HomePage';
```

### Root Layout with Providers

```typescript
// src/app/layout.tsx
import { Providers } from './providers';
import './styles/globals.css';

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
```

```typescript
// src/app/providers/index.tsx
'use client';

import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { ThemeProvider } from 'next-themes';

const queryClient = new QueryClient();

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <QueryClientProvider client={queryClient}>
      <ThemeProvider attribute="class" defaultTheme="system">
        {children}
      </ThemeProvider>
    </QueryClientProvider>
  );
}
```

### Server Components with Data Fetching

```typescript
// src/app/products/[id]/page.tsx
import { ProductDetailPage } from '@/pages/product-detail';
import { getProductById } from '@/entities/product';

interface Props {
  params: { id: string };
}

export default async function Page({ params }: Props) {
  const product = await getProductById(params.id);
  return <ProductDetailPage product={product} />;
}

export async function generateStaticParams() {
  const products = await getProducts();
  return products.map((product) => ({ id: product.id }));
}
```

### Server Actions in Features

```typescript
// src/features/auth/api/actions.ts
'use server';

import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';
import { loginSchema } from '../model/schema';

export async function loginAction(formData: FormData) {
  const rawData = {
    email: formData.get('email'),
    password: formData.get('password'),
  };

  const result = loginSchema.safeParse(rawData);
  if (!result.success) {
    return { errors: result.error.flatten().fieldErrors };
  }

  const response = await fetch(`${process.env.API_URL}/auth/login`, {
    method: 'POST',
    body: JSON.stringify(result.data),
    headers: { 'Content-Type': 'application/json' },
  });

  if (!response.ok) {
    return { errors: { form: ['Invalid credentials'] } };
  }

  const { token } = await response.json();
  cookies().set('token', token, { httpOnly: true, secure: true });
  redirect('/dashboard');
}
```

---

## Pages Router Setup (Next.js 12)

### Directory Structure

```
project-root/
├── pages/                    # Next.js Pages Router (root)
│   ├── _app.tsx              # Custom App
│   ├── _document.tsx
│   ├── index.tsx             # Home → re-exports from src/pages
│   ├── products/
│   │   ├── index.tsx
│   │   └── [id].tsx
│   └── api/
├── src/
│   ├── app/
│   │   ├── custom-app/       # _app component
│   │   └── providers/
│   ├── pages/                # FSD pages layer
│   ├── widgets/
│   ├── features/
│   ├── entities/
│   └── shared/
└── next.config.js
```

### Custom App Component

```typescript
// pages/_app.tsx
export { CustomApp as default } from '@/app/custom-app';

// src/app/custom-app/CustomApp.tsx
import type { AppProps } from 'next/app';
import { Providers } from '../providers';
import '../styles/globals.css';

export function CustomApp({ Component, pageProps }: AppProps) {
  return (
    <Providers>
      <Component {...pageProps} />
    </Providers>
  );
}
```

### Page with getServerSideProps

```typescript
// pages/products/[id].tsx
import { ProductDetailPage } from '@/pages/product-detail';
import { getProductById } from '@/entities/product';
import type { GetServerSideProps } from 'next';

export default ProductDetailPage;

export const getServerSideProps: GetServerSideProps = async ({ params }) => {
  const product = await getProductById(params?.id as string);

  if (!product) {
    return { notFound: true };
  }

  return { props: { product } };
};
```

---

## TypeScript Configuration

```json
// tsconfig.json
{
  "compilerOptions": {
    "baseUrl": ".",
    "paths": {
      "@/*": ["./src/*"]
    }
  }
}
```

---

## API Routes

FSD is frontend-focused. For API routes:

### Option 1: Keep in `src/app/api/`

```
src/app/
├── api/
│   ├── auth/
│   │   └── route.ts
│   └── products/
│       └── route.ts
```

### Option 2: Separate Backend (Monorepo)

```
packages/
├── frontend/          # Next.js + FSD
│   └── src/
│       ├── app/
│       ├── pages/     # FSD pages
│       └── ...
└── backend/           # Express/Fastify
    └── src/
        └── routes/
```

---

## Database Queries

Keep database logic in `shared/db/`:

```typescript
// shared/db/client.ts
import { drizzle } from 'drizzle-orm/postgres-js';
import postgres from 'postgres';

const client = postgres(process.env.DATABASE_URL!);
export const db = drizzle(client);
```

```typescript
// shared/db/queries/products.ts
import { db } from '../client';
import { products } from '../schema';
import { eq } from 'drizzle-orm';

export async function getAllProducts() {
  return db.select().from(products);
}

export async function getProductById(id: string) {
  return db.select().from(products).where(eq(products.id, id)).limit(1);
}
```

```typescript
// entities/product/api/productApi.ts
import { getAllProducts, getProductById as dbGetProduct } from '@/shared/db/queries/products';
import { mapProductRow } from '../model/mapper';

export async function getProducts() {
  const rows = await getAllProducts();
  return rows.map(mapProductRow);
}

export async function getProductById(id: string) {
  const [row] = await dbGetProduct(id);
  return row ? mapProductRow(row) : null;
}
```

---

## Middleware

```typescript
// middleware.ts
import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';

export function middleware(request: NextRequest) {
  const token = request.cookies.get('token')?.value;
  const isAuthPage = request.nextUrl.pathname.startsWith('/login');
  const isProtected = request.nextUrl.pathname.startsWith('/dashboard');

  if (isProtected && !token) {
    return NextResponse.redirect(new URL('/login', request.url));
  }

  if (isAuthPage && token) {
    return NextResponse.redirect(new URL('/dashboard', request.url));
  }

  return NextResponse.next();
}

export const config = {
  matcher: ['/dashboard/:path*', '/login'],
};
```

---

## Common Patterns

### Loading States

```typescript
// src/app/products/loading.tsx
import { ProductListSkeleton } from '@/widgets/product-list';

export default function Loading() {
  return <ProductListSkeleton />;
}
```

### Error Boundaries

```typescript
// src/app/products/error.tsx
'use client';

import { Button } from '@/shared/ui';

export default function Error({
  error,
  reset,
}: {
  error: Error;
  reset: () => void;
}) {
  return (
    <div className="flex flex-col items-center justify-center min-h-screen">
      <h2 className="text-xl font-bold mb-4">Something went wrong!</h2>
      <p className="text-gray-600 mb-4">{error.message}</p>
      <Button onClick={reset}>Try again</Button>
    </div>
  );
}
```

### Not Found

```typescript
// src/app/products/[id]/not-found.tsx
import Link from 'next/link';

export default function NotFound() {
  return (
    <div className="flex flex-col items-center justify-center min-h-screen">
      <h2 className="text-xl font-bold mb-4">Product Not Found</h2>
      <Link href="/products" className="text-blue-600 hover:underline">
        Back to Products
      </Link>
    </div>
  );
}
```

---

## Best Practices

1. **Keep Next.js routes thin** — Only re-exports and data fetching
2. **All UI logic in FSD layers** — Components, state, business logic
3. **Use path aliases** — Clean imports across layers
4. **Server Components default** — Add `'use client'` only when needed
5. **Colocate server actions** — In feature's `api/` segment with `'use server'`
6. **Shared DB queries** — Keep database logic in `shared/db/`
7. **Middleware at root** — Authentication, redirects, headers

---

## Resources

| Resource | Link |
|----------|------|
| Official Guide | [feature-sliced.design/docs/guides/tech/with-nextjs](https://feature-sliced.design/docs/guides/tech/with-nextjs) |
| FSD Pure Template | [github.com/yunglocokid/FSD-Pure-Next.js-Template](https://github.com/yunglocokid/FSD-Pure-Next.js-Template) |
| i18n Example | [github.com/nikolay-malygin/i18n-Next.js-14-FSD](https://github.com/nikolay-malygin/i18n-Next.js-14-FSD) |
| App Router Guide | [dev.to/m_midas](https://dev.to/m_midas/how-to-deal-with-nextjs-using-feature-sliced-design-4c67) |
