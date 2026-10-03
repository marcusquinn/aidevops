# Cloudflare Durable Objects Storage

Use SQLite for new classes. Existing KV-backed classes need their matching API reference; using key-value methods does not by itself identify the backend.

Fetch the relevant current documentation before implementing or reviewing changes.

| Task | Documentation |
|------|---------------|
| Choose SQL, key-value access, transactions, or recovery APIs | [SQLite storage API](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/index.md); [Legacy KV storage API](https://developers.cloudflare.com/durable-objects/api/legacy-kv-storage-api/index.md) |
| Configure the backend, class lifecycle, and placement | [Configuration](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/do-storage/configuration.md) |
| Find operation semantics and storage options | [API routing](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/do-storage/api.md) |
| Design schemas, caches, scheduled work, or cleanup | [Patterns](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/do-storage/patterns.md) |
| Diagnose concurrency, limits, and billing | [Troubleshooting](do-storage-gotchas.md) |
| Verify storage behavior in the Workers runtime | [Testing](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/do-storage/testing.md) |

For object routing, WebSockets, and coordination design, see the [Durable Objects skill](durable-objects.md).
