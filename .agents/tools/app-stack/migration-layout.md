---
description: Standard database schema and migration layout for TypeScript monorepo apps using Drizzle
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Migration Layout

Put database ownership in one package. Apps consume the database package; apps do not own migrations unless they have a separate database.

## Standard home

```text
packages/db/
  drizzle.config.ts
  migrations/
    0000_initial.sql
    0001_feature_name.sql
    meta/
      0000_snapshot.json
      _journal.json
  src/
    schema/
      index.ts        # re-exports all schema modules
      auth.ts
      workspace.ts
      billing.ts
      ...
    scripts/
      migrate.ts     # optional programmatic migrator
      seed.ts
      status.ts
```

Use this Drizzle shape by default:

```typescript
export default defineConfig({
  out: './migrations',
  schema: './src/schema/index.ts',
  dialect: 'postgresql',
  casing: 'snake_case',
  strict: true,
  verbose: true,
});
```

## Rules

- `packages/db/src/schema/index.ts` is the single schema entrypoint for generation.
- `packages/db/migrations/` and `packages/db/migrations/meta/` are committed; never gitignore generated SQL or snapshots.
- One feature or operational concern per migration; separate schema, RLS, seed, and large data backfill steps when reviewability improves.
- Review generated SQL before applying; hand-write safe renames, data backfills, RLS policies, trigger changes, and zero-downtime indexes.
- Prefer additive migrations: add nullable/defaulted columns, backfill, deploy code, then enforce `NOT NULL` or constraints.
- Runtime metadata can create controlled DDL for configurable entities, but durable core objects still need reviewed migrations and an append-only DDL/audit log.
- Use external provider IDs as integration fields, not primary keys.

## Verification

- Run Drizzle generate and confirm no unplanned schema drift.
- Migrate both an empty database and a copy/fixture of an existing database.
- Inspect the generated SQL and migration journal.
- Verify RLS policies and permission checks for every new workspace-scoped table.
- Confirm changed tables are exported from `src/schema/index.ts` and covered by typecheck/tests.
