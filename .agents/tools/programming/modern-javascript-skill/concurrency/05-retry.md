<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Retry Pattern

```javascript
async function withRetry(fn, { retries = 3, delay = 1000, backoff = 2 } = {}) {
  let lastError;
  for (let attempt = 0; attempt < retries; attempt++) {
    try { return await fn(); }
    catch (error) {
      lastError = error;
      if (attempt < retries - 1)
        await new Promise(r => setTimeout(r, delay * backoff ** attempt));
    }
  }
  throw lastError;
}
```
