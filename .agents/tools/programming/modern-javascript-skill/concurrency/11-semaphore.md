<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Semaphore

```javascript
class Semaphore {
  #permits; #queue = [];
  constructor(permits) { this.#permits = permits; }
  async acquire() {
    if (this.#permits > 0) { this.#permits--; return; }
    const { promise, resolve } = Promise.withResolvers();
    this.#queue.push(resolve);
    return promise;
  }
  release() { this.#queue.length ? this.#queue.shift()() : this.#permits++; }
  async withPermit(fn) { await this.acquire(); try { return await fn(); } finally { this.release(); } }
}
// Usage: const sem = new Semaphore(3); await Promise.all(items.map(i => sem.withPermit(() => process(i))));
```
