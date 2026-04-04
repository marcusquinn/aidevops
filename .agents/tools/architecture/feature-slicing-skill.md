---
description: Feature-Sliced Design Architecture — layer hierarchy, import rules, placement decisions
mode: subagent
imported_from: external
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
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

**Entity vs Feature:** Entities = THINGS with identity (`user`, `product`). Features = ACTIONS with side effects (`auth`, `add-to-cart`).

**Segments within a slice:** `ui/` (components), `api/` (data fetching), `model/` (types/stores/logic), `lib/` (utilities), `config/` (flags/constants). Use purpose-driven names, not essence-based (`hooks/`, `types/`).

**Public API:** Every slice exposes exports via `index.ts`. External code imports ONLY from this file — never from internal paths. See [public-api.md](feature-slicing-skill/public-api.md) for patterns and `@x` notation.

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

## Reference Docs

| File | Purpose |
|------|---------|
| [feature-slicing-skill/layers.md](feature-slicing-skill/layers.md) | Complete layer specs, directory structure, flowcharts |
| [feature-slicing-skill/public-api.md](feature-slicing-skill/public-api.md) | Export patterns, @x notation, tree-shaking |
| [feature-slicing-skill/implementation.md](feature-slicing-skill/implementation.md) | Code patterns: entities, features, React Query, TypeScript aliases |
| [feature-slicing-skill/nextjs.md](feature-slicing-skill/nextjs.md) | App Router integration, page re-exports |
| [feature-slicing-skill/migration.md](feature-slicing-skill/migration.md) | Incremental migration strategy |
| [feature-slicing-skill/cheatsheet.md](feature-slicing-skill/cheatsheet.md) | Quick reference, import matrix |
