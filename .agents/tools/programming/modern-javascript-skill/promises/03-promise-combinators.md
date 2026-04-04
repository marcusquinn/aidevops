<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Promise Combinators

| Method | Behaviour | Use when |
|--------|-----------|----------|
| `Promise.all(arr)` | Resolves when all resolve; rejects on first rejection | All must succeed |
| `Promise.allSettled(arr)` | Resolves when all settle; returns `{status, value/reason}[]` | Need all results regardless of failure |
| `Promise.race(arr)` | Settles with first to settle (resolve or reject) | Timeout patterns, first responder |
| `Promise.any(arr)` | Resolves with first success; rejects (`AggregateError`) only if all fail | Fallback sources |

```javascript
// all — parallel fetch
const [users, posts] = await Promise.all([fetchUsers(), fetchPosts()]);

// allSettled — partial results
const results = await Promise.allSettled([primary(), backup(), cache()]);
const ok = results.filter(r => r.status === 'fulfilled').map(r => r.value);

// race — timeout (ES2024)
async function fetchWithTimeout(url, ms) {
  const { promise: timeout, reject } = Promise.withResolvers();
  const id = setTimeout(() => reject(new Error('Timeout')), ms);
  try { return await Promise.race([fetch(url), timeout]); }
  finally { clearTimeout(id); }
}

// any — fallback
const data = await Promise.any([primary(), secondary(), tertiary()]);
// throws AggregateError (error.errors[]) if all fail
```
