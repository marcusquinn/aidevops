# FSD with Next.js Integration

> **Source:** [Official Next.js Guide](https://feature-sliced.design/docs/guides/tech/with-nextjs) | [FSD Pure Next.js Template](https://github.com/yunglocokid/FSD-Pure-Next.js-Template)

## The Challenge

FSD's flat slice architecture conflicts with Next.js's `app/` and `pages/` routing conventions. The solution: use `src/app/` for Next.js App Router (Next.js ignores it when root `app/` exists), serving as both the routing layer AND the FSD app layer. Route files re-export page components from the FSD `pages/` layer.

---

## App Router Setup (Next.js 13+)

### Directory Structure

```text
src/
├── app/                  # Next.js App Router + FSD app layer
│   ├── layout.tsx        # Root layout with providers
│   ├── page.tsx          # Re-exports from pages/
│   ├── products/
│   │   ├── page.tsx
│   │   └── [id]/
│   │       └── page.tsx
│   ├── login/
│   │   └── page.tsx
│   ├── api/              # API routes
│   ├── providers/        # React context providers
│   │   └── index.tsx
│   └── styles/
│       └── globals.css
├── pages/                # FSD pages layer (NOT Next.js routing)
│   ├── home/
│   ├── products/
│   ├── product-detail/
│   └── login/
├── widgets/
├── features/
├── entities/
└── shared/
```

Middleware (`middleware.ts`) and `next.config.js` live at project root.

### Page Re-Export Pattern

Route files are thin — re-export only:

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

// src/pages/home/index.ts — public API barrel
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

// src/app/providers/index.tsx — wrap all context providers here
'use client';
export function Providers({ children }: { children: React.ReactNode }) {
  return <QueryClientProvider client={queryClient}>
    <ThemeProvider>{children}</ThemeProvider>
  </QueryClientProvider>;
}
```

### Server Components with Data Fetching

When a route needs server-side data, the `src/app/` file fetches and passes props:

```typescript
// src/app/products/[id]/page.tsx
import { ProductDetailPage } from '@/pages/product-detail';
import { getProductById } from '@/entities/product';

export default async function Page({ params }: { params: { id: string } }) {
  const product = await getProductById(params.id);
  return <ProductDetailPage product={product} />;
}

export async function generateStaticParams() {
  const products = await getProducts();
  return products.map((product) => ({ id: product.id }));
}
```

### Server Actions in Features

Colocate server actions in the feature's `api/` segment with `'use server'`:

```typescript
// src/features/auth/api/actions.ts
'use server';
import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';
import { loginSchema } from '../model/schema';

export async function loginAction(formData: FormData) {
  const result = loginSchema.safeParse(Object.fromEntries(formData));
  if (!result.success) return { errors: result.error.flatten().fieldErrors };

  const response = await fetch(`${process.env.API_URL}/auth/login`, {
    method: 'POST', body: JSON.stringify(result.data),
    headers: { 'Content-Type': 'application/json' },
  });
  if (!response.ok) return { errors: { form: ['Invalid credentials'] } };

  const { token } = await response.json();
  cookies().set('token', token, { httpOnly: true, secure: true });
  redirect('/dashboard');
}
```

---

## Pages Router (Next.js 12 — Legacy)

Key difference: Next.js `pages/` lives at root (not `src/`), FSD pages stay in `src/pages/`.

```text
pages/                    # Next.js Pages Router (root)
│   ├── _app.tsx          # → re-exports from src/app/custom-app
│   ├── index.tsx         # → re-exports from src/pages/home
│   └── products/[id].tsx
src/
│   ├── app/
│   │   ├── custom-app/   # _app component
│   │   └── providers/
│   ├── pages/            # FSD pages layer
│   ├── widgets/
│   ├── features/
│   ├── entities/
│   └── shared/
```

```typescript
// pages/_app.tsx — thin re-export
export { CustomApp as default } from '@/app/custom-app';

// pages/products/[id].tsx — data fetching stays in the route file
import { ProductDetailPage } from '@/pages/product-detail';
import { getProductById } from '@/entities/product';
import type { GetServerSideProps } from 'next';

export default ProductDetailPage;

export const getServerSideProps: GetServerSideProps = async ({ params }) => {
  const product = await getProductById(params?.id as string);
  if (!product) return { notFound: true };
  return { props: { product } };
};
```

---

## TypeScript Path Aliases

```json
// tsconfig.json
{ "compilerOptions": { "baseUrl": ".", "paths": { "@/*": ["./src/*"] } } }
```

---

## API Routes, Database, and Middleware

### API Routes

FSD is frontend-focused. Two options for API routes:

1. **Colocate in `src/app/api/`** — simple projects
2. **Separate backend package** — monorepo (`packages/frontend/` + `packages/backend/`)

### Database Queries

Keep database logic in `shared/db/`, expose through entity APIs — never import DB directly in pages/widgets:

```typescript
// shared/db/queries/products.ts — raw DB access
export async function getAllProducts() { return db.select().from(products); }
export async function getProductById(id: string) {
  return db.select().from(products).where(eq(products.id, id)).limit(1);
}

// entities/product/api/productApi.ts — maps DB rows to domain models
import { getAllProducts, getProductById as dbGetProduct } from '@/shared/db/queries/products';
import { mapProductRow } from '../model/mapper';

export async function getProducts() {
  return (await getAllProducts()).map(mapProductRow);
}
export async function getProductById(id: string) {
  const [row] = await dbGetProduct(id);
  return row ? mapProductRow(row) : null;
}
```

### Middleware

Place at project root. Standard pattern for auth redirects:

```typescript
// middleware.ts
import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';

export function middleware(request: NextRequest) {
  const token = request.cookies.get('token')?.value;
  const isAuthPage = request.nextUrl.pathname.startsWith('/login');
  const isProtected = request.nextUrl.pathname.startsWith('/dashboard');

  if (isProtected && !token) return NextResponse.redirect(new URL('/login', request.url));
  if (isAuthPage && token) return NextResponse.redirect(new URL('/dashboard', request.url));
  return NextResponse.next();
}

export const config = { matcher: ['/dashboard/:path*', '/login'] };
```

---

## Next.js File Conventions in FSD

Use standard Next.js file conventions (`loading.tsx`, `error.tsx`, `not-found.tsx`) in `src/app/` route directories, importing skeletons/UI from FSD layers:

```typescript
// src/app/products/loading.tsx
import { ProductListSkeleton } from '@/widgets/product-list';
export default function Loading() { return <ProductListSkeleton />; }
```

Same pattern for `error.tsx` (import error UI from `shared/ui`, use `'use client'` + `reset` prop) and `not-found.tsx` (import link/UI from shared).

---

## Key Rules

1. **Thin route files** — only re-exports and data fetching in `src/app/`
2. **All UI/logic in FSD layers** — components, state, business logic stay in `pages/widgets/features/entities/shared`
3. **Path aliases** — `@/*` for clean cross-layer imports
4. **Server Components by default** — add `'use client'` only when needed
5. **Colocate server actions** — in feature's `api/` segment with `'use server'`
6. **DB in `shared/db/`** — expose through entity APIs, never import directly in pages/widgets
7. **Middleware at root** — authentication, redirects, headers

---

## Resources

| Resource | Link |
|----------|------|
| Official Guide | [feature-sliced.design/docs/guides/tech/with-nextjs](https://feature-sliced.design/docs/guides/tech/with-nextjs) |
| FSD Pure Template | [github.com/yunglocokid/FSD-Pure-Next.js-Template](https://github.com/yunglocokid/FSD-Pure-Next.js-Template) |
| i18n Example | [github.com/nikolay-malygin/i18n-Next.js-14-FSD](https://github.com/nikolay-malygin/i18n-Next.js-14-FSD) |
| App Router Guide | [dev.to/m_midas](https://dev.to/m_midas/how-to-deal-with-nextjs-using-feature-sliced-design-4c67) |
