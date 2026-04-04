<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Anti-Patterns

| Anti-pattern | Fix |
|--------------|-----|
| `async function f() { return await p; }` | `function f() { return p; }` — no wrapper needed |
| Sequential awaits for independent ops | `Promise.all([a(), b(), c()])` |
| `async` callback in `forEach` | `for...of` (sequential) or `Promise.all(arr.map(...))` (parallel) |
| Unhandled rejection | Wrap in `try/catch` or `.catch()` |
| Callback inside `async` function | `promisify(fn)` or `fs/promises` |

```javascript
// forEach trap — items not awaited
items.forEach(async item => await processItem(item)); // ❌

for (const item of items) await processItem(item);                    // ✅ sequential
await Promise.all(items.map(item => processItem(item)));              // ✅ parallel
```
