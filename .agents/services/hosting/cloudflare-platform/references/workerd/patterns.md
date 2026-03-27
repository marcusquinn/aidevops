# Workerd Patterns

## Multi-Service Architecture

```capnp
const config :Workerd.Config = (
  services = [
    (name = "frontend", worker = (
      modules = [(name = "index.js", esModule = embed "frontend/index.js")],
      compatibilityDate = "2024-01-15",
      bindings = [(name = "API", service = "api")]
    )),
    (name = "api", worker = (
      modules = [(name = "index.js", esModule = embed "api/index.js")],
      compatibilityDate = "2024-01-15",
      bindings = [(name = "DB", service = "postgres"), (name = "CACHE", kvNamespace = "kv")]
    )),
    (name = "postgres", external = (address = "db.internal:5432", http = ())),
    (name = "kv", disk = (path = "/var/kv", writable = true)),
  ],
  sockets = [(name = "http", address = "*:8080", http = (), service = "frontend")]
);
```

For a reverse proxy, use the same `external` binding pattern — point a worker at a backend service via `bindings = [(name = "BACKEND", service = "backend")]` with `(name = "backend", external = (address = "internal:8080", http = ()))`.

## Durable Objects

```capnp
const config :Workerd.Config = (
  services = [(name = "app", worker = (
    modules = [
      (name = "index.js", esModule = embed "index.js"),
      (name = "room.js", esModule = embed "room.js"),
    ],
    compatibilityDate = "2024-01-15",
    bindings = [(name = "ROOMS", durableObjectNamespace = "Room")],
    durableObjectNamespaces = [(className = "Room", uniqueKey = "v1")],
    durableObjectStorage = (localDisk = "/var/do")
  ))],
  sockets = [(name = "http", address = "*:8080", http = (), service = "app")]
);
```

## Dev vs Prod Configs

Use `inherit` to override only what changes between environments:

```capnp
const devWorker :Workerd.Worker = (
  modules = [(name = "index.js", esModule = embed "src/index.js")],
  compatibilityDate = "2024-01-15",
  bindings = [(name = "API_URL", text = "http://localhost:3000"), (name = "DEBUG", text = "true")]
);
const prodWorker :Workerd.Worker = (
  inherit = "dev-service",
  bindings = [(name = "API_URL", text = "https://api.prod.com"), (name = "DEBUG", text = "false")]
);
```

## Local Development

```bash
# Via wrangler (set MINIFLARE_WORKERD_PATH to use local binary)
export MINIFLARE_WORKERD_PATH="/path/to/workerd"
wrangler dev

# Direct
workerd serve config.capnp --socket-addr http=*:3000 --verbose
```

Inject env vars at runtime: `bindings = [(name = "DATABASE_URL", fromEnvironment = "DATABASE_URL")]`.

## Testing

Add test modules to the worker, then run with `workerd test`:

```capnp
const testWorker :Workerd.Worker = (
  modules = [(name = "index.js", esModule = embed "src/index.js"), (name = "test.js", esModule = embed "tests/test.js")],
  compatibilityDate = "2024-01-15"
);
```

Run: `workerd test config.capnp` or `workerd test config.capnp --test-only=test.js`

## Production Deployment

**Systemd** — socket-activated service (`workerd.socket` on `0.0.0.0:80`):

```ini
[Service]
Type=exec
ExecStart=/usr/bin/workerd serve /etc/workerd/config.capnp --socket-fd http=3
Restart=always
User=nobody
NoNewPrivileges=true
```

**Docker:**

```dockerfile
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates
COPY workerd /usr/local/bin/
COPY config.capnp /etc/workerd/
COPY src/ /etc/workerd/src/
EXPOSE 8080
CMD ["workerd", "serve", "/etc/workerd/config.capnp"]
```

**Compiled binary:** `workerd compile config.capnp myConfig -o production-server && ./production-server`

## Best Practices

1. **ES modules over service worker syntax** — required for Durable Objects, multi-module workers
2. **Explicit bindings** — no global namespace; declare every dependency in capnp config
3. **Pin `compatibilityDate`** in production after testing — prevents surprise runtime changes
4. **Use `ctx.waitUntil()`** for background tasks (logging, analytics) that shouldn't block the response
5. **Service isolation** — split concerns into separate named services with typed bindings

See [gotchas.md](./gotchas.md) for common errors.
