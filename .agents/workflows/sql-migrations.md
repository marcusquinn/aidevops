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

## Generating and Applying Migrations

| Tool | Generate | Apply |
|------|----------|-------|
| **Supabase** | `supabase db diff -f name` | `supabase migration up` |
| **Drizzle** | `npx drizzle-kit generate` | `npx drizzle-kit migrate` |
| **Prisma** | `npx prisma migrate dev --name name` | `npx prisma migrate deploy` |
| **Atlas** | `atlas migrate diff name --dir file://migrations --to file://schema.sql --dev-url docker://postgres/15` | `atlas migrate apply -u "postgres://..."` |
| **migra** | `migra $DB schemas/` | `psql $DB -f file.sql` |
| **Flyway** | N/A (imperative) | `flyway migrate` |
| **Laravel** | `php artisan make:migration` | `php artisan migrate` |
| **Rails** | `rails g migration` | `rails db:migrate` |

**ALWAYS review generated migrations before committing.** Check: only expected changes, no unintended destructive operations, correct types/constraints. Data migrations may need manual adjustment.

### Known Limitations (require manual migrations)

- DML statements (`INSERT`, `UPDATE`, `DELETE`)
- RLS policy modifications, view ownership/grants
- Materialized views, table partitions, comments
- Some `ALTER POLICY` statements

### Tool-Specific Commands

```bash
# Drizzle
npx drizzle-kit generate   # Generate from schema changes
npx drizzle-kit push       # Push directly (dev only, no migration file)
npx drizzle-kit pull       # Pull existing DB schema to TypeScript

# Prisma
npx prisma migrate dev --name add_user_email    # Development
npx prisma migrate deploy                        # Production
npx prisma migrate reset                         # Reset (dev only)

# Laravel
php artisan migrate:rollback
php artisan migrate:fresh --seed    # Dev only

# Rails
rails db:rollback
rails db:migrate:redo              # Rollback + migrate
```

Flyway file naming: `V1__create_users.sql`, `V2__add_email.sql`, `R__refresh_views.sql` (repeatable), `U2__undo_add_email.sql` (undo).

## Naming Convention

```text
{YYYYMMDDHHMMSS}_{action}_{target}.sql

20240502100843_create_users_table.sql
20240503142030_add_email_to_users.sql
20240504083015_drop_legacy_sessions_table.sql
```

| Prefix | Purpose |
|--------|---------|
| `create_` | New table |
| `add_` | New column/index |
| `drop_` | Remove table/column |
| `rename_` | Rename column/table |
| `alter_` | Modify column type |
| `seed_` | Initial data |
| `backfill_` | Data migration |

Avoid: `migration_1.sql`, `fix_stuff.sql`, `update_db.sql`

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

```sql
-- PostgreSQL
CREATE TABLE IF NOT EXISTS users (...);
CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);

-- Idempotent column addition (PostgreSQL — no IF NOT EXISTS for ALTER TABLE ADD COLUMN)
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

## Rollback and Safety

### Reversible vs Irreversible Operations

| Operation | Rollback | Notes |
|-----------|----------|-------|
| `CREATE TABLE` | `DROP TABLE` | Safe |
| `ADD COLUMN` | `DROP COLUMN` | Safe |
| `CREATE INDEX` | `DROP INDEX` | Safe |
| `ADD CONSTRAINT` | `DROP CONSTRAINT` | Safe |
| `DROP TABLE` | **Irreversible** | Backup first, or rename instead |
| `DROP COLUMN` | **Irreversible** | Backup column data first |
| `TRUNCATE` | **Irreversible** | Never use in migrations |
| Data `UPDATE` | **Irreversible** | Store originals in backup table |

For irreversible migrations, mark the DOWN section:

```sql
-- ====== DOWN ======
-- IRREVERSIBLE: restore from backup if needed.
SELECT 'This migration is irreversible' AS warning;
```

### Rollback Commands

```bash
flyway undo
npx prisma migrate resolve --rolled-back 20240502100843_add_email
rails db:rollback STEP=1
php artisan migrate:rollback --step=1

# Point-in-time recovery
pg_restore -d dbname backup_before_migration.dump   # PostgreSQL
mysql dbname < backup_before_migration.sql           # MySQL
```

## Production Safety

### Safe Operations Checklist

| Operation | Safe? | Strategy |
|-----------|-------|----------|
| Add nullable column | Yes | Direct |
| Add NOT NULL column | Caution | Add nullable → backfill → add constraint |
| Drop column | Caution | Remove from code first → wait → drop |
| Rename column | Caution | Expand-contract pattern |
| Add index | Caution | Use `CONCURRENTLY` (PostgreSQL) |
| Change column type | Caution | New column → migrate data → drop old |

### Expand-Contract Pattern (risky changes)

```sql
-- Phase 1: EXPAND — add new column, keep old
ALTER TABLE users ADD COLUMN email_new VARCHAR(255);
UPDATE users SET email_new = email;

-- Phase 2: Deploy code writing to BOTH columns, reading from new

-- Phase 3: CONTRACT — remove old column
ALTER TABLE users DROP COLUMN email;
ALTER TABLE users RENAME COLUMN email_new TO email;
```

### Concurrent Index Creation (PostgreSQL)

```sql
CREATE INDEX CONCURRENTLY idx_users_email ON users(email);  -- Non-blocking (production-safe)
CREATE INDEX idx_users_email ON users(email);               -- Blocks writes — avoid on large tables
```

## Git Workflow Integration

### Pre-Push Checklist

1. Migration has both UP and DOWN sections
2. DOWN section actually reverses the UP changes
3. Tested locally (run up, run down, run up again)
4. No modifications to already-pushed migrations
5. Timestamp is current (regenerate if rebasing)

### Team Collaboration

- Pull before creating new migrations
- Use timestamps (not sequential numbers) for ordering
- One migration per PR when possible
- Rebase carefully — may need to regenerate timestamps if two developers create same-timestamp files

### Commit Messages

```bash
git commit -m "feat(db): add user_preferences table with indexes"
git commit -m "fix(db): correct foreign key constraint on orders"
git commit -m "chore(db): backfill user status from legacy field"
```

## CI/CD Integration

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
      - name: Backup database
        run: pg_dump $DATABASE_URL > backup_$(date +%Y%m%d_%H%M%S).sql
        env:
          DATABASE_URL: ${{ secrets.DATABASE_URL }}
      - name: Run migrations
        run: flyway migrate   # or: npx prisma migrate deploy / rails db:migrate
        env:
          DATABASE_URL: ${{ secrets.DATABASE_URL }}
      - name: Verify
        run: psql $DATABASE_URL -c "SELECT 1"
```

## Migration Tracking

Most tools create a tracking table automatically. Query example (Flyway):

```sql
SELECT version, description, installed_on, success
FROM flyway_schema_history ORDER BY installed_rank;
```

Framework-agnostic raw runner:

```bash
for f in migrations/*.sql; do psql $DATABASE_URL -f "$f"; done
```
