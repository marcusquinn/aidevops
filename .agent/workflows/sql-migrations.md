# SQL Migrations Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Version-controlled database schema changes with rollback support
- **Location**: `migrations/` or `database/migrations/` in project root
- **Naming**: `{timestamp}_{action}_{target}.sql`

**Critical Rules**:
- NEVER modify migrations that have been pushed/deployed
- ALWAYS include rollback (down) logic
- ALWAYS backup before running migrations in production
- ONE logical change per migration file

<!-- AI-CONTEXT-END -->

## Naming Convention

### Timestamp-Based (Recommended)

```
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

### Bad Names to Avoid

```
migration_1.sql          # Not descriptive
fix_stuff.sql            # Vague
20240502_changes.sql     # No specificity
update_db.sql            # Meaningless
```

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

-- Column addition (PostgreSQL)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'users' AND column_name = 'phone'
    ) THEN
        ALTER TABLE users ADD COLUMN phone VARCHAR(20);
    END IF;
END $$;

-- MySQL
CREATE TABLE IF NOT EXISTS users (...);
-- MySQL doesn't support IF NOT EXISTS for indexes, use procedures
```

## Directory Structure

```
project/
├── migrations/
│   ├── 20240502100843_create_users_table.sql
│   ├── 20240502101659_add_email_to_users.sql
│   └── 20240503142030_create_products_table.sql
├── seeds/
│   ├── 001_base_data.sql           # Required reference data
│   └── 002_test_data.sql           # Development/test data
└── scripts/
    ├── migrate.sh                   # Run pending migrations
    └── rollback.sh                  # Rollback last migration
```

## Schema vs Data Migrations

**Keep them separate:**

```sql
-- V6__add_status_column.sql (Schema - fast, reversible)
ALTER TABLE orders ADD COLUMN status VARCHAR(20) DEFAULT 'pending';

-- V7__backfill_order_status.sql (Data - slow, may be irreversible)
UPDATE orders SET status = 'completed' WHERE shipped_at IS NOT NULL;
UPDATE orders SET status = 'pending' WHERE shipped_at IS NULL;
```

## Rollback Strategies

### Reversible Operations

| Operation | Rollback |
|-----------|----------|
| `CREATE TABLE` | `DROP TABLE` |
| `ADD COLUMN` | `DROP COLUMN` |
| `CREATE INDEX` | `DROP INDEX` |
| `ADD CONSTRAINT` | `DROP CONSTRAINT` |

### Irreversible Operations

| Operation | Why | Mitigation |
|-----------|-----|------------|
| `DROP TABLE` | Data lost | Backup first, or rename instead |
| `DROP COLUMN` | Data lost | Backup column data first |
| `TRUNCATE` | Data lost | Never use in migrations |
| Data `UPDATE` | Original values lost | Store originals in backup table |

### Marking Irreversible Migrations

```sql
-- ====== DOWN ======
-- IRREVERSIBLE: This migration cannot be rolled back.
-- Data was permanently deleted. Restore from backup if needed.
SELECT 'This migration is irreversible' AS warning;
-- Or raise an error:
-- RAISE EXCEPTION 'Cannot rollback: data was deleted';
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
| Add nullable column | ✅ | Direct |
| Add NOT NULL column | ⚠️ | Add nullable → backfill → add constraint |
| Drop column | ⚠️ | Remove from code first → wait → drop |
| Rename column | ⚠️ | Expand-contract pattern |
| Add index | ⚠️ | Use `CONCURRENTLY` (PostgreSQL) |
| Change column type | ⚠️ | Create new column → migrate → drop old |

### Concurrent Index Creation (PostgreSQL)

```sql
-- ✅ Safe: Non-blocking
CREATE INDEX CONCURRENTLY idx_users_email ON users(email);

-- ⚠️ Blocks writes during creation
CREATE INDEX idx_users_email ON users(email);
```

## Git Workflow Integration

### Branch Naming

When creating migrations, use appropriate branch type:

```bash
# Schema changes
git checkout -b feature/add-user-preferences-table

# Bug fixes to schema
git checkout -b bugfix/fix-orders-foreign-key

# Data migrations
git checkout -b chore/backfill-user-status
```

### Commit Messages

```bash
# Schema migrations
git commit -m "feat(db): add user_preferences table with indexes"
git commit -m "feat(db): add email column to users table"

# Data migrations
git commit -m "chore(db): backfill user status from legacy field"

# Fixes
git commit -m "fix(db): correct foreign key constraint on orders"
```

### Pre-Push Checklist

Before pushing migration files:

1. ✅ Migration has both UP and DOWN sections
2. ✅ DOWN section actually reverses the UP changes
3. ✅ Tested locally (run up, run down, run up again)
4. ✅ No modifications to already-pushed migrations
5. ✅ Timestamp is current (regenerate if rebasing)

## Team Collaboration

### Avoiding Conflicts

1. **Pull before creating** new migrations
2. **Use timestamps** (not sequential numbers) for ordering
3. **One migration per PR** when possible
4. **Rebase carefully** - may need to regenerate timestamps

### Conflict Resolution

If two developers create migrations with same timestamp:

```bash
# Developer B rebases and regenerates timestamp
git rebase main
# Rename migration file with new timestamp
mv migrations/20240502100843_add_phone.sql \
   migrations/20240502101530_add_phone.sql
```

### Never Modify Pushed Migrations

Once a migration is pushed to a shared branch:

```
❌ NEVER edit the migration file
❌ NEVER rename the migration file
❌ NEVER delete the migration file

✅ Create a NEW migration to fix issues
✅ Create a NEW migration to rollback changes
```

## CI/CD Integration

### GitHub Actions Example

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
          # Run a simple query to verify database is accessible
          psql $DATABASE_URL -c "SELECT 1"
```

## Tool-Specific Patterns

### Flyway

```
migrations/
├── V1__create_users.sql
├── V2__add_email_to_users.sql
├── R__refresh_views.sql          # Repeatable
└── U2__undo_add_email.sql        # Undo
```

### Prisma

```bash
npx prisma migrate dev --name add_user_email    # Development
npx prisma migrate deploy                        # Production
npx prisma migrate reset                         # Reset (dev only)
```

### Laravel

```bash
php artisan make:migration create_users_table
php artisan migrate
php artisan migrate:rollback
php artisan migrate:fresh --seed    # Dev only
```

### Rails

```bash
rails generate migration CreateUsers
rails db:migrate
rails db:rollback
rails db:migrate:redo              # Rollback + migrate
```

### Raw SQL (Framework-Agnostic)

```bash
# Simple migration runner script
#!/bin/bash
for f in migrations/*.sql; do
    echo "Running $f..."
    psql $DATABASE_URL -f "$f"
done
```

## Rollback Procedures

### Single Migration Rollback

```bash
# Extract and run DOWN section
# Most tools have built-in commands:
flyway undo
npx prisma migrate resolve --rolled-back 20240502100843_add_email
rails db:rollback STEP=1
php artisan migrate:rollback --step=1
```

### Point-in-Time Recovery

For catastrophic failures, restore from backup:

```bash
# PostgreSQL
pg_restore -d dbname backup_before_migration.dump

# MySQL
mysql dbname < backup_before_migration.sql
```

## Migration Tracking Table

Most tools create a tracking table:

```sql
-- Example: Flyway schema_history
CREATE TABLE flyway_schema_history (
    installed_rank INT PRIMARY KEY,
    version VARCHAR(50),
    description VARCHAR(200),
    type VARCHAR(20),
    script VARCHAR(1000),
    checksum INT,
    installed_by VARCHAR(100),
    installed_on TIMESTAMP,
    execution_time INT,
    success BOOLEAN
);
```

Query to see migration status:

```sql
SELECT version, description, installed_on, success
FROM flyway_schema_history
ORDER BY installed_rank;
```
