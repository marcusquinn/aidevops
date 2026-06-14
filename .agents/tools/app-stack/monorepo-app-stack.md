---
description: TypeScript monorepo app-stack defaults for web, API, desktop, mobile, and extension surfaces
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# TypeScript Monorepo App Stack

Use when the product has durable app state, shared domain logic, multiple surfaces, or a roadmap likely to add desktop/mobile/extension clients.

## Default shape

```text
apps/
  web/          # React/Next web app
  api/          # API/server runtime when not colocated with web
  desktop/      # Electron shell when needed
  mobile/       # Expo app when needed
  extension/    # WXT extension when needed
packages/
  db/           # Drizzle schema, migrations, repositories
  domain/       # entities, services, workflow rules, validation
  ui/           # shared components/tokens
  config/       # eslint/tsconfig/tailwind/build config
  sdk/          # typed client/API helpers
```

Add surfaces only when a user workflow requires them; keep package boundaries ready so later surfaces are cheap.

## Defaults

- Language: TypeScript throughout.
- Web: React/Next for product UX.
- Data: Postgres + Drizzle + migrations; RLS for workspace/user boundaries.
- Validation: shared schemas in domain/API packages.
- UI: component library package with design tokens and accessibility rules.
- Background jobs: explicit worker package or hosting-native queue/cron.
- Local-first desktop/extension cache: PGlite only when Postgres schema reuse is worth the startup/performance trade-off.

## Package rules

- `packages/db` owns table definitions, relations, migration helpers, and seed data.
- `packages/domain` owns business rules and metadata interpretation; avoid framework imports.
- `packages/ui` owns presentational components and interaction primitives.
- Apps compose packages; apps do not become dumping grounds for reusable logic.
- Keep server-only code out of renderer/mobile/extension bundles.

## Verification

- Show the planned directory tree before implementation.
- Confirm which surfaces are in-scope now.
- Confirm database ownership and migration command.
- Run typecheck, lint, tests, and surface-specific build for changed packages.
- For UI changes, use `workflows/ui-verification.md` for browser evidence.
