<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Async Iteration

```javascript
// Paginated fetch with async generator
async function* fetchPages(url) {
  for (let page = 1; ; page++) {
    const data = await fetch(`${url}?page=${page}`).then(r => r.json());
    if (data.length === 0) break;
    yield data;
  }
}
for await (const page of fetchPages('/api/items')) processPage(page);
```
