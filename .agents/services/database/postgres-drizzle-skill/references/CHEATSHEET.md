# Drizzle + PostgreSQL Quick Reference

## Chapters

| File | Contents |
|------|----------|
| [01-schema.md](CHEATSHEET/01-schema.md) | Column types, constraints, indexes, enums |
| [02-relations.md](CHEATSHEET/02-relations.md) | One-to-many, many-to-many, type inference |
| [03-queries.md](CHEATSHEET/03-queries.md) | Operators, select, relational queries, aggregations, prepared statements |
| [04-mutations.md](CHEATSHEET/04-mutations.md) | Insert, update, delete, transactions |
| [05-config.md](CHEATSHEET/05-config.md) | drizzle-kit commands, drizzle.config.ts, connection setup |
| [06-reference.md](CHEATSHEET/06-reference.md) | Error codes, PostgreSQL 18 features, quick tips |

## Quick Lookup

**Schema:** `pgTable`, `uuid`, `text`, `varchar`, `integer`, `bigint`, `boolean`, `timestamp`, `numeric`, `jsonb`, `pgEnum` — see [01-schema.md](CHEATSHEET/01-schema.md)

**Relations:** `relations()`, `one()`, `many()`, junction tables — see [02-relations.md](CHEATSHEET/02-relations.md)

**Queries:** `eq`, `and`, `or`, `ilike`, `inArray`, `findMany`, `findFirst`, `with` — see [03-queries.md](CHEATSHEET/03-queries.md)

**Mutations:** `insert`, `update`, `delete`, `onConflictDoUpdate`, `transaction` — see [04-mutations.md](CHEATSHEET/04-mutations.md)

**Config:** `drizzle-kit generate|migrate|push|pull|studio`, `defineConfig` — see [05-config.md](CHEATSHEET/05-config.md)

**Reference:** PG error codes, PG18 features, performance tips — see [06-reference.md](CHEATSHEET/06-reference.md)
