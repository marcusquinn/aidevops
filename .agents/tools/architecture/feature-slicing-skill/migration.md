# Migrating to Feature-Sliced Design

> **Source:** [Migration from Custom Architecture](https://feature-sliced.design/docs/guides/migration/from-custom) | [Migration from v2.0 to v2.1](https://feature-sliced.design/docs/guides/migration/from-v2-0) | [Community: Migrating a Legacy React Project](https://medium.com/@O5-25/migrating-a-legacy-react-project-to-feature-sliced-design-benefits-challenges-and-considerations-0aeecbc8b866)

## When to Migrate

Migrate if: project too large/interconnected, new features slow, onboarding hard, circular deps common, code ownership unclear. Skip if current architecture works.

## Phase 1: Setup (Incremental — migrate alongside existing code)

```bash
mkdir -p src/{app,pages,widgets,features,entities,shared}/{ui,api,model,lib}
```

**Path aliases** (`tsconfig.json`):

```json
{ "compilerOptions": { "baseUrl": ".", "paths": { "@/*": ["./src/*"], "@components/*": ["src/components/*"], "@hooks/*": ["src/hooks/*"] } } }
```

## Phase 2: Migrate Shared Utilities

```bash
mv src/utils/api.ts src/shared/api/client.ts
mv src/utils/dates.ts src/shared/lib/dates.ts
mv src/utils/validation.ts src/shared/lib/validation.ts
mv src/utils/constants.ts src/shared/config/constants.ts
mv src/hooks/*.ts src/shared/lib/

for component in src/components/*.tsx; do
  name=$(basename "$component" .tsx)
  mkdir -p "src/shared/ui/$name"
  mv "$component" "src/shared/ui/$name/$name.tsx"
  echo "export { $name } from './$name';" > "src/shared/ui/$name/index.ts"
done
```

Update imports:

```typescript
// Before
import { formatDate } from '@/utils/dates';
import { Button } from '@/components/Button';
// After
import { formatDate } from '@/shared/lib';
import { Button } from '@/shared/ui';
```

## Phase 3: Extract Entities

Entities = business domain objects (types, CRUD API calls, reusable domain UI).

```text
src/types/user.ts          → src/entities/user/model/types.ts
src/api/userApi.ts         → src/entities/user/api/userApi.ts
src/components/UserAvatar  → src/entities/user/ui/UserAvatar.tsx
src/store/userSlice.ts     → src/entities/user/model/store.ts
```

**Public API** (`entities/user/index.ts`):

```typescript
export { UserAvatar } from './ui/UserAvatar';
export { UserCard } from './ui/UserCard';
export { getUser, updateUser, deleteUser } from './api/userApi';
export type { User, UserRole } from './model/types';
export { useUserStore } from './model/store';
```

## Phase 4: Extract Features

Features = user interactions with business value (login, add-to-cart, search, form submit).

```text
src/components/LoginForm.tsx  → src/features/auth/ui/LoginForm.tsx
src/components/LogoutButton   → src/features/auth/ui/LogoutButton.tsx
src/api/authApi.ts            → src/features/auth/api/authApi.ts
src/store/authSlice.ts        → src/features/auth/model/store.ts
```

## Phase 5: Migrate Pages

```text
src/pages/Home.tsx          → src/pages/home/ui/HomePage.tsx + index.ts
src/pages/ProductList.tsx   → src/pages/products/ui/ProductsPage.tsx + index.ts
src/pages/ProductDetail.tsx → src/pages/product-detail/ui/ProductDetailPage.tsx + api/loader.ts + index.ts
```

```typescript
// Before: direct API call in page
import { fetchProduct } from '@/api/products';
import { AddToCartButton } from '@/components/AddToCartButton';

// After: compose from layers
import { useProduct } from '@/entities/product';
import { AddToCart } from '@/features/add-to-cart';
import { ProductReviews } from '@/widgets/product-reviews';
```

## Common Patterns

### Circular Dependencies

Extract shared dep to a lower layer; compose at page/widget level.

```typescript
// Before: UserCard ↔ useAuth circular
// After:
// entities/user/ui/UserCard.tsx — no auth dep
// features/auth/model/store.ts — no UserCard dep
// pages/profile/ui/ProfilePage.tsx — composes both
```

### Global State

Split monolithic store by domain into entity/feature models.

```typescript
// Before
export const store = configureStore({ reducer: { user, products, cart, auth } });
// After (Zustand)
// entities/user/model/store.ts | entities/product/model/store.ts
// features/cart/model/store.ts | features/auth/model/store.ts
```

### Mixed Business Logic in Components

Separate display (entity UI) from interaction (feature UI); compose in page/widget.

```typescript
// entities/product/ui/ProductCard.tsx — display only
export function ProductCard({ product, actions }) {
  return <div><img src={product.image} /><h3>{product.name}</h3>{actions}</div>;
}
// features/add-to-cart/ui/AddToCartButton.tsx — interaction only
export function AddToCartButton({ product }) {
  const addToCart = useCartStore((s) => s.addItem);
  return <button onClick={() => addToCart(product)}>Add to Cart</button>;
}
// Composed in page/widget:
<ProductCard product={product} actions={<AddToCartButton product={product} />} />
```

## Migration Checklist

- [ ] Create FSD directory structure
- [ ] Configure path aliases
- [ ] Migrate utilities → `shared/lib/`, `shared/api/`, `shared/ui/`
- [ ] Extract entities with public APIs
- [ ] Extract features with public APIs
- [ ] Migrate pages to page slices
- [ ] Extract reusable widgets
- [ ] Setup `app/` layer with providers
- [ ] Remove old directory structure
- [ ] Update documentation

## Rollback Strategy

Keep old path aliases (from Phase 1) active during migration; use feature flags to switch gradually.

```typescript
import { UserCard as LegacyUserCard } from '@components/UserCard';
import { UserCard as FSDUserCard } from '@/entities/user';
export const UserCard = process.env.USE_FSD ? FSDUserCard : LegacyUserCard;
```
