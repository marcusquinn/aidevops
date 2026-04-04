<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Throttle Async

```javascript
function throttleAsync(fn, ms) {
  let lastCall = 0, pending = null;
  return (...args) => {
    const elapsed = Date.now() - lastCall;
    if (elapsed >= ms) { lastCall = Date.now(); return fn(...args); }
    return pending ??= new Promise(resolve => setTimeout(async () => {
      lastCall = Date.now(); pending = null; resolve(await fn(...args));
    }, ms - elapsed));
  };
}
```
