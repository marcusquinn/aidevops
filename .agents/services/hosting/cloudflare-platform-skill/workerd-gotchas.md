<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Workerd Gotchas

## Config Errors

```capnp
# Missing compat date — always set compatibilityDate
const worker :Workerd.Worker = (
  serviceWorkerScript = embed "worker.js",
  compatibilityDate = "2024-01-15"   # REQUIRED
)

# Wrong binding type — use json not text for parsed objects
(name = "CONFIG", json = '{"key":"value"}')    # GOOD: returns parsed object
(name = "CONFIG", text = '{"key":"value"}')    # BAD: returns string

# Service vs namespace — use durableObjectNamespace for DOs
(name = "ROOM", durableObjectNamespace = "Room")   # GOOD
(name = "ROOM", service = "room-service")          # BAD: just a Fetcher

# Module name mismatch — use simple names, not embed paths
modules = [(name = "index.js", esModule = embed "src/index.js")]      # GOOD
modules = [(name = "src/index.js", esModule = embed "src/index.js")]  # BAD: import fails
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

**Binding not found** — Check: binding name matches code (`env.BINDING` or global), service exists, ES module vs service worker syntax.

**Module not found** — Check: module name matches import path, `embed` path correct, no CommonJS in `.mjs`.

**Compatibility errors** — Check: `compatibilityDate` set, API available on that date ([docs](https://developers.cloudflare.com/workers/configuration/compatibility-dates/)), required `compatibilityFlags` enabled.

## Performance

**High memory** — `v8Flags = ["--max-old-space-size=2048"]`. Reduce `memoryCache.limits.maxTotalValueSize`. Profile with `--verbose`.

**Slow startup** — Compile binary: `workerd compile config.capnp name -o binary`. Reduce module count.

**Request timeouts** — Check external service connectivity, DNS resolution, TLS handshake (`tlsOptions`).

## Build Issues

**Cap'n Proto errors** — Install: `brew install capnp` / `apt install capnproto`. Import: `using Workerd = import "/workerd/workerd.capnp";`. Validate: `capnp compile -I. config.capnp`.

**Embed path issues** — Paths relative to config file. Use absolute if needed: `embed "/full/path/file.js"`.

**V8 flags** — Can break everything. Not supported in production Cloudflare Workers. Test thoroughly.

## Security

```capnp
# Secrets — never hardcode; use env vars
(name = "API_KEY", fromEnvironment = "API_KEY")     # GOOD
(name = "API_KEY", text = "sk-1234567890")          # BAD

# Network — restrict access
network = (allow = ["public"], deny = ["local"])    # GOOD
network = (allow = ["*"])                           # BAD

# Crypto keys — non-extractable
cryptoKey = (extractable = false, ...)              # GOOD
cryptoKey = (extractable = true, ...)               # BAD
```

## Compatibility Changes

When updating `compatibilityDate`: review [compat dates docs](https://developers.cloudflare.com/workers/configuration/compatibility-dates/), check flags between old/new date, test locally, deploy.

**Version mismatch** — Workerd version = max compat date supported. If `compatibilityDate = "2025-01-01"` but workerd is v1.20241201.0, it fails. Update workerd binary.

## Troubleshooting Steps

1. Enable verbose logging: `workerd serve config.capnp --verbose`
2. Validate config: `capnp compile -I. config.capnp`
3. Test bindings: log `Object.keys(env)` to verify
4. Check versions: workerd version vs compat date
5. Isolate issue: minimal repro config
6. Review schema: [workerd.capnp](https://github.com/cloudflare/workerd/blob/main/src/workerd/server/workerd.capnp)

See [patterns.md](./patterns.md) for working examples.
