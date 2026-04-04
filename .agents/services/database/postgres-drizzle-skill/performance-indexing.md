<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Performance: Indexing

## B-Tree (Default)

Equality, range, sorting, left-anchored LIKE.

```sql
CREATE INDEX users_email_idx ON users(email);
CREATE INDEX orders_user_date_idx ON orders(user_id, created_at DESC);  -- composite (order matters)
CREATE UNIQUE INDEX users_email_unique ON users(email);
```

```typescript
export const users = pgTable('users', {
  email: text('email').notNull(),
  createdAt: timestamp('created_at').notNull(),
}, (table) => [
  index('users_email_idx').on(table.email),
  index('users_created_idx').on(table.createdAt),
]);
```

## Partial Indexes

```sql
CREATE INDEX active_users_email_idx ON users(email) WHERE deleted_at IS NULL;
CREATE INDEX pending_orders_idx ON orders(created_at) WHERE status = 'pending';
```

```typescript
index('active_users_idx').on(table.email).where(sql`deleted_at IS NULL`)
```

## Covering Indexes (INCLUDE)

```sql
CREATE INDEX orders_user_idx ON orders(user_id) INCLUDE (status, total);  -- index-only scan
```

## GIN for JSONB

| Class | Size | Operators | Best For |
|-------|------|-----------|----------|
| `jsonb_ops` (default) | 60-80% | @>, ?, ?\|, ?& | Key existence |
| `jsonb_path_ops` | 20-30% | @> only | Containment only |

```sql
CREATE INDEX data_gin_idx ON events USING gin(data);
CREATE INDEX data_gin_path_idx ON events USING gin(data jsonb_path_ops);  -- smaller
```

## Expression Indexes

Query must match expression exactly.

```sql
CREATE INDEX users_email_lower_idx ON users(lower(email));
CREATE INDEX orders_month_idx ON orders(date_trunc('month', created_at));
CREATE INDEX events_type_idx ON events((data->>'type'));
-- lower(email) = '...' uses index; email = 'UPPER@...' does NOT
```
