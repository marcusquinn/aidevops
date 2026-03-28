# Durable Objects Patterns

## Parent-Child Relationships

Don't put all data in a single DO. For hierarchical data (workspaces → projects, game servers → matches), create separate child DOs. Parent coordinates; children handle own state independently.

```typescript
export class GameServer extends DurableObject<Env> {
  async createMatch(matchId: string): Promise<string> {
    this.ctx.storage.sql.exec(
      "INSERT INTO matches (id, created_at, status) VALUES (?, ?, ?)",
      matchId, Date.now(), "active"
    );
    return matchId;
  }

  async routeToMatch(matchId: string, playerId: string, action: string) {
    const childId = this.env.MATCH.idFromName(matchId);
    const child = this.env.MATCH.get(childId);
    return await child.handleAction(playerId, action);
  }

  async listMatches(): Promise<string[]> {
    // Query parent only - children stay hibernated
    return this.ctx.storage.sql
      .exec<{ id: string }>("SELECT id FROM matches WHERE status = ?", "active")
      .toArray()
      .map(r => r.id);
  }
}
```

Benefits: parallelism across children, each child has own SQLite database, listing doesn't wake children.

## Fleet Pattern (Hierarchical DOs)

URL-based hierarchy creates infinite nesting of manager/agent relationships. Each path segment (`/team/project/task`) maps to a unique DO via `idFromName()`.

```typescript
// Worker: Route all requests based on URL path
app.all('*', async (c) => {
  const path = new URL(c.req.url).pathname;
  const parts = path.split('/').filter(Boolean);
  const doName = parts.length === 0 ? '/' : `/${parts.join('/')}`;
  
  const id = c.env.FLEET_DO.idFromName(doName);
  return c.env.FLEET_DO.get(id).fetch(c.req.raw);
});

// Single DO class handles both manager and agent roles
export class FleetDO extends DurableObject<Env> {
  async deleteWithCascade() {
    const data = await this.ctx.storage.get<{ agents: string[] }>('data');
    const myPath = /* derive from context */;
    for (const agent of data?.agents || []) {
      const childPath = myPath === '/' ? `/${agent}` : `${myPath}/${agent}`;
      const child = this.env.FLEET_DO.get(this.env.FLEET_DO.idFromName(childPath));
      await child.fetch(new Request('https://internal' + childPath, { method: 'DELETE' }));
    }
    await this.ctx.storage.deleteAll();
  }
}
```

Use cases: collaborative IDEs (file per DO), distributed task runners, IoT device management, game server infrastructure.

## Per-User DO Pattern

One DO per user for settings, presence, inbox, profile data. Deterministic routing via `idFromName(userId)`.

```typescript
export class UserDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS profile (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS inbox (id TEXT PRIMARY KEY, data TEXT, created_at INTEGER);
      `);
    });
  }

  async getProfile(): Promise<Record<string, string>> {
    return Object.fromEntries(
      this.ctx.storage.sql.exec<{ key: string; value: string }>("SELECT * FROM profile").toArray()
        .map(r => [r.key, r.value])
    );
  }

  async updateProfile(updates: Record<string, string>) {
    for (const [key, value] of Object.entries(updates)) {
      this.ctx.storage.sql.exec(
        "INSERT OR REPLACE INTO profile (key, value) VALUES (?, ?)", key, value
      );
    }
    this.broadcast({ type: 'profile_updated', data: updates });
  }

  private broadcast(msg: object) {
    const payload = JSON.stringify(msg);
    for (const ws of this.ctx.getWebSockets()) ws.send(payload);
  }
}

// Worker: deterministic per-user routing
const stub = env.USER_DO.get(env.USER_DO.idFromName(userId));
```

## Colo-Aware Sharding

Use `request.cf.colo` (IATA airport code, e.g., "SFO") for geographic distribution. Rate limit per-colo before hitting DO.

```typescript
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const userId = new URL(request.url).searchParams.get("userId") || "unknown";
    const shardKey = `${request.cf?.colo || "unknown"}:${userId}`;

    // Rate limit per-colo (counters not shared across datacenters)
    const { success } = await env.RATE_LIMITER.limit({ key: shardKey });
    if (!success) return new Response("Rate limited", { status: 429 });

    return await env.MY_DO.get(env.MY_DO.idFromName(shardKey)).fetch(request);
  }
}
```

## Rate Limiting

```typescript
async checkLimit(key: string, limit: number, windowMs: number): Promise<boolean> {
  const req = await this.ctx.storage.sql.exec(
    "SELECT COUNT(*) as count FROM requests WHERE key = ? AND timestamp > ?",
    key, Date.now() - windowMs
  ).one();
  if (req.count >= limit) return false;
  this.ctx.storage.sql.exec("INSERT INTO requests (key, timestamp) VALUES (?, ?)", key, Date.now());
  return true;
}
```

## Distributed Lock

```typescript
private held = false;
async acquire(timeoutMs = 5000): Promise<boolean> {
  if (this.held) return false;
  this.held = true;
  await this.ctx.storage.setAlarm(Date.now() + timeoutMs);
  return true;
}
async release() { this.held = false; await this.ctx.storage.deleteAlarm(); }
async alarm() { this.held = false; }
```

## Real-time Collaboration

```typescript
async fetch(req: Request): Promise<Response> {
  const [client, server] = Object.values(new WebSocketPair());
  this.ctx.acceptWebSocket(server);
  server.send(JSON.stringify({ type: "init", content: this.ctx.storage.kv.get("doc") || "" }));
  return new Response(null, { status: 101, webSocket: client });
}

async webSocketMessage(ws: WebSocket, msg: string) {
  const data = JSON.parse(msg);
  if (data.type === "edit") {
    this.ctx.storage.kv.put("doc", data.content);
    for (const c of this.ctx.getWebSockets()) if (c !== ws) c.send(msg);
  }
}
```

## Session Management

```typescript
async createSession(userId: string, data: object): Promise<string> {
  const id = crypto.randomUUID(), exp = Date.now() + 86400000;
  this.ctx.storage.sql.exec("INSERT INTO sessions VALUES (?, ?, ?, ?)", id, userId, JSON.stringify(data), exp);
  await this.ctx.storage.setAlarm(exp);
  return id;
}

async getSession(id: string): Promise<object | null> {
  const row = this.ctx.storage.sql.exec("SELECT data FROM sessions WHERE id = ? AND expires_at > ?", id, Date.now()).one();
  return row ? JSON.parse(row.data) : null;
}

async alarm() { this.ctx.storage.sql.exec("DELETE FROM sessions WHERE expires_at <= ?", Date.now()); }
```

## Deduplication

```typescript
private pending = new Map<string, Promise<Response>>();
async deduplicatedFetch(url: string): Promise<Response> {
  if (this.pending.has(url)) return this.pending.get(url)!;
  const p = fetch(url).finally(() => this.pending.delete(url));
  this.pending.set(url, p);
  return p;
}
```

## Multiple Events (Single Alarm)

```typescript
async scheduleEvent(id: string, runAt: number, repeatMs?: number) {
  await this.ctx.storage.put(`event:${id}`, { id, runAt, repeatMs });
  const curr = await this.ctx.storage.getAlarm();
  if (!curr || runAt < curr) await this.ctx.storage.setAlarm(runAt);
}

async alarm() {
  const now = Date.now(), events = await this.ctx.storage.list({ prefix: "event:" });
  let next: number | null = null;
  for (const [key, ev] of events) {
    if (ev.runAt <= now) {
      await this.processEvent(ev);
      ev.repeatMs ? await this.ctx.storage.put(key, { ...ev, runAt: now + ev.repeatMs }) : await this.ctx.storage.delete(key);
    }
    if (ev.runAt > now && (!next || ev.runAt < next)) next = ev.runAt;
  }
  if (next) await this.ctx.storage.setAlarm(next);
}
```

## Best Practices

**Hibernation-first**: Sleep by default, wake for meaningful work, sleep again. All state must persist to storage — in-memory state is lost on eviction. Use `blockConcurrencyWhile()` in constructor to reload state on wake. Use `idFromName()` for coordination, `newUniqueId()` for sharding. Leverage WebSocket hibernation API.

**Atom of Coordination**: Each DO owns ONE logical unit (user, room, document, session). If data spans multiple boundaries or lacks natural ownership, DO may be wrong choice.

**Storage**: Prefer SQLite, create indexes judiciously, batch with transactions, set alarms for cleanup, use PITR before risky ops.

**Performance**: One DO ~1000 req/s max — shard for more, cache in memory, avoid long ops, use alarms for deferred work.

**Reliability**: Handle 503 with retry+backoff, design for cold starts, test migrations, monitor alarm retries.

**Security**: Validate inputs in Workers, don't trust user-supplied names, rate limit DO creation, use jurisdiction tags, encrypt sensitive data.
