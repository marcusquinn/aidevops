---
description: PostgreSQL + Drizzle ORM — type-safe database applications
mode: subagent
imported_from: external
---
# PostgreSQL + Drizzle ORM

## Commands

```bash
npx drizzle-kit generate   # Generate migration from schema changes
npx drizzle-kit migrate    # Apply pending migrations
npx drizzle-kit push       # Push schema directly (dev only!)
npx drizzle-kit studio     # Open database browser
```

## Decision Trees

**Relationship modeling:**

```text
One-to-many (user has posts)     → FK on "many" side + relations()
Many-to-many (posts have tags)   → Junction table + relations()
One-to-one (user has profile)    → FK with unique constraint
Self-referential (comments)      → FK to same table
```

**Slow query diagnosis:**

```text
Missing index on WHERE/JOIN columns  → Add index
N+1 queries in loop                  → Use relational queries API
Full table scan                      → EXPLAIN ANALYZE, add index
Large result set                     → Add pagination (limit/offset)
Connection overhead                  → Enable connection pooling
```

## Anti-Patterns

| Priority | Issue | Impact | Fix |
|----------|-------|--------|-----|
| CRITICAL | No FK index | Full table scans on JOINs | Add index on every FK column |
| CRITICAL | N+1 in loops | Query per row | Use `with:` relational queries |
| HIGH | No pooling | Connection per request | Use `@neondatabase/serverless` or similar |
| HIGH | Unanalysed slow queries | Unknown bottleneck | `EXPLAIN ANALYZE` to find missing indexes |
| HIGH | `push` in prod | Data loss risk | Always use `generate` + `migrate` |
| MEDIUM | Storing JSON as text | No validation, bad queries | Use `jsonb()` column type |
| MEDIUM | No partial indexes | Oversized indexes | Partial indexes for filtered subsets |
| MEDIUM | Random UUIDs for PKs | Poor index locality | UUIDv7 (PG18+) |

## Reference

| File | Purpose |
|------|---------|
| [schema.md](postgres-drizzle-skill/schema.md) | Column types, constraints, table definitions |
| [queries.md](postgres-drizzle-skill/queries.md) | Operators, joins, aggregations, transactions |
| [relations.md](postgres-drizzle-skill/relations.md) | One-to-many, many-to-many, self-referential |
| [migrations.md](postgres-drizzle-skill/migrations.md) | drizzle-kit workflows |
| [postgres.md](postgres-drizzle-skill/postgres.md) | PG18 features, RLS, partitioning |
| [performance.md](postgres-drizzle-skill/performance.md) | Indexing, pooling, caching, monitoring |
| [cheatsheet.md](postgres-drizzle-skill/cheatsheet.md) | Quick reference |

## Resources

**Drizzle ORM:** [Docs](https://orm.drizzle.team) · [GitHub](https://github.com/drizzle-team/drizzle-orm) · [drizzle-kit](https://orm.drizzle.team/kit-docs/overview)

**PostgreSQL:** [Docs](https://www.postgresql.org/docs/) · [SQL Commands](https://www.postgresql.org/docs/current/sql-commands.html) · [Performance](https://www.postgresql.org/docs/current/performance-tips.html) · [Index Types](https://www.postgresql.org/docs/current/indexes-types.html) · [JSON Functions](https://www.postgresql.org/docs/current/functions-json.html) · [RLS](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)

**Related subagents:** `tools/database/vector-search.md` (pgvector) · `services/database/multi-org-isolation.md` (RLS tenant isolation) · `tools/database/pglite-local-first.md` (embedded Postgres)
