---
description: "|"
mode: subagent
imported_from: external
---
# Feature-Sliced Design Architecture

Frontend architecture methodology organizing code by **business domain** rather than technical role, with strict layer hierarchy and import rules.

> **Docs:** [feature-sliced.design](https://feature-sliced.design) | **GitHub:** [feature-sliced](https://github.com/feature-sliced) | **Examples:** [feature-sliced/examples](https://github.com/feature-sliced/examples)

## THE IMPORT RULE (Critical)

**Modules can ONLY import from layers strictly below them. Never sideways or upward.**

```
app → pages → widgets → features → entities → shared
```

| Violation | Example | Fix |
|-----------|---------|-----|
| Cross-slice (same layer) | `features/auth` → `features/user` | Extract to `entities/` or `shared/` |
| Upward import | `entities/user` → `features/auth` | Move shared code down |
| Shared importing up | `shared/` → `entities/` | Shared has NO internal deps |

**Exception:** `app/` and `shared/` have no slices — internal cross-imports allowed within them.

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

## Placement Decisions

**Where does this code go?**

| Code type | Layer |
|-----------|-------|
| App-wide config, providers, routing | `app/` |
| Full page / route component | `pages/` |
| Complex reusable UI block | `widgets/` |
| User action with business value | `features/` |
| Business domain object (data model) | `entities/` |
| Reusable, domain-agnostic code | `shared/` |

**Entity vs Feature:** Entities = THINGS with identity (`user`, `product`). Features = ACTIONS with side effects (`auth`, `add-to-cart`).

**Segments within a slice:** `ui/` (components), `api/` (data fetching), `model/` (types/stores/logic), `lib/` (utilities), `config/` (flags/constants). Use purpose-driven names, not essence-based (`hooks/`, `types/`).

## Directory Structure

```
src/
├── app/            # providers/, routes/, styles/
├── pages/{name}/   # ui/, api/, model/, index.ts
├── widgets/{name}/ # ui/, index.ts
├── features/{name}/# ui/, api/, model/, index.ts
├── entities/{name}/# ui/, api/, model/, index.ts
└── shared/         # ui/, api/, lib/, config/, routes/, i18n/
```

Every slice exposes a public API via `index.ts`. External code imports ONLY from this file.

## Public API Pattern

```typescript
// entities/user/index.ts — explicit named exports only
export { UserCard, UserAvatar } from './ui/UserCard';
export { getUser, updateUser } from './api/userApi';
export type { User, UserRole } from './model/types';

// ✅ import { UserCard } from '@/entities/user';
// ❌ import { UserCard } from '@/entities/user/ui/UserCard';
// ❌ export * from './ui';  — exposes internals, harms tree-shaking
```

## Cross-Entity References (@x Notation)

When entities legitimately reference each other, expose a targeted sub-API:

```typescript
// entities/product/@x/order.ts
export type { ProductId } from '../model/types';

// entities/order/model/types.ts
import type { ProductId } from '@/entities/product/@x/order';
```

Keep cross-imports minimal. Consider merging entities if references are extensive.

## Anti-Patterns

| Anti-Pattern | Fix |
|--------------|-----|
| Cross-slice import (`features/a` → `features/b`) | Extract shared logic down |
| Generic segments (`components/`, `hooks/`) | Use `ui/`, `lib/`, `model/` |
| Wildcard exports (`export * from './button'`) | Explicit named exports |
| Business logic in `shared/lib` | Move to `entities/` |
| Single-use widget | Keep in page slice |
| Import from internal paths | Always use `index.ts` |
| All interactions as features | Only reused actions are features |

## TypeScript Path Aliases

```json
{ "compilerOptions": { "baseUrl": ".", "paths": { "@/*": ["./src/*"] } } }
```

## Reference Docs

| File | Purpose |
|------|---------|
| [feature-slicing-skill/layers.md](feature-slicing-skill/layers.md) | Complete layer specs, flowcharts |
| [feature-slicing-skill/public-api.md](feature-slicing-skill/public-api.md) | Export patterns, @x notation, tree-shaking |
| [feature-slicing-skill/implementation.md](feature-slicing-skill/implementation.md) | Code patterns: entities, features, React Query |
| [feature-slicing-skill/nextjs.md](feature-slicing-skill/nextjs.md) | App Router integration, page re-exports |
| [feature-slicing-skill/migration.md](feature-slicing-skill/migration.md) | Incremental migration strategy |
| [feature-slicing-skill/cheatsheet.md](feature-slicing-skill/cheatsheet.md) | Quick reference, import matrix |
