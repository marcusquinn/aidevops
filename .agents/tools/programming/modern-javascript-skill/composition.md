# Function Composition and Higher-Order Functions

Currying, partial application, pipe, compose, point-free style, memoization with TTL and LRU, Maybe monad, Result monad, transducers, debounce, throttle, once.

## Higher-Order Functions

```javascript
// Functions as arguments: map, filter, reduce
const doubled = [1, 2, 3].map(x => x * 2);
const evens = [1, 2, 3, 4].filter(x => x % 2 === 0);
const sum = [1, 2, 3].reduce((acc, x) => acc + x, 0);

// Custom higher-order function
function unless(predicate, fn) {
  return (...args) => {
    if (!predicate(...args)) return fn(...args);
  };
}
const logUnlessEmpty = unless(arr => arr.length === 0, arr => console.log(arr));

// Partial application
const partial = (fn, ...presetArgs) =>
  (...laterArgs) => fn(...presetArgs, ...laterArgs);
const greet = (greeting, name) => `${greeting}, ${name}!`;
const sayHello = partial(greet, 'Hello');
sayHello('Alice');  // "Hello, Alice!"

// Closure for state
function counter(start = 0) {
  let count = start;
  return {
    increment: () => ++count,
    decrement: () => --count,
    get: () => count
  };
}
```

## Function Composition

```javascript
// Right-to-left composition
const compose = (...fns) => x =>
  fns.reduceRight((acc, fn) => fn(acc), x);

// Left-to-right composition (pipe)
const pipe = (...fns) => x =>
  fns.reduce((acc, fn) => fn(acc), x);

const processText = pipe(
  str => str.trim(),
  str => str.toLowerCase(),
  str => str.replace(/\s+/g, '-')
);
processText('  Hello World  ');  // 'hello-world'
```

### Point-Free Style

```javascript
const prop = key => obj => obj[key];
const map = fn => arr => arr.map(fn);
const filter = fn => arr => arr.filter(fn);

// Before: const getNames = users => users.map(user => user.name);
// After (point-free):
const getNames = pipe(map(prop('name')));

const isPositive = n => n > 0;
const not = fn => (...args) => !fn(...args);
const isNegative = not(isPositive);
const getPositive = filter(isPositive);
```

## Memoization

```javascript
// Basic memoization
function memoize(fn) {
  const cache = new Map();
  return (...args) => {
    const key = JSON.stringify(args);
    if (cache.has(key)) return cache.get(key);
    const result = fn(...args);
    cache.set(key, result);
    return result;
  };
}

const fibonacci = memoize(n => {
  if (n <= 1) return n;
  return fibonacci(n - 1) + fibonacci(n - 2);
});

// Memoization with TTL
function memoizeWithTTL(fn, ttl) {
  const cache = new Map();
  return (...args) => {
    const key = JSON.stringify(args);
    const cached = cache.get(key);
    if (cached && Date.now() - cached.timestamp < ttl) return cached.value;
    const value = fn(...args);
    cache.set(key, { value, timestamp: Date.now() });
    return value;
  };
}
const fetchUser = memoizeWithTTL(
  id => fetch(`/api/users/${id}`).then(r => r.json()),
  60000  // 1 minute TTL
);

// Memoization with LRU eviction
function memoizeLRU(fn, maxSize = 100) {
  const cache = new Map();
  return (...args) => {
    const key = JSON.stringify(args);
    if (cache.has(key)) {
      const value = cache.get(key);
      cache.delete(key);
      cache.set(key, value);  // Move to end (most recent)
      return value;
    }
    const result = fn(...args);
    cache.set(key, result);
    if (cache.size > maxSize) {
      cache.delete(cache.keys().next().value);
    }
    return result;
  };
}
```

## Functor and Monad Patterns

### Maybe (Optional)

```javascript
class Maybe {
  constructor(value) { this.value = value; }
  static of(value) { return new Maybe(value); }
  isNothing() { return this.value === null || this.value === undefined; }
  map(fn) { return this.isNothing() ? this : Maybe.of(fn(this.value)); }
  flatMap(fn) { return this.isNothing() ? this : fn(this.value); }
  getOrElse(defaultValue) { return this.isNothing() ? defaultValue : this.value; }
}

const city = Maybe.of({ name: 'Alice', address: { city: 'NYC' } })
  .map(u => u.address)
  .map(a => a.city)
  .getOrElse('Unknown');

// For most cases, optional chaining is simpler:
// const city = user?.address?.city ?? 'Unknown';
```

### Result (Either)

```javascript
class Result {
  constructor(value, error) { this.value = value; this.error = error; }
  static ok(value) { return new Result(value, null); }
  static err(error) { return new Result(null, error); }
  isOk() { return this.error === null; }
  map(fn) { return this.isOk() ? Result.ok(fn(this.value)) : this; }
  mapError(fn) { return this.isOk() ? this : Result.err(fn(this.error)); }
  unwrap() { if (this.isOk()) return this.value; throw this.error; }
  unwrapOr(defaultValue) { return this.isOk() ? this.value : defaultValue; }
}

function divide(a, b) {
  if (b === 0) return Result.err('Division by zero');
  return Result.ok(a / b);
}
const result = divide(10, 2).map(x => x * 2).map(x => x + 1).unwrapOr(0);  // 11
```

## Transducers

```javascript
// Composable transformations without intermediate arrays
// Note: map/filter here are transducer versions (reducer → reducer), not array versions above
const mapT = fn => reducer => (acc, x) => reducer(acc, fn(x));
const filterT = pred => reducer => (acc, x) => pred(x) ? reducer(acc, x) : acc;

const transduce = (xform, reducer, init, coll) =>
  coll.reduce(xform(reducer), init);

const xform = compose(
  filterT(x => x % 2 === 0),
  mapT(x => x * 2)
);
const result = transduce(xform, (acc, x) => [...acc, x], [], [1, 2, 3, 4, 5]);
// [4, 8] - only one iteration through the array
```

## Practical Utilities

```javascript
// General-purpose curry
function curry(fn) {
  return function curried(...args) {
    if (args.length >= fn.length) return fn.apply(this, args);
    return (...more) => curried(...args, ...more);
  };
}
const add = curry((a, b, c) => a + b + c);
add(1)(2)(3);   // 6
add(1, 2)(3);   // 6
add(1, 2, 3);   // 6

// Debounce — delays execution until ms after last call
function debounce(fn, ms) {
  let timeoutId;
  return (...args) => {
    clearTimeout(timeoutId);
    timeoutId = setTimeout(() => fn(...args), ms);
  };
}

// Throttle — limits execution to once per ms
function throttle(fn, ms) {
  let lastCall = 0;
  return (...args) => {
    const now = Date.now();
    if (now - lastCall >= ms) {
      lastCall = now;
      return fn(...args);
    }
  };
}

// Once — executes fn only on first call, returns cached result after
function once(fn) {
  let called = false, result;
  return (...args) => {
    if (!called) { called = true; result = fn(...args); }
    return result;
  };
}
```

## Best Practices

1. **Pure functions** — isolate side effects to application edges
2. **Immutable updates** — return new data, never mutate
3. **Compose small functions** — build complex behavior from simple parts
4. **Higher-order functions** — map/filter/reduce over loops
5. **Memoize expensive computations** — cache results of pure functions
6. **Avoid shared mutable state** — pass data explicitly
7. **Make side effects explicit** — clearly mark impure functions
8. **Use const by default** — prevent accidental reassignment
