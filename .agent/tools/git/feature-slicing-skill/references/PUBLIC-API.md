# FSD Public API Patterns

> **Source:** [Public API Reference](https://feature-sliced.design/docs/reference/public-api)

## What is a Public API?

A public API is a **contract** between a slice and consuming code. It controls which objects are accessible and how they can be imported.

**Implementation:** An `index.ts` barrel file with explicit re-exports.

---

## Three Goals of Quality Public APIs

1. **Protection from structural changes** — Shield consumers from internal refactoring
2. **Behavioral transparency** — Significant changes reflect in the API
3. **Selective exposure** — Only necessary parts exposed

---

## Basic Pattern

```typescript
// entities/user/index.ts
export { UserCard } from './ui/UserCard';
export { UserAvatar } from './ui/UserAvatar';
export { getUser, updateUser } from './api/userApi';
export type { User, UserRole } from './model/types';
export { userSchema } from './model/schema';
```

**Usage:**
```typescript
import { UserCard, type User } from '@/entities/user';
```

---

## Avoid Wildcard Exports

**Don't do this:**
```typescript
export * from './ui';
export * from './api';
export * from './model';
```

**Problems:**
- Reduces discoverability
- Accidentally exposes internals
- Complicates refactoring
- Harms tree-shaking

---

## Segment-Level Public APIs

For large slices, define public APIs per segment:

```
entities/user/
├── ui/
│   ├── UserCard.tsx
│   ├── UserAvatar.tsx
│   └── index.ts
├── api/
│   ├── userApi.ts
│   └── index.ts
├── model/
│   ├── types.ts
│   ├── schema.ts
│   └── index.ts
└── index.ts
```

```typescript
// entities/user/ui/index.ts
export { UserCard } from './UserCard';
export { UserAvatar } from './UserAvatar';

// entities/user/index.ts
export * from './ui';
export * from './api';
export * from './model';
```

---

## Cross-Imports with @x Notation

> [Official @x Documentation](https://feature-sliced.design/docs/reference/public-api#public-api-for-cross-imports)

When entities legitimately reference each other:

```
entities/
├── song/
│   ├── @x/
│   │   └── artist.ts
│   ├── model/
│   │   └── types.ts
│   └── index.ts
└── artist/
    ├── model/
    │   └── types.ts
    └── index.ts
```

```typescript
// entities/song/@x/artist.ts
export type { Song, SongId } from '../model/types';

// entities/artist/model/types.ts
import type { Song } from '@/entities/song/@x/artist';

export interface Artist {
  name: string;
  songs: Song[];
}
```

**Guidelines for @x:**
- Keep cross-imports minimal
- Document why the cross-reference exists
- Consider merging entities if references are extensive
- Use only on Entities layer

---

## Avoiding Circular Imports

**Problem:** Importing from index within a slice causes circulars.

```typescript
// ❌
import { UserCard } from '../index';

// ✅
import { UserCard } from '../ui/UserCard';
```

**Rule:** Within a slice, use relative imports. External consumers use the public API.

---

## Tree-Shaking Optimization

For large shared UI libraries, split into component-level indices:

```
shared/ui/
├── Button/
│   ├── Button.tsx
│   └── index.ts
├── Input/
│   ├── Input.tsx
│   └── index.ts
├── Modal/
│   ├── Modal.tsx
│   └── index.ts
└── index.ts
```

**Import patterns:**
```typescript
import { Button, Input } from '@/shared/ui';

import { Button } from '@/shared/ui/Button';
```

---

## Index File Challenges

**Four major issues:**

1. **Circular imports** — Internal files reimporting from index
2. **Tree-shaking failures** — Unrelated utilities bundled together
3. **Weak enforcement** — Nothing prevents direct imports technically
4. **Performance degradation** — Too many indices slow dev servers

**Solutions:**
- Use relative imports within slices
- Create separate indices per component in `shared/`
- Review imports during code review
- Consider monorepo for very large projects

---

## Complete Example

```typescript
// entities/product/model/types.ts
export interface Product {
  id: string;
  name: string;
  price: number;
  imageUrl: string;
  category: string;
}

export interface ProductFilters {
  category?: string;
  minPrice?: number;
  maxPrice?: number;
}
```

```typescript
// entities/product/model/schema.ts
import { z } from 'zod';

export const productSchema = z.object({
  id: z.string(),
  name: z.string().min(1),
  price: z.number().positive(),
  imageUrl: z.string().url(),
  category: z.string(),
});
```

```typescript
// entities/product/api/productApi.ts
import { apiClient } from '@/shared/api';
import type { Product, ProductFilters } from '../model/types';

export async function getProducts(filters?: ProductFilters): Promise<Product[]> {
  const { data } = await apiClient.get('/products', { params: filters });
  return data;
}

export async function getProductById(id: string): Promise<Product> {
  const { data } = await apiClient.get(`/products/${id}`);
  return data;
}
```

```tsx
// entities/product/ui/ProductCard.tsx
import type { Product } from '../model/types';

interface ProductCardProps {
  product: Product;
  onSelect?: (product: Product) => void;
}

export function ProductCard({ product, onSelect }: ProductCardProps) {
  return (
    <div onClick={() => onSelect?.(product)}>
      <img src={product.imageUrl} alt={product.name} />
      <h3>{product.name}</h3>
      <p>${product.price}</p>
    </div>
  );
}
```

```typescript
// entities/product/index.ts
export { ProductCard } from './ui/ProductCard';
export { getProducts, getProductById } from './api/productApi';
export type { Product, ProductFilters } from './model/types';
export { productSchema } from './model/schema';
```
