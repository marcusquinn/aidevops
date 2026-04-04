<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Concurrency Patterns

| Need | Pattern | Key API | Chapter |
|------|---------|---------|---------|
| One at a time | Sequential | `for...of` + `await` / `Array.fromAsync` | [01-sequential.md](concurrency/01-sequential.md) |
| All at once | Parallel | `Promise.all` | [02-parallel.md](concurrency/02-parallel.md) |
| Fixed chunks | Batched | `Promise.all` in loop | [03-batched.md](concurrency/03-batched.md) |
| N simultaneous | Pool | `Promise.race` + `Set` | [04-pool.md](concurrency/04-pool.md) |
| Retry on failure | Retry | Exponential backoff | [05-retry.md](concurrency/05-retry.md) |
| Time limit | Timeout | `Promise.withResolvers` + `Promise.race` | [06-timeout.md](concurrency/06-timeout.md) |
| Delay rapid calls | Debounce | `clearTimeout` + `Promise.withResolvers` | [07-debounce.md](concurrency/07-debounce.md) |
| Rate limit calls | Throttle | Elapsed time check | [08-throttle.md](concurrency/08-throttle.md) |
| Paginated/streaming | Async iteration | `async function*` + `for await` | [09-async-iteration.md](concurrency/09-async-iteration.md) |
| Cancel in-flight | Cancellation | `AbortController` | [10-cancellation.md](concurrency/10-cancellation.md) |
| Limit concurrent access | Semaphore | Permit queue | [11-semaphore.md](concurrency/11-semaphore.md) |
