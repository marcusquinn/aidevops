<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Schema Definition

## Primary Keys

```typescript
import { integer, serial, uuid } from 'drizzle-orm/pg-core';
import { sql } from 'drizzle-orm';

id: uuid('id').primaryKey().defaultRandom(),                   // UUIDv4
id: uuid('id').primaryKey().default(sql`uuidv7()`),            // UUIDv7 (PG18+)
id: integer('id').primaryKey().generatedAlwaysAsIdentity(),    // identity (preferred over serial)
id: serial('id').primaryKey(),                                 // legacy
```

## Column Types

```typescript
import { bigint, boolean, integer, jsonb, numeric, text, timestamp, varchar } from 'drizzle-orm/pg-core';

name: text('name').notNull(),
email: varchar('email', { length: 255 }).unique(),
age: integer('age'),
price: numeric('price', { precision: 10, scale: 2 }),
count: bigint('count', { mode: 'number' }),
active: boolean('active').default(true),
createdAt: timestamp('created_at', { withTimezone: true }).defaultNow(),
updatedAt: timestamp('updated_at', { withTimezone: true }).$onUpdate(() => new Date()),
data: jsonb('data').$type<{ key: string }>(),
tags: text('tags').array(),
```

## Constraints & Foreign Keys

```typescript
import { check, uuid } from 'drizzle-orm/pg-core';
import { sql } from 'drizzle-orm';

email: text('email').notNull().unique(),
status: text('status').notNull().default('pending'),
authorId: uuid('author_id').references(() => users.id, { onDelete: 'cascade' }),

// check() is table-level only (not column-level)
}, (table) => [
  check('price_positive', sql`${table.price} > 0`),
]);
```

## Indexes

```typescript
import { index, uniqueIndex } from 'drizzle-orm/pg-core';
import { sql } from 'drizzle-orm';

}, (table) => [
  index('idx_name').on(table.column),                    // B-tree
  uniqueIndex('idx_unique').on(table.column),            // Unique
  index('idx_composite').on(table.col1, table.col2),     // Composite
  index('idx_partial').on(table.col).where(sql`...`),    // Partial
]);
```

## Enums

```typescript
import { pgEnum } from 'drizzle-orm/pg-core';

export const statusEnum = pgEnum('status', ['pending', 'active', 'archived']);
status: statusEnum('status').default('pending'),
```
