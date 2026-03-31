# Workerd Runtime

V8-based JS/Wasm runtime powering Cloudflare Workers. Standards-based (Fetch API, Web Crypto, Streams, WebSocket), capability-secured bindings (prevent SSRF), nanoservice architecture with local-call-perf service bindings. Version = max compat date supported.

**Use cases:** local Workers dev (via Wrangler), self-hosted Workers runtime, custom embedded runtime, debugging runtime-specific issues.

## Quick Start

```bash
workerd serve config.capnp
workerd compile config.capnp myConfig -o binary
workerd test config.capnp
```

## Core Concepts

| Concept | Detail |
|---------|--------|
| **Service** | Named endpoint (worker/network/disk/external) |
| **Binding** | Capability-based resource access (KV/DO/R2/services) |
| **Compatibility date** | Feature gate — always set |
| **Modules** | ES modules (recommended) or service worker syntax |
| **Config** | `workerd.capnp` — services, sockets (HTTP/HTTPS listeners), extensions |

## See Also

- [workerd-patterns.md](./workerd-patterns.md) — multi-service, DO, proxies, dev/prod configs, deployment
- [workerd-gotchas.md](./workerd-gotchas.md) — config errors, network access, debugging, performance, security

## References

- [GitHub](https://github.com/cloudflare/workerd)
- [Compat Dates](https://developers.cloudflare.com/workers/configuration/compatibility-dates/)
- [workerd.capnp](https://github.com/cloudflare/workerd/blob/main/src/workerd/server/workerd.capnp)
