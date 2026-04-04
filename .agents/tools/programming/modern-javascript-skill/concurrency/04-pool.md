<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Concurrency Pool

```javascript
async function pool(items, concurrency, fn) {
  const results = [], executing = new Set();
  for (const item of items) {
    const p = fn(item).then(r => { executing.delete(p); return r; });
    results.push(p); executing.add(p);
    if (executing.size >= concurrency) await Promise.race(executing);
  }
  return Promise.all(results);
}
await pool(items, 5, processItem);
```
