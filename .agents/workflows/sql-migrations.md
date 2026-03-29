---
mode: subagent
---
# SQL Migrations Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Version-controlled database schema changes with rollback support
- **Declarative**: `schemas/` — desired state, generate migrations automatically
- **Migrations**: `migrations/` — versioned, timestamped files
- **Naming**: `{YYYYMMDDHHMMSS}_{action}_{target}.sql`

**Critical Rules**:

- NEVER modify pushed/deployed migrations — create a NEW migration instead
- ALWAYS generate migrations via diff (don't write manually)
- ALWAYS review generated migrations before committing
- ALWAYS backup before running migrations in production
- ONE logical change per migration file

**Workflow**: Edit `schemas/` → generate migration via diff → review → apply locally → commit both schema and migration files

<!-- AI-CONTEXT-END -->

## Directory Structure

```text
project/
├── schemas/          # Declarative schema files (source of truth; prefix: 00, 01, 10, 20…)
├── migrations/       # Generated migration files
├── seeds/            # Initial/test data
└── scripts/
    ├── migrate.sh    # Run pending migrations
    └── rollback.sh   # Rollback last migration
```

## Tool Commands

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

**Dev-only commands:** `drizzle-kit push`/`pull`, `prisma migrate reset`, `php artisan migrate:fresh --seed`.

**Flyway naming:** `V1__create_users.sql`, `V2__add_email.sql`, `R__refresh_views.sql` (repeatable), `U2__undo_add_email.sql` (undo).

**Known limitations (require manual migrations):** DML statements, RLS policies, view ownership/grants, materialized views, table partitions, comments, some `ALTER POLICY`.

## Naming Convention

| Prefix | Purpose | Prefix | Purpose |
|--------|---------|--------|---------|
| `create_` | New table | `rename_` | Rename column/table |
| `add_` | New column/index | `alter_` | Modify column type |
| `drop_` | Remove table/column | `seed_` / `backfill_` | Initial/migrated data |

Example: `20240502100843_create_users_table.sql`. Avoid: `migration_1.sql`, `fix_stuff.sql`.

## Migration File Structure

**Up/Down pattern (required):**

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

**Idempotent column addition (PostgreSQL)** — lacks `IF NOT EXISTS` for `ALTER TABLE ADD COLUMN`:

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

**Schema vs data migrations (keep separate):**

```sql
-- V6__add_status_column.sql (Schema — fast, reversible)
ALTER TABLE orders ADD COLUMN status VARCHAR(20) DEFAULT 'pending';

-- V7__backfill_order_status.sql (Data — slow, may be irreversible)
UPDATE orders SET status = 'completed' WHERE shipped_at IS NOT NULL;
UPDATE orders SET status = 'pending' WHERE shipped_at IS NULL;
```

## Rollback and Safety

| Operation | Rollback | Notes |
|-----------|----------|-------|
| `CREATE TABLE/INDEX/CONSTRAINT` | `DROP` equivalent | Safe |
| `ADD COLUMN` | `DROP COLUMN` | Safe |
| `DROP TABLE/COLUMN` | **Irreversible** | Backup first, or rename instead |
| `TRUNCATE` | **Irreversible** | Never use in migrations |
| Data `UPDATE` | **Irreversible** | Store originals in backup table |

Mark irreversible DOWN sections: `-- IRREVERSIBLE: restore from backup if needed.`

Point-in-time recovery: `pg_dump`/`pg_restore` (PostgreSQL), `mysqldump` (MySQL).

## Production Safety

| Operation | Safe? | Strategy |
|-----------|-------|----------|
| Add nullable column | Yes | Direct |
| Add NOT NULL column | Caution | Add nullable → backfill → add constraint |
| Drop column | Caution | Remove from code first → wait → drop |
| Rename column | Caution | Expand-contract pattern |
| Add index | Caution | `CREATE INDEX CONCURRENTLY` (PostgreSQL) |
| Change column type | Caution | New column → migrate data → drop old |

**Expand-contract:** (1) EXPAND — add new column, copy data, deploy code writing both/reading new. (2) CONTRACT — drop old column, rename new.

## Git and CI/CD

**Pre-push checklist:** (1) UP and DOWN sections present, (2) DOWN reverses UP, (3) tested locally (up → down → up), (4) no modifications to pushed migrations, (5) timestamp is current (regenerate on rebase). Review: verify only expected changes, no unintended destructive ops, correct types/constraints.

**Team rules:** Pull before creating migrations. Timestamps not sequential numbers. One migration per PR. Rebase carefully — regenerate timestamps for conflicts.

**Commit messages:** `feat(db): add user_preferences table`, `fix(db): correct FK on orders`, `chore(db): backfill user status`.

**CI/CD:** Trigger on `push` to `main` with `paths: ['migrations/**']`. Steps: backup → migrate → verify.

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

Most tools auto-create a tracking table (e.g., `flyway_schema_history`). Framework-agnostic runner: `for f in migrations/*.sql; do psql $DATABASE_URL -f "$f"; done`.
