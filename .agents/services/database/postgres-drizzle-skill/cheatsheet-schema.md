# Schema Definition

## Column Types

```typescript
import { bigint, boolean, integer, jsonb, numeric, serial, text, timestamp, uuid, varchar } from 'drizzle-orm/pg-core';

// Primary keys
id: uuid('id').primaryKey().defaultRandom(),
id: uuid('id').primaryKey().default(sql`uuidv7()`),
id: integer('id').primaryKey().generatedAlwaysAsIdentity(),
id: serial('id').primaryKey(),

// Scalars
name: text('name').notNull(),
email: varchar('email', { length: 255 }).unique(),
age: integer('age'),
price: numeric('price', { precision: 10, scale: 2 }),
count: bigint('count', { mode: 'number' }),
active: boolean('active').default(true),

// Time and structured data
createdAt: timestamp('created_at', { withTimezone: true }).defaultNow(),
updatedAt: timestamp('updated_at', { withTimezone: true }).$onUpdate(() => new Date()),
data: jsonb('data').$type<{ key: string }>(),
tags: text('tags').array(),
```

## Constraints

```typescript
email: text('email').notNull().unique(),
status: text('status').notNull().default('pending'),
price: numeric('price').check(sql`price > 0`),

// Foreign key
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
