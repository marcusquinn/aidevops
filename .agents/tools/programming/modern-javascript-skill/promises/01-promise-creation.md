<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Promise Creation

```javascript
// Constructor
const p = new Promise((resolve, reject) => {
  success ? resolve(result) : reject(new Error('Failed'));
});

// ES2024: external control
const { promise, resolve, reject } = Promise.withResolvers();
someEvent.on('complete', resolve);
someEvent.on('error', reject);

// Shortcuts
Promise.resolve(42);
Promise.reject(new Error('Failed'));
```
