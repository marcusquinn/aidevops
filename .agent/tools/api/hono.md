---
description: Hono web framework - API routes, middleware, validation
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
  context7_*: true
---

# Hono - Lightweight Web Framework

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Fast, lightweight web framework for building APIs
- **Use Case**: API routes in Next.js, edge functions, serverless
- **Docs**: Use Context7 MCP for current documentation

**Key Features**:
- TypeScript-first with full type inference
- Works on Edge, Node.js, Bun, Deno, Cloudflare Workers
- Built-in middleware (CORS, auth, validation)
- RPC-style client with type safety

**Common Patterns**:

```tsx
// Basic route
import { Hono } from "hono";

const app = new Hono();

app.get("/api/users", (c) => {
  return c.json({ users: [] });
});

app.post("/api/users", async (c) => {
  const body = await c.req.json();
  return c.json({ created: body }, 201);
});
```

**Zod Validation**:

```tsx
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";

const createUserSchema = z.object({
  name: z.string().min(1),
  email: z.string().email(),
});

app.post(
  "/api/users",
  zValidator("json", createUserSchema),
  async (c) => {
    const data = c.req.valid("json"); // Typed!
    return c.json({ user: data });
  }
);
```

**RPC Client** (type-safe API calls):

```tsx
// Server: Define routes with types
const routes = app
  .get("/api/users", (c) => c.json({ users: [] }))
  .post("/api/users", zValidator("json", schema), (c) => {
    return c.json({ user: c.req.valid("json") });
  });

export type AppType = typeof routes;

// Client: Full type inference
import { hc } from "hono/client";
import type { AppType } from "./server";

const client = hc<AppType>("/");
const res = await client.api.users.$get();
const data = await res.json(); // Typed!
```

**Next.js Integration**:

```tsx
// app/api/[[...route]]/route.ts
import { Hono } from "hono";
import { handle } from "hono/vercel";

const app = new Hono().basePath("/api");

app.get("/hello", (c) => c.json({ message: "Hello!" }));

export const GET = handle(app);
export const POST = handle(app);
```

<!-- AI-CONTEXT-END -->

## Detailed Patterns

### Middleware

```tsx
import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { timing } from "hono/timing";

const app = new Hono();

// Global middleware
app.use("*", logger());
app.use("*", timing());
app.use("/api/*", cors());

// Route-specific middleware
app.use("/api/admin/*", async (c, next) => {
  const token = c.req.header("Authorization");
  if (!token) {
    return c.json({ error: "Unauthorized" }, 401);
  }
  await next();
});
```

### Error Handling

```tsx
import { HTTPException } from "hono/http-exception";

app.onError((err, c) => {
  if (err instanceof HTTPException) {
    return err.getResponse();
  }
  console.error(err);
  return c.json({ error: "Internal Server Error" }, 500);
});

// Throwing errors
app.get("/api/users/:id", async (c) => {
  const user = await getUser(c.req.param("id"));
  if (!user) {
    throw new HTTPException(404, { message: "User not found" });
  }
  return c.json(user);
});
```

### Grouped Routes

```tsx
const app = new Hono();

// User routes
const users = new Hono()
  .get("/", (c) => c.json({ users: [] }))
  .get("/:id", (c) => c.json({ id: c.req.param("id") }))
  .post("/", (c) => c.json({ created: true }));

// Mount under /api/users
app.route("/api/users", users);
```

### Context Variables

```tsx
// Set variables in middleware
app.use("*", async (c, next) => {
  const user = await getAuthUser(c.req.header("Authorization"));
  c.set("user", user);
  await next();
});

// Access in routes
app.get("/api/profile", (c) => {
  const user = c.get("user");
  return c.json(user);
});
```

### Streaming Responses

```tsx
import { streamText } from "hono/streaming";

app.get("/api/stream", (c) => {
  return streamText(c, async (stream) => {
    for (let i = 0; i < 10; i++) {
      await stream.write(`data: ${i}\n\n`);
      await stream.sleep(100);
    }
  });
});
```

### File Uploads

```tsx
app.post("/api/upload", async (c) => {
  const body = await c.req.parseBody();
  const file = body["file"] as File;
  
  if (!file) {
    return c.json({ error: "No file" }, 400);
  }
  
  const buffer = await file.arrayBuffer();
  // Process file...
  
  return c.json({ filename: file.name, size: file.size });
});
```

## Common Mistakes

1. **Forgetting to export route types**
   - RPC client needs `AppType` export
   - Export at end of route file

2. **Not awaiting `next()`**
   - Middleware must `await next()`
   - Otherwise response may be sent early

3. **Wrong validator target**
   - `zValidator("json", schema)` for body
   - `zValidator("query", schema)` for query params
   - `zValidator("param", schema)` for URL params

4. **Missing basePath in Next.js**
   - Use `.basePath("/api")` when mounting at `/api`
   - Routes are relative to basePath

## Related

- `tools/api/vercel-ai-sdk.md` - AI streaming with Hono
- `tools/api/drizzle.md` - Database queries in routes
- Context7 MCP for Hono documentation
