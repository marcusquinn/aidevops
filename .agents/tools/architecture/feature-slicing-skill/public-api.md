# FSD Public API Patterns

> **Source:** [Public API Reference](https://feature-sliced.design/docs/reference/public-api)

A public API is a **contract** between a slice and consuming code — an `index.ts` barrel file with explicit re-exports that controls what is accessible and how it can be imported.

## Three Goals

1. **Protection from structural changes** — shield consumers from internal refactoring
2. **Behavioral transparency** — significant changes reflect in the API
3. **Selective exposure** — only necessary parts exposed

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

```typescript
import { UserCard, type User } from '@/entities/user';
```

---

## Avoid Wildcard Exports

```typescript
// Don't — reduces discoverability, exposes internals, harms tree-shaking
export * from './ui';
export * from './api';
export * from './model';
```

---

## Segment-Level Public APIs

For large slices, define public APIs per segment:

```text
entities/user/
├── ui/
│   ├── UserCard.tsx
│   ├── UserAvatar.tsx
│   └── index.ts          # exports UserCard, UserAvatar
├── api/
│   └── index.ts
├── model/
│   └── index.ts
└── index.ts               # re-exports from ./ui, ./api, ./model
```

```typescript
// entities/user/ui/index.ts
export { UserCard } from './UserCard';
export { UserAvatar } from './UserAvatar';

// entities/user/index.ts — wildcard OK here (segment indices are curated)
export * from './ui';
export * from './api';
export * from './model';
```

---

## Cross-Imports with @x Notation

> [Official @x Documentation](https://feature-sliced.design/docs/reference/public-api#public-api-for-cross-imports)

When entities legitimately reference each other, expose a scoped API via `@x/`:

```text
entities/
├── song/
│   ├── @x/
│   │   └── artist.ts      # exports only what artist needs
│   ├── model/types.ts
│   └── index.ts
└── artist/
    ├── model/types.ts
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

**Rules:** Keep cross-imports minimal. Document why. Consider merging if references are extensive. Use only on Entities layer.

---

## Circular Imports

```typescript
// Within a slice — use relative imports, NOT the barrel
import { UserCard } from '../ui/UserCard';   // correct
import { UserCard } from '../index';          // circular
```

External consumers use the public API (`@/entities/user`).

---

## Tree-Shaking Optimization

For large shared UI libraries, split into component-level indices:

```text
shared/ui/
├── Button/
│   ├── Button.tsx
│   └── index.ts
├── Input/
│   └── index.ts
├── Modal/
│   └── index.ts
└── index.ts
```

```typescript
import { Button, Input } from '@/shared/ui';       // standard
import { Button } from '@/shared/ui/Button';        // granular
```

---

## Index File Challenges

| Problem | Solution |
|---------|----------|
| Circular imports (internal files reimporting from index) | Use relative imports within slices |
| Tree-shaking failures (unrelated utilities bundled) | Separate indices per component in `shared/` |
| Weak enforcement (nothing prevents direct imports) | Review imports during code review |
| Performance degradation (too many indices slow dev servers) | Consider monorepo for very large projects |

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

export function ProductCard({ product, onSelect }: {
  product: Product;
  onSelect?: (product: Product) => void;
}) {
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
// entities/product/index.ts — the public API
export { ProductCard } from './ui/ProductCard';
export { getProducts, getProductById } from './api/productApi';
export type { Product, ProductFilters } from './model/types';
export { productSchema } from './model/schema';
```
