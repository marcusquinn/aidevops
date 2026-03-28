---
description: "|"
mode: subagent
imported_from: external
---
# modern-javascript

# Modern JavaScript (ES6-ES2025)

Write clean, performant, maintainable JavaScript using modern language features. This skill covers ES6 through ES2025, emphasizing immutability, functional patterns, and expressive syntax.

## Quick Decision Trees

### "Which array method should I use?"

```
What do I need?
├─ Transform each element           → .map()
├─ Keep some elements               → .filter()
├─ Find one element                 → .find() / .findLast()
├─ Check if condition met           → .some() / .every()
├─ Reduce to single value           → .reduce()
├─ Get last element                 → .at(-1)
├─ Sort without mutating            → .toSorted()
├─ Reverse without mutating         → .toReversed()
├─ Group by property                → Object.groupBy()
└─ Flatten nested arrays            → .flat() / .flatMap()
```

### "How do I handle nullish values?"

```
Nullish handling?
├─ Safe property access              → obj?.prop / obj?.[key]
├─ Safe method call                  → obj?.method?.()
├─ Default for null/undefined only   → value ?? 'default'
├─ Default for any falsy             → value || 'default'
├─ Assign if null/undefined          → obj.prop ??= 'default'
└─ Check property exists             → Object.hasOwn(obj, 'key')
```

### "Should I mutate or copy?"

```
Always prefer non-mutating methods:
├─ Sort array      → .toSorted()    (not .sort())
├─ Reverse array   → .toReversed()  (not .reverse())
├─ Splice array    → .toSpliced()   (not .splice())
├─ Update element  → .with(i, val)  (not arr[i] = val)
├─ Add to array    → [...arr, item] (not .push())
└─ Merge objects   → {...obj, key}  (not Object.assign())
```

## ES Version Quick Reference

| Version | Year | Key Features |
|---------|------|--------------|
| ES6 | 2015 | let/const, arrow functions, classes, destructuring, spread, Promises, modules, Symbol, Map/Set, Proxy, generators |
| ES2016 | 2016 | Array.includes(), exponentiation operator ** |
| ES2017 | 2017 | async/await, Object.values/entries, padStart/padEnd, trailing commas, SharedArrayBuffer, Atomics |
| ES2018 | 2018 | Rest/spread for objects, for await...of, Promise.finally(), RegExp named groups, lookbehind, dotAll flag |
| ES2019 | 2019 | .flat(), .flatMap(), Object.fromEntries(), trimStart/End(), optional catch binding, stable Array.sort() |
| ES2020 | 2020 | Optional chaining ?., nullish coalescing ??, BigInt, Promise.allSettled(), globalThis, dynamic import() |
| ES2021 | 2021 | String.replaceAll(), Promise.any(), logical assignment ??= and or=, numeric separators 1_000_000 |
| ES2022 | 2022 | .at(), Object.hasOwn(), top-level await, private class fields #field, static blocks, Error.cause |
| ES2023 | 2023 | .toSorted(), .toReversed(), .toSpliced(), .with(), .findLast(), .findLastIndex(), hashbang grammar |
| ES2024 | 2024 | Object.groupBy(), Map.groupBy(), Promise.withResolvers(), RegExp v flag, resizable ArrayBuffer |
| ES2025 | 2025 | Iterator helpers (.map, .filter, .take), Set methods (.union, .intersection), RegExp.escape(), using/await using |

## Modernization Patterns

```javascript
// Array access (ES2022)
const last = arr.at(-1);
const secondLast = arr.at(-2);

// Non-mutating array ops (ES2023) — never mutate with .sort()/.reverse()/.splice()
const sorted = arr.toSorted((a, b) => a - b);
const reversed = arr.toReversed();
const updated = arr.with(2, 'new value');
const removed = arr.toSpliced(1, 1);

// String replacement (ES2021)
const result = str.replaceAll('foo', 'bar'); // not str.replace(/foo/g, 'bar')

// Grouping (ES2024) — replaces verbose .reduce() accumulator pattern
const grouped = Object.groupBy(items, item => item.category);

// Nullish handling — ?? and ?. only match null/undefined, not 0/''/false
const value = input ?? 'default';           // not input || 'default'
const name = user?.profile?.name;           // not user && user.profile && ...

// Property existence (ES2022) — hasOwnProperty can be overwritten
if (Object.hasOwn(obj, 'key')) { }

// Logical assignment (ES2021)
obj.prop ??= 'default';  // Assign if null/undefined
obj.count ||= 0;         // Assign if falsy
obj.enabled &&= check(); // Assign if truthy
```

## Async Patterns

### Promise Combinators

```javascript
// Wait for all, fail if any fails
const [users, posts] = await Promise.all([fetchUsers(), fetchPosts()]);

// Wait for all, get status of each
const results = await Promise.allSettled([fetchA(), fetchB()]);
results.forEach(r => {
  if (r.status === 'fulfilled') console.log(r.value);
  else console.error(r.reason);
});

// First to succeed
const fastest = await Promise.any([fetchFromCDN1(), fetchFromCDN2()]);

// First to settle
const winner = await Promise.race([fetchData(), timeout(5000)]);
```

### Promise.withResolvers (ES2024) and Top-Level Await (ES2022)

```javascript
// Expose resolve/reject outside constructor (replaces let resolve, reject + new Promise)
const { promise, resolve, reject } = Promise.withResolvers();

// Top-level await in ES modules
const config = await fetch('/config.json').then(r => r.json());
const db = await connectDatabase(config);
export { db };
```

## Functional Patterns

### Immutable Object Updates

```javascript
const updated = { ...user, age: 31 };                               // Add/update
const { password, ...userWithoutPassword } = user;                  // Remove
const nested = { ...state, user: { ...state.user, name: 'New' } }; // Nested
```

### Array Transformations

```javascript
// flatMap for filter+map in single pass
const activeNames = users.flatMap(u => u.active ? [u.name] : []);

// ES2024: Group then process
const byStatus = Object.groupBy(users, u => u.active ? 'active' : 'inactive');
const activeNames = byStatus.active?.map(u => u.name) ?? [];
```

### Composition

```javascript
const pipe = (...fns) => x => fns.reduce((v, f) => f(v), x);

const processUser = pipe(
  user => ({ ...user, name: user.name.trim() }),
  user => ({ ...user, email: user.email.toLowerCase() }),
  user => ({ ...user, createdAt: new Date() })
);
```

## Destructuring Patterns

```javascript
// Object: rename, default, nested, rest
const { name: userName, age = 18 } = user;
const { address: { city, country } } = user;
const { id, ...userData } = user;

// Array: skip, rest, swap, function returns
const [first, , third] = array;
const [head, ...tail] = array;
[a, b] = [b, a];
const [x, y] = getCoordinates();
```

## Reference Documentation

### ES Version References

| File | Purpose |
|------|---------|
| [modern-javascript-skill/es2016-es2017.md](modern-javascript-skill/es2016-es2017.md) | includes, async/await, Object.values/entries, string padding |
| [modern-javascript-skill/es2018-es2019.md](modern-javascript-skill/es2018-es2019.md) | rest/spread objects, flat/flatMap, RegExp named groups |
| [modern-javascript-skill/es2022-es2023.md](modern-javascript-skill/es2022-es2023.md) | .at(), .toSorted(), .toReversed(), .findLast(), class features |
| [modern-javascript-skill/es2024.md](modern-javascript-skill/es2024.md) | Object.groupBy, Promise.withResolvers, RegExp v flag |
| [modern-javascript-skill/es2025.md](modern-javascript-skill/es2025.md) | Set methods, iterator helpers, using/await using |
| [modern-javascript-skill/upcoming.md](modern-javascript-skill/upcoming.md) | Temporal API, Decorators, Decorator Metadata |

### Pattern References

| File | Purpose |
|------|---------|
| [modern-javascript-skill/promises.md](modern-javascript-skill/promises.md) | Promise fundamentals, async/await, combinators |
| [modern-javascript-skill/concurrency.md](modern-javascript-skill/concurrency.md) | Parallel, batched, pool patterns, retry, cancellation |
| [modern-javascript-skill/immutability.md](modern-javascript-skill/immutability.md) | Immutable data patterns, pure functions |
| [modern-javascript-skill/composition.md](modern-javascript-skill/composition.md) | Higher-order functions, memoization, monads |
| [modern-javascript-skill/cheatsheet.md](modern-javascript-skill/cheatsheet.md) | Quick syntax reference |

## Resources

- **ECMAScript Specification**: https://tc39.es/ecma262/
- **TC39 Proposals**: https://github.com/tc39/proposals
- **MDN Web Docs**: https://developer.mozilla.org/en-US/docs/Web/JavaScript
- **JavaScript.info**: https://javascript.info/
- **Can I Use**: https://caniuse.com
- **Node.js ES Compatibility**: https://node.green/
