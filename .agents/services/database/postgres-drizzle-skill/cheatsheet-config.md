# Configuration & Setup

## drizzle-kit Commands

```bash
npx drizzle-kit generate   # Generate migration from schema
npx drizzle-kit migrate    # Apply migrations
npx drizzle-kit push       # Push schema directly (dev)
npx drizzle-kit pull       # Introspect existing DB
npx drizzle-kit studio     # Open Drizzle Studio
npx drizzle-kit check      # Verify migrations
```

## drizzle.config.ts

```typescript
import { defineConfig } from 'drizzle-kit';

export default defineConfig({
  schema: './src/db/schema.ts',
  out: './drizzle',
  dialect: 'postgresql',
  dbCredentials: {
    url: process.env.DATABASE_URL!,
  },
});
```

## Connection Setup

### postgres.js (Recommended)

```typescript
import { drizzle } from 'drizzle-orm/postgres-js';
import postgres from 'postgres';
import * as schema from './schema';

const client = postgres(process.env.DATABASE_URL!);
export const db = drizzle(client, { schema });
```

### node-postgres

```typescript
import { drizzle } from 'drizzle-orm/node-postgres';
import { Pool } from 'pg';
import * as schema from './schema';

const pool = new Pool({ connectionString: process.env.DATABASE_URL });
export const db = drizzle(pool, { schema });
```
