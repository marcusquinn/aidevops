# FSD Layers Reference

> **Source:** [Layers Reference](https://feature-sliced.design/docs/reference/layers) | [FSD Overview](https://feature-sliced.design/docs/get-started/overview)

## Layer Hierarchy

Arranged from highest to lowest responsibility. Each layer can only import from layers below it.

| Layer | Purpose | Has Slices | Required |
|-------|---------|------------|----------|
| `app/` | Application initialization, providers, routing | No | Yes |
| `pages/` | Route-based screens | Yes | Yes |
| `widgets/` | Complex reusable UI blocks | Yes | No |
| `features/` | User interactions with business value | Yes | No |
| `entities/` | Business domain models | Yes | No |
| `shared/` | Reusable infrastructure | No | Yes |

**Note:** `processes/` layer is DEPRECATED. Use pages with composition instead.

---

## Import Rule

```
app/      → can import: pages, widgets, features, entities, shared
pages/    → can import: widgets, features, entities, shared
widgets/  → can import: features, entities, shared
features/ → can import: entities, shared
entities/ → can import: shared (use @x for cross-entity)
shared/   → can import: external packages only
```

**Exception:** `app/` and `shared/` have no slices, so internal cross-segment imports are allowed.

---

## Layer Details

### Shared Layer

> [Shared Layer Docs](https://feature-sliced.design/docs/reference/layers#shared)

Foundation layer for external connections and utilities. **No business domain knowledge.**

**Segments:**
```
shared/
├── api/           # Backend client, request functions, interceptors
├── ui/            # Business-agnostic UI (buttons, inputs, modals)
├── lib/           # Focused utilities (dates, colors, validation)
├── config/        # Environment variables, feature flags
├── routes/        # Route path constants
├── i18n/          # Translation setup
└── types/         # Global TypeScript types (utility types)
```

**Guidelines:**
- Avoid generic names: `components/`, `hooks/`, `utils/`
- Use purpose-driven segment names
- Should be extractable to a separate package
- NO domain logic

**TypeScript Types:**
- Utility types → `shared/lib/utility-types`
- DTOs → `shared/api` near request functions
- Avoid generic `shared/types` folder

---

### Entities Layer

> [Entities Layer Docs](https://feature-sliced.design/docs/reference/layers#entities)

Real-world business concepts the application works with.

**Structure:**
```
entities/
├── user/
│   ├── ui/           # UserAvatar, UserCard, UserBadge
│   ├── api/          # getUser, updateUser, queries
│   ├── model/        # User types, validation, store
│   ├── lib/          # formatUserName, calculateAge
│   └── index.ts      # Public API
├── product/
│   ├── ui/
│   ├── api/
│   ├── model/
│   └── index.ts
└── order/
    └── ...
```

**What belongs here:**
- Data models and TypeScript interfaces
- API functions for CRUD operations
- Reusable UI representations
- Validation schemas (Zod, Yup)
- Entity-specific mappers (DTO → Domain)

**What doesn't belong:**
- User interactions (→ features)
- Page layouts (→ pages)
- Composed UI blocks (→ widgets)

**Cross-Entity References (@x Notation):**

> [Cross-Imports @x Notation](https://feature-sliced.design/docs/reference/public-api#public-api-for-cross-imports)

When entities must reference each other:

```
entities/
├── product/
│   ├── @x/
│   │   └── order.ts    # API for order entity only
│   └── index.ts
└── order/
    └── model/types.ts  # imports from product/@x/order
```

```typescript
// entities/product/@x/order.ts
export type { ProductId, ProductName } from '../model/types';

// entities/order/model/types.ts
import type { ProductId } from '@/entities/product/@x/order';
```

---

### Features Layer

> [Features Layer Docs](https://feature-sliced.design/docs/reference/layers#features)

User-facing interactions that provide business value.

**Key principle:** Not everything is a feature. Per [FSD v2.1](https://github.com/feature-sliced/documentation/releases/tag/v2.1), keep non-reused interactions in page slices.

**Structure:**
```
features/
├── auth/
│   ├── ui/           # LoginForm, LogoutButton
│   ├── api/          # login, logout, register
│   ├── model/        # auth state, session, schemas
│   └── index.ts
├── add-to-cart/
│   ├── ui/           # AddToCartButton, QuantitySelector
│   ├── api/          # addToCart mutation
│   ├── model/        # validation
│   └── index.ts
└── search-products/
    ├── ui/           # SearchInput, Filters
    ├── api/          # searchProducts
    ├── model/        # search state
    └── index.ts
```

**Feature vs Entity Decision:**

| Entity | Feature |
|--------|---------|
| Represents a THING | Represents an ACTION |
| `user` — user data | `auth` — login/logout |
| `product` — product info | `add-to-cart` — adding |
| `comment` — comment data | `write-comment` — creating |

---

### Widgets Layer

> [Widgets Layer Docs](https://feature-sliced.design/docs/reference/layers#widgets)

Large, self-sufficient UI components reused across multiple pages.

**When to use widgets:**
- Component is reused across multiple pages
- Component is complex with multiple children
- Component delivers a complete use case

**Structure:**
```
widgets/
├── header/
│   ├── ui/           # Header, NavMenu, UserDropdown
│   └── index.ts
├── sidebar/
│   ├── ui/           # Sidebar, SidebarItem
│   └── index.ts
└── product-list/
    ├── ui/           # ProductList, ProductGrid, Filters
    └── index.ts
```

**Widget vs Feature:**
- Widget = composed UI block (visual)
- Feature = user interaction (behavioral)

Widgets often compose multiple features:
```tsx
// widgets/header/ui/Header.tsx
import { UserAvatar } from '@/entities/user';
import { LogoutButton } from '@/features/auth';
import { SearchBox } from '@/features/search';
```

**Don't create widgets for:**
- Single-use components (keep in page)
- Simple compositions (compose in page directly)

---

### Pages Layer

> [Pages Layer Docs](https://feature-sliced.design/docs/reference/layers#pages)

Individual screens or routes. One slice per route (generally).

**Structure:**
```
pages/
├── home/
│   ├── ui/           # HomePage, HeroSection
│   ├── api/          # loader functions
│   └── index.ts
├── product-detail/
│   ├── ui/           # ProductDetailPage
│   ├── api/          # getProduct loader
│   └── index.ts
└── checkout/
    ├── ui/           # CheckoutPage, Steps
    ├── api/          # checkout mutations
    ├── model/        # form validation
    └── index.ts
```

**Guidelines:**
- One slice per route (generally)
- Similar pages can share a slice (login/register)
- Pages compose widgets, features, entities
- Minimal business logic — delegate to lower layers
- Non-reused interactions stay in page slice (v2.1)

---

### App Layer

> [App Layer Docs](https://feature-sliced.design/docs/reference/layers#app)

Application-wide configuration and initialization.

**Structure:**
```
app/
├── providers/        # React context, store setup
│   ├── ThemeProvider.tsx
│   ├── QueryProvider.tsx
│   └── index.ts
├── routes/           # Router configuration
│   └── router.tsx
├── styles/           # Global CSS, theme tokens
│   ├── globals.css
│   └── theme.ts
└── index.tsx         # Entry point
```

**Responsibilities:**
- Initialize application state
- Set up routing
- Configure global providers
- Define global styles
- Application-wide error boundaries

---

## Layer Selection Flowchart

```
START: Where does this code go?
│
├─ Reusable infrastructure without business logic?
│  └─ YES → shared/
│
├─ Business domain object/data model?
│  └─ YES → entities/
│
├─ User interaction with business value?
│  ├─ YES, reused across pages → features/
│  └─ YES, single page only → Keep in pages/ slice
│
├─ Complex, reusable UI composition?
│  └─ YES → widgets/
│
├─ Route/screen component?
│  └─ YES → pages/
│
└─ App-wide initialization/config?
   └─ YES → app/
```

---

## Common Mistakes

1. **Features in entities** — Entities are data, features are actions
2. **Single-use widgets** — Keep in pages/ instead (v2.1)
3. **Business logic in shared** — Shared must be domain-agnostic
4. **Too many layers** — Start with shared, pages, app; add as needed
5. **Importing upward** — Strictly forbidden
6. **Generic segment names** — Use purpose-driven: `api/`, `model/`, `ui/`
7. **Everything is a feature** — Only reused interactions qualify
