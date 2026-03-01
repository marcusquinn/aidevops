---
description: PGlite - Embedded Postgres for local-first desktop and extension apps
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# PGlite - Local-First Embedded Postgres

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Embedded Postgres (WASM) for desktop/extension apps that share schema with a production Postgres backend
- **Package**: `@electric-sql/pglite` (~3MB gzipped)
- **Drizzle adapter**: `drizzle-orm/pglite`
- **Sync**: ElectricSQL (`@electric-sql/pglite-sync`) - pull-only in v1
- **Docs**: https://pglite.dev/docs/
- **Repo**: https://github.com/electric-sql/pglite
- **License**: Apache 2.0 / PostgreSQL License (dual)

**When to use PGlite**: You have a Postgres production DB with Drizzle `pg-core` schemas and need an embedded local database in an Electron, Tauri, or browser extension app. PGlite lets you reuse the exact same schema, migrations, and queries locally.

**When NOT to use PGlite**:

- React Native / Expo mobile apps (WASM not supported in RN runtime)
- CLI tools or shell scripts (no CLI interface; use SQLite)
- High-frequency write workloads (WASM overhead, ~5k inserts/sec vs ~50k for native SQLite)
- Datasets >500MB local (memory pressure from WASM)
- Projects using SQLite schemas (`sqliteTable`) - no benefit, added complexity

<!-- AI-CONTEXT-END -->

## Decision Guide: PGlite vs SQLite for Local Embedded DB

```text
Is your production DB PostgreSQL?
  NO  --> Use SQLite (better-sqlite3 / bun:sqlite)
  YES --> Are you using Drizzle pg-core schemas (pgTable, pgEnum, timestamp)?
    NO  --> Either works; SQLite is simpler
    YES --> Is the target Electron, Tauri, or browser extension?
      NO (React Native)  --> SQLite + PowerSync (WASM not supported in RN)
      YES --> PGlite (shared schema, zero translation layer)
```

### Why PGlite over SQLite when production is Postgres

| Factor | PGlite | SQLite |
|--------|--------|--------|
| Schema sharing | Same `pgTable` / `pgEnum` / `timestamp` | Requires separate `sqliteTable` schema |
| Migrations | Identical SQL for local and production | Separate migration sets per dialect |
| Drizzle dialect | `drizzle-orm/pglite` (pg-core) | `drizzle-orm/better-sqlite3` (sqlite-core) |
| Type fidelity | Full: enums, timestamps, booleans | Lossy: enum->text, timestamp->text, boolean->integer |
| ORM code reuse | 100% - same queries work everywhere | Separate query layer per dialect |
| Performance | ~3-5x slower than native SQLite (WASM) | Native speed |
| Bundle size | +3MB gzipped (WASM binary) | ~1MB native addon |
| Startup time | 500ms-2s (WASM init) | <50ms |

**The schema compatibility advantage is decisive.** Maintaining two Drizzle dialects (pg-core for prod, sqlite-core for local) means duplicate schemas, separate migrations, type mapping bugs, and divergent query logic. PGlite eliminates all of this.

## Implementation Pattern

### 1. Drizzle adapter swap (one schema, two runtimes)

The core pattern: your `@workspace/db` package exports schema and a factory. Each runtime provides its own client.

```typescript
// packages/db/src/schema/index.ts (SHARED - no changes needed)
import { pgTable, pgEnum, text, timestamp, boolean } from "drizzle-orm/pg-core";

export const statusEnum = pgEnum("status", ["active", "inactive"]);

export const items = pgTable("items", {
  id: text("id").primaryKey(),
  title: text("title").notNull(),
  status: statusEnum("status").notNull(),
  createdAt: timestamp("created_at").defaultNow().notNull(),
});
```

```typescript
// packages/db/src/server.ts (PRODUCTION - existing, unchanged)
import { drizzle } from "drizzle-orm/postgres-js";
import postgres from "postgres";
import * as schema from "./schema";

const client = postgres(process.env.DATABASE_URL!);
export const db = drizzle({ client, schema, casing: "snake_case" });
```

```typescript
// packages/db/src/local.ts (NEW - PGlite for desktop/extension)
import { PGlite } from "@electric-sql/pglite";
import { drizzle } from "drizzle-orm/pglite";
import * as schema from "./schema";

export async function createLocalDb(dataDir: string) {
  const client = new PGlite(dataDir);
  await client.waitReady;
  return drizzle({ client, schema, casing: "snake_case" });
}
```

```jsonc
// packages/db/package.json - add export
{
  "exports": {
    ".": "./src/index.ts",
    "./server": "./src/server.ts",
    "./local": "./src/local.ts",
    "./schema": "./src/schema/index.ts"
  }
}
```

### 2. Electron integration

Run PGlite in the main process. Expose typed operations via IPC to renderer.

**Security note**: Never expose raw SQL execution over IPC. A compromised renderer (e.g. XSS) could escalate to full DB access. Instead, expose specific named operations.

```typescript
// apps/desktop/src/main/database.ts
import { createLocalDb } from "@workspace/db/local";
import { eq } from "drizzle-orm";
import { app, ipcMain } from "electron";
import { migrate } from "drizzle-orm/pglite/migrator";
import path from "path";
import * as schema from "@workspace/db/schema";

let db: Awaited<ReturnType<typeof createLocalDb>>;

export async function initDatabase() {
  const dataDir = path.join(app.getPath("userData"), "pgdata");
  db = await createLocalDb(dataDir);

  // Migrations path: use app.getAppPath() for packaged builds
  // __dirname is unreliable in asar archives — bundle migrations
  // as extraResources or resolve via app.getAppPath()
  const migrationsPath = app.isPackaged
    ? path.join(process.resourcesPath, "migrations")
    : path.join(app.getAppPath(), "packages/db/migrations");

  await migrate(db, { migrationsFolder: migrationsPath });

  // Expose NAMED operations — never raw SQL over IPC
  ipcMain.handle("db:items:list", async () => {
    return db.select().from(schema.items);
  });

  ipcMain.handle("db:items:get", async (_event, id: string) => {
    return db.select().from(schema.items).where(eq(schema.items.id, id));
  });

  return db;
}
```

```typescript
// apps/desktop/src/renderer/db.ts
import { ipcRenderer } from "electron";

// Type-safe IPC wrappers — no raw SQL exposed to renderer
export const items = {
  list: () => ipcRenderer.invoke("db:items:list"),
  get: (id: string) => ipcRenderer.invoke("db:items:get", id),
};
```

### 3. Browser extension integration (WXT / Manifest V3)

PGlite runs in the extension's service worker or offscreen document. Use IndexedDB persistence.

```typescript
// apps/extension/src/background/database.ts
import { PGlite } from "@electric-sql/pglite";
import { drizzle } from "drizzle-orm/pglite";
import * as schema from "@workspace/db/schema";

let db: ReturnType<typeof drizzle>;

export async function getDb() {
  if (!db) {
    const client = new PGlite("idb://extension-data");
    await client.waitReady;
    db = drizzle({ client, schema, casing: "snake_case" });
  }
  return db;
}
```

### 4. Tauri integration

PGlite runs in the webview's JS context with filesystem persistence via Tauri's app data directory.

```typescript
// apps/desktop-tauri/src/lib/database.ts
import { PGlite } from "@electric-sql/pglite";
import { drizzle } from "drizzle-orm/pglite";
import { appDataDir } from "@tauri-apps/api/path";
import * as schema from "@workspace/db/schema";

export async function createLocalDb() {
  const dataDir = await appDataDir();
  const client = new PGlite(`${dataDir}/pgdata`);
  await client.waitReady;
  return drizzle({ client, schema, casing: "snake_case" });
}
```

## Sync with Production Postgres

### Write-through-API pattern (recommended)

PGlite serves as a **local read cache**. Writes go through your existing API (Hono, tRPC, etc.) to the production Postgres. ElectricSQL syncs changes back down.

```text
[Desktop/Extension App]
  |
  |-- READS --> PGlite (local, fast, offline-capable)
  |-- WRITES --> Hono API --> Production Postgres
  |                              |
  |                              v
  |<--- ElectricSQL sync ---- Postgres logical replication
```

This fits naturally with monorepo architectures where mobile and web apps already write through the API.

### ElectricSQL sync setup

```typescript
import { PGlite } from "@electric-sql/pglite";
import { electricSync } from "@electric-sql/pglite-sync";

const client = new PGlite("idb://my-app", {
  extensions: { electric: electricSync() },
});

// Sync a shape (subset of data) from production
await client.electric.syncShapeToTable({
  shape: {
    url: "https://your-electric-server.com/v1/shape",
    params: { table: "items" },
  },
  table: "items",
  primaryKey: ["id"],
});
```

**ElectricSQL v1 limitations**:

- Pull-only (server to client). Writes require API calls.
- Requires Postgres with logical replication enabled.
- Self-hosting Electric requires Docker + Postgres config.
- Large initial shape loads can be slow.

### Alternative: no sync (offline-only local DB)

For apps that don't need server sync (local-only tools, dev utilities), PGlite works standalone with filesystem or IndexedDB persistence. No ElectricSQL needed.

## Persistence Options

| Backend | Use case | Config |
|---------|----------|--------|
| In-memory | Tests, ephemeral | `new PGlite()` |
| Filesystem | Electron, Tauri, Node | `new PGlite("./path/to/pgdata")` |
| IndexedDB | Browser extension, PWA | `new PGlite("idb://db-name")` |

## Extensions

PGlite supports dynamic extension loading:

```typescript
import { PGlite } from "@electric-sql/pglite";
import { vector } from "@electric-sql/pglite/contrib/pgvector";

const db = new PGlite({
  extensions: { vector },
});

// pgvector works locally - same as production
await db.exec("CREATE EXTENSION IF NOT EXISTS vector");
await db.exec(`
  CREATE TABLE embeddings (
    id TEXT PRIMARY KEY,
    content TEXT,
    embedding vector(1536)
  )
`);
```

Supported extensions include: pgvector, pg_trgm, ltree, hstore, uuid-ossp. Check https://pglite.dev/extensions/ for the full list.

## Platform Compatibility Matrix

| Platform | Runtime | PGlite works? | Persistence | Notes |
|----------|---------|---------------|-------------|-------|
| Electron (main) | Node.js | Yes | Filesystem | Recommended: run in main process |
| Electron (renderer) | Chromium | Yes | IndexedDB | Use multi-tab worker for shared access |
| Tauri (webview) | WebView | Yes | Filesystem via Tauri API | |
| Browser extension (MV3) | Service worker | Yes | IndexedDB | Single connection; use offscreen doc for heavy queries |
| React Native / Expo | Hermes/JSC | No | N/A | WASM not supported; use SQLite + PowerSync |
| Node.js / Bun | Server | Yes | Filesystem | Useful for local dev without Docker Postgres |
| Deno | Server | Yes | Filesystem | |

## Performance Characteristics

```text
Approximate benchmarks (Apple Silicon, 100k rows):

PGlite (WASM):
  SELECT by PK:        ~0.5ms
  Complex JOIN:        ~15ms
  Full scan 100k:      ~80ms
  INSERT throughput:   ~5k/sec
  Startup (cold):      500ms-2s

better-sqlite3 (native):
  SELECT by PK:        ~0.1ms
  Complex JOIN:        ~5ms
  Full scan 100k:      ~20ms
  INSERT throughput:   ~50k/sec
  Startup:             <50ms
```

PGlite is 3-10x slower than native SQLite. This is acceptable for desktop/extension CRUD workloads but not suitable for high-throughput ingestion or real-time analytics on large datasets.

## Gotchas

1. **Single connection only** - PGlite is single-user. No concurrent writers. Use a mutex or message queue if multiple renderer windows need DB access.
2. **WASM startup latency** - Show a loading state. Don't block app launch on DB init.
3. **Electron version** - Requires Electron 28+ for reliable WASM SharedArrayBuffer support.
4. **Bundle size** - The WASM binary adds ~3MB gzipped to your app bundle.
5. **Not all extensions** - Check the extension matrix before assuming production Postgres extensions work locally.
6. **No `LISTEN/NOTIFY`** - Postgres pub/sub doesn't work in PGlite. Use PGlite's live query API instead for reactivity.

## Live Queries (Reactivity)

PGlite has built-in live query support - useful for reactive UIs without polling:

```typescript
import { live } from "@electric-sql/pglite/live";

const client = new PGlite({
  extensions: { live },
});

const db = drizzle({ client, schema });

// Subscribe to query results - callback fires on any change
const { unsubscribe } = await client.live.query(
  "SELECT * FROM items WHERE status = $1",
  ["active"],
  (results) => {
    // Re-render UI with updated data
    updateItemsList(results.rows);
  }
);
```

## Related

- **Vector search**: `tools/database/vector-search.md` — decision guide for vector databases including PGlite+pgvector for local-first vector search
- **SQLite (for aidevops internals)**: `memory/README.md` - SQLite FTS5 for cross-session memory
- **Multi-org isolation**: `services/database/multi-org-isolation.md` — tenant isolation schema for server-side Postgres
- **PowerSync**: https://www.powersync.com - SQLite sync with Postgres (better for React Native)
- **ElectricSQL**: https://electric-sql.com - Postgres sync engine (works with PGlite)
- **TanStack DB**: https://tanstack.com/db - Reactive client store (pairs with Electric)
