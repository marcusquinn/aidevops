<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Debounce Async

```javascript
// ES2024: Promise.withResolvers() — rejects prior pending calls on each invocation
function debounceAsync(fn, ms) {
  let timeoutId, pending = null;
  return (...args) => {
    clearTimeout(timeoutId);
    pending?.reject?.(new Error('Debounced'));
    const { promise, resolve, reject } = Promise.withResolvers();
    pending = { reject };
    timeoutId = setTimeout(async () => {
      try { resolve(await fn(...args)); }
      catch (e) { reject(e); }
    }, ms);
    return promise;
  };
}
const debouncedSearch = debounceAsync(searchAPI, 300);
```
