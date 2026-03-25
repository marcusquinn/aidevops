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
// UUID (recommended)
id: uuid('id').primaryKey().defaultRandom(),           // UUIDv4
id: uuid('id').primaryKey().default(sql`uuidv7()`),    // UUIDv7 (PG18+, better index perf)

// Identity (preferred over serial)
id: integer('id').primaryKey().generatedAlwaysAsIdentity(),
id: integer('id').primaryKey().generatedByDefaultAsIdentity(),  // allows manual override
id: integer('id').primaryKey().generatedAlwaysAsIdentity({ startWith: 1000, increment: 1, cache: 100 }),

// Serial (legacy)
id: serial('id').primaryKey(),       // 4 bytes, up to 2,147,483,647
id: bigserial('id').primaryKey(),    // 8 bytes, up to 9,223,372,036,854,775,807
id: smallserial('id').primaryKey(),  // 2 bytes, up to 32,767
```

## String Types

```typescript
name: text('name').notNull(),                          // unlimited length
email: varchar('email', { length: 255 }).notNull(),    // variable with limit
countryCode: char('country_code', { length: 2 }),      // fixed, padded with spaces
status: text('status').notNull().default('pending'),
```

## Numeric Types

```typescript
// Integers
age: integer('age'),                                          // 4 bytes
count: smallint('count'),                                     // 2 bytes
bigNumber: bigint('big_number', { mode: 'number' }),          // JS number
bigNumberStr: bigint('big_number', { mode: 'bigint' }),       // JS BigInt

// Floating point (approximate)
score: real('score'),                   // 4 bytes, 6 decimal precision
amount: doublePrecision('amount'),      // 8 bytes, 15 decimal precision

// Exact numeric (use for money)
price: numeric('price', { precision: 10, scale: 2 }),
total: decimal('total', { precision: 19, scale: 4 }),  // alias for numeric
```

## Date/Time Types

```typescript
// Timestamp with timezone (recommended)
createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
localTime: timestamp('local_time', { withTimezone: false }),

// Timestamp modes
tsDate: timestamp('ts', { mode: 'date' }),      // JavaScript Date (default)
tsString: timestamp('ts', { mode: 'string' }),  // ISO string
tsNumber: timestamp('ts', { mode: 'number' }),  // Unix timestamp
precise: timestamp('precise', { precision: 6, withTimezone: true }),

// Date / Time / Interval
birthDate: date('birth_date'),
birthDateString: date('birth_date', { mode: 'string' }),  // 'YYYY-MM-DD'
openTime: time('open_time'),
openTimeWithTz: time('open_time', { withTimezone: true }),
duration: interval('duration'),
```

## Boolean

```typescript
isActive: boolean('is_active').notNull().default(true),
verified: boolean('verified').default(false),
```

## JSON/JSONB

JSONB is preferred (binary format, indexable, faster queries).

```typescript
data: jsonb('data'),
settings: jsonb('settings').$type<{ theme: 'light' | 'dark'; notifications: boolean; language: string }>(),
config: jsonb('config').$type<Record<string, unknown>>().default({}),
rawData: json('raw_data'),  // text format, preserves whitespace/order
```

### Querying JSONB

```typescript
.where(sql`${events.data}->>'type' = 'purchase'`)     // access nested field
.where(sql`${events.data} @> '{"status": "active"}'`) // containment (@>)
.where(sql`${events.data} ? 'error_code'`)             // key existence
```

## Enums

```typescript
// PostgreSQL enum
export const statusEnum = pgEnum('status', ['pending', 'active', 'archived']);
export const roleEnum = pgEnum('user_role', ['admin', 'user', 'guest']);

export const users = pgTable('users', {
  id: uuid('id').primaryKey().defaultRandom(),
  status: statusEnum('status').notNull().default('pending'),
  role: roleEnum('role').notNull().default('user'),
});

// TypeScript enum alternative (check constraint — easier to modify)
export const users = pgTable('users', {
  status: text('status', { enum: ['pending', 'active', 'archived'] }).notNull(),
});
```

## Arrays

```typescript
tags: text('tags').array(),
scores: integer('scores').array(),
categories: text('categories').array().default([]),

// Querying
import { arrayContains, arrayContained, arrayOverlaps } from 'drizzle-orm';
.where(arrayContains(posts.tags, ['typescript', 'drizzle']))
.where(arrayOverlaps(posts.tags, ['react', 'vue']))
```

## Constraints

```typescript
// Not null & default
email: text('email').notNull(),
status: text('status').notNull().default('active'),
createdAt: timestamp('created_at').notNull().defaultNow(),

// Unique (column-level)
email: text('email').notNull().unique(),

// Unique (composite, table-level)
}, (table) => [
  uniqueIndex('users_email_tenant_idx').on(table.email, table.tenantId),
]);

// Check constraints
export const products = pgTable('products', {
  price: numeric('price', { precision: 10, scale: 2 }).notNull(),
  quantity: integer('quantity').notNull(),
}, (table) => [
  check('price_positive', sql`${table.price} > 0`),
  check('quantity_non_negative', sql`${table.quantity} >= 0`),
]);
```

## Foreign Keys

```typescript
// Inline reference
authorId: uuid('author_id').notNull().references(() => users.id),

// With actions
authorId: uuid('author_id').notNull().references(() => users.id, {
  onDelete: 'cascade',  // CASCADE | SET NULL | SET DEFAULT | RESTRICT | NO ACTION
  onUpdate: 'cascade',
}),

// Self-referential
import { AnyPgColumn } from 'drizzle-orm/pg-core';
parentId: uuid('parent_id').references((): AnyPgColumn => categories.id),

// Composite foreign key
export const orderItems = pgTable('order_items', {
  orderId: uuid('order_id').notNull(),
  productId: uuid('product_id').notNull(),
  quantity: integer('quantity').notNull(),
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
  index('users_email_lower_idx').on(sql`lower(${table.email})`),    // expression

  // Index types: default=btree, 'hash' (equality only), 'gin' (arrays/JSONB/FTS), 'gist' (geometric/range)
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

## Reusable Timestamps Pattern

```typescript
const timestamps = {
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow().$onUpdate(() => new Date()),
};

export const users = pgTable('users', { id: uuid('id').primaryKey().defaultRandom(), email: text('email').notNull(), ...timestamps });
export const posts = pgTable('posts', { id: uuid('id').primaryKey().defaultRandom(), title: text('title').notNull(), ...timestamps });
```

## Soft Delete Pattern

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

## Multi-Tenant Pattern

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

## Generated Columns

```typescript
// Stored (computed at write)
totalPrice: numeric('total_price', { precision: 10, scale: 2 })
  .generatedAlwaysAs(sql`price * (1 + tax_rate)`),

// Virtual (PG18+, computed at read — not stored on disk)
displayPrice: text('display_price').generatedAlwaysAs(sql`price::text || ' USD'`),
```

## Schema Organization

```
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

// schema/index.ts
export * from './users';
export * from './posts';
export * from './comments';
```
