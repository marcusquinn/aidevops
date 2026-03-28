# Schema Definition

## Column Types

```typescript
import { pgTable, uuid, text, varchar, integer, bigint, boolean,
  timestamp, date, numeric, json, jsonb, pgEnum, serial } from 'drizzle-orm/pg-core';

// Primary Keys
id: uuid('id').primaryKey().defaultRandom(),           // UUIDv4
id: uuid('id').primaryKey().default(sql`uuidv7()`),    // UUIDv7 (PG18+)
id: integer('id').primaryKey().generatedAlwaysAsIdentity(),  // Identity
id: serial('id').primaryKey(),                          // Serial (legacy)

// Strings
name: text('name').notNull(),
email: varchar('email', { length: 255 }).unique(),

// Numbers
age: integer('age'),
price: numeric('price', { precision: 10, scale: 2 }),
count: bigint('count', { mode: 'number' }),

// Boolean
active: boolean('active').default(true),

// Timestamps
createdAt: timestamp('created_at', { withTimezone: true }).defaultNow(),
updatedAt: timestamp('updated_at', { withTimezone: true }).$onUpdate(() => new Date()),

// JSON
data: jsonb('data').$type<{ key: string }>(),

// Arrays
tags: text('tags').array(),
```

## Constraints

```typescript
email: text('email').notNull().unique(),
status: text('status').notNull().default('pending'),
price: numeric('price').check(sql`price > 0`),

// Foreign Key
authorId: uuid('author_id').references(() => users.id, { onDelete: 'cascade' }),
```

## Indexes

```typescript
}, (table) => [
  index('idx_name').on(table.column),                    // B-tree
  uniqueIndex('idx_unique').on(table.column),            // Unique
  index('idx_composite').on(table.col1, table.col2),     // Composite
  index('idx_partial').on(table.col).where(sql`...`),    // Partial
]);
```

## Enums

```typescript
export const statusEnum = pgEnum('status', ['pending', 'active', 'archived']);
status: statusEnum('status').default('pending'),
```
