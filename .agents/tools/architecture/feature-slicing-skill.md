---
description: "|"
mode: subagent
imported_from: external
---

# Feature-Sliced Design Architecture

Frontend architecture organizing code by **business domain** with strict layer hierarchy and import rules.

> **Docs:** [feature-sliced.design](https://feature-sliced.design) | **GitHub:** [feature-sliced](https://github.com/feature-sliced) | **Examples:** [feature-sliced/examples](https://github.com/feature-sliced/examples)

## THE IMPORT RULE (Critical)

**Modules can ONLY import from layers strictly below them. Never sideways or upward.**

```
app → pages → widgets → features → entities → shared
 ↓      ↓        ↓          ↓          ↓         ✓
 ✓      ✓        ✓          ✓          ✓      (external only)
```

| Violation | Example | Fix |
|-----------|---------|-----|
| Cross-slice (same layer) | `features/auth` → `features/user` | Extract to `entities/` or `shared/` |
| Upward import | `entities/user` → `features/auth` | Move shared code down |
| Shared importing up | `shared/` → `entities/` | Shared has NO internal deps |

**Exception:** `app/` and `shared/` have no slices — internal cross-imports are allowed within them.

## Layer Hierarchy

| Layer | Purpose | Has Slices | Required |
|-------|---------|------------|----------|
| `app/` | Initialization, routing, providers, global styles | No | Yes |
| `pages/` | Route-based screens (one slice per route) | Yes | Yes |
| `widgets/` | Complex reusable UI blocks (header, sidebar) | Yes | No |
| `features/` | User interactions with business value (login, checkout) | Yes | No |
| `entities/` | Business domain models (user, product, order) | Yes | No |
| `shared/` | Project-agnostic infrastructure (UI kit, API client, utils) | No | Yes |

**Minimal setup:** `app/`, `pages/`, `shared/` — add other layers as complexity grows.

## Feature vs Entity

Entities = THINGS with identity (noun: `user`, `product`, `order`). Features = ACTIONS with side effects (verb: `auth`, `add-to-cart`, `checkout`).

## Segments (within a slice)

`ui/` (components, styles) | `api/` (backend calls, DTOs) | `model/` (types, schemas, stores) | `lib/` (slice utils) | `config/` (flags, constants). Use purpose-driven names — not `hooks/`, `types/`.

## Directory Structure

```
src/
├── app/                    # No slices: providers/, routes/, styles/
├── pages/{page}/           # ui/, api/, model/, index.ts
├── widgets/{widget}/       # ui/, index.ts
├── features/{feature}/     # ui/, api/, model/, index.ts
├── entities/{entity}/      # ui/, api/, model/, index.ts
└── shared/                 # No slices: ui/, api/, lib/, config/, routes/, i18n/
```

See [references/LAYERS.md](references/LAYERS.md) for full specifications.

## Public API Pattern

Every slice MUST expose a public API via `index.ts`. External code imports ONLY from this file.

```typescript
// entities/user/index.ts — explicit named exports (no wildcards)
export { UserCard } from './ui/UserCard';
export { UserAvatar } from './ui/UserAvatar';
export { getUser, updateUser } from './api/userApi';
export type { User, UserRole } from './model/types';
export { userSchema } from './model/schema';

// ✅ import { UserCard, type User } from '@/entities/user';
// ❌ import { UserCard } from '@/entities/user/ui/UserCard';
// ❌ export * from './ui';  — exposes internals, harms tree-shaking
```

## Cross-Entity References (@x Notation)

When entities must reference each other, use `@x/` for controlled cross-slice exports:

```typescript
// entities/product/@x/order.ts
export type { ProductId } from '../model/types';
// entities/order/model/types.ts
import type { ProductId } from '@/entities/product/@x/order';
```

Keep cross-imports minimal. Merge entities if references are extensive.

## Anti-Patterns

| Anti-Pattern | Problem | Fix |
|--------------|---------|-----|
| Cross-slice import | `features/a` → `features/b` | Extract shared logic down |
| Generic segments | `components/`, `hooks/` | Use `ui/`, `lib/`, `model/` |
| Wildcard exports | `export * from './button'` | Explicit named exports |
| Business logic in shared | Domain logic in `shared/lib` | Move to `entities/` |
| Single-use widgets | Widget used by one page | Keep in page slice |
| Skipping public API | Import from internal paths | Always use `index.ts` |
| Making everything a feature | All interactions as features | Only reused actions |

## TypeScript Configuration

```json
{ "compilerOptions": { "baseUrl": ".", "paths": { "@/*": ["./src/*"] } } }
```

## References

| File | Purpose |
|------|---------|
| [references/LAYERS.md](references/LAYERS.md) | Complete layer specifications, flowcharts |
| [references/PUBLIC-API.md](references/PUBLIC-API.md) | Export patterns, @x notation, tree-shaking |
| [references/IMPLEMENTATION.md](references/IMPLEMENTATION.md) | Code patterns: entities, features, React Query |
| [references/NEXTJS.md](references/NEXTJS.md) | App Router integration, page re-exports |
| [references/MIGRATION.md](references/MIGRATION.md) | Incremental migration strategy |
| [references/CHEATSHEET.md](references/CHEATSHEET.md) | Quick reference, import matrix |

- **Specification**: [feature-sliced.design/docs/reference](https://feature-sliced.design/docs/reference)
- **Awesome FSD**: [feature-sliced/awesome](https://github.com/feature-sliced/awesome) (curated articles, videos, tools)
