<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Workerd Runtime

V8-based JS/Wasm runtime for Cloudflare Workers. It exposes web-standard APIs (Fetch, Web Crypto, Streams, WebSocket), uses capability-based bindings to limit resource access and SSRF risk, and supports nanoservice-style local service bindings. Workerd version sets the newest supported compatibility date.

Use it for local Workers development via Wrangler, self-hosted Workers runtimes, embedded runtime experiments, and debugging runtime-specific behavior.

## Quick Start

```bash
workerd serve config.capnp
workerd compile config.capnp myConfig -o binary
workerd test config.capnp
```

## Core Concepts

- **Service** — named endpoint backed by a worker, network target, disk resource, or external service.
- **Binding** — capability-based access to KV, Durable Objects, R2, services, and other resources.
- **Compatibility date** — feature gate; always set it explicitly.
- **Modules** — prefer ES modules; service worker syntax still works.
- **Config** — `workerd.capnp` declares services, sockets, and extensions.

## Related Docs

- [workerd-patterns.md](./workerd-patterns.md) — multi-service layouts, Durable Objects, proxying, env-specific config, deployment
- [workerd-gotchas.md](./workerd-gotchas.md) — config failures, network access, debugging, performance, security

## References

- [GitHub](https://github.com/cloudflare/workerd)
- [Compatibility dates](https://developers.cloudflare.com/workers/configuration/compatibility-dates/)
- [workerd.capnp](https://github.com/cloudflare/workerd/blob/main/src/workerd/server/workerd.capnp)
