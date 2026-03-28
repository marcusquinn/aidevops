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

## When to Use PGlite

```text
Is your production DB PostgreSQL?
  NO  --> Use SQLite (better-sqlite3 / bun:sqlite)
  YES --> Using Drizzle pg-core schemas (pgTable, pgEnum, timestamp)?
    NO  --> Either works; SQLite is simpler
    YES --> Target is Electron, Tauri, or browser extension?
      NO (React Native)  --> SQLite + PowerSync (WASM unsupported in RN)
      YES --> PGlite (shared schema, zero translation layer)
```

**Do NOT use PGlite for**: React Native/Expo (WASM unsupported), CLI tools, high-frequency writes (>5k/sec), datasets >500MB, or SQLite-schema projects.

| Factor | PGlite | SQLite |
|--------|--------|--------|
| Schema sharing | Same `pgTable`/`pgEnum`/`timestamp` | Requires separate `sqliteTable` schema |
| Migrations | Identical SQL for local and production | Separate migration sets per dialect |
| Drizzle dialect | `drizzle-orm/pglite` (pg-core) | `drizzle-orm/better-sqlite3` (sqlite-core) |
| Type fidelity | Full: enums, timestamps, booleans | Lossy: enum->text, timestamp->text, boolean->integer |
| ORM code reuse | 100% — same queries everywhere | Separate query layer per dialect |
| Cold startup | 500ms-2s | <50ms |
| SELECT by PK | ~0.5ms | ~0.1ms |
| Complex JOIN | ~15ms | ~5ms |
| Full scan | ~80ms | ~20ms |
| INSERT throughput | ~5k/sec | ~50k/sec |
| Bundle size | +3MB gzipped | ~1MB native addon |

PGlite is 3-10x slower than native SQLite — acceptable for desktop/extension CRUD, not for high-throughput ingestion or real-time analytics. Benchmarks on Apple Silicon, 100k rows.

## Implementation Pattern

### 1. Drizzle adapter swap (one schema, two runtimes)

Export schema and a factory from `@workspace/db`; each runtime provides its own client. Add `"./local"` and `"./schema"` to `package.json` exports.

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

Run PGlite in the main process. **Security**: never expose raw SQL over IPC — a compromised renderer could escalate to full DB access. Expose named operations only.

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
  // __dirname unreliable in asar — bundle migrations as extraResources
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

Runs in service worker or offscreen document with IndexedDB persistence. Wrap in a lazy singleton to avoid re-init on every message:

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

Same `createLocalDb` pattern — use `appDataDir()` from `@tauri-apps/api/path` for filesystem persistence: `new PGlite(\`${await appDataDir()}/pgdata\`)`.

## Sync with Production Postgres

**Write-through-API pattern (recommended)**: PGlite is a local read cache. Reads hit PGlite; writes go through your API to production Postgres; ElectricSQL syncs changes back via logical replication.

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

**ElectricSQL v1 limitations**: pull-only (writes require API), requires Postgres logical replication, self-hosting needs Docker, large initial shape loads can be slow. For apps without server sync, PGlite works standalone.

## Persistence and Extensions

**Persistence**: in-memory `new PGlite()` (tests), filesystem `new PGlite("./path")` (Electron/Tauri/Node), IndexedDB `new PGlite("idb://name")` (extension/PWA).

```typescript
import { PGlite } from "@electric-sql/pglite";
import { vector } from "@electric-sql/pglite/contrib/pgvector";

const db = new PGlite({ extensions: { vector } });
await db.exec("CREATE EXTENSION IF NOT EXISTS vector");
await db.exec(`CREATE TABLE embeddings (id TEXT PRIMARY KEY, content TEXT, embedding vector(1536))`);
```

Supported: pgvector, pg_trgm, ltree, hstore, uuid-ossp. Full list: https://pglite.dev/extensions/

## Platform Compatibility and Gotchas

| Platform | Runtime | Persistence | Notes |
|----------|---------|-------------|-------|
| Electron (main) | Node.js | Filesystem | Recommended; requires Electron 28+ for SharedArrayBuffer |
| Electron (renderer) | Chromium | IndexedDB | Use multi-tab worker for shared access |
| Tauri (webview) | WebView | Filesystem via Tauri API | |
| Browser extension (MV3) | Service worker | IndexedDB | Use offscreen doc for heavy queries |
| React Native / Expo | Hermes/JSC | **Not supported** | WASM unsupported; use SQLite + PowerSync |
| Node.js / Bun / Deno | Server | Filesystem | Local dev without Docker Postgres |

**Gotchas**: (1) Single connection — no concurrent writers; use mutex/message queue for multi-window. (2) WASM startup 500ms-2s — show loading state, don't block app launch. (3) Bundle +3MB gzipped. (4) Check https://pglite.dev/extensions/ before assuming production extension parity. (5) No `LISTEN/NOTIFY` — use live query API instead (see below).

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

- `tools/database/vector-search.md` — PGlite+pgvector for local-first vector search
- `reference/memory.md` — SQLite FTS5 for cross-session memory
- `services/database/multi-org-isolation.md` — tenant isolation for server-side Postgres
- [PowerSync](https://www.powersync.com) — SQLite sync with Postgres (React Native)
- [ElectricSQL](https://electric-sql.com) — Postgres sync engine (works with PGlite)
- [TanStack DB](https://tanstack.com/db) — Reactive client store (pairs with Electric)
