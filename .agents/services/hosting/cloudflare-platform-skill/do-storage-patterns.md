# DO Storage Patterns & Best Practices

Reference corpus for Durable Objects storage examples. Content moved into chapter files to keep the entry point short while preserving every example.

## Chapters

- [01-schema-migration.md](./do-storage-patterns/01-schema-migration.md) - Versioned SQLite schema upgrades during Durable Object startup.
- [02-in-memory-caching.md](./do-storage-patterns/02-in-memory-caching.md) - Read-through cache pattern backed by Durable Object storage.
- [03-rate-limiting.md](./do-storage-patterns/03-rate-limiting.md) - Sliding-window request counting with SQL cleanup.
- [04-batch-processing-with-alarms.md](./do-storage-patterns/04-batch-processing-with-alarms.md) - Queue items in memory and flush them on an alarm.
- [05-initialization-and-counters.md](./do-storage-patterns/05-initialization-and-counters.md) - `blockConcurrencyWhile()` initialization plus safe counter increment patterns.
- [06-cleanup.md](./do-storage-patterns/06-cleanup.md) - Explicit alarm cleanup before deleting storage state.

## Related

- [do-storage.md](./do-storage.md) - API overview, storage backends, and core capabilities.
- [do-storage-gotchas.md](./do-storage-gotchas.md) - Concurrency, transaction, limit, and alarm pitfalls.

## Preservation Notes

- All original code blocks moved to the chapter files above.
- No examples were removed; this file is now the index for the same material.
