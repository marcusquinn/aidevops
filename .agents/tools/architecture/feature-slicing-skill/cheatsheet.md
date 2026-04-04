<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# FSD Quick Reference

> **Sources:** [Tutorial](https://feature-sliced.design/docs/get-started/tutorial) | [Layers](https://feature-sliced.design/docs/reference/layers) | [Slices & Segments](https://feature-sliced.design/docs/reference/slices-segments)

## Layer Hierarchy

```
app/      → Providers, routing, global styles       [NO slices, REQUIRED]
pages/    → Route screens, one slice per route      [HAS slices, REQUIRED]
widgets/  → Complex reusable UI blocks              [HAS slices, optional]
features/ → User interactions with business value   [HAS slices, optional]
entities/ → Business domain models                  [HAS slices, optional]
shared/   → Project-agnostic infrastructure         [NO slices, REQUIRED]
```

**Import Rule:** Only import from layers BELOW. Never sideways or up. Start with `app/`, `pages/`, `shared/` — add others as complexity grows.

---

## Import Matrix

|  | app | pages | widgets | features | entities | shared |
|--|-----|-------|---------|----------|----------|--------|
| **app** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **pages** | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ |
| **widgets** | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ |
| **features** | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ |
| **entities** | ❌ | ❌ | ❌ | ❌ | @x* | ✅ |
| **shared** | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |

*Use @x notation for cross-entity references

---

## Entity vs Feature

| Entity (noun) | Feature (verb) |
|---------------|----------------|
| `user` | `auth` (login/logout) |
| `product` | `add-to-cart` |
| `comment` | `write-comment` |
| `order` | `checkout` |

**Entities:** THINGS with identity. **Features:** ACTIONS with side effects.

## Segments

| Segment | Purpose | Examples |
|---------|---------|----------|
| `ui/` | Components, styles | `UserCard.tsx`, `Button.tsx` |
| `api/` | Backend calls, DTOs | `getUser()`, `createOrder()` |
| `model/` | Types, schemas, stores | `User`, `userSchema`, `useUserStore` |
| `lib/` | Slice utilities | `formatUserName()` |
| `config/` | Configuration | Feature flags, constants |

**Naming:** Use purpose-driven names (`api/`, `model/`) not essence-based (`hooks/`, `types/`).

## File Structure

| Layer | Key files |
|-------|-----------|
| `entities/{name}/` | `ui/{Name}Card.tsx`, `api/{name}Api.ts`, `api/queries.ts`, `model/types.ts`, `model/schema.ts`, `model/mapper.ts`, `index.ts` |
| `features/{name}/` | `ui/{Name}Form.tsx`, `ui/{Name}Button.tsx`, `api/{name}Api.ts`, `model/types.ts`, `model/schema.ts`, `model/store.ts`, `index.ts` |
| `pages/{name}/` | `ui/{Name}Page.tsx`, `api/loader.ts`, `model/schema.ts`, `index.ts` |

## Public API Pattern

```typescript
// entities/user/index.ts
export { UserCard } from './ui/UserCard';
export { getUser, updateUser } from './api/userApi';
export { useUser, useUsers } from './api/queries';
export type { User, UserRole } from './model/types';
export { userSchema } from './model/schema';
export { mapUserDTO } from './model/mapper';
```

```typescript
// ✅ import { UserCard, type User } from '@/entities/user';
// ❌ import { UserCard } from '@/entities/user/ui/UserCard';
```

## Cross-Entity References (@x)

```typescript
// entities/product/@x/order.ts
export type { ProductId } from '../model/types';

// entities/order/model/types.ts
import type { ProductId } from '@/entities/product/@x/order';
```

## TypeScript Path Aliases

```json
{ "compilerOptions": { "baseUrl": ".", "paths": { "@/*": ["./src/*"] } } }
```

## Anti-Patterns

| ❌ Don't | ✅ Do |
|----------|-------|
| Import from higher layer | Import from lower layers only |
| Cross-slice import (same layer) | Use lower layer or @x |
| Generic segments: `components/`, `hooks/` | Purpose segments: `ui/`, `lib/` |
| Wildcard exports: `export *` | Explicit exports |
| Business logic in `shared/` | Keep shared domain-agnostic |
| Single-use widgets | Keep in page slice |
| Everything is a feature | Only reused interactions |
| Import from internal paths | Always use `index.ts` |

---

## Resources

| Resource | Link |
|----------|------|
| Official Docs | [feature-sliced.design](https://feature-sliced.design) |
| Examples | [feature-sliced/examples](https://github.com/feature-sliced/examples) |
| Awesome FSD | [feature-sliced/awesome](https://github.com/feature-sliced/awesome) |
| v2.1 Notes | [Pages Come First!](https://github.com/feature-sliced/documentation/releases/tag/v2.1) |
