<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Drizzle Schema Definition

Comprehensive reference for defining PostgreSQL schemas with Drizzle ORM.

## Imports

```typescript
import {
  pgTable, uuid, text, varchar, char,
  integer, smallint, bigint, serial, smallserial, bigserial,
  boolean, timestamp, date, time, interval,
  numeric, decimal, real, doublePrecision,
  json, jsonb, pgEnum,
  index, uniqueIndex, primaryKey, foreignKey, check,
} from 'drizzle-orm/pg-core';
import { sql } from 'drizzle-orm';
```

## Primary Keys

```typescript
id: uuid('id').primaryKey().defaultRandom(),                    // UUIDv4
id: uuid('id').primaryKey().default(sql`uuidv7()`),             // UUIDv7 (PG18+, better index perf)
id: integer('id').primaryKey().generatedAlwaysAsIdentity(),      // Identity (preferred over serial)
id: integer('id').primaryKey().generatedByDefaultAsIdentity(),   // Identity, allows manual override
id: integer('id').primaryKey().generatedAlwaysAsIdentity({ startWith: 1000, increment: 1, cache: 100 }),
id: serial('id').primaryKey(),                                   // Serial 4B (legacy)
id: bigserial('id').primaryKey(),                                // Serial 8B (legacy)
id: smallserial('id').primaryKey(),                              // Serial 2B (legacy)
```

## Column Types

```typescript
// Strings
name: text('name').notNull(),                                    // unlimited length
email: varchar('email', { length: 255 }).notNull(),              // variable with limit
countryCode: char('country_code', { length: 2 }),                // fixed, space-padded
status: text('status').notNull().default('pending'),

// Numeric — integers
age: integer('age'),                                             // 4B
count: smallint('count'),                                        // 2B
bigNumber: bigint('big_number', { mode: 'number' }),             // 8B → JS number
bigNumberStr: bigint('big_number', { mode: 'bigint' }),          // 8B → JS BigInt

// Numeric — floating point (approximate)
score: real('score'),                                            // 4B, ~6 decimal digits
amount: doublePrecision('amount'),                               // 8B, ~15 decimal digits

// Numeric — exact (use for money)
price: numeric('price', { precision: 10, scale: 2 }),
total: decimal('total', { precision: 19, scale: 4 }),            // alias for numeric

// Boolean
isActive: boolean('is_active').notNull().default(true),
verified: boolean('verified').default(false),

// Timestamps — withTimezone: true recommended
createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
localTime: timestamp('local_time', { withTimezone: false }),
precise: timestamp('precise', { precision: 6, withTimezone: true }),
// Modes: 'date' (JS Date, default), 'string' (ISO), 'number' (Unix)
tsDate: timestamp('ts', { mode: 'date' }),
tsString: timestamp('ts', { mode: 'string' }),
tsNumber: timestamp('ts', { mode: 'number' }),

// Date / Time / Interval
birthDate: date('birth_date'),                                   // JS Date
birthDateString: date('birth_date', { mode: 'string' }),         // 'YYYY-MM-DD'
openTime: time('open_time'),
openTimeWithTz: time('open_time', { withTimezone: true }),
duration: interval('duration'),

// JSON — JSONB preferred (binary, indexable, faster). JSON preserves whitespace/key order.
data: jsonb('data'),
settings: jsonb('settings').$type<{ theme: 'light' | 'dark'; notifications: boolean; language: string }>(),
config: jsonb('config').$type<Record<string, unknown>>().default({}),
rawData: json('raw_data'),

// Arrays
tags: text('tags').array(),
scores: integer('scores').array(),
categories: text('categories').array().default([]),
```

## Querying JSONB & Arrays

```typescript
// JSONB
.where(sql`${events.data}->>'type' = 'purchase'`)               // access nested field
.where(sql`${events.data} @> '{"status": "active"}'`)           // containment (@>)
.where(sql`${events.data} ? 'error_code'`)                      // key existence

// Arrays
import { arrayContains, arrayContained, arrayOverlaps } from 'drizzle-orm';
.where(arrayContains(posts.tags, ['typescript', 'drizzle']))
.where(arrayOverlaps(posts.tags, ['react', 'vue']))
```

## Enums

```typescript
export const statusEnum = pgEnum('status', ['pending', 'active', 'archived']);
export const roleEnum = pgEnum('user_role', ['admin', 'user', 'guest']);

export const users = pgTable('users', {
  id: uuid('id').primaryKey().defaultRandom(),
  status: statusEnum('status').notNull().default('pending'),
  role: roleEnum('role').notNull().default('user'),
});

// Text + enum constraint (easier to modify, no migration for new values)
status: text('status', { enum: ['pending', 'active', 'archived'] }).notNull(),
```

## Constraints & Foreign Keys

```typescript
// Not null, default, unique
email: text('email').notNull().unique(),
status: text('status').notNull().default('active'),
createdAt: timestamp('created_at').notNull().defaultNow(),

// Composite unique (table-level)
}, (table) => [
  uniqueIndex('users_email_tenant_idx').on(table.email, table.tenantId),
]);

// Check constraints
}, (table) => [
  check('price_positive', sql`${table.price} > 0`),
  check('quantity_non_negative', sql`${table.quantity} >= 0`),
]);

// Foreign key — inline
authorId: uuid('author_id').notNull().references(() => users.id),

// Foreign key — with actions (CASCADE | SET NULL | SET DEFAULT | RESTRICT | NO ACTION)
authorId: uuid('author_id').notNull().references(() => users.id, {
  onDelete: 'cascade', onUpdate: 'cascade',
}),

// Self-referential
import { AnyPgColumn } from 'drizzle-orm/pg-core';
parentId: uuid('parent_id').references((): AnyPgColumn => categories.id),

// Composite foreign key
}, (table) => [
  foreignKey({ columns: [table.orderId, table.productId], foreignColumns: [orders.id, products.id] }),
]);
```

## Indexes

```typescript
}, (table) => [
  index('users_email_idx').on(table.email),                          // single column
  index('orders_user_date_idx').on(table.userId, table.createdAt),   // composite
  uniqueIndex('users_email_unique').on(table.email),                 // unique
  index('active_users_idx').on(table.email).where(sql`deleted_at IS NULL`), // partial
  index('users_email_lower_idx').on(sql`lower(${table.email})`),     // expression
  // Types: btree (default), hash (equality only), gin (arrays/JSONB/FTS), gist (geometric/range)
  index('idx').on(table.data).using('gin'),
]);
```

## Composite Primary Key

```typescript
import { primaryKey } from 'drizzle-orm/pg-core';

export const usersToGroups = pgTable('users_to_groups', {
  userId: uuid('user_id').notNull().references(() => users.id),
  groupId: uuid('group_id').notNull().references(() => groups.id),
  joinedAt: timestamp('joined_at').notNull().defaultNow(),
}, (table) => [
  primaryKey({ columns: [table.userId, table.groupId] }),
]);
```

## Common Patterns

### Reusable Timestamps

```typescript
const timestamps = {
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow().$onUpdate(() => new Date()),
};

export const users = pgTable('users', { id: uuid('id').primaryKey().defaultRandom(), email: text('email').notNull(), ...timestamps });
```

### Soft Delete

```typescript
export const users = pgTable('users', {
  id: uuid('id').primaryKey().defaultRandom(),
  email: text('email').notNull(),
  deletedAt: timestamp('deleted_at', { withTimezone: true }),
  ...timestamps,
}, (table) => [
  index('active_users_email_idx').on(table.email).where(sql`deleted_at IS NULL`),
]);

import { isNull } from 'drizzle-orm';
const activeUsers = await db.select().from(users).where(isNull(users.deletedAt));
```

### Multi-Tenant

```typescript
export const users = pgTable('users', {
  id: uuid('id').primaryKey().defaultRandom(),
  tenantId: uuid('tenant_id').notNull().references(() => tenants.id),
  email: text('email').notNull(),
}, (table) => [
  uniqueIndex('users_tenant_email_idx').on(table.tenantId, table.email),
  index('users_tenant_idx').on(table.tenantId),
]);
```

### Generated Columns

```typescript
totalPrice: numeric('total_price', { precision: 10, scale: 2 })
  .generatedAlwaysAs(sql`price * (1 + tax_rate)`),              // stored (computed at write)
displayPrice: text('display_price')
  .generatedAlwaysAs(sql`price::text || ' USD'`),               // virtual (PG18+, computed at read)
```

## Schema Organization

```text
# Small projects          # Large projects
src/db/                   src/db/
  schema.ts               schema/
  index.ts                  index.ts     # re-exports all
                            users.ts     # table + relations
                            posts.ts
                            comments.ts
                          index.ts
```

```typescript
// schema/users.ts
export const users = pgTable('users', { ... });
export const usersRelations = relations(users, ({ many }) => ({ ... }));

// schema/index.ts — re-export all
export * from './users';
export * from './posts';
export * from './comments';
```
