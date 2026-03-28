# FSD with Next.js Integration

> **Source:** [Official Next.js Guide](https://feature-sliced.design/docs/guides/tech/with-nextjs) | [FSD Pure Next.js Template](https://github.com/yunglocokid/FSD-Pure-Next.js-Template)

## The Challenge

FSD's flat slice architecture conflicts with Next.js's `app/` and `pages/` routing. Solution: `src/app/` serves as both the Next.js App Router and FSD app layer. Route files re-export page components from the FSD `pages/` layer.

**Core rules:** Thin route files (re-exports + data fetching only in `src/app/`). All UI/logic in FSD layers. Server Components by default (`'use client'` only when needed). Server actions in feature `api/` segments. DB in `shared/db/` exposed through entity APIs. Middleware at project root. Path aliases: `@/*` → `./src/*`.

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

FSD page components live in `src/pages/<name>/ui/<Name>.tsx` with a barrel export at `src/pages/<name>/index.ts`.

### Root Layout with Providers

```typescript
// src/app/layout.tsx — standard Next.js root layout
import { Providers } from './providers';
import './styles/globals.css';

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return <html lang="en"><body><Providers>{children}</Providers></body></html>;
}

// src/app/providers/index.tsx — 'use client'; wrap all context providers
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

### Server Actions

Colocate in the feature's `api/` segment with `'use server'`:

```typescript
// src/features/auth/api/actions.ts
'use server';
import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';
import { loginSchema } from '../model/schema';

export async function loginAction(formData: FormData) {
  const result = loginSchema.safeParse(Object.fromEntries(formData));
  if (!result.success) return { errors: result.error.flatten().fieldErrors };
  const res = await fetch(`${process.env.API_URL}/auth/login`, {
    method: 'POST', body: JSON.stringify(result.data),
    headers: { 'Content-Type': 'application/json' } });
  if (!res.ok) return { errors: { form: ['Invalid credentials'] } };
  cookies().set('token', (await res.json()).token, { httpOnly: true, secure: true });
  redirect('/dashboard');
}
```

---

## Pages Router (Next.js 12 — Legacy)

Next.js `pages/` at root (not `src/`), FSD pages in `src/pages/`. Same re-export pattern — `pages/_app.tsx` re-exports from `src/app/custom-app/`, route files re-export FSD page components. Data fetching (`getServerSideProps`/`getStaticProps`) stays in the route file:

```typescript
// pages/_app.tsx
export { CustomApp as default } from '@/app/custom-app';

// pages/products/[id].tsx
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

## API Routes, Database, and Middleware

**Path aliases** — `tsconfig.json`: `{ "compilerOptions": { "baseUrl": ".", "paths": { "@/*": ["./src/*"] } } }`

### API Routes

FSD is frontend-focused. Two options: (1) colocate in `src/app/api/` for simple projects, (2) separate backend package in a monorepo (`packages/frontend/` + `packages/backend/`).

### Database Queries

Keep DB logic in `shared/db/`, expose through entity APIs — never import DB directly in pages/widgets:

```typescript
// shared/db/queries/products.ts — raw DB access
export async function getAllProducts() { return db.select().from(products); }
export async function getProductById(id: string) {
  return db.select().from(products).where(eq(products.id, id)).limit(1);
}
// entities/product/api/productApi.ts — maps DB rows to domain models
import { getAllProducts, getProductById as dbGetProduct } from '@/shared/db/queries/products';
import { mapProductRow } from '../model/mapper';
export const getProducts = async () => (await getAllProducts()).map(mapProductRow);
export const getProductById = async (id: string) => {
  const [row] = await dbGetProduct(id); return row ? mapProductRow(row) : null;
};
```

### Middleware

Place at project root (`middleware.ts`). Standard auth redirect pattern:

```typescript
import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';
export function middleware(request: NextRequest) {
  const token = request.cookies.get('token')?.value;
  const isAuth = request.nextUrl.pathname.startsWith('/login');
  const isProtected = request.nextUrl.pathname.startsWith('/dashboard');
  if (isProtected && !token) return NextResponse.redirect(new URL('/login', request.url));
  if (isAuth && token) return NextResponse.redirect(new URL('/dashboard', request.url));
  return NextResponse.next();
}
export const config = { matcher: ['/dashboard/:path*', '/login'] };
```

---

## Next.js File Conventions in FSD

Use `loading.tsx`, `error.tsx`, `not-found.tsx` in `src/app/` route directories, importing skeletons/UI from FSD layers. Example: `src/app/products/loading.tsx` imports `ProductListSkeleton` from `@/widgets/product-list`. Same pattern for `error.tsx` (`'use client'` + `reset` prop, UI from `shared/ui`) and `not-found.tsx`.

---

## Resources

| Resource | Link |
|----------|------|
| Official Guide | [feature-sliced.design/docs/guides/tech/with-nextjs](https://feature-sliced.design/docs/guides/tech/with-nextjs) |
| FSD Pure Template | [github.com/yunglocokid/FSD-Pure-Next.js-Template](https://github.com/yunglocokid/FSD-Pure-Next.js-Template) |
| i18n Example | [github.com/nikolay-malygin/i18n-Next.js-14-FSD](https://github.com/nikolay-malygin/i18n-Next.js-14-FSD) |
| App Router Guide | [dev.to/m_midas](https://dev.to/m_midas/how-to-deal-with-nextjs-using-feature-sliced-design-4c67) |
