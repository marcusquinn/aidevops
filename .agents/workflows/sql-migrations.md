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
├── schemas/                    # Declarative schema files (source of truth)
│   ├── 00_extensions.sql       # PostgreSQL extensions
│   ├── 01_types.sql            # Custom types and enums
│   ├── 10_users.sql            # Users table and related
│   ├── 20_products.sql         # Products domain
│   └── 30_orders.sql          # Orders domain
├── migrations/                 # Generated migration files
│   ├── 20240502100843_create_users_table.sql
│   └── 20240503142030_add_email_to_users.sql
├── seeds/                      # Initial/test data
│   └── 001_base_data.sql
└── scripts/
    ├── migrate.sh              # Run pending migrations
    └── rollback.sh             # Rollback last migration
```

Prefix schema files with numbers to control execution order (dependencies). Use gaps (00, 01, 10, 20, 30, 90) to allow insertions.

## Declarative Schema Workflow (Recommended)

| Approach | Pros | Cons |
|----------|------|------|
| **Declarative** | Single source of truth, easy to review, auto-generated migrations | Requires diff tool, some edge cases |
| **Imperative** | Full control, works everywhere | Scattered across files, manual, error-prone |

### Writing Schema Files

Each file declares the desired state of related tables:

```sql
-- schemas/10_users.sql

CREATE TABLE IF NOT EXISTS "users" (
    "id" SERIAL PRIMARY KEY,
    "email" VARCHAR(255) NOT NULL UNIQUE,
    "name" VARCHAR(255),
    "created_at" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);

-- Related function
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();
```

### Generating and Applying Migrations

| Tool | Schema Format | Generate Migration | Apply Migration |
|------|---------------|-------------------|-----------------|
| **Supabase** | SQL files | `supabase db diff -f name` | `supabase migration up` |
| **Drizzle** | TypeScript | `npx drizzle-kit generate` | `npx drizzle-kit migrate` |
| **Prisma** | Prisma Schema | `npx prisma migrate dev --name name` | `npx prisma migrate deploy` |
| **Atlas** | HCL/SQL/ORM | `atlas migrate diff name` | `atlas migrate apply` |
| **migra** | SQL files | `migra $DB schemas/` | `psql $DB -f file.sql` |
| **Flyway** | SQL files | N/A (imperative) | `flyway migrate` |
| **Laravel** | PHP | `php artisan make:migration` | `php artisan migrate` |
| **Rails** | Ruby | `rails g migration` | `rails db:migrate` |

**ALWAYS review generated migrations before committing.** Check for: only expected changes, no unintended destructive operations, correct column types/constraints. Data migrations may need manual adjustment.

### Known Limitations

Some entities require manual migrations (not captured by diff tools):

- DML statements (`INSERT`, `UPDATE`, `DELETE`)
- RLS policy modifications
- View ownership and grants
- Materialized views, table partitions, comments
- Some ALTER POLICY statements

For these, create manual migration files alongside generated ones.

## Tool-Specific Patterns

### Drizzle ORM (TypeScript)

```typescript
// schemas/users.ts
import { pgTable, serial, text, timestamp } from 'drizzle-orm/pg-core';

export const users = pgTable('users', {
  id: serial('id').primaryKey(),
  email: text('email').notNull().unique(),
  name: text('name'),
  createdAt: timestamp('created_at').defaultNow(),
});
```

```bash
npx drizzle-kit generate   # Generate migration from schema changes
npx drizzle-kit migrate    # Apply migrations
npx drizzle-kit push       # Push directly (dev only, no migration file)
npx drizzle-kit pull       # Pull existing DB schema to TypeScript
```

### Atlas (Universal)

```bash
# Declarative: apply schema directly
atlas schema apply -u "postgres://..." --to file://schema.sql

# Versioned: generate migration file
atlas migrate diff add_users \
  --dir "file://migrations" \
  --to "file://schema.sql" \
  --dev-url "docker://postgres/15"

# Apply versioned migrations
atlas migrate apply -u "postgres://..."
```

### Flyway

```text
migrations/
├── V1__create_users.sql
├── V2__add_email_to_users.sql
├── R__refresh_views.sql          # Repeatable
└── U2__undo_add_email.sql        # Undo
```

### Framework CLIs

```bash
# Prisma
npx prisma migrate dev --name add_user_email    # Development
npx prisma migrate deploy                        # Production
npx prisma migrate reset                         # Reset (dev only)

# Laravel
php artisan make:migration create_users_table
php artisan migrate
php artisan migrate:rollback
php artisan migrate:fresh --seed    # Dev only

# Rails
rails generate migration CreateUsers
rails db:migrate
rails db:rollback
rails db:migrate:redo              # Rollback + migrate
```

## Naming Convention

```text
{YYYYMMDDHHMMSS}_{action}_{target}_{details}.sql

Examples:
20240502100843_create_users_table.sql
20240502101659_add_email_to_users.sql
20240503142030_drop_legacy_sessions_table.sql
20240504083015_add_index_email_unique_to_users.sql
20240505091200_rename_name_to_full_name_in_users.sql
```

### Action Prefixes

| Prefix | Purpose | Example |
|--------|---------|---------|
| `create_` | New table | `create_users_table.sql` |
| `add_` | New column/index | `add_email_to_users.sql` |
| `drop_` | Remove table/column | `drop_legacy_table.sql` |
| `rename_` | Rename column/table | `rename_name_to_full_name_in_users.sql` |
| `alter_` | Modify column type | `alter_price_to_decimal_in_products.sql` |
| `seed_` | Initial data | `seed_default_roles.sql` |
| `backfill_` | Data migration | `backfill_user_status.sql` |

**Bad names to avoid**: `migration_1.sql`, `fix_stuff.sql`, `20240502_changes.sql`, `update_db.sql`

## File Structure

### Up/Down Pattern (Required)

Every migration MUST have both up and down sections:

```sql
-- migrations/20240502100843_create_users_table.sql

-- ====== UP ======
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255) NOT NULL UNIQUE,
    name VARCHAR(255),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_users_email ON users(email);

-- ====== DOWN ======
DROP INDEX IF EXISTS idx_users_email;
DROP TABLE IF EXISTS users;
```

### Idempotent Migrations (Preferred)

Write migrations that can run multiple times safely:

```sql
-- PostgreSQL
CREATE TABLE IF NOT EXISTS users (...);
CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);

-- Column addition (PostgreSQL — no IF NOT EXISTS for ALTER TABLE ADD COLUMN)
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

### Schema vs Data Migrations

Keep them separate:

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
-- IRREVERSIBLE: This migration cannot be rolled back.
-- Data was permanently deleted. Restore from backup if needed.
SELECT 'This migration is irreversible' AS warning;
```

### Rollback Commands

```bash
flyway undo
npx prisma migrate resolve --rolled-back 20240502100843_add_email
rails db:rollback STEP=1
php artisan migrate:rollback --step=1

# Point-in-time recovery (catastrophic failures)
pg_restore -d dbname backup_before_migration.dump   # PostgreSQL
mysql dbname < backup_before_migration.sql           # MySQL
```

## Production Safety

### Expand-Contract Pattern

For risky changes (rename column, change type), use three phases:

```sql
-- Phase 1: EXPAND (add new, keep old)
-- 20240601_add_email_new_to_users.sql
ALTER TABLE users ADD COLUMN email_new VARCHAR(255);
UPDATE users SET email_new = email;

-- Phase 2: APPLICATION UPDATE
-- Deploy code that writes to BOTH columns, reads from new

-- Phase 3: CONTRACT (remove old)
-- 20240615_drop_old_email_from_users.sql
ALTER TABLE users DROP COLUMN email;
ALTER TABLE users RENAME COLUMN email_new TO email;
```

### Safe Operations Checklist

| Operation | Safe? | Strategy |
|-----------|-------|----------|
| Add nullable column | Yes | Direct |
| Add NOT NULL column | Caution | Add nullable → backfill → add constraint |
| Drop column | Caution | Remove from code first → wait → drop |
| Rename column | Caution | Expand-contract pattern |
| Add index | Caution | Use `CONCURRENTLY` (PostgreSQL) |
| Change column type | Caution | Create new column → migrate → drop old |

### Concurrent Index Creation (PostgreSQL)

```sql
-- Non-blocking (safe for production)
CREATE INDEX CONCURRENTLY idx_users_email ON users(email);

-- Blocks writes during creation (avoid on large tables)
CREATE INDEX idx_users_email ON users(email);
```

## Git Workflow Integration

### Branch Naming and Commits

```bash
# Branch naming
git checkout -b feature/add-user-preferences-table   # Schema changes
git checkout -b bugfix/fix-orders-foreign-key         # Bug fixes
git checkout -b chore/backfill-user-status            # Data migrations

# Commit messages (conventional commits)
git commit -m "feat(db): add user_preferences table with indexes"
git commit -m "fix(db): correct foreign key constraint on orders"
git commit -m "chore(db): backfill user status from legacy field"
```

### Pre-Push Checklist

1. Migration has both UP and DOWN sections
2. DOWN section actually reverses the UP changes
3. Tested locally (run up, run down, run up again)
4. No modifications to already-pushed migrations
5. Timestamp is current (regenerate if rebasing)

### Team Collaboration

- **Pull before creating** new migrations
- **Use timestamps** (not sequential numbers) for ordering
- **One migration per PR** when possible
- **Rebase carefully** — may need to regenerate timestamps
- If two developers create migrations with the same timestamp, the rebasing developer renames their file with a new timestamp

## CI/CD Integration

```yaml
name: Database Migration
on:
  push:
    branches: [main]
    paths:
      - 'migrations/**'

jobs:
  migrate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Backup database
        run: |
          pg_dump $DATABASE_URL > backup_$(date +%Y%m%d_%H%M%S).sql
        env:
          DATABASE_URL: ${{ secrets.DATABASE_URL }}

      - name: Run migrations
        run: |
          # Your migration tool command
          flyway migrate
          # OR: npx prisma migrate deploy
          # OR: bundle exec rails db:migrate
        env:
          DATABASE_URL: ${{ secrets.DATABASE_URL }}

      - name: Verify migration
        run: |
          psql $DATABASE_URL -c "SELECT 1"
```

## Migration Tracking Table

Most tools create a tracking table automatically. Example (Flyway):

```sql
SELECT version, description, installed_on, success
FROM flyway_schema_history
ORDER BY installed_rank;
```

Raw SQL runner (framework-agnostic):

```bash
#!/bin/bash
for f in migrations/*.sql; do
    echo "Running $f..."
    psql $DATABASE_URL -f "$f"
done
```
