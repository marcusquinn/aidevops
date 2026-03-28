# Concurrency Patterns

Sequential, parallel, batched execution, concurrency pools, retry with exponential backoff, timeout wrappers, async debounce, async throttle, for-await-of, async generators, stream chunking, AbortController cancellation, semaphore pattern.

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
// All at once
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
    results.push(p);
    executing.add(p);
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
  setTimeout(() => reject(new Error(message)), ms);
  return Promise.race([promise, timeout]);
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
  return async (...args) => {
    const elapsed = Date.now() - lastCall;
    if (elapsed >= ms) { lastCall = Date.now(); return fn(...args); }
    if (!pending) {
      pending = new Promise(resolve => {
        setTimeout(async () => {
          lastCall = Date.now(); pending = null;
          resolve(await fn(...args));
        }, ms - elapsed);
      });
    }
    return pending;
  };
}
```

## Async Iteration

```javascript
// Async generator with for-await-of
async function* fetchPages(url) {
  let page = 1;
  while (true) {
    const response = await fetch(`${url}?page=${page}`);
    const data = await response.json();
    if (data.length === 0) break;
    yield data;
    page++;
  }
}

for await (const page of fetchPages('/api/items')) {
  processPage(page);
}

// Chunk a stream
async function* chunkStream(stream, chunkSize) {
  let buffer = [];
  for await (const item of stream) {
    buffer.push(item);
    if (buffer.length >= chunkSize) { yield buffer; buffer = []; }
  }
  if (buffer.length > 0) yield buffer;
}

for await (const chunk of chunkStream(dataStream, 100)) {
  await processBatch(chunk);
}
```

## Cancellation Patterns

```javascript
// AbortController: pass signal, catch AbortError
const controller = new AbortController();
setTimeout(() => controller.abort(), 5000);
try {
  const response = await fetch('/api/data', { signal: controller.signal });
  const data = await response.json();
} catch (error) {
  if (error.name === 'AbortError') console.log('Request was cancelled');
}

// Cancellable operation factory
function createCancellableOperation(fn) {
  const controller = new AbortController();
  const promise = (async () => {
    try { return await fn(controller.signal); }
    catch (e) {
      if (e.name === 'AbortError') return { cancelled: true };
      throw e;
    }
  })();
  return { promise, cancel: () => controller.abort() };
}
```

## Semaphore Pattern

```javascript
class Semaphore {
  #permits;
  #queue = [];

  constructor(permits) { this.#permits = permits; }

  async acquire() {
    if (this.#permits > 0) { this.#permits--; return; }
    const { promise, resolve } = Promise.withResolvers();
    this.#queue.push(resolve);
    return promise;
  }

  release() {
    if (this.#queue.length > 0) this.#queue.shift()();
    else this.#permits++;
  }

  async withPermit(fn) {
    await this.acquire();
    try { return await fn(); }
    finally { this.release(); }
  }
}

const semaphore = new Semaphore(3);
await Promise.all(items.map(item => semaphore.withPermit(() => processItem(item))));
```
