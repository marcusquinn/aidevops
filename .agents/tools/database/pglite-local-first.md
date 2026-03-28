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

- **Purpose**: Embedded Postgres (WASM) for desktop/extension apps sharing schema with a production Postgres backend
- **Package**: `@electric-sql/pglite` (~3MB gzipped)
- **Drizzle adapter**: `drizzle-orm/pglite`
- **Sync**: ElectricSQL (`@electric-sql/pglite-sync`) — pull-only in v1
- **Docs**: https://pglite.dev/docs/ | **Repo**: https://github.com/electric-sql/pglite
- **License**: Apache 2.0 / PostgreSQL License (dual)

<!-- AI-CONTEXT-END -->

## Decision Guide: PGlite vs SQLite

```text
Is your production DB PostgreSQL?
  NO  --> Use SQLite (better-sqlite3 / bun:sqlite)
  YES --> Are you using Drizzle pg-core schemas (pgTable, pgEnum, timestamp)?
    NO  --> Either works; SQLite is simpler
    YES --> Is the target Electron, Tauri, or browser extension?
      NO (React Native)  --> SQLite + PowerSync (WASM not supported in RN)
      YES --> PGlite (shared schema, zero translation layer)
```

**Do NOT use PGlite for**: React Native/Expo (WASM unsupported), CLI tools, high-frequency writes (>5k/sec), datasets >500MB, or SQLite-schema projects.

| Factor | PGlite | SQLite |
|--------|--------|--------|
| Schema sharing | Same `pgTable` / `pgEnum` / `timestamp` | Requires separate `sqliteTable` schema |
| Migrations | Identical SQL for local and production | Separate migration sets per dialect |
| Drizzle dialect | `drizzle-orm/pglite` (pg-core) | `drizzle-orm/better-sqlite3` (sqlite-core) |
| Type fidelity | Full: enums, timestamps, booleans | Lossy: enum→text, timestamp→text, boolean→integer |
| ORM code reuse | 100% — same queries work everywhere | Separate query layer per dialect |
| Performance | ~3-5x slower (WASM) | Native speed |
| Bundle size | +3MB gzipped | ~1MB native addon |
| Startup time | 500ms-2s | <50ms |

Maintaining two Drizzle dialects means duplicate schemas, separate migrations, type mapping bugs, and divergent query logic. PGlite eliminates all of this when production is Postgres.

## Implementation Pattern

### 1. Drizzle adapter swap (one schema, two runtimes)

Your `@workspace/db` package exports schema and a factory; each runtime provides its own client. Add `"./local": "./src/local.ts"` and `"./schema": "./src/schema/index.ts"` to `package.json` exports.

```typescript
// packages/db/src/schema/index.ts (SHARED - no changes needed)
import { pgTable, pgEnum, text, timestamp } from "drizzle-orm/pg-core";

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
export const db = drizzle({ client: postgres(process.env.DATABASE_URL!), schema, casing: "snake_case" });
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

### 2. Electron integration

Run PGlite in the main process. **Security**: never expose raw SQL over IPC — a compromised renderer (XSS) could escalate to full DB access. Expose named operations only.

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
  db = await createLocalDb(path.join(app.getPath("userData"), "pgdata"));

  // __dirname is unreliable in asar archives — bundle migrations as extraResources
  await migrate(db, {
    migrationsFolder: app.isPackaged
      ? path.join(process.resourcesPath, "migrations")
      : path.join(app.getAppPath(), "packages/db/migrations"),
  });

  ipcMain.handle("db:items:list", async () => db.select().from(schema.items));
  ipcMain.handle("db:items:get", async (_event, id: string) =>
    db.select().from(schema.items).where(eq(schema.items.id, id))
  );
  return db;
}
```

```typescript
// apps/desktop/src/renderer/db.ts — type-safe IPC wrappers, no raw SQL
import { ipcRenderer } from "electron";
export const items = {
  list: () => ipcRenderer.invoke("db:items:list"),
  get: (id: string) => ipcRenderer.invoke("db:items:get", id),
};
```

### 3. Browser extension (WXT / Manifest V3)

PGlite runs in the service worker or offscreen document with IndexedDB persistence. Use a lazy singleton to avoid re-initialising on every message.

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

PGlite runs in the webview's JS context. Use `appDataDir()` for filesystem persistence.

```typescript
import { PGlite } from "@electric-sql/pglite";
import { drizzle } from "drizzle-orm/pglite";
import { appDataDir } from "@tauri-apps/api/path";
import * as schema from "@workspace/db/schema";

export async function createLocalDb() {
  const client = new PGlite(`${await appDataDir()}/pgdata`);
  await client.waitReady;
  return drizzle({ client, schema, casing: "snake_case" });
}
```

## Sync with Production Postgres

**Write-through-API pattern (recommended)**: PGlite is a local read cache. Reads hit PGlite; writes go through your API (Hono, tRPC) to production Postgres; ElectricSQL syncs changes back down via logical replication.

```typescript
import { PGlite } from "@electric-sql/pglite";
import { electricSync } from "@electric-sql/pglite-sync";

const client = new PGlite("idb://my-app", { extensions: { electric: electricSync() } });
await client.electric.syncShapeToTable({
  shape: { url: "https://your-electric-server.com/v1/shape", params: { table: "items" } },
  table: "items",
  primaryKey: ["id"],
});
```

**ElectricSQL v1 limitations**: pull-only (writes require API calls), requires Postgres logical replication, self-hosting needs Docker, large initial shape loads can be slow.

For apps that don't need server sync, PGlite works standalone — no ElectricSQL needed.

## Persistence Options

| Backend | Use case | Config |
|---------|----------|--------|
| In-memory | Tests, ephemeral | `new PGlite()` |
| Filesystem | Electron, Tauri, Node | `new PGlite("./path/to/pgdata")` |
| IndexedDB | Browser extension, PWA | `new PGlite("idb://db-name")` |

## Extensions

```typescript
import { PGlite } from "@electric-sql/pglite";
import { vector } from "@electric-sql/pglite/contrib/pgvector";

const db = new PGlite({ extensions: { vector } });
await db.exec("CREATE EXTENSION IF NOT EXISTS vector");
await db.exec(`CREATE TABLE embeddings (id TEXT PRIMARY KEY, content TEXT, embedding vector(1536))`);
```

Supported: pgvector, pg_trgm, ltree, hstore, uuid-ossp. Full list: https://pglite.dev/extensions/

## Platform Compatibility

| Platform | Runtime | Works? | Persistence | Notes |
|----------|---------|--------|-------------|-------|
| Electron (main) | Node.js | Yes | Filesystem | Recommended: run in main process |
| Electron (renderer) | Chromium | Yes | IndexedDB | Use multi-tab worker for shared access |
| Tauri (webview) | WebView | Yes | Filesystem via Tauri API | |
| Browser extension (MV3) | Service worker | Yes | IndexedDB | Use offscreen doc for heavy queries |
| React Native / Expo | Hermes/JSC | No | N/A | WASM unsupported; use SQLite + PowerSync |
| Node.js / Bun | Server | Yes | Filesystem | Useful for local dev without Docker Postgres |
| Deno | Server | Yes | Filesystem | |

## Performance (Apple Silicon, 100k rows)

| Operation | PGlite (WASM) | better-sqlite3 (native) |
|-----------|---------------|------------------------|
| SELECT by PK | ~0.5ms | ~0.1ms |
| Complex JOIN | ~15ms | ~5ms |
| Full scan | ~80ms | ~20ms |
| INSERT throughput | ~5k/sec | ~50k/sec |
| Cold startup | 500ms-2s | <50ms |

PGlite is 3-10x slower than native SQLite — acceptable for desktop/extension CRUD, not suitable for high-throughput ingestion or real-time analytics.

## Gotchas

1. **Single connection only** — no concurrent writers. Use a mutex or message queue for multiple renderer windows.
2. **WASM startup latency** — show a loading state; don't block app launch on DB init.
3. **Electron version** — requires Electron 28+ for reliable WASM SharedArrayBuffer support.
4. **Bundle size** — WASM binary adds ~3MB gzipped.
5. **Extension support** — check https://pglite.dev/extensions/ before assuming production extensions work locally.
6. **No `LISTEN/NOTIFY`** — use PGlite's live query API instead for reactivity.

## Live Queries

```typescript
import { live } from "@electric-sql/pglite/live";

const client = new PGlite({ extensions: { live } });
const db = drizzle({ client, schema });

const { unsubscribe } = await client.live.query(
  "SELECT * FROM items WHERE status = $1",
  ["active"],
  (results) => updateItemsList(results.rows) // fires on any matching row change
);
```

## Related

- **Vector search**: `tools/database/vector-search.md` — decision guide including PGlite+pgvector for local-first vector search
- **SQLite (aidevops internals)**: `reference/memory.md` — SQLite FTS5 for cross-session memory
- **Multi-org isolation**: `services/database/multi-org-isolation.md` — tenant isolation schema for server-side Postgres
- **PowerSync**: https://www.powersync.com — SQLite sync with Postgres (better for React Native)
- **ElectricSQL**: https://electric-sql.com — Postgres sync engine (works with PGlite)
- **TanStack DB**: https://tanstack.com/db — Reactive client store (pairs with Electric)
