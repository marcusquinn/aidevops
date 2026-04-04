---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# SQL Migrations Workflow

## Quick Reference

- **Declarative**: `schemas/` — desired state, generate migrations automatically
- **Migrations**: `migrations/` — versioned, timestamped `{YYYYMMDDHHMMSS}_{action}_{target}.sql` files
- **Workflow**: Edit `schemas/` → generate migration via diff → review → apply locally → commit both
- **Critical Rules**: NEVER modify pushed/deployed migrations (create NEW). ALWAYS generate via diff, review before committing, backup before production. ONE logical change per file.

## Directory Structure

`schemas/` (source of truth, prefix: 00, 01, 10, 20...) | `migrations/` (generated) | `seeds/` (initial/test data) | `scripts/migrate.sh`, `scripts/rollback.sh`

## Tool Commands

| Tool | Generate | Apply | Rollback |
|------|----------|-------|----------|
| Supabase | `supabase db diff -f name` | `supabase migration up` | -- |
| Drizzle | `npx drizzle-kit generate` | `npx drizzle-kit migrate` | -- |
| Prisma | `npx prisma migrate dev --name name` | `npx prisma migrate deploy` | `npx prisma migrate resolve --rolled-back <name>` |
| Atlas | `atlas migrate diff name --dir file://migrations --to file://schema.sql --dev-url docker://postgres/15` | `atlas migrate apply -u "postgres://..."` | -- |
| migra | `migra $DB schemas/` | `psql $DB -f file.sql` | -- |
| Flyway | N/A (imperative) | `flyway migrate` | `flyway undo` |
| Laravel | `php artisan make:migration` | `php artisan migrate` | `php artisan migrate:rollback --step=1` |
| Rails | `rails g migration` | `rails db:migrate` | `rails db:rollback STEP=1` |

**Dev-only:** `drizzle-kit push`/`pull`, `prisma migrate reset`, `php artisan migrate:fresh --seed`. **Flyway naming:** `V1__create_users.sql`, `V2__add_email.sql`, `R__refresh_views.sql` (repeatable), `U2__undo_add_email.sql` (undo). **Manual migrations:** DML, RLS policies, view ownership/grants, materialized views, table partitions, comments, some `ALTER POLICY`.

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
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_users_email ON users(email);
-- ====== DOWN ======
DROP INDEX IF EXISTS idx_users_email;
DROP TABLE IF EXISTS users;
```

**Idempotent column addition (PostgreSQL):**

```sql
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
        WHERE table_name='users' AND column_name='phone')
    THEN ALTER TABLE users ADD COLUMN phone VARCHAR(20);
    END IF;
END $$;
```

**Separate schema and data migrations** — schema is fast/reversible, data may be slow/irreversible:

```sql
-- V6__add_status_column.sql (Schema)
ALTER TABLE orders ADD COLUMN status VARCHAR(20) DEFAULT 'pending';
-- V7__backfill_order_status.sql (Data)
UPDATE orders SET status = CASE WHEN shipped_at IS NOT NULL THEN 'completed' ELSE 'pending' END;
```

## Rollback and Safety

| Operation | Rollback | Notes |
|-----------|----------|-------|
| `CREATE TABLE/INDEX/CONSTRAINT` | `DROP` equivalent | Safe |
| `ADD COLUMN` | `DROP COLUMN` | Safe |
| `DROP TABLE/COLUMN` | **Irreversible** | Backup first, or rename instead |
| `TRUNCATE` | **Irreversible** | Never use in migrations |
| Data `UPDATE` | **Irreversible** | Store originals in backup table |

Mark irreversible DOWN sections: `-- IRREVERSIBLE: restore from backup if needed.` Recovery: `pg_dump`/`pg_restore` (PostgreSQL), `mysqldump` (MySQL).

## Production Safety

| Operation | Safe? | Strategy |
|-----------|-------|----------|
| Add nullable column | Yes | Direct |
| Add NOT NULL column | Caution | Add nullable → backfill → add constraint |
| Drop column | Caution | Remove from code first → wait → drop |
| Rename column | Caution | Expand-contract pattern |
| Add index | Caution | `CREATE INDEX CONCURRENTLY` (PostgreSQL) |
| Change column type | Caution | New column → migrate data → drop old |

**Expand-contract:** EXPAND — add new column, copy data, deploy code writing both/reading new. CONTRACT — drop old column, rename new.

## Git and CI/CD

**Pre-push:** UP and DOWN present; DOWN reverses UP; tested locally (up → down → up); no modifications to pushed migrations; timestamp current (regenerate on rebase). Review: only expected changes, no destructive ops, correct types/constraints.

**Team rules:** Pull before creating. Timestamps not sequential numbers. One migration per PR. Rebase carefully — regenerate timestamps for conflicts. Commit style: `feat(db): add user_preferences table`, `fix(db): correct FK on orders`, `chore(db): backfill user status`.

**CI/CD:** Trigger on `push` to `main` with `paths: ['migrations/**']`. Steps: backup → migrate → verify. Most tools auto-create a tracking table (e.g., `flyway_schema_history`). Prefer managed tools — they handle ordering, locking, and state tracking. Example workflow: `on: push(main, migrations/**) → pg_dump → flyway migrate → psql SELECT 1`.

## Framework-Agnostic Runner

When no migration tool is available, gate execution on a tracking table. Properties: idempotent (`WHERE NOT EXISTS`), ordered (lexicographic glob), auditable (`schema_migrations`), injection-safe (`psql -v` + `:'name'`), concurrent-safe (`pg_advisory_xact_lock`), empty-dir safe (`compgen -G`), `-- no-tx` convention for `CREATE INDEX CONCURRENTLY`.

```bash
#!/usr/bin/env bash
set -euo pipefail
DB_URL="${DATABASE_URL:?DATABASE_URL is required}"
psql "$DB_URL" -c "CREATE TABLE IF NOT EXISTS schema_migrations (
    filename TEXT PRIMARY KEY, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);"
compgen -G "migrations/*.sql" > /dev/null || { echo "No migration files found."; exit 0; }
for f in migrations/*.sql; do
  name="$(basename "$f")"
  if grep -qiE '^\s*--\s*no-tx\b' "$f"; then
    psql "$DB_URL" -v "name=$name" -c "SELECT pg_advisory_lock(hashtext('schema_migrations'));"
    psql "$DB_URL" -f "$f"
    psql "$DB_URL" -v "name=$name" -c "INSERT INTO schema_migrations (filename) SELECT :'name' WHERE NOT EXISTS (SELECT 1 FROM schema_migrations WHERE filename = :'name');"
    psql "$DB_URL" -c "SELECT pg_advisory_unlock(hashtext('schema_migrations'));"
    echo "Applied (or skipped): $name"; continue
  fi
  psql "$DB_URL" -v "name=$name" <<SQL
SELECT pg_advisory_xact_lock(hashtext('schema_migrations'));
BEGIN;
\i $f
INSERT INTO schema_migrations (filename)
  SELECT :'name' WHERE NOT EXISTS (SELECT 1 FROM schema_migrations WHERE filename = :'name');
COMMIT;
SQL
  echo "Applied (or skipped): $name"
done
```
