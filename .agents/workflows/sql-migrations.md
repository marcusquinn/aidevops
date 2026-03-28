---
mode: subagent
---
# SQL Migrations Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Version-controlled database schema changes with rollback support
- **Declarative**: `schemas/` — define desired state, generate migrations automatically
- **Migrations**: `migrations/` — versioned, timestamped migration files
- **Naming**: `{YYYYMMDDHHMMSS}_{action}_{target}.sql`

**Critical Rules**:

- NEVER modify migrations that have been pushed/deployed — create a NEW migration to fix issues
- ALWAYS generate migrations via diff (don't write manually)
- ALWAYS review generated migrations before committing
- ALWAYS backup before running migrations in production
- ONE logical change per migration file

**Workflow**: Edit `schemas/` → generate migration via diff → review → apply locally → commit both schema and migration files

<!-- AI-CONTEXT-END -->

## Directory Structure

```text
project/
├── schemas/          # Declarative schema files (source of truth; prefix for order: 00, 01, 10, 20…)
├── migrations/       # Generated migration files
├── seeds/            # Initial/test data
└── scripts/
    ├── migrate.sh    # Run pending migrations
    └── rollback.sh   # Rollback last migration
```

## Generating, Applying, and Rolling Back Migrations

| Tool | Generate | Apply | Rollback |
|------|----------|-------|----------|
| **Supabase** | `supabase db diff -f name` | `supabase migration up` | — |
| **Drizzle** | `npx drizzle-kit generate` | `npx drizzle-kit migrate` | — |
| **Prisma** | `npx prisma migrate dev --name name` | `npx prisma migrate deploy` | `npx prisma migrate resolve --rolled-back <name>` |
| **Atlas** | `atlas migrate diff name --dir file://migrations --to file://schema.sql --dev-url docker://postgres/15` | `atlas migrate apply -u "postgres://..."` | — |
| **migra** | `migra $DB schemas/` | `psql $DB -f file.sql` | — |
| **Flyway** | N/A (imperative) | `flyway migrate` | `flyway undo` |
| **Laravel** | `php artisan make:migration` | `php artisan migrate` | `php artisan migrate:rollback --step=1` |
| **Rails** | `rails g migration` | `rails db:migrate` | `rails db:rollback STEP=1` |

**Review before committing:** Check only expected changes, no unintended destructive operations, correct types/constraints. Data migrations may need manual adjustment.

Dev-only commands: `npx drizzle-kit push` (push without migration file), `npx drizzle-kit pull` (pull DB schema to TS), `npx prisma migrate reset`, `php artisan migrate:fresh --seed`.

Flyway file naming: `V1__create_users.sql`, `V2__add_email.sql`, `R__refresh_views.sql` (repeatable), `U2__undo_add_email.sql` (undo).

### Known Limitations (require manual migrations)

DML statements (`INSERT`/`UPDATE`/`DELETE`), RLS policy modifications, view ownership/grants, materialized views, table partitions, comments, some `ALTER POLICY` statements.

## Naming Convention

| Prefix | Purpose | Prefix | Purpose |
|--------|---------|--------|---------|
| `create_` | New table | `rename_` | Rename column/table |
| `add_` | New column/index | `alter_` | Modify column type |
| `drop_` | Remove table/column | `seed_` / `backfill_` | Initial/migrated data |

Example: `20240502100843_create_users_table.sql`. Avoid: `migration_1.sql`, `fix_stuff.sql`.

## Migration File Structure

### Up/Down Pattern (Required)

```sql
-- migrations/20240502100843_create_users_table.sql

-- ====== UP ======
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255) NOT NULL UNIQUE,
    name VARCHAR(255),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_users_email ON users(email);

-- ====== DOWN ======
DROP INDEX IF EXISTS idx_users_email;
DROP TABLE IF EXISTS users;
```

### Idempotent Column Addition (PostgreSQL)

PostgreSQL has no `IF NOT EXISTS` for `ALTER TABLE ADD COLUMN` — use a check:

```sql
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'users' AND column_name = 'phone'
    ) THEN
        ALTER TABLE users ADD COLUMN phone VARCHAR(20);
    END IF;
END $$;
```

Note: MySQL doesn't support `IF NOT EXISTS` for indexes — use stored procedures.

### Schema vs Data Migrations (keep separate)

```sql
-- V6__add_status_column.sql (Schema — fast, reversible)
ALTER TABLE orders ADD COLUMN status VARCHAR(20) DEFAULT 'pending';

-- V7__backfill_order_status.sql (Data — slow, may be irreversible)
UPDATE orders SET status = 'completed' WHERE shipped_at IS NOT NULL;
UPDATE orders SET status = 'pending' WHERE shipped_at IS NULL;
```

## Rollback, Safety, and Production Operations

### Reversible vs Irreversible Operations

| Operation | Rollback | Notes |
|-----------|----------|-------|
| `CREATE TABLE/INDEX/CONSTRAINT` | `DROP` equivalent | Safe |
| `ADD COLUMN` | `DROP COLUMN` | Safe |
| `DROP TABLE/COLUMN` | **Irreversible** | Backup first, or rename instead |
| `TRUNCATE` | **Irreversible** | Never use in migrations |
| Data `UPDATE` | **Irreversible** | Store originals in backup table |

For irreversible migrations, mark the DOWN section:

```sql
-- ====== DOWN ======
-- IRREVERSIBLE: restore from backup if needed.
SELECT 'This migration is irreversible' AS warning;
```

Point-in-time recovery: `pg_dump`/`pg_restore` (PostgreSQL), `mysqldump` (MySQL).

### Production Safety Checklist

| Operation | Safe? | Strategy |
|-----------|-------|----------|
| Add nullable column | Yes | Direct |
| Add NOT NULL column | Caution | Add nullable → backfill → add constraint |
| Drop column | Caution | Remove from code first → wait → drop |
| Rename column | Caution | Expand-contract pattern (below) |
| Add index | Caution | `CREATE INDEX CONCURRENTLY` (PostgreSQL) |
| Change column type | Caution | New column → migrate data → drop old |

### Expand-Contract Pattern

```sql
-- Phase 1: EXPAND — add new column, keep old
ALTER TABLE users ADD COLUMN email_new VARCHAR(255);
UPDATE users SET email_new = email;
-- Phase 2: Deploy code writing to BOTH columns, reading from new
-- Phase 3: CONTRACT — remove old column
ALTER TABLE users DROP COLUMN email;
ALTER TABLE users RENAME COLUMN email_new TO email;
```

Concurrent index creation (PostgreSQL): `CREATE INDEX CONCURRENTLY idx_name ON table(col);` — non-blocking, production-safe. Without `CONCURRENTLY`, blocks writes on large tables.

## Git Workflow Integration

**Pre-push checklist:** (1) Migration has UP and DOWN sections, (2) DOWN reverses UP, (3) tested locally (up → down → up), (4) no modifications to pushed migrations, (5) timestamp is current (regenerate if rebasing).

**Team rules:** Pull before creating migrations. Use timestamps not sequential numbers. One migration per PR. Rebase carefully — regenerate timestamps for conflicts.

**Commit messages:** `feat(db): add user_preferences table`, `fix(db): correct FK on orders`, `chore(db): backfill user status`.

## CI/CD Integration

Trigger on `push` to `main` with `paths: ['migrations/**']`. Steps: backup → migrate → verify.

```yaml
name: Database Migration
on:
  push:
    branches: [main]
    paths: ['migrations/**']
jobs:
  migrate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: pg_dump $DATABASE_URL > backup_$(date +%Y%m%d_%H%M%S).sql
        env: { DATABASE_URL: "${{ secrets.DATABASE_URL }}" }
      - run: flyway migrate   # or: npx prisma migrate deploy / rails db:migrate
        env: { DATABASE_URL: "${{ secrets.DATABASE_URL }}" }
      - run: psql $DATABASE_URL -c "SELECT 1"
```

Most tools create a tracking table automatically (e.g., `flyway_schema_history`). Framework-agnostic runner: `for f in migrations/*.sql; do psql $DATABASE_URL -f "$f"; done`.
