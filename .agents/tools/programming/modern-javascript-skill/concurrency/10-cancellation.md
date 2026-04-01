# Cancellation

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
