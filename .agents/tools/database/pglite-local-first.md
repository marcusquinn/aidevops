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

**Do NOT use PGlite for**: high-frequency writes (>5k/sec), datasets >500MB, or SQLite-schema projects.

| Factor | PGlite | SQLite |
|--------|--------|--------|
| Schema/migrations | Same `pgTable`/`pgEnum`/`timestamp`, identical SQL, 100% ORM reuse | Separate `sqliteTable` schema, dialect, migration sets, query layer |
| Type fidelity | Full: enums, timestamps, booleans | Lossy: enum->text, timestamp->text, boolean->integer |
| Cold startup | 500ms-2s | <50ms |
| Perf (100k rows, Apple Silicon) | SELECT ~0.5ms, JOIN ~15ms, scan ~80ms, INSERT ~5k/s | SELECT ~0.1ms, JOIN ~5ms, scan ~20ms, INSERT ~50k/s |
| Bundle size | +3MB gzipped | ~1MB native addon |

3-10x slower than native SQLite — acceptable for desktop/extension CRUD, not for high-throughput ingestion.

## Persistence Modes

| Mode | Constructor | Use case |
|------|-------------|----------|
| In-memory | `new PGlite()` | Tests |
| Filesystem | `new PGlite("./path")` | Electron, Tauri, Node |
| IndexedDB | `new PGlite("idb://name")` | Extension, PWA |

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

Production server uses `drizzle-orm/postgres-js` with the same schema — no changes needed.

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
// apps/desktop/src/main/database.ts — main process only
export async function initDatabase() {
  const db = await createLocalDb(path.join(app.getPath("userData"), "pgdata"));
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

Renderer: expose type-safe IPC wrappers (`ipcRenderer.invoke("db:items:list")`), never raw SQL.

### 3. Browser extension (WXT / Manifest V3)

Same `createLocalDb` pattern with `idb://` persistence. Wrap in a lazy singleton (service workers restart on every message):

```typescript
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

### 4. Tauri

Same `createLocalDb` — use `appDataDir()` from `@tauri-apps/api/path`: `new PGlite(\`${await appDataDir()}/pgdata\`)`.

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

## Extensions

```typescript
import { vector } from "@electric-sql/pglite/contrib/pgvector";
const db = new PGlite({ extensions: { vector } });
await db.exec("CREATE EXTENSION IF NOT EXISTS vector");
```

Supported: pgvector, pg_trgm, ltree, hstore, uuid-ossp. Full list: https://pglite.dev/extensions/

## Platform Compatibility and Gotchas

| Platform | Persistence | Notes |
|----------|-------------|-------|
| Electron (main) | Filesystem | Recommended; requires Electron 28+ for SharedArrayBuffer |
| Electron (renderer) | IndexedDB | Use multi-tab worker for shared access |
| Tauri (webview) | Filesystem via Tauri API | |
| Browser extension (MV3) | IndexedDB | Use offscreen doc for heavy queries |
| React Native / Expo | **Not supported** | WASM unsupported; use SQLite + PowerSync |
| Node.js / Bun / Deno | Filesystem | Local dev without Docker Postgres |

**Gotchas**: (1) Single connection — no concurrent writers; use mutex/message queue for multi-window. (2) WASM startup 500ms-2s — show loading state, don't block app launch. (3) Check https://pglite.dev/extensions/ before assuming production extension parity. (4) No `LISTEN/NOTIFY` — use live query API instead.

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
