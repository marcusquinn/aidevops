# Concurrency Patterns

Sequential, parallel, batched execution, concurrency pools, retry with exponential backoff, timeout wrappers, async debounce, async throttle, for-await-of, async generators, stream chunking, AbortController cancellation, semaphore pattern.

## Sequential Execution

```javascript
// One at a time (traditional)
async function sequential(items) {
  const results = [];
  for (const item of items) {
    results.push(await processItem(item));
  }
  return results;
}

// ES2025: Using Array.fromAsync with async generator
async function* processSequentially(items) {
  for (const item of items) {
    yield await processItem(item);
  }
}
const results = await Array.fromAsync(processSequentially(items));
```

## Parallel Execution

```javascript
// All at once
async function parallel(items) {
  return Promise.all(items.map(item => processItem(item)));
}
```

## Batched Execution

```javascript
// N at a time
async function batched(items, batchSize) {
  const results = [];
  for (let i = 0; i < items.length; i += batchSize) {
    const batch = items.slice(i, i + batchSize);
    const batchResults = await Promise.all(
      batch.map(item => processItem(item))
    );
    results.push(...batchResults);
  }
  return results;
}
```

## Concurrency Pool

```javascript
async function pool(items, concurrency, fn) {
  const results = [];
  const executing = new Set();

  for (const item of items) {
    const promise = fn(item).then(result => {
      executing.delete(promise);
      return result;
    });
    results.push(promise);
    executing.add(promise);

    if (executing.size >= concurrency) {
      await Promise.race(executing);
    }
  }

  return Promise.all(results);
}

// Process 100 items, max 5 concurrent
await pool(items, 5, processItem);
```

## Retry Pattern

```javascript
async function withRetry(fn, { retries = 3, delay = 1000, backoff = 2 } = {}) {
  let lastError;

  for (let attempt = 0; attempt < retries; attempt++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error;
      if (attempt < retries - 1) {
        await new Promise(r => setTimeout(r, delay * backoff ** attempt));
      }
    }
  }

  throw lastError;
}

const data = await withRetry(() => fetchData(), {
  retries: 5,
  delay: 500,
  backoff: 2
});
```

## Timeout Wrapper

```javascript
// ES2024: Using Promise.withResolvers()
function withTimeout(promise, ms, message = 'Timeout') {
  const { promise: timeout, reject } = Promise.withResolvers();
  setTimeout(() => reject(new Error(message)), ms);
  return Promise.race([promise, timeout]);
}

const data = await withTimeout(fetchData(), 5000);
```

## Debounce Async

```javascript
// ES2024: Using Promise.withResolvers()
function debounceAsync(fn, ms) {
  let timeoutId;
  let pending = null;

  return (...args) => {
    clearTimeout(timeoutId);
    pending?.reject?.(new Error('Debounced'));

    const { promise, resolve, reject } = Promise.withResolvers();
    pending = { reject };

    timeoutId = setTimeout(async () => {
      try {
        resolve(await fn(...args));
      } catch (error) {
        reject(error);
      }
    }, ms);

    return promise;
  };
}

const debouncedSearch = debounceAsync(searchAPI, 300);
```

## Throttle Async

```javascript
function throttleAsync(fn, ms) {
  let lastCall = 0;
  let pending = null;

  return async (...args) => {
    const now = Date.now();
    const timeSinceLastCall = now - lastCall;

    if (timeSinceLastCall >= ms) {
      lastCall = now;
      return fn(...args);
    }

    if (!pending) {
      pending = new Promise(resolve => {
        setTimeout(async () => {
          lastCall = Date.now();
          pending = null;
          resolve(await fn(...args));
        }, ms - timeSinceLastCall);
      });
    }

    return pending;
  };
}
```

## Async Iteration

### for-await-of

```javascript
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
```

### Async Generators

```javascript
async function* streamData(source) {
  const reader = source.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      yield value;
    }
  } finally {
    reader.releaseLock();
  }
}
```

### Process Stream in Chunks

```javascript
async function* chunkStream(stream, chunkSize) {
  let buffer = [];
  for await (const item of stream) {
    buffer.push(item);
    if (buffer.length >= chunkSize) {
      yield buffer;
      buffer = [];
    }
  }
  if (buffer.length > 0) {
    yield buffer;
  }
}

for await (const chunk of chunkStream(dataStream, 100)) {
  await processBatch(chunk);
}
```

## Cancellation Patterns

### AbortController

```javascript
async function fetchWithCancel(url, signal) {
  const response = await fetch(url, { signal });
  return response.json();
}

const controller = new AbortController();

// Start fetch
const promise = fetchWithCancel('/api/data', controller.signal);

// Cancel after 5 seconds
setTimeout(() => controller.abort(), 5000);

try {
  const data = await promise;
} catch (error) {
  if (error.name === 'AbortError') {
    console.log('Request was cancelled');
  }
}
```

### Cancellable Operations

```javascript
function createCancellableOperation(fn) {
  const controller = new AbortController();

  const promise = (async () => {
    try {
      return await fn(controller.signal);
    } catch (error) {
      if (error.name === 'AbortError') {
        return { cancelled: true };
      }
      throw error;
    }
  })();

  return {
    promise,
    cancel: () => controller.abort()
  };
}

const { promise, cancel } = createCancellableOperation(async (signal) => {
  const response = await fetch('/api/data', { signal });
  return response.json();
});

// Cancel if needed
cancel();
```

## Semaphore Pattern

```javascript
class Semaphore {
  #permits;
  #queue = [];

  constructor(permits) {
    this.#permits = permits;
  }

  async acquire() {
    if (this.#permits > 0) {
      this.#permits--;
      return;
    }

    const { promise, resolve } = Promise.withResolvers();
    this.#queue.push(resolve);
    return promise;
  }

  release() {
    if (this.#queue.length > 0) {
      const resolve = this.#queue.shift();
      resolve();
    } else {
      this.#permits++;
    }
  }

  async withPermit(fn) {
    await this.acquire();
    try {
      return await fn();
    } finally {
      this.release();
    }
  }
}

// Limit concurrent operations to 3
const semaphore = new Semaphore(3);

await Promise.all(
  items.map(item =>
    semaphore.withPermit(() => processItem(item))
  )
);
```
