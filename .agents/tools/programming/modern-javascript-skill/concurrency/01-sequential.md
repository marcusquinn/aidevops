<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Sequential Execution

```javascript
// ES2025: Array.fromAsync with async generator (traditional: for...of + push)
async function* processSequentially(items) {
  for (const item of items) yield await processItem(item);
}
const results = await Array.fromAsync(processSequentially(items));
```
