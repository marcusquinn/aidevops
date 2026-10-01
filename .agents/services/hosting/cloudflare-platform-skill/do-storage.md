---
name: do-storage
description: "Cloudflare do storage: product reference"
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudflare Durable Objects Storage

Use SQLite for new classes. Existing KV-backed classes need their matching API reference; using key-value methods does not by itself identify the backend.

Fetch the relevant current documentation before implementing or reviewing changes.

| Task | Documentation |
|------|---------------|
| Choose SQL, key-value access, transactions, or recovery APIs | [SQLite storage API](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/); [Legacy KV storage API](https://developers.cloudflare.com/durable-objects/api/legacy-kv-storage-api/) |
| Configure the backend, class lifecycle, and placement | [Configuration](do-storage.md) |
| Find operation semantics and storage options | [API routing](do-storage.md) |
| Design schemas, caches, scheduled work, or cleanup | [Patterns](do-storage-patterns.md) |
| Diagnose concurrency, limits, and billing | [Troubleshooting](do-storage-gotchas.md) |
| Verify storage behavior in the Workers runtime | [Testing](do-storage-gotchas.md) |

For object routing, WebSockets, and coordination design, see the [Durable Objects skill](durable-objects.md).
