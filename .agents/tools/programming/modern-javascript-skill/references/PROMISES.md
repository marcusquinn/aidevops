# Promises and Async/Await

## Promise Creation

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

## Async/Await

```javascript
async function getUserData(userId) {
  try {
    const user = await fetchUser(userId);
    const posts = await fetchPosts(user.id);
    return { user, posts };
  } catch (error) {
    throw error;
  }
}
```

### Error Handling Patterns

```javascript
// try/catch
try { return await riskyOp(); } catch { return defaultValue; }

// Error-first return (Go-style)
async function safe() {
  try { return [null, await riskyOp()]; }
  catch (e) { return [e, null]; }
}
const [err, data] = await safe();

// Wrapper utility
const to = p => p.then(d => [null, d]).catch(e => [e, null]);
const [err, user] = await to(fetchUser(id));
```

### Top-Level Await (ES2022, ES modules only)

```javascript
const config = await loadConfig();
export const db = await connectDatabase(config);
```

## Promise Combinators

| Method | Behaviour | Use when |
|--------|-----------|----------|
| `Promise.all(arr)` | Resolves when all resolve; rejects on first rejection | All must succeed |
| `Promise.allSettled(arr)` | Resolves when all settle; returns `{status, value/reason}[]` | Need all results regardless of failure |
| `Promise.race(arr)` | Settles with first to settle (resolve or reject) | Timeout patterns, first responder |
| `Promise.any(arr)` | Resolves with first success; rejects (`AggregateError`) only if all fail | Fallback sources |

```javascript
// all — parallel fetch
const [users, posts] = await Promise.all([fetchUsers(), fetchPosts()]);

// allSettled — partial results
const results = await Promise.allSettled([primary(), backup(), cache()]);
const ok = results.filter(r => r.status === 'fulfilled').map(r => r.value);

// race — timeout (ES2024)
async function fetchWithTimeout(url, ms) {
  const { promise: timeout, reject } = Promise.withResolvers();
  const id = setTimeout(() => reject(new Error('Timeout')), ms);
  try { return await Promise.race([fetch(url), timeout]); }
  finally { clearTimeout(id); }
}

// any — fallback
const data = await Promise.any([primary(), secondary(), tertiary()]);
// throws AggregateError (error.errors[]) if all fail
```

## Anti-Patterns

| Anti-pattern | Fix |
|--------------|-----|
| `async function f() { return await p; }` | `function f() { return p; }` — no wrapper needed |
| Sequential awaits for independent ops | `Promise.all([a(), b(), c()])` |
| `async` callback in `forEach` | `for...of` (sequential) or `Promise.all(arr.map(...))` (parallel) |
| Unhandled rejection | Wrap in `try/catch` or `.catch()` |
| Callback inside `async` function | `promisify(fn)` or `fs/promises` |

```javascript
// forEach trap — items not awaited
items.forEach(async item => await processItem(item)); // ❌

for (const item of items) await processItem(item);                    // ✅ sequential
await Promise.all(items.map(item => processItem(item)));              // ✅ parallel
```
