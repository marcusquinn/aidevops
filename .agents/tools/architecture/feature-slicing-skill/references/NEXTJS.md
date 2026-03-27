# FSD with Next.js Integration

> **Source:** [Official Next.js Guide](https://feature-sliced.design/docs/guides/tech/with-nextjs) | [FSD Pure Next.js Template](https://github.com/yunglocokid/FSD-Pure-Next.js-Template)

## The Challenge

FSD conflicts with Next.js's built-in `app/` and `pages/` folders. Solution: place the App Router in `src/app/` — Next.js ignores `src/app/` if root `app/` exists. This directory serves as both Next.js routing AND the FSD app layer. Re-export page components from FSD `pages/` layer.

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
│   │   │   └── [id]/page.tsx
│   │   ├── login/page.tsx
│   │   ├── api/              # API routes
│   │   ├── providers/index.tsx
│   │   └── styles/globals.css
│   ├── pages/                # FSD pages layer (NOT Next.js routing)
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

export function HomePage() {
  return (
    <>
      <Header />
      <main><FeaturedProducts /></main>
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
      <body><Providers>{children}</Providers></body>
    </html>
  );
}

// src/app/providers/index.tsx
'use client';

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

export default async function Page({ params }: { params: { id: string } }) {
  const product = await getProductById(params.id);
  return <ProductDetailPage product={product} />;
}

export async function generateStaticParams() {
  const products = await getProducts();
  return products.map((p) => ({ id: p.id }));
}
```

### Server Actions in Features

```typescript
// src/features/auth/api/actions.ts — 'use server'
export async function loginAction(formData: FormData) {
  const result = loginSchema.safeParse({
    email: formData.get('email'),
    password: formData.get('password'),
  });
  if (!result.success) return { errors: result.error.flatten().fieldErrors };

  const response = await fetch(`${process.env.API_URL}/auth/login`, {
    method: 'POST',
    body: JSON.stringify(result.data),
    headers: { 'Content-Type': 'application/json' },
  });
  if (!response.ok) return { errors: { form: ['Invalid credentials'] } };

  const { token } = await response.json();
  cookies().set('token', token, { httpOnly: true, secure: true });
  redirect('/dashboard');
}
```

---

## TypeScript Configuration

```json
{
  "compilerOptions": {
    "baseUrl": ".",
    "paths": { "@/*": ["./src/*"] }
  }
}
```

---

## API Routes

FSD is frontend-focused. Two options for API routes:

- **Option 1:** Keep in `src/app/api/` (route handlers alongside pages)
- **Option 2:** Separate backend package in a monorepo (`packages/frontend` + `packages/backend`)

---

## Database Queries

Keep database logic in `shared/db/`:

```typescript
// shared/db/client.ts
export const db = drizzle(postgres(process.env.DATABASE_URL!));

// shared/db/queries/products.ts
export async function getProductById(id: string) {
  return db.select().from(products).where(eq(products.id, id)).limit(1);
}

// entities/product/api/productApi.ts
export async function getProductById(id: string) {
  const [row] = await dbGetProduct(id);
  return row ? mapProductRow(row) : null;
}
```

---

## Middleware

```typescript
// middleware.ts (root)
export function middleware(request: NextRequest) {
  const token = request.cookies.get('token')?.value;
  const isProtected = request.nextUrl.pathname.startsWith('/dashboard');
  const isAuthPage = request.nextUrl.pathname.startsWith('/login');

  if (isProtected && !token) return NextResponse.redirect(new URL('/login', request.url));
  if (isAuthPage && token) return NextResponse.redirect(new URL('/dashboard', request.url));
  return NextResponse.next();
}

export const config = { matcher: ['/dashboard/:path*', '/login'] };
```

---

## Common Patterns

```typescript
// Loading state: src/app/products/loading.tsx
export default function Loading() { return <ProductListSkeleton />; }

// Error boundary: src/app/products/error.tsx — 'use client'
export default function Error({ error, reset }: { error: Error; reset: () => void }) {
  return <div><h2>Something went wrong!</h2><p>{error.message}</p><Button onClick={reset}>Try again</Button></div>;
}

// Not found: src/app/products/[id]/not-found.tsx
export default function NotFound() {
  return <div><h2>Product Not Found</h2><Link href="/products">Back to Products</Link></div>;
}
```

---

## Best Practices

1. **Keep Next.js routes thin** — only re-exports and data fetching
2. **All UI logic in FSD layers** — components, state, business logic
3. **Use path aliases** — `@/*` for clean cross-layer imports
4. **Server Components default** — add `'use client'` only when needed
5. **Colocate server actions** — in feature's `api/` segment with `'use server'`
6. **Shared DB queries** — keep database logic in `shared/db/`
7. **Middleware at root** — authentication, redirects, headers

---

## Resources

| Resource | Link |
|----------|------|
| Official Guide | [feature-sliced.design/docs/guides/tech/with-nextjs](https://feature-sliced.design/docs/guides/tech/with-nextjs) |
| FSD Pure Template | [github.com/yunglocokid/FSD-Pure-Next.js-Template](https://github.com/yunglocokid/FSD-Pure-Next.js-Template) |
| i18n Example | [github.com/nikolay-malygin/i18n-Next.js-14-FSD](https://github.com/nikolay-malygin/i18n-Next.js-14-FSD) |
| App Router Guide | [dev.to/m_midas](https://dev.to/m_midas/how-to-deal-with-nextjs-using-feature-sliced-design-4c67) |
