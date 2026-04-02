# Workerd Patterns

## Best Practices

| Rule | Detail |
|------|--------|
| ES modules | Prefer over service worker syntax |
| Explicit bindings | No global namespace assumptions |
| Type safety | Define `Env` interfaces |
| Service isolation | Split concerns across services |
| Pin compat date | Set in production after testing |
| Background tasks | Use `ctx.waitUntil()` |
| Error handling | Wrap handlers in try/catch |
| Secrets | Use `fromEnvironment`, never hardcode |

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
      bindings = [
        (name = "DB", service = "postgres"),
        (name = "CACHE", kvNamespace = "kv"),
      ]
    )),
    (name = "postgres", external = (address = "db.internal:5432", http = ())),
    (name = "kv", disk = (path = "/var/kv", writable = true)),
  ],
  sockets = [(name = "http", address = "*:8080", http = (), service = "frontend")]
);
```

## Durable Objects

Add as a service entry in the `services` list:

```capnp
(name = "app", worker = (
  modules = [
    (name = "index.js", esModule = embed "index.js"),
    (name = "room.js", esModule = embed "room.js"),
  ],
  compatibilityDate = "2024-01-15",
  bindings = [(name = "ROOMS", durableObjectNamespace = "Room")],
  durableObjectNamespaces = [(className = "Room", uniqueKey = "v1")],
  durableObjectStorage = (localDisk = "/var/do")
))
```

## Dev vs Prod Configs

Named configs per environment; override bindings via `fromEnvironment`:

```capnp
const devWorker :Workerd.Worker = (
  modules = [(name = "index.js", esModule = embed "src/index.js")],
  compatibilityDate = "2024-01-15",
  bindings = [
    (name = "API_URL", fromEnvironment = "API_URL"),
    (name = "DEBUG", fromEnvironment = "DEBUG"),
  ]
);
```

Run with: `API_URL=http://localhost:3000 DEBUG=true workerd serve dev.capnp`

## HTTP Reverse Proxy

Service-worker syntax with external backend (add to `services`/`sockets` blocks):

```capnp
(name = "proxy", worker = (
  serviceWorkerScript = embed "proxy.js",
  compatibilityDate = "2024-01-15",
  bindings = [(name = "BACKEND", service = "backend")]
)),
(name = "backend", external = (address = "internal:8080", http = ()))
# socket: (name = "http", address = "*:80", http = (), service = "proxy")
```

## Local Development

| Method | Command |
|--------|---------|
| Wrangler | `export MINIFLARE_WORKERD_PATH="/path/to/workerd" && wrangler dev` |
| Direct | `workerd serve config.capnp --verbose` |
| With env vars | `API_URL=https://api.example.com workerd serve config.capnp` |

## Testing

```capnp
const testWorker :Workerd.Worker = (
  modules = [
    (name = "index.js", esModule = embed "src/index.js"),
    (name = "test.js", esModule = embed "tests/test.js"),
  ],
  compatibilityDate = "2024-01-15"
);
```

```bash
workerd test config.capnp
workerd test config.capnp --test-only=test.js
```

## Production Deployment

### Systemd

`/etc/systemd/system/workerd.service`:

```ini
[Unit]
Description=workerd runtime
After=network-online.target
Requires=workerd.socket

[Service]
Type=exec
ExecStart=/usr/bin/workerd serve /etc/workerd/config.capnp --socket-fd http=3
Restart=always
User=nobody
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/workerd.socket`:

```ini
[Socket]
ListenStream=0.0.0.0:80

[Install]
WantedBy=sockets.target
```

### Docker

```dockerfile
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates
COPY workerd /usr/local/bin/
COPY config.capnp /etc/workerd/
COPY src/ /etc/workerd/src/
EXPOSE 8080
CMD ["workerd", "serve", "/etc/workerd/config.capnp"]
```

### Compiled Binary

```bash
workerd compile config.capnp myConfig -o production-server
./production-server
```

See [workerd-gotchas.md](./workerd-gotchas.md) for common errors.
