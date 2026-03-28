# Drizzle Migrations

Reference for managing database migrations with drizzle-kit.

For base config and commands, see [cheatsheet-config.md](cheatsheet-config.md). This file covers migration-specific config, workflows, patterns, and troubleshooting.

---

## Migration-Specific Config

**Multiple schema files:**

```typescript
schema: './src/db/schema/*.ts',  // glob
// or
schema: ['./src/db/schema/users.ts', './src/db/schema/posts.ts'],
```

**Environment-specific credentials:**

```typescript
dbCredentials: {
  url: process.env.NODE_ENV === 'production'
    ? process.env.DATABASE_URL!
    : process.env.DEV_DATABASE_URL!,
},
```

**`verbose: true` and `strict: true`** in `defineConfig()` are recommended for migration safety.

---

## Push vs Generate

| Aspect | `push` | `generate` + `migrate` |
|--------|--------|------------------------|
| Migration files | No | Yes |
| Version control | No | Yes |
| Rollback support | No | Manual |
| Team collaboration | Difficult | Easy |
| Production use | Not recommended | Recommended |

**Transitioning from push to migrate:**

```bash
npx drizzle-kit pull      # pull current schema as baseline
npx drizzle-kit generate  # future changes use generate
```

---

## Development Workflow

```bash
# 1. Modify schema in TypeScript
# 2. Generate and review migration
npx drizzle-kit generate
cat drizzle/0001_*.sql
# 3. Apply locally
npx drizzle-kit migrate
```

**Output structure:**

```text
drizzle/
  0000_initial.sql
  0001_add_posts_table.sql
  meta/
    0000_snapshot.json
    _journal.json
```

---

## Production Workflow

**Option 1: Programmatic migration**

```typescript
// src/db/migrate.ts
import { drizzle } from 'drizzle-orm/postgres-js';
import { migrate } from 'drizzle-orm/postgres-js/migrator';
import postgres from 'postgres';

const runMigrations = async () => {
  const connection = postgres(process.env.DATABASE_URL!, { max: 1 });
  const db = drizzle(connection);
  await migrate(db, { migrationsFolder: './drizzle' });
  await connection.end();
};

runMigrations().catch(console.error);
```

```bash
node -r tsx src/db/migrate.ts  # run before app starts
```

**Option 2: CI/CD**

```yaml
- name: Run migrations
  run: npx drizzle-kit migrate
  env:
    DATABASE_URL: ${{ secrets.DATABASE_URL }}
```

**Option 3: Application startup**

```typescript
await migrate(db, { migrationsFolder: './drizzle' });
app.listen(3000);
```

---

## Migration Patterns

### Adding a column

```typescript
// Nullable (safe)
name: text('name'),
// Generated: ALTER TABLE "users" ADD COLUMN "name" text;

// Required (must include default for existing rows)
name: text('name').notNull().default('Unknown'),
// Generated: ALTER TABLE "users" ADD COLUMN "name" text NOT NULL DEFAULT 'Unknown';
```

### Renaming a column

**Warning:** Drizzle may generate DROP + ADD instead of RENAME. Use manual migration:

```sql
ALTER TABLE "users" RENAME COLUMN "name" TO "full_name";
```

### Adding an index

```typescript
(table) => [index('users_email_idx').on(table.email)]
// Generated: CREATE INDEX "users_email_idx" ON "users" ("email");
```

### Adding a foreign key

```typescript
authorId: uuid('author_id').notNull().references(() => users.id)
// Generated: ALTER TABLE "posts" ADD CONSTRAINT "posts_author_id_users_id_fk"
//   FOREIGN KEY ("author_id") REFERENCES "users"("id");
```

### Creating / dropping a table

Add or remove the table definition from schema. Drizzle generates the appropriate `CREATE TABLE` or `DROP TABLE` SQL.

---

## Custom Migrations

```sql
-- drizzle/0005_custom_migration.sql
ALTER TABLE posts ADD COLUMN search_vector tsvector;
CREATE INDEX posts_search_idx ON posts USING gin(search_vector);

CREATE OR REPLACE FUNCTION posts_search_trigger() RETURNS trigger AS $$
BEGIN
  NEW.search_vector := to_tsvector('english', NEW.title || ' ' || NEW.content);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER posts_search_update
  BEFORE INSERT OR UPDATE ON posts
  FOR EACH ROW EXECUTE FUNCTION posts_search_trigger();
```

**Data migrations:**

```sql
UPDATE users SET full_name = first_name || ' ' || last_name WHERE full_name IS NULL;
UPDATE posts SET word_count = array_length(string_to_array(content, ' '), 1);
```

---

## Rollback Strategies

Drizzle doesn't generate automatic rollbacks. Tracking table: `SELECT * FROM __drizzle_migrations;`

- **Manual rollback script**: Create `drizzle/rollback/NNNN_name.sql` alongside each migration
- **Point-in-time recovery**: Use PostgreSQL backup/restore for critical rollbacks
- **Additive design**: Prefer nullable columns and feature flags — add before requiring

```typescript
newFeature: text('new_feature'),           // Phase 1: nullable (safe)
newFeature: text('new_feature').notNull(), // Phase 2: required after backfill
```

---

## Best Practices

1. **Review generated SQL** before applying: `cat drizzle/0001_*.sql`
2. **Test on production copy**: `pg_dump production_db | psql test_db && npx drizzle-kit migrate --config=drizzle.config.test.ts`
3. **One feature per migration** — easier to review and rollback
4. **Wrap large data migrations** in `BEGIN; ... COMMIT;`
5. **Zero-downtime indexes**: `CREATE INDEX CONCURRENTLY users_email_idx ON users(email);`
6. **Version control migrations** — never add `drizzle/` to `.gitignore`
7. **CI validation**: `npx drizzle-kit generate && git diff --exit-code drizzle/`

---

## Troubleshooting

**"Migration already applied"**

```sql
SELECT * FROM __drizzle_migrations;
-- Manually mark as applied if needed:
INSERT INTO __drizzle_migrations (hash, created_at) VALUES ('migration_hash', NOW());
```

**"Schema out of sync"**

```bash
npx drizzle-kit pull
diff src/db/schema.ts drizzle/schema.ts
```

**"Cannot drop column"** — check for dependencies:

```sql
SELECT * FROM pg_depend WHERE refobjid = 'table_name'::regclass;
```

**Concurrent migration issues** — use advisory locks:

```typescript
await db.execute(sql`SELECT pg_advisory_lock(12345)`);
await migrate(db, { migrationsFolder: './drizzle' });
await db.execute(sql`SELECT pg_advisory_unlock(12345)`);
```
