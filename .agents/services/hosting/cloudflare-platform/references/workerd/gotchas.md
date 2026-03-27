# Workerd Gotchas

## Configuration Errors

### Missing Compat Date

```capnp
# BAD — missing compat date
const worker :Workerd.Worker = (
  serviceWorkerScript = embed "worker.js"
)

# GOOD — always set compatibilityDate
const worker :Workerd.Worker = (
  serviceWorkerScript = embed "worker.js",
  compatibilityDate = "2024-01-15"
)
```

### Wrong Binding Type

```capnp
(name = "CONFIG", text = '{"key":"value"}')    # BAD — returns string, not parsed
(name = "CONFIG", json = '{"key":"value"}')    # GOOD — returns parsed object
```

### Service vs Namespace

```capnp
(name = "ROOM", service = "room-service")          # BAD — just a Fetcher
(name = "ROOM", durableObjectNamespace = "Room")   # GOOD — DO namespace
```

### Module Name Mismatch

```capnp
modules = [(name = "src/index.js", esModule = embed "src/index.js")]  # BAD — import fails
modules = [(name = "index.js", esModule = embed "src/index.js")]      # GOOD — simple names
```

## Network Access

Fetch calls fail without explicit network config:

```capnp
services = [
  (name = "internet", network = (allow = ["public"])),
  (name = "worker", worker = (
    ...,
    bindings = [(name = "API", service = "internet")]
  ))
]
```

Or use an external service binding:

```capnp
bindings = [
  (name = "API", service = (
    name = "api-backend",
    external = (address = "api.com:443", http = (style = tls))
  ))
]
```

## Debugging

**Worker not responding** — Check: socket `address = "*:8080"` set, service name matches socket config, worker has `fetch()` handler, port available.

**Binding not found** — Check: binding name in config matches code (`env.BINDING` or global), service exists, ES module vs service worker syntax (env vs global).

**Module not found** — Check: module name in config matches import path, `embed` path correct, ES module syntax valid (no CommonJS in `.mjs`).

**Compatibility errors** — Check: `compatibilityDate` set, API available on that date ([docs](https://developers.cloudflare.com/workers/configuration/compatibility-dates/)), required `compatibilityFlags` enabled.

## Performance

**High memory** — V8 flags: `v8Flags = ["--max-old-space-size=2048"]`. Reduce `memoryCache.limits.maxTotalValueSize`. Profile with `--verbose`.

**Slow startup** — Compile binary: `workerd compile config.capnp name -o binary`. Reduce module count. Review compat flags (some have perf impact).

**Request timeouts** — Check external service connectivity, DNS resolution, TLS handshake (`tlsOptions`).

## Build Issues

**Cap'n Proto errors** — Install: `brew install capnp` / `apt install capnproto`. Check import: `using Workerd = import "/workerd/workerd.capnp";`. Validate: `capnp compile -I. config.capnp`.

**Embed path issues** — Paths are relative to config file location. Use absolute paths if needed: `embed "/full/path/file.js"`. Verify file exists before running.

**V8 flags warning** — `v8Flags` can break everything. Use only if necessary, test thoroughly. Not supported in production Cloudflare Workers.

## Security

### Hardcoded Secrets

```capnp
(name = "API_KEY", text = "sk-1234567890")         # BAD — never hardcode
(name = "API_KEY", fromEnvironment = "API_KEY")     # GOOD — use env vars
```

### Overly Broad Network Access

```capnp
network = (allow = ["*"])                           # BAD — too permissive
network = (allow = ["public"], deny = ["local"])    # GOOD — restrictive
```

### Extractable Keys

```capnp
cryptoKey = (extractable = true, ...)               # BAD — extractable keys risky
cryptoKey = (extractable = false, ...)              # GOOD — non-extractable
```

## Compatibility Changes

When updating `compatibilityDate`: review [compatibility dates docs](https://developers.cloudflare.com/workers/configuration/compatibility-dates/), check flags enabled between old/new date, test locally, update code for breaking changes, deploy.

**Version mismatch** — Workerd version = max compat date supported. If `compatibilityDate = "2025-01-01"` but workerd is v1.20241201.0, it fails. Update workerd binary.

## Troubleshooting Steps

1. Enable verbose logging: `workerd serve config.capnp --verbose`
2. Validate config: `capnp compile -I. config.capnp`
3. Test bindings: log `Object.keys(env)` to verify
4. Check versions: workerd version vs compat date
5. Isolate issue: minimal repro config
6. Review schema: [workerd.capnp](https://github.com/cloudflare/workerd/blob/main/src/workerd/server/workerd.capnp)

See [patterns.md](./patterns.md) for working examples.
