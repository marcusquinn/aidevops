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

**Purpose**: Fast, lightweight API framework. Use for Next.js API routes, edge functions, serverless.
**Docs**: Context7 MCP for current documentation.

**Features**: TypeScript-first, full type inference, Edge/Node.js/Bun/Deno/Cloudflare Workers, built-in middleware (CORS, auth, validation), RPC client with type safety.

**Basic routes**:

```tsx
import { Hono } from "hono";
const app = new Hono();
app.get("/api/users", (c) => c.json({ users: [] }));
app.post("/api/users", async (c) => {
  const body = await c.req.json();
  return c.json({ created: body }, 201);
});
```

**Zod validation**:

```tsx
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
app.post(
  "/api/users",
  zValidator("json", z.object({ name: z.string().min(1), email: z.string().email() })),
  async (c) => c.json({ user: c.req.valid("json") })
);
```

**RPC client** (type-safe):

```tsx
// server.ts
const routes = app
  .get("/api/users", (c) => c.json({ users: [] }))
  .post("/api/users", zValidator("json", createUserSchema), (c) =>
    c.json({ user: c.req.valid("json") })
  );
export type AppType = typeof routes;

// client.ts
import { hc } from "hono/client";
import type { AppType } from "./server";
const client = hc<AppType>("/");
const data = await (await client.api.users.$get()).json();
```

**Next.js** (`app/api/[[...route]]/route.ts`):

```tsx
import { Hono } from "hono";
import { handle } from "hono/vercel";
const app = new Hono().basePath("/api");
app.get("/hello", (c) => c.json({ message: "Hello!" }));
export const GET = handle(app);
export const POST = handle(app);
```

<!-- AI-CONTEXT-END -->

## Patterns

### Middleware

```tsx
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { timing } from "hono/timing";

app.use("*", logger(), timing());
app.use("/api/*", cors());

// Auth — validate token, not just header presence
app.use("/api/admin/*", async (c, next) => {
  const authHeader = c.req.header("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return c.json({ error: "Missing or malformed Authorization header" }, 401);
  }
  let user;
  try {
    user = await verifyToken(authHeader.slice(7));
  } catch {
    return c.json({ error: "Invalid or expired token" }, 401);
  }
  if (!user) return c.json({ error: "Invalid or expired token" }, 401);
  c.set("user", user);
  await next();
});
```

### Error Handling

```tsx
import { HTTPException } from "hono/http-exception";

app.onError((err, c) => {
  if (err instanceof HTTPException) return err.getResponse();
  console.error("[API Error]", {
    message: err.message,
    path: c.req.path,
    method: c.req.method,
    ...(process.env.NODE_ENV !== "production" && { stack: err.stack }),
  });
  return c.json({ error: "Internal Server Error" }, 500);
});

app.get("/api/users/:id", async (c) => {
  const user = await getUser(c.req.param("id"));
  if (!user) throw new HTTPException(404, { message: "User not found" });
  return c.json(user);
});
```

### Grouped Routes

```tsx
const users = new Hono()
  .get("/", (c) => c.json({ users: [] }))
  .get("/:id", (c) => c.json({ id: c.req.param("id") }))
  .post("/", (c) => c.json({ created: true }));
app.route("/api/users", users);
```

### Context Variables

```tsx
app.use("*", async (c, next) => {
  c.set("user", await getAuthUser(c.req.header("Authorization")));
  await next();
});
app.get("/api/profile", (c) => c.json(c.get("user")));
```

### Streaming

```tsx
import { streamText } from "hono/streaming";
app.get("/api/stream", (c) =>
  streamText(c, async (stream) => {
    for (let i = 0; i < 10; i++) {
      await stream.write(`data: ${i}\n\n`);
      await stream.sleep(100);
    }
  })
);
```

### File Uploads

```tsx
app.post("/api/upload", async (c) => {
  const file = (await c.req.parseBody())["file"] as File;
  if (!file) return c.json({ error: "No file" }, 400);
  if (file.size > 10 * 1024 * 1024) return c.json({ error: "File too large" }, 413);
  if (!["image/jpeg", "image/png", "image/webp"].includes(file.type))
    return c.json({ error: "Invalid file type" }, 400);

  // Sanitize: strip path separators, unsafe chars, dotfiles; prefix with UUID
  const safeName = `${crypto.randomUUID()}-${
    file.name.replace(/[/\\]/g, "").replace(/[^a-zA-Z0-9._-]/g, "_").replace(/^\.+/, "_") || "upload"
  }`;
  const buffer = await file.arrayBuffer();
  return c.json({ filename: safeName, size: file.size });
});
```

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| RPC client has no types | Export `AppType = typeof routes` from server |
| Middleware skips response | Always `await next()` in middleware |
| Wrong validator target | `"json"` body · `"query"` params · `"param"` URL segments |
| Routes 404 in Next.js | Use `.basePath("/api")`; routes are relative to it |

## Related

- `tools/api/vercel-ai-sdk.md` — AI streaming with Hono
- `tools/api/drizzle.md` — Database queries in routes
- Context7 MCP for Hono documentation
