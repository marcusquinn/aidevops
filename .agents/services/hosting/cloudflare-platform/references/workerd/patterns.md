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

```capnp
const config :Workerd.Config = (
  services = [
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
  ],
  sockets = [(name = "http", address = "*:8080", http = (), service = "app")]
);
```

## Dev vs Prod Configs

```capnp
const devWorker :Workerd.Worker = (
  modules = [(name = "index.js", esModule = embed "src/index.js")],
  compatibilityDate = "2024-01-15",
  bindings = [
    (name = "API_URL", text = "http://localhost:3000"),
    (name = "DEBUG", text = "true"),
  ]
);

const prodWorker :Workerd.Worker = (
  inherit = "dev-service",
  bindings = [
    (name = "API_URL", text = "https://api.prod.com"),
    (name = "DEBUG", text = "false"),
  ]
);
```

## HTTP Reverse Proxy

```capnp
const config :Workerd.Config = (
  services = [
    (name = "proxy", worker = (
      serviceWorkerScript = embed "proxy.js",
      compatibilityDate = "2024-01-15",
      bindings = [(name = "BACKEND", service = "backend")]
    )),
    (name = "backend", external = (address = "internal:8080", http = ()))
  ],
  sockets = [(name = "http", address = "*:80", http = (), service = "proxy")]
);
```

## Local Development & Testing

```bash
export MINIFLARE_WORKERD_PATH="/path/to/workerd" && wrangler dev   # via Wrangler
export DATABASE_URL="postgres://..." API_KEY="secret"
workerd serve config.capnp --socket-addr http=*:3000 --verbose     # direct
workerd test config.capnp [--test-only=test.js]                    # tests
```

```capnp
bindings = [
  (name = "DATABASE_URL", fromEnvironment = "DATABASE_URL"),
  (name = "API_KEY", fromEnvironment = "API_KEY"),
]

const testWorker :Workerd.Worker = (
  modules = [
    (name = "index.js", esModule = embed "src/index.js"),
    (name = "test.js", esModule = embed "tests/test.js"),
  ],
  compatibilityDate = "2024-01-15"
);
```

## Production Deployment

```ini
# /etc/systemd/system/workerd.service
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

# /etc/systemd/system/workerd.socket
[Socket]
ListenStream=0.0.0.0:80
[Install]
WantedBy=sockets.target
```

```dockerfile
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates
COPY workerd /usr/local/bin/
COPY config.capnp /etc/workerd/
COPY src/ /etc/workerd/src/
EXPOSE 8080
CMD ["workerd", "serve", "/etc/workerd/config.capnp"]
```

```bash
workerd compile config.capnp myConfig -o production-server && ./production-server
```

## Worker Patterns

```javascript
export default {
  async fetch(request, env, ctx) {
    console.log("Request", {method: request.method, url: request.url});
    ctx.waitUntil(logToAnalytics(request, env));
    try {
      return await handleRequest(request, env);
    } catch (error) {
      console.error("Request failed", error);
      return new Response("Internal Error", {status: 500});
    }
  }
};
```

## Best Practices

| Rule | Detail |
|------|--------|
| ES modules | Prefer over service worker syntax |
| Explicit bindings | No global namespace assumptions |
| Type safety | Define `Env` interfaces |
| Service isolation | Split concerns across services |
| Pin compat date | Lock in production after testing |
| Background tasks | Use `ctx.waitUntil()` |
| Error handling | Wrap handlers in try/catch |
| Resource limits | Configure caches/storage limits |

See [gotchas.md](./gotchas.md) for common errors.
