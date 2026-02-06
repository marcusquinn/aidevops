# Promises and Async/Await

Promise creation, Promise.withResolvers(), async/await, try/catch, error-first returns, top-level await, Promise.all(), Promise.allSettled(), Promise.race(), Promise.any(), anti-patterns to avoid.

## Promise Fundamentals

### Creating Promises

```javascript
// Basic Promise
const promise = new Promise((resolve, reject) => {
  setTimeout(() => {
    if (success) {
      resolve(result);
    } else {
      reject(new Error('Failed'));
    }
  }, 1000);
});

// ES2024: Promise.withResolvers()
const { promise, resolve, reject } = Promise.withResolvers();
// Control from outside
someEvent.on('complete', resolve);
someEvent.on('error', reject);

// Already resolved/rejected
const resolved = Promise.resolve(42);
const rejected = Promise.reject(new Error('Failed'));
```

### Promise Chaining

> **Prefer async/await** (see below) for most cases. Use `.then()` for simple transforms or when you need the callback style.

```javascript
fetchUser(userId)
  .then(user => fetchPosts(user.id))
  .then(posts => processPosts(posts))
  .then(result => console.log(result))
  .catch(error => console.error(error))
  .finally(() => cleanup());
```

## Async/Await

### Basic Usage

```javascript
async function getUserData(userId) {
  try {
    const user = await fetchUser(userId);
    const posts = await fetchPosts(user.id);
    const comments = await fetchComments(posts[0].id);
    return { user, posts, comments };
  } catch (error) {
    console.error('Failed to get user data:', error);
    throw error;
  }
}
```

### Error Handling Patterns

```javascript
// Try/catch
async function withTryCatch() {
  try {
    const result = await riskyOperation();
    return result;
  } catch (error) {
    return defaultValue;
  }
}

// Error-first return (Go-style)
async function withErrorReturn() {
  try {
    const result = await riskyOperation();
    return [null, result];
  } catch (error) {
    return [error, null];
  }
}

const [error, data] = await withErrorReturn();
if (error) handleError(error);
else processData(data);

// Wrapper utility
function to(promise) {
  return promise
    .then(data => [null, data])
    .catch(error => [error, null]);
}

const [err, user] = await to(fetchUser(id));
```

### Top-Level Await (ES2022)

```javascript
// In ES modules (not CommonJS)
const config = await loadConfig();
const db = await connectDatabase(config);

export { db };
```

## Promise Combinators

### Promise.all()

Wait for all promises; fail if any fails.

```javascript
// Parallel execution
const [users, posts, comments] = await Promise.all([
  fetchUsers(),
  fetchPosts(),
  fetchComments()
]);

// With error handling
try {
  const results = await Promise.all([taskA(), taskB(), taskC()]);
} catch (error) {
  // Any rejection cancels all
  console.error('One task failed:', error);
}
```

### Promise.allSettled()

Wait for all; get status of each.

```javascript
const results = await Promise.allSettled([
  fetchFromPrimary(),
  fetchFromBackup(),
  fetchFromCache()
]);

const successes = results
  .filter(r => r.status === 'fulfilled')
  .map(r => r.value);

const failures = results
  .filter(r => r.status === 'rejected')
  .map(r => r.reason);
```

### Promise.race()

First to settle (resolve or reject) wins.

```javascript
// Timeout pattern (ES2024)
async function fetchWithTimeout(url, ms) {
  const { promise: timeout, reject } = Promise.withResolvers();
  const timerId = setTimeout(() => reject(new Error('Timeout')), ms);

  try {
    return await Promise.race([fetch(url), timeout]);
  } finally {
    clearTimeout(timerId);
  }
}

// First responder
const data = await Promise.race([
  fetchFromServer1(),
  fetchFromServer2()
]);
```

### Promise.any()

First to succeed wins; fails only if all fail.

```javascript
// Fallback pattern
try {
  const data = await Promise.any([
    fetchFromPrimary(),
    fetchFromSecondary(),
    fetchFromTertiary()
  ]);
} catch (error) {
  // AggregateError with all failures
  console.error('All sources failed:', error.errors);
}
```

## Anti-Patterns

### Unnecessary async

```javascript
// ❌ Unnecessary wrapper
async function getUser(id) {
  return await fetchUser(id);
}

// ✅ Just return the promise
function getUser(id) {
  return fetchUser(id);
}
```

### Sequential when parallel is possible

```javascript
// ❌ Sequential (slow)
const users = await fetchUsers();
const posts = await fetchPosts();
const comments = await fetchComments();

// ✅ Parallel (fast)
const [users, posts, comments] = await Promise.all([
  fetchUsers(),
  fetchPosts(),
  fetchComments()
]);
```

### Forgetting error handling

```javascript
// ❌ Unhandled rejection
async function process() {
  const data = await fetchData();  // If this fails, crash
  return transform(data);
}

// ✅ Handle errors
async function process() {
  try {
    const data = await fetchData();
    return transform(data);
  } catch (error) {
    logger.error('Processing failed:', error);
    throw error;  // or return fallback
  }
}
```

### Mixing callbacks and promises

```javascript
// ❌ Callback hell in async function
async function mixed() {
  fs.readFile('file.txt', (err, data) => {
    // This doesn't work with await
  });
}

// ✅ Promisify callbacks
import { promisify } from 'util';
const readFile = promisify(fs.readFile);

async function clean() {
  const data = await readFile('file.txt');
  return data;
}

// Or use fs.promises
import { readFile } from 'fs/promises';
```

### Creating promise inside loop

```javascript
// ❌ Promises created but not awaited properly
async function bad() {
  items.forEach(async item => {
    await processItem(item);  // This doesn't wait!
  });
  // Function returns before items are processed
}

// ✅ Use for...of for sequential
async function sequential() {
  for (const item of items) {
    await processItem(item);
  }
}

// ✅ Use Promise.all for parallel
async function parallel() {
  await Promise.all(items.map(item => processItem(item)));
}
```
