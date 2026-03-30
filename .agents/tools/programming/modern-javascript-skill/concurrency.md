# Concurrency Patterns

| Need | Pattern | Key API |
|------|---------|---------|
| One at a time | Sequential | `for...of` + `await` / `Array.fromAsync` |
| All at once | Parallel | `Promise.all` |
| Fixed chunks | Batched | `Promise.all` in loop |
| N simultaneous | Pool | `Promise.race` + `Set` |
| Retry on failure | Retry | Exponential backoff |
| Time limit | Timeout | `Promise.withResolvers` + `Promise.race` |
| Delay rapid calls | Debounce | `clearTimeout` + `Promise.withResolvers` |
| Rate limit calls | Throttle | Elapsed time check |
| Paginated/streaming | Async iteration | `async function*` + `for await` |
| Cancel in-flight | Cancellation | `AbortController` |
| Limit concurrent access | Semaphore | Permit queue |

## Sequential Execution

```javascript
// ES2025: Array.fromAsync with async generator (traditional: for...of + push)
async function* processSequentially(items) {
  for (const item of items) yield await processItem(item);
}
const results = await Array.fromAsync(processSequentially(items));
```

## Parallel Execution

```javascript
const results = await Promise.all(items.map(item => processItem(item)));
```

## Batched Execution

```javascript
async function batched(items, batchSize) {
  const results = [];
  for (let i = 0; i < items.length; i += batchSize)
    results.push(...await Promise.all(items.slice(i, i + batchSize).map(processItem)));
  return results;
}
```

## Concurrency Pool

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

## Retry Pattern

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

## Timeout Wrapper

```javascript
// ES2024: Promise.withResolvers()
function withTimeout(promise, ms, message = 'Timeout') {
  const { promise: timeout, reject } = Promise.withResolvers();
  const id = setTimeout(() => reject(new Error(message)), ms);
  return Promise.race([promise, timeout]).finally(() => clearTimeout(id));
}
const data = await withTimeout(fetchData(), 5000);
```

## Debounce Async

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

## Throttle Async

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

## Async Iteration

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

## Cancellation

```javascript
// Cancellable operation factory — pass signal to fetch/streams, catch AbortError
function createCancellable(fn) {
  const controller = new AbortController();
  const promise = (async () => {
    try { return await fn(controller.signal); }
    catch (e) { if (e.name === 'AbortError') return { cancelled: true }; throw e; }
  })();
  return { promise, cancel: () => controller.abort() };
}
// Usage: const { promise, cancel } = createCancellable(signal => fetch(url, { signal }));
```

## Semaphore

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
