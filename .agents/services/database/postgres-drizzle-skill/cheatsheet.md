# Drizzle + PostgreSQL Quick Reference

## Chapters

| File | Contents |
|------|----------|
| [cheatsheet-schema.md](cheatsheet-schema.md) | Column types, constraints, indexes, enums |
| [cheatsheet-relations.md](cheatsheet-relations.md) | One-to-many, many-to-many, type inference |
| [cheatsheet-queries.md](cheatsheet-queries.md) | Operators, select, relational queries, aggregations, prepared statements |
| [cheatsheet-mutations.md](cheatsheet-mutations.md) | Insert, update, delete, transactions |
| [cheatsheet-config.md](cheatsheet-config.md) | drizzle-kit commands, drizzle.config.ts, connection setup |
| [cheatsheet-reference.md](cheatsheet-reference.md) | Error codes, PostgreSQL 18 features, quick tips |

## Quick Lookup

**Schema:** `pgTable`, `uuid`, `text`, `varchar`, `integer`, `bigint`, `boolean`, `timestamp`, `numeric`, `jsonb`, `pgEnum` — see [cheatsheet-schema.md](cheatsheet-schema.md)

**Relations:** `relations()`, `one()`, `many()`, junction tables — see [cheatsheet-relations.md](cheatsheet-relations.md)

**Queries:** `eq`, `and`, `or`, `ilike`, `inArray`, `findMany`, `findFirst`, `with` — see [cheatsheet-queries.md](cheatsheet-queries.md)

**Mutations:** `insert`, `update`, `delete`, `onConflictDoUpdate`, `transaction` — see [cheatsheet-mutations.md](cheatsheet-mutations.md)

**Config:** `drizzle-kit generate|migrate|push|pull|studio`, `defineConfig` — see [cheatsheet-config.md](cheatsheet-config.md)

**Reference:** PG error codes, PG18 features, performance tips — see [cheatsheet-reference.md](cheatsheet-reference.md)
