<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Timeout Wrapper

```javascript
// ES2024: Promise.withResolvers()
function withTimeout(promise, ms, message = 'Timeout') {
  const { promise: timeout, reject } = Promise.withResolvers();
  const id = setTimeout(() => reject(new Error(message)), ms);
  return Promise.race([promise, timeout]).finally(() => clearTimeout(id));
}
const data = await withTimeout(fetchData(), 5000);
```
